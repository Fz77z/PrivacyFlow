# Development

PrivacyFlow has two parts.
The app in `app/` is a Swift package.
The worker in `worker/` is a Python package that runs the models, bundled inside the app with its own Python runtime.
[architecture.md](architecture.md) explains how they fit together.

## Requirements

- A Mac with Apple Silicon, on macOS 14 or later.
- Xcode 16 or later.
- [uv](https://docs.astral.sh/uv/).

## Build the app

```sh
./scripts/build-app.sh
```

This builds `build/PrivacyFlow.app` with its private Python runtime and signs it ad hoc.
It installs nothing.
The first build downloads the pinned Python runtime and packages, which takes a few minutes; later builds reuse them.
Delete `build/runtime` after changing anything in `worker/`.

The build fails if any shipped file contains your home directory path, or needs a newer macOS than 14.

## Work on the worker

```sh
cd worker
uv venv --python 3.12
uv pip install --no-deps -r pyproject.toml
uv pip install --no-deps -e .
uv pip install pytest
.venv/bin/python -m pytest
```

The end-to-end test runs the real models.
Set `PRIVACYFLOW_MODELS` to a directory holding the three model directories (the app keeps them in `~/Library/Application Support/PrivacyFlow/models`) and `PRIVACYFLOW_VAD` to `app/Resources/SileroVAD/silero_vad.onnx`; without them it is skipped.

To run a built app against this environment instead of its bundled runtime, set `PRIVACYFLOW_DEV_PYTHON` to `worker/.venv/bin/python`.
The Status tab says when it is in use.

## Test the app

```sh
swift test --package-path app
```

## Release

1. When a model changes, publish it and pin the app to it.
   Log in to Hugging Face with a write token first (`hf auth login`), then run:
   `worker/.venv/bin/python scripts/publish-models.py --namespace <huggingface-name> --models <directory of built models>`.
   This uploads each model with its license and card, and pins `app/Resources/models.json` to the exact revisions uploaded.
2. Set the version in `app/VERSION`.
3. Build the disk image with `./scripts/release.sh`.
   It prints the image's path and SHA-256.
4. Attach the image to a GitHub release.

`release.sh` signs ad hoc by default.
With `SIGNING=developer-id`, plus `DEVELOPER_ID_IDENTITY` and `NOTARY_PROFILE`, it signs with a Developer ID and the hardened runtime, then notarises and staples the image.
