# Architecture

PrivacyFlow is a macOS dictation app.
Hold the dictation key (Right Option by default), speak, release, and the text appears at the cursor.
Everything runs on the Mac: no audio or text ever leaves it.

It has two processes.

- **The app** (`app/`, Swift) owns everything the user sees and touches: the hotkey, the microphone, the capsule and console windows, settings, model downloads, and inserting text.
- **The worker** (`worker/`, Python) owns the three models and turns one recorded utterance into the text to insert.

The app starts the worker once, keeps it resident, and talks to it over JSON lines on stdin and stdout.

## Pipeline for one dictation

1. The user presses the dictation key.
   The app resumes the already-open microphone stream and sends `{"prepare": true}` so the router is resident before it is needed.
2. The user releases the key.
   The app writes the capture as a 16 kHz mono 16-bit WAV in its cache directory and sends `{"audio_path": ...}`.
3. The worker rejects silence (energy floor, then the Silero speech gate), transcribes with Whisper, and asks the router which route the transcript needs.
4. `PASS_THROUGH` returns the raw transcript.
   `LIGHT_CLEANUP`, `TRANSFORM` and `COMPLEX` return S1-mini's rewrite.
5. The app deletes the WAV, puts the text on the pasteboard, and pastes it into the application that was frontmost when the dictation started.

A new dictation can start while earlier ones are still being processed.
Transcription and placement are two serial stages, so dictations are pasted in the order they were spoken, and a paste waits while the dictation key is physically held.

## Models

| Role | Model | Format | Size |
| --- | --- | --- | --- |
| Speech recognition | Whisper large-v3-turbo | MLX, 8-bit | ~0.8 GB |
| Router | Kev (Qwen2.5-0.5B, LoRA merged, pointer head) | MLX | ~1 GB |
| Text processor | S1-mini by Superwhisper | MLX, 8-bit | ~0.6 GB |
| Speech gate | Silero VAD | ONNX | 2 MB, ships inside the app |

The three large models are downloaded by the app on first launch from pinned Hugging Face revisions listed in `app/Resources/models.json`.
Every file is checked against its SHA-256 before it is used.
The worker never touches the network, and runs with `HF_HUB_OFFLINE=1`.

## Keeping the models resident

macOS compresses and swaps out memory that has not been touched for a while.
Before this was addressed, the first dictation after a long idle spent 5 to 22 seconds bringing the models back, on a machine under memory pressure.

Two measures deal with it.

- After loading, the worker `mlock`s every model weight buffer, so macOS cannot compress or swap the weights at all.
  About 2.4 GB stays wired while PrivacyFlow runs.
  Measured on 2026-09-28 right after touching and releasing 9 GB, a route took 2.7 to 4.4 s and a rewrite 4.6 to 6.7 s unlocked, against 89 to 130 ms and 141 to 154 ms locked.
  If locking fails, the worker refuses to start and says why, rather than running with the stall silently back.
- The press-time warm-up touches only the router, which every dictation needs.
  S1-mini is warmed after a dictation that did not use it, off the critical path, so the rarely used rewriter never goes cold and never makes a pass-through dictation wait.

## Worker protocol

One JSON object per line in each direction.
The worker answers requests strictly in order, one reply per request.
Only the protocol reaches the worker's stdout; everything else goes to stderr.

The worker is started as:

```
<runtime>/bin/python3 -I -B -m privacyflow_worker --models <directory> --vad <silero_vad.onnx>
```

`<directory>` holds one subdirectory per downloaded model, named as in `models.json`: `whisper-large-v3-turbo-mlx-q8`, `kev-router-v6-mlx` and `s1-mini-mlx-q8`.
`--vad` is the path of the Silero model inside the app bundle.

### Startup

The worker's first line is exactly one of:

```json
{"ready": true, "memory_locked_bytes": 2486816128, "load_ms": 3692.3}
{"ready": false, "error": "readable reason"}
```

### Requests and replies

| Request | Reply |
| --- | --- |
| `{"prepare": true}` | `{"prepared": true, "prepare_ms": 12.3}` or `{"prepared": false, "error": "..."}` |
| `{"audio_path": "/abs/path.wav"}` | one of the dictation replies below |

Anything else, including a line that is not JSON, is answered with `{"error": "..."}`.

Dictation replies:

```json
{"transcript": "...", "route": "PASS_THROUGH", "output": "...", "asr_ms": 512.0, "router_ms": 40.1, "processing_ms": null}
{"no_speech": true}
{"unintelligible": true, "audio_seconds": 2.1, "detail": "average log probability -1.42, floor -1.0"}
{"error": "readable reason", "transcript": "... or absent"}
```

`processing_ms` is null unless S1-mini ran.
`error` carries the transcript whenever recognition had already succeeded, so the app can leave the words on the clipboard instead of losing them.

The WAV must be 16 kHz mono 16-bit.
The worker refuses anything else rather than resampling.
