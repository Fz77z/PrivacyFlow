"""The worker process: loads the models once, then answers the app over JSON lines.

stdin carries one request per line and stdout one reply per request, in
order. Only the protocol reaches stdout: everything else in this process runs
with stdout redirected to stderr, because a stray print from any library would
shift every later reply onto the wrong request. docs/architecture.md is the
contract.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import pathlib
import sys
import time
import traceback
from importlib.metadata import version
from typing import Callable, Iterable

import numpy as np

# The subdirectories of the models directory, named as in the app's models.json.
WHISPER_DIR = "whisper-large-v3-turbo-mlx-q8"
ROUTER_DIR = "kev-router-v6-mlx"
REWRITER_DIR = "s1-mini-mlx-q8"

# mlx-lm is installed without its declared dependencies, because it declares
# transformers>=5 and every S1-mini rewrite was validated under 4.57.6. With
# no resolver checking the pair, these are checked here: the router and the
# rewriter call mlx-lm's internal load_model() and cache, which a new release
# may change, and a drifted tokenizer would show up as subtly wrong text.
PINNED = {"mlx-lm": "0.31.3", "transformers": "4.57.6"}

# Below this level the capture is room noise rather than speech: across one
# machine's presses, silence measured 0.00061 to 0.00129 RMS and the quietest
# real dictation 0.00223, so the floor sits in the middle of that gap.
SILENCE_RMS = 0.0017
MIN_SECONDS = 0.35

PREPARE_TEXT = "this is a warm up utterance for the router"


class NoSpeech(Exception):
    """The capture held no speech. A non-event for the user, not a failure."""


class Unintelligible(Exception):
    """Whisper heard speech and could not make sense of it.

    Reported to the user, because it threw away words they did say. `detail`
    carries the measurement behind the decision, never what was decoded.
    """

    def __init__(self, audio_seconds: float, detail: str) -> None:
        super().__init__(detail)
        self.audio_seconds = audio_seconds
        self.detail = detail


class ProcessingFailed(Exception):
    """A failure after the transcript existed, carrying it so the app can keep the words."""

    def __init__(self, message: str, transcript: str, rewriter_ran: bool) -> None:
        super().__init__(message)
        self.transcript = transcript
        self.rewriter_ran = rewriter_ran


class Worker:
    """The loaded models, and the handling of one request at a time."""

    def __init__(self, speech_gate, recognizer, router, rewriter) -> None:
        self.speech_gate = speech_gate
        self.recognizer = recognizer
        self.router = router
        self.rewriter = rewriter

    def serve(self, lines: Iterable[str], send: Callable[[dict], None]) -> None:
        """Answer each request line in order, one reply per line.

        S1-mini is warmed after replying to a dictation that did not use it:
        most dictations pass through untouched, so it would otherwise sit idle
        for hours and make the next rewrite pay to wake it. Warming after the
        reply keeps that cost off the dictation that triggered it.

        A failed warm-up is reported on stderr and serving continues, as with a
        failed prepare: it is an optimisation, and a broken S1-mini still fails
        explicitly on the next dictation that needs it.
        """
        for line in lines:
            if not line.strip():
                continue
            reply, rewriter_idle = self.answer(line)
            send(reply)
            if not rewriter_idle:
                continue
            try:
                self.rewriter.warm_up()
            except Exception:
                print("privacyflow worker: warming S1-mini failed", file=sys.stderr)
                traceback.print_exc(file=sys.stderr)

    def answer(self, line: str) -> tuple[dict, bool]:
        """The reply to one request line, and whether it was a dictation that left S1-mini idle."""
        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            return {"error": f"the request is not valid JSON: {error}"}, False
        if not isinstance(request, dict):
            return {"error": "the request must be a JSON object"}, False

        if request.get("prepare") is True:
            return self.prepare(), False
        if "audio_path" in request:
            return self.dictate(request["audio_path"])
        return {"error": f"unknown request with keys {sorted(request)}"}, False

    def prepare(self) -> dict:
        """Route throwaway text so the router is resident before the user releases the key.

        Only the router: every dictation needs it, and the app asks for this
        while the user is still speaking. S1-mini is kept warm after
        dictations instead, off the critical path.
        """
        started = time.perf_counter()
        try:
            self.router.route(PREPARE_TEXT)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            return {"prepared": False, "error": _describe(error)}
        return {"prepared": True, "prepare_ms": _milliseconds_since(started)}

    def dictate(self, audio_path) -> tuple[dict, bool]:
        """Turn one recorded utterance into the reply the app acts on."""
        rewriter_ran = False
        try:
            reply, rewriter_ran = self._dictate(audio_path)
        except NoSpeech:
            reply = {"no_speech": True}
        except Unintelligible as misheard:
            reply = {"unintelligible": True, "audio_seconds": round(misheard.audio_seconds, 2),
                     "detail": misheard.detail}
        except ProcessingFailed as failure:
            traceback.print_exc(file=sys.stderr)
            reply = {"error": _describe(failure), "transcript": failure.transcript}
            rewriter_ran = failure.rewriter_ran
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            reply = {"error": _describe(error)}
        return reply, not rewriter_ran

    def _dictate(self, audio_path) -> tuple[dict, bool]:
        """The dictation pipeline. Returns the success reply and whether S1-mini ran."""
        from .audio import SAMPLE_RATE, read_utterance

        if not isinstance(audio_path, str) or not pathlib.Path(audio_path).is_absolute():
            raise ValueError(f"audio_path must be an absolute path, got {audio_path!r}")
        samples = read_utterance(pathlib.Path(audio_path))

        # Silence is rejected before Whisper, which answers it with an invented
        # sentence rather than with nothing. The energy floor catches
        # near-silence; the speech gate catches loud non-speech...
        if len(samples) / SAMPLE_RATE < MIN_SECONDS:
            raise NoSpeech()
        # Accumulated in float64: a float32 mean over millions of squared
        # samples loses enough precision to move the decision.
        if float(np.sqrt(np.mean(np.square(samples, dtype=np.float64)))) < SILENCE_RMS:
            raise NoSpeech()
        if not self.speech_gate.measure(samples).is_speech:
            raise NoSpeech()

        transcription = self.recognizer.transcribe(samples)
        if not transcription.text:
            raise RuntimeError("Whisper returned no transcript")
        _require_intelligible(transcription)

        # From here the user's words exist, and every failure carries them...
        text = transcription.text
        try:
            routing = self.router.route(text)
        except Exception as error:
            raise ProcessingFailed(f"the router failed: {_describe(error)}", text, rewriter_ran=False) from error

        reply = {"transcript": text, "route": routing.route, "output": text,
                 "asr_ms": round(transcription.asr_ms, 1),
                 "router_ms": round(routing.latency_ms, 1), "processing_ms": None}
        if routing.route == "PASS_THROUGH":
            return reply, False

        # Every other route is rewritten by S1-mini. COMPLEX asks for more than
        # a rewrite, but a rewrite is the most PrivacyFlow can do on this Mac,
        # and it is better than inserting the raw transcript...
        from .rewriter import currency_contradiction

        try:
            rewrite = self.rewriter.rewrite(text, structure=routing.structure)
        except Exception as error:
            raise ProcessingFailed(f"S1-mini failed to rewrite this {routing.route} dictation: "
                                   f"{_describe(error)}", text, rewriter_ran=True) from error
        # Inserting nothing while reporting success would look exactly like a
        # silent failure, so an empty rewrite is refused...
        if not rewrite.text:
            raise ProcessingFailed(f"S1-mini returned an empty rewrite for this {routing.route} dictation",
                                   text, rewriter_ran=True)
        # A wrong amount pasted into a payment field is worse than no text...
        changed = currency_contradiction(text, rewrite.text)
        if changed:
            raise ProcessingFailed(f"S1-mini changed the currency to {' '.join(changed)}; nothing was inserted",
                                   text, rewriter_ran=True)

        reply.update(output=rewrite.text, processing_ms=round(rewrite.latency_ms, 1))
        return reply, True


def _require_intelligible(transcription) -> None:
    """Refuse a decode that Whisper itself did not believe.

    The two checks are separate because they are different failures, and the
    number that shows one is healthy while the other is happening.
    """
    from .recognizer import MAX_COMPRESSION_RATIO, MIN_AVG_LOGPROB

    if transcription.avg_logprob_min < MIN_AVG_LOGPROB:
        raise Unintelligible(transcription.audio_seconds,
                             f"average log probability {transcription.avg_logprob_min:.2f}, "
                             f"floor {MIN_AVG_LOGPROB}")
    if transcription.compression_ratio_max > MAX_COMPRESSION_RATIO:
        raise Unintelligible(transcription.audio_seconds,
                             f"compression ratio {transcription.compression_ratio_max:.2f}, "
                             f"ceiling {MAX_COMPRESSION_RATIO}")


def _describe(error: BaseException) -> str:
    """A readable one-line reason for the app to show."""
    return str(error) or type(error).__name__


def _milliseconds_since(started: float) -> float:
    return round((time.perf_counter() - started) * 1000.0, 1)


def _check_pinned_versions() -> None:
    """Refuse to start on library versions the serving code was not validated against."""
    for package, expected in PINNED.items():
        installed = version(package)
        if installed != expected:
            raise RuntimeError(f"PrivacyFlow's worker needs {package} {expected}, but {installed} is installed")


def load(models: pathlib.Path, vad: pathlib.Path) -> tuple[Worker, int]:
    """Load every model, wire the MLX weights into memory, and warm each model once.

    Returns the worker and the number of bytes locked. Loading happens here
    rather than on first use so that a missing file stops the worker at
    startup with a readable reason, not on the user's first dictation.
    """
    import mlx.core as mx
    from mlx.utils import tree_flatten

    from . import memory_lock
    from .recognizer import Recognizer
    from .rewriter import Rewriter
    from .router import Router
    from .speech_gate import SpeechGate

    if not models.is_dir():
        raise RuntimeError(f"the models directory does not exist: {models}")
    _check_pinned_versions()
    worker = Worker(
        speech_gate=SpeechGate(vad),
        recognizer=Recognizer(models / WHISPER_DIR),
        router=Router(models / ROUTER_DIR),
        rewriter=Rewriter(models / REWRITER_DIR),
    )

    weights = [array for model in (worker.recognizer.model, worker.router.model, worker.rewriter.model)
               for _, array in tree_flatten(model.parameters())]
    weights += list(worker.router.head.values())
    mx.eval(weights)
    locked_bytes = memory_lock.lock(weights)

    # Each model's first inference compiles its kernels, which belongs here
    # rather than in the user's first dictation.
    worker.recognizer.warm_up()
    worker.router.route(PREPARE_TEXT)
    worker.rewriter.warm_up()
    return worker, locked_bytes


def _claim_protocol_stream():
    """Take the process's real stdout for the protocol alone.

    Redirecting sys.stdout only catches Python's own prints. Native code inside
    MLX, onnxruntime or tokenizers writes to file descriptor 1 directly, and a
    single stray line there would shift every later reply onto the wrong
    request. So the protocol gets a private duplicate of descriptor 1, and
    descriptor 1 itself is pointed at stderr.
    """
    sys.stdout.flush()
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    return protocol


class _Arguments(argparse.ArgumentParser):
    """Argument parsing that raises instead of exiting, so the failure reaches the ready line."""

    def error(self, message: str):
        raise ValueError(f"invalid worker arguments: {message}")


def main(argv: list[str] | None = None, stdin=None, stdout=None) -> int:
    """Start the worker: one ready line, then one reply per request until stdin closes."""
    stdin = stdin or sys.stdin
    protocol = stdout or _claim_protocol_stream()

    def send(record: dict) -> None:
        protocol.write(json.dumps(record, ensure_ascii=False) + "\n")
        protocol.flush()

    with contextlib.redirect_stdout(sys.stderr):
        started = time.perf_counter()
        try:
            parser = _Arguments(prog="privacyflow_worker")
            parser.add_argument("--models", type=pathlib.Path, required=True)
            parser.add_argument("--vad", type=pathlib.Path, required=True)
            arguments = parser.parse_args(argv)
            worker, locked_bytes = load(arguments.models, arguments.vad)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            send({"ready": False, "error": _describe(error)})
            return 1
        send({"ready": True, "memory_locked_bytes": locked_bytes, "load_ms": _milliseconds_since(started)})
        worker.serve(stdin, send)
    return 0
