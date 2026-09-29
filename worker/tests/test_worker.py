"""The worker's protocol and dictation pipeline, with the models replaced by fakes.

What is held here is the contract the app relies on: replies in order and one
per request, silence and noise answered without Whisper, a transcript never
lost once it exists, and the warm-up policy that keeps the router and S1-mini
resident without making a dictation wait.
"""
from __future__ import annotations

import io
import json
import math
import struct
import wave

import pytest

from privacyflow_worker import memory_lock, worker
from privacyflow_worker.recognizer import Transcription
from privacyflow_worker.rewriter import Rewrite, currency_contradiction
from privacyflow_worker.router import Routing
from privacyflow_worker.speech_gate import Measurement


class Events(list):
    """What the fakes were asked to do, and when replies went out, in order."""


class FakeGate:
    def __init__(self, events: Events, is_speech: bool = True) -> None:
        self.events, self.is_speech = events, is_speech

    def measure(self, samples):
        self.events.append("gate")
        return Measurement(is_speech=self.is_speech, speech_seconds=1.0, strongest_frame=0.9)


class FakeRecognizer:
    def __init__(self, events: Events, text: str = "hello there", avg_logprob: float = -0.2,
                 compression_ratio: float = 1.2) -> None:
        self.events = events
        self.result = Transcription(text=text, audio_seconds=1.0, asr_ms=100.0,
                                    avg_logprob_min=avg_logprob, compression_ratio_max=compression_ratio)

    def transcribe(self, samples):
        self.events.append("transcribe")
        # A library printing to stdout mid-request is the failure the
        # redirection in main() exists for.
        print("a stray library print")
        return self.result


class FakeRouter:
    def __init__(self, events: Events, route: str = "PASS_THROUGH", structure: str = "prose",
                 fails: bool = False) -> None:
        self.events, self.decision, self.structure, self.fails = events, route, structure, fails

    def route(self, text: str) -> Routing:
        self.events.append(f"route:{text}")
        if self.fails:
            raise RuntimeError("router exploded")
        return Routing(route=self.decision, structure=self.structure, route_probabilities={},
                       structure_probabilities={}, latency_ms=30.0)


class FakeRewriter:
    def __init__(self, events: Events, output: str = "Hello there.", fails: bool = False) -> None:
        self.events, self.output, self.fails = events, output, fails

    def rewrite(self, text: str, structure: str) -> Rewrite:
        self.events.append(f"rewrite:{structure}")
        if self.fails:
            raise RuntimeError("generation exploded")
        return Rewrite(text=self.output, latency_ms=150.0)

    def warm_up(self) -> None:
        self.events.append("warm rewriter")


def make_worker(events: Events, **overrides) -> worker.Worker:
    parts = {"speech_gate": FakeGate(events), "recognizer": FakeRecognizer(events),
             "router": FakeRouter(events), "rewriter": FakeRewriter(events)}
    parts.update(overrides)
    return worker.Worker(**parts)


def write_wav(path, seconds: float = 1.0, amplitude: int = 8000, rate: int = 16_000,
              channels: int = 1, width: int = 2):
    """A tone loud enough to clear the energy floor, or silence at amplitude 0."""
    frames = int(seconds * rate)
    samples = [int(amplitude * math.sin(2 * math.pi * 220 * n / rate)) for n in range(frames)]
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(width)
        output.setframerate(rate)
        if width == 2:
            output.writeframes(struct.pack(f"<{frames * channels}h",
                                           *[s for s in samples for _ in range(channels)]))
        else:
            output.writeframes(bytes((s >> 8) + 128 for s in samples for _ in range(channels)))
    return path


def serve(worker_instance: worker.Worker, requests: list[dict | str], events: Events) -> list[dict]:
    """Run the request loop, recording each reply as an event as it is sent."""
    replies = []

    def send(record: dict) -> None:
        events.append("reply")
        replies.append(record)

    lines = [r if isinstance(r, str) else json.dumps(r) for r in requests]
    worker_instance.serve((line + "\n" for line in lines), send)
    return replies


