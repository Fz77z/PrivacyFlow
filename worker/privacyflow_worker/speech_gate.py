"""Whether a capture holds speech at all, asked before Whisper sees it.

Whisper does not answer non-speech with nothing. It answers with a confident
invented sentence: blowing into the microphone reliably produced "Thank you.",
with a decode as confident as real speech. The energy floor only rejects
near-silence, and a blow is loud. The separating information is in the audio,
not in the transcript, so this is Silero's voice-activity model rather than
another threshold on Whisper's output.

It runs on CPU in about 3 ms per audio second, leaving Metal free for
transcription, and on a rejected capture it saves the whole Whisper pass.
"""
from __future__ import annotations

import pathlib
from dataclasses import dataclass

import numpy as np

from .audio import SAMPLE_RATE

# The window the model was exported for, and the 64 samples of the preceding
# frame it expects in front of them. Both are the model's contract: feeding a
# bare 512 makes every probability collapse towards zero.
FRAME = 512
CONTEXT = 64

# Silero's own default. Across the measured set the strongest non-speech frame
# reached 0.092 and the weakest speech frame 0.972, so this sits in open space.
SPEECH_THRESHOLD = 0.5

# Every measured non-speech capture held zero frames above the threshold and
# the weakest speech clip held 0.35 seconds of them. This sits between the two,
# so one spurious frame does not admit a blow and a clipped word is not lost.
MIN_SPEECH_SECONDS = 0.1


@dataclass(frozen=True)
class Measurement:
    """What the gate found, and the numbers behind the verdict."""

    is_speech: bool
    speech_seconds: float
    strongest_frame: float


class SpeechGate:
    """The Silero voice-activity model, loaded once and kept resident."""

    def __init__(self, model_path: pathlib.Path) -> None:
        import onnxruntime

        if not model_path.is_file():
            raise RuntimeError(f"the Silero voice-activity model is missing: {model_path}")
        # One thread each: this runs alone on the request path, and the default
        # pool costs more in scheduling than it saves on a model this small.
        options = onnxruntime.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        self.session = onnxruntime.InferenceSession(
            str(model_path), providers=["CPUExecutionProvider"], sess_options=options)

    def measure(self, samples: np.ndarray) -> Measurement:
        """Score one whole capture, carrying the recurrent state frame to frame.

        Each frame is presented with the tail of the one before it. A capture
        shorter than one frame yields no frames, and so no speech.
        """
        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros((1, CONTEXT), dtype=np.float32)
        rate = np.array(SAMPLE_RATE, dtype=np.int64)
        probabilities = []
        for start in range(0, len(samples) - FRAME + 1, FRAME):
            padded = np.concatenate([context, samples[start:start + FRAME].reshape(1, FRAME)], axis=1)
            output, state = self.session.run(None, {"input": padded, "state": state, "sr": rate})
            context = padded[:, -CONTEXT:]
            probabilities.append(float(output[0][0]))

        speech_seconds = sum(p >= SPEECH_THRESHOLD for p in probabilities) * FRAME / SAMPLE_RATE
        return Measurement(
            is_speech=speech_seconds >= MIN_SPEECH_SECONDS,
            speech_seconds=speech_seconds,
            strongest_frame=max(probabilities, default=0.0),
        )
