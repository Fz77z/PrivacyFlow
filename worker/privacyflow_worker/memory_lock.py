"""Keeping the model weights resident, so an idle machine cannot page them out.

macOS compresses and swaps memory that has not been touched for a while. On a
machine under memory pressure, the first dictation after a long idle spent 5
to 22 seconds bringing the weights back. Wiring every weight buffer with
mlock(2) takes them out of reach of the compressor and the pager entirely.

MLX keeps each array in unified memory that the CPU can address, and exposes
it through Python's buffer protocol without copying. The buffer protocol has
no format for bfloat16, so each array is first viewed as an unsigned integer
array of the same item size, which shares the buffer rather than copying it.
The tests hold this to writing through the returned address and seeing the
original array change.
"""
from __future__ import annotations

import ctypes
import os
from typing import Callable, Iterable

import numpy as np

_UNSIGNED = {1: "uint8", 2: "uint16", 4: "uint32", 8: "uint64"}


class MemoryLockFailed(RuntimeError):
    """The weights could not be wired, so the worker must not start."""


def buffer_of(array) -> tuple[int, int]:
    """The address and length in bytes of an evaluated MLX array's live buffer."""
    import mlx.core as mx

    view = array.view(getattr(mx, _UNSIGNED[array.dtype.size]))
    mx.eval(view)
    memory = memoryview(view)
    if not memory.c_contiguous or memory.nbytes != array.nbytes:
        raise MemoryLockFailed(f"a weight of shape {array.shape} is not one contiguous buffer")
    address = np.frombuffer(memory, dtype=np.uint8).__array_interface__["data"][0]
    return address, memory.nbytes


def _libc_mlock() -> Callable[[int, int], int]:
    """mlock(2) from the C library, returning 0 or -1 with errno set."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mlock.argtypes = (ctypes.c_void_p, ctypes.c_size_t)
    libc.mlock.restype = ctypes.c_int
    return libc.mlock


def lock(arrays: Iterable, mlock: Callable[[int, int], int] | None = None) -> int:
    """Wire every array's buffer into physical memory, returning the bytes locked.

    Buffers shared between arrays are locked once. Any failure is raised, with
    the reason macOS gave: running with the weights unlocked would bring the
    multi-second stalls back without anyone knowing.
    """
    mlock = mlock or _libc_mlock()
    buffers: dict[int, int] = {}
    for array in arrays:
        address, length = buffer_of(array)
        buffers[address] = max(buffers.get(address, 0), length)

    total = sum(buffers.values())
    for address, length in buffers.items():
        if mlock(address, length) != 0:
            reason = os.strerror(ctypes.get_errno())
            raise MemoryLockFailed(
                f"could not lock the {total / 1e9:.2f} GB of model weights in memory "
                f"({reason}); without the lock macOS can page them out while idle")
    return total