def test_startup_then_one_reply_per_request_in_order_on_a_clean_stdout(tmp_path, monkeypatch):
    events = Events()
    monkeypatch.setattr(worker, "load", lambda models, vad: (make_worker(events), 2_400_000_000))
    speech = write_wav(tmp_path / "speech.wav")
    requests = [{"prepare": True}, {"audio_path": str(speech)}, "", "not json", {"prepare": True}]
    stdout = io.StringIO()

    code = worker.main(["--models", str(tmp_path), "--vad", str(tmp_path / "vad.onnx")],
                       stdin=io.StringIO("\n".join(json.dumps(r) if isinstance(r, dict) else r
                                                   for r in requests) + "\n"),
                       stdout=stdout)

    lines = [json.loads(line) for line in stdout.getvalue().splitlines()]
    assert code == 0
    assert lines[0]["ready"] is True and lines[0]["memory_locked_bytes"] == 2_400_000_000
    assert "prepared" in lines[1]
    assert lines[2]["transcript"] == "hello there"
    assert "error" in lines[3]
    assert "prepared" in lines[4]
    assert len(lines) == 5


def test_a_weight_lock_failure_is_the_ready_line(tmp_path, monkeypatch):
    def refuse(models, vad):
        raise memory_lock.MemoryLockFailed("could not lock the 2.40 GB of model weights in memory")

    monkeypatch.setattr(worker, "load", refuse)
    stdout = io.StringIO()

    code = worker.main(["--models", str(tmp_path), "--vad", str(tmp_path / "vad.onnx")],
                       stdin=io.StringIO(""), stdout=stdout)

    assert code == 1
    assert json.loads(stdout.getvalue()) == {
        "ready": False, "error": "could not lock the 2.40 GB of model weights in memory"}


def test_mlock_refusing_any_buffer_fails_the_lock():
    mx = pytest.importorskip("mlx.core")
    weights = [mx.ones((64, 64), dtype=mx.bfloat16), mx.ones((64,), dtype=mx.float32)]
    mx.eval(weights)
    calls = []

    def mlock(address, length):
        calls.append(length)
        return -1 if len(calls) == 2 else 0

    with pytest.raises(memory_lock.MemoryLockFailed):
        memory_lock.lock(weights, mlock=mlock)


@pytest.mark.parametrize("dtype", ["bfloat16", "float16", "float32", "uint32"])
def test_the_locked_address_is_the_live_buffer_not_a_copy(dtype):
    """Locking a copy would wire memory nobody reads and leave the weights pageable."""
    import ctypes

    mx = pytest.importorskip("mlx.core")
    array = mx.ones((256, 256), dtype=getattr(mx, dtype))
    mx.eval(array)

    address, length = memory_lock.buffer_of(array)
    ctypes.memset(address, 0, length)

    assert length == array.nbytes
    assert array.astype(mx.float32).sum().item() == 0


def test_silence_is_no_speech_without_asking_whisper(tmp_path):
    events = Events()
    replies = serve(make_worker(events), [{"audio_path": str(write_wav(tmp_path / "s.wav", amplitude=0))}], events)

    assert replies == [{"no_speech": True}]
    assert "transcribe" not in events


def test_loud_non_speech_is_no_speech_without_asking_whisper(tmp_path):
    events = Events()
    gate = FakeGate(events, is_speech=False)
    replies = serve(make_worker(events, speech_gate=gate), [{"audio_path": str(write_wav(tmp_path / "s.wav"))}], events)

    assert replies == [{"no_speech": True}]
    assert "transcribe" not in events


@pytest.mark.parametrize("decode, detail", [
    ({"avg_logprob": -1.42}, "average log probability -1.42, floor -1.0"),
    ({"compression_ratio": 9.16}, "compression ratio 9.16, ceiling 2.4"),
])
def test_a_decode_whisper_did_not_believe_is_unintelligible_and_never_routed(tmp_path, decode, detail):
    events = Events()
    recognizer = FakeRecognizer(events, text="thank you", **decode)
    replies = serve(make_worker(events, recognizer=recognizer),
                    [{"audio_path": str(write_wav(tmp_path / "s.wav"))}], events)

    assert replies == [{"unintelligible": True, "audio_seconds": 1.0, "detail": detail}]
    assert not any(event.startswith("route") for event in events)


