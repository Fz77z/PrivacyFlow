"""The real worker process against the real models, driven the way the app drives it.

Skipped unless the models are present, because they are 2.4 GB downloaded by
the app rather than part of the repository:

    PRIVACYFLOW_MODELS=/path/to/models PRIVACYFLOW_VAD=/path/to/silero_vad.onnx \\
        .venv/bin/python -m pytest tests/test_end_to_end.py -q
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys

import pytest

MODELS = os.environ.get("PRIVACYFLOW_MODELS")
VAD = os.environ.get("PRIVACYFLOW_VAD")

pytestmark = [
    pytest.mark.skipif(not (MODELS and VAD), reason="PRIVACYFLOW_MODELS and PRIVACYFLOW_VAD are not set"),
    pytest.mark.skipif(not (shutil.which("say") and shutil.which("afconvert")),
                       reason="synthesising speech needs macOS say and afconvert"),
]


def synthesise(text: str, directory: pathlib.Path) -> pathlib.Path:
    """Speak `text` with macOS text-to-speech into the WAV format the app records."""
    spoken = directory / "spoken.aiff"
    recording = directory / "recording.wav"
    subprocess.run(["say", "-o", str(spoken), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(spoken), str(recording)],
                   check=True)
    return recording


def test_a_spoken_dictation_comes_back_as_text(tmp_path):
    recording = synthesise("Please send the quarterly report to the finance team by Friday.", tmp_path)
    process = subprocess.Popen(
        [sys.executable, "-I", "-m", "privacyflow_worker", "--models", MODELS, "--vad", VAD],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        ready = json.loads(process.stdout.readline())
        assert ready["ready"] is True, ready
        assert ready["memory_locked_bytes"] > 2_000_000_000

        replies = []
        for request in ({"prepare": True}, {"audio_path": str(recording)}):
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            replies.append(json.loads(process.stdout.readline()))
    finally:
        process.stdin.close()
        process.wait(timeout=60)

    prepared, dictation = replies
    assert prepared["prepared"] is True
    assert "quarterly report" in dictation["transcript"].lower()
    assert dictation["route"] in ("PASS_THROUGH", "LIGHT_CLEANUP", "TRANSFORM", "COMPLEX")
    assert "quarterly report" in dictation["output"].lower()
    assert process.returncode == 0
