"""Speech recognition with Whisper large-v3-turbo on MLX.

The build is the 8-bit quantisation of mlx-community/whisper-large-v3-turbo
at group size 64. Measured on 111 real recordings against the full-precision
build, routing decisions were identical on all 108 that were routed and
transcripts word-identical on 103, at 833 MB against 1543 MB.
"""
from __future__ import annotations

import pathlib
import sys
import time
import types
from dataclasses import dataclass
from importlib.metadata import version

import numpy as np

from .audio import SAMPLE_RATE

# The only mlx-whisper this module has been checked against. It reaches into
# the package's import graph below, which a new release may change.
MLX_WHISPER_VERSION = "0.4.3"

# S1-mini covers English only, so dictation is English only. Pinning the
# language also skips Whisper's language detection, a second encoder pass that
# costs as much as the transcription it precedes.
LANGUAGE = "en"

# Whisper's own threshold for a decode it could not trust: mlx-whisper retries
# below it at a higher temperature, so a decode still below it afterwards was
# refused twice. A hallucinated "Thank you." from room noise scored -1.85
# while real dictations scored around -0.2.
MIN_AVG_LOGPROB = -1.0

# Whisper's own threshold for the other way a decode goes wrong: a repetition
# loop, where it repeats a phrase until the token budget runs out. Log
# probability cannot see it: a loop from 5.3 seconds of humming scored -0.179,
# better than the median dictation, with a compression ratio of 9.16 against
# a maximum of 1.797 across 122 real dictations.
MAX_COMPRESSION_RATIO = 2.4


@dataclass(frozen=True)
class Transcription:
    """One recognised utterance, and the decode statistics that say whether to trust it."""

    text: str
    audio_seconds: float
    asr_ms: float
    avg_logprob_min: float
    compression_ratio_max: float


def _import_mlx_whisper():
    """Import mlx-whisper without its word-timestamp module.

    mlx_whisper.transcribe imports mlx_whisper.timing at module level, and
    timing imports numba and scipy: 231 MB with llvmlite, measured installed.
    They serve only word-level timestamps, which dictation never asks for. So
    the timing module is registered in advance as one that refuses to run, and
    numba and scipy are not installed. Asking for word timestamps fails
    loudly instead of silently returning none.
    """
    installed = version("mlx-whisper")
    if installed != MLX_WHISPER_VERSION:
        raise RuntimeError(
            f"PrivacyFlow replaces mlx-whisper {MLX_WHISPER_VERSION}'s timing module, "
            f"but mlx-whisper {installed} is installed")

    def add_word_timestamps(*args, **kwargs):
        raise RuntimeError("word timestamps are not installed in PrivacyFlow's worker")

    timing = types.ModuleType("mlx_whisper.timing")
    timing.add_word_timestamps = add_word_timestamps
    sys.modules["mlx_whisper.timing"] = timing

    import mlx_whisper

    return mlx_whisper


class Recognizer:
    """A resident Whisper, loaded once from a local build."""

    def __init__(self, model_dir: pathlib.Path) -> None:
        import mlx.core as mx

        # mlx-whisper treats a path that does not exist as a Hub repo id, which
        # would fail with a confusing offline-download error.
        if not (model_dir / "config.json").is_file():
            raise RuntimeError(f"the Whisper model is missing at {model_dir}")
        self.mlx_whisper = _import_mlx_whisper()
        self.model_path = str(model_dir)
        # transcribe() keeps one process-wide model, keyed by path and loaded
        # with the float16 activations it asks for. Loading it here with the
        # same key makes every transcription reuse this instance.
        from mlx_whisper.transcribe import ModelHolder

        self.model = ModelHolder.get_model(self.model_path, mx.float16)

    def transcribe(self, samples: np.ndarray) -> Transcription:
        """Transcribe mono float32 samples at 16 kHz."""
        import mlx.core as mx

        started = time.perf_counter()
        result = self.mlx_whisper.transcribe(samples, path_or_hf_repo=self.model_path, language=LANGUAGE)
        # MLX runs asynchronously, so the time only means something once the
        # work has landed.
        mx.synchronize()
        asr_ms = (time.perf_counter() - started) * 1000.0

        segments = result.get("segments") or []
        return Transcription(
            text=result["text"].strip(),
            audio_seconds=len(samples) / SAMPLE_RATE,
            asr_ms=asr_ms,
            avg_logprob_min=min((s["avg_logprob"] for s in segments), default=0.0),
            compression_ratio_max=max((s["compression_ratio"] for s in segments), default=0.0),
        )

    def warm_up(self) -> None:
        """Spend MLX's one-time first-inference cost before the user dictates."""
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))