@pytest.mark.parametrize("parts, reason", [
    ({"router": "fails"}, "router exploded"),
    ({"rewriter": "fails"}, "generation exploded"),
    ({"rewriter": "changes the currency"}, "changed the currency to $"),
    ({"rewriter": "returns nothing"}, "empty rewrite"),
])
def test_every_failure_after_recognition_carries_the_transcript(tmp_path, parts, reason):
    events = Events()
    recognizer = FakeRecognizer(events, text="send forty pounds to sam")
    router = FakeRouter(events, route="TRANSFORM", fails=parts.get("router") == "fails")
    rewriter = {
        None: FakeRewriter(events),
        "fails": FakeRewriter(events, fails=True),
        "changes the currency": FakeRewriter(events, output="Send $40 to Sam."),
        "returns nothing": FakeRewriter(events, output=""),
    }[parts.get("rewriter")]
    replies = serve(make_worker(events, recognizer=recognizer, router=router, rewriter=rewriter),
                    [{"audio_path": str(write_wav(tmp_path / "s.wav"))}], events)

    assert replies[0]["transcript"] == "send forty pounds to sam"
    assert reason in replies[0]["error"]
    assert set(replies[0]) == {"error", "transcript"}


@pytest.mark.parametrize("rate, channels, width", [(48_000, 1, 2), (16_000, 2, 2), (16_000, 1, 1)])
def test_anything_but_16k_mono_16_bit_is_refused_rather_than_converted(tmp_path, rate, channels, width):
    events = Events()
    path = write_wav(tmp_path / "s.wav", rate=rate, channels=channels, width=width)
    replies = serve(make_worker(events), [{"audio_path": str(path)}], events)

    assert "16 kHz mono 16-bit" in replies[0]["error"]
    assert "transcript" not in replies[0]
    assert "transcribe" not in events


def test_prepare_touches_only_the_router():
    events = Events()
    replies = serve(make_worker(events), [{"prepare": True}], events)

    assert replies[0]["prepared"] is True
    assert events == [f"route:{worker.PREPARE_TEXT}", "reply"]


def test_s1_is_warmed_after_the_reply_to_a_dictation_that_did_not_use_it(tmp_path):
    events = Events()
    replies = serve(make_worker(events), [{"audio_path": str(write_wav(tmp_path / "s.wav"))}], events)

    assert replies[0]["route"] == "PASS_THROUGH"
    assert replies[0]["processing_ms"] is None
    assert events[-2:] == ["reply", "warm rewriter"]


def test_a_failed_s1_warm_up_does_not_stop_the_worker_answering(tmp_path):
    """The warm-up is an optimisation; a dead resident worker loses every later dictation."""
    events = Events()

    class FailingWarmUp(FakeRewriter):
        def warm_up(self) -> None:
            self.events.append("warm rewriter")
            raise RuntimeError("warm-up exploded")

    speech = str(write_wav(tmp_path / "s.wav"))
    replies = serve(make_worker(events, rewriter=FailingWarmUp(events)),
                    [{"audio_path": speech}, {"prepare": True}, {"audio_path": speech}], events)

    assert [reply.get("route") or reply.get("prepared") for reply in replies] == [
        "PASS_THROUGH", True, "PASS_THROUGH"]
    assert events.count("warm rewriter") == 2


def test_s1_is_not_rewarmed_after_a_dictation_it_just_rewrote(tmp_path):
    events = Events()
    router = FakeRouter(events, route="LIGHT_CLEANUP")
    serve(make_worker(events, router=router), [{"audio_path": str(write_wav(tmp_path / "s.wav"))}], events)

    assert "warm rewriter" not in events


def test_complex_is_rewritten_by_s1_with_the_routers_structure(tmp_path):
    events = Events()
    router = FakeRouter(events, route="COMPLEX", structure="lists")
    rewriter = FakeRewriter(events, output="1. Milk\n2. Eggs")
    replies = serve(make_worker(events, router=router, rewriter=rewriter),
                    [{"audio_path": str(write_wav(tmp_path / "s.wav"))}], events)

    assert replies[0]["route"] == "COMPLEX"
    assert replies[0]["output"] == "1. Milk\n2. Eggs"
    assert replies[0]["processing_ms"] == 150.0
    assert "rewrite:lists" in events


@pytest.mark.parametrize("transcript, rewrite, contradicted", [
    ("send forty pounds to sam", "Send $40 to Sam.", ["$"]),
    ("it was twenty bucks", "It was $20.", []),
    ("the european tickets were twenty five fifty each", "The European tickets were $25.50 each.", []),
    ("after pounding the table he paid twenty", "After pounding the table, he paid $20.", []),
    ("ten euros please", "€10, please.", []),
])
def test_only_a_spoken_currency_can_be_contradicted(transcript, rewrite, contradicted):
    """A changed currency is refused, but words that merely contain a currency's name are not one."""
    assert currency_contradiction(transcript, rewrite) == contradicted
