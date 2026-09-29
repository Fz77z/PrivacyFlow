"""Reading the app's recorded utterance.

The app records 16 kHz mono 16-bit WAV, which is exactly what Whisper and the
speech gate consume. Anything else is refused rather than converted: a
different rate means the app and the worker disagree about the contract, and
resampling here would hide that.
"""
from __future__ import annotations

import pathlib
import wave

import numpy as np

SAMPLE_RATE = 16_000


def read_utterance(path: pathlib.Path) -> np.ndarray:
    """Read one utterance as float32 samples in [-1, 1), refusing any other format."""
    with wave.open(str(path)) as handle:
        channels, width, rate = handle.getnchannels(), handle.getsampwidth(), handle.getframerate()
        if (channels, width, rate) != (1, 2, SAMPLE_RATE):
            raise ValueError(
                f"the recording must be 16 kHz mono 16-bit WAV, got {rate} Hz, "
                f"{channels} channel(s), {8 * width}-bit")
        # WAV is little-endian by definition, so the dtype fixes the byte order
        # rather than inheriting this machine's.
        samples = np.frombuffer(handle.readframes(handle.getnframes()), dtype="<i2")
    return samples.astype(np.float32) / 32768.0
