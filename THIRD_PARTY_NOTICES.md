# Third-party notices

PrivacyFlow's own code is MIT licensed (see `LICENSE`).
It runs models and bundles software made by others, listed here with their licenses.

## Models

| Model | Author | License | How PrivacyFlow uses it |
| --- | --- | --- | --- |
| S1-mini | Superwhisper | Apache-2.0 with an additional naming term | Rewrites transcripts as finished text, converted to 8-bit MLX |
| Whisper large-v3-turbo | OpenAI | MIT | Speech recognition, converted to 8-bit MLX |
| Qwen2.5-0.5B | Alibaba Cloud | Apache-2.0 | Base of the Kev router, with a merged LoRA adapter and a pointer head |
| Silero VAD | Silero Team | MIT | Speech gate, shipped inside the app |

S1-mini is a derivative work of Qwen3-0.6B, Copyright 2024 Alibaba Cloud, licensed under Apache-2.0.
Its license adds one term: any use, distribution, or integration of the model must continue to identify it by its original name, "S1-mini" by "Superwhisper".
PrivacyFlow names it that way in the app and in its documentation.
The converted models are published with each original license file beside the weights.

## Bundled software

The app contains a private Python runtime built from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) (CPython, PSF License, and the libraries it links, each under its own license).
Inside it are these packages, each installed with its license files in its `.dist-info` directory:

| Package | License |
| --- | --- |
| mlx, mlx-metal | MIT |
| mlx-lm | MIT |
| mlx-whisper | MIT |
| numpy | BSD-3-Clause and bundled components |
| onnxruntime | MIT |
| transformers | Apache-2.0 |
| tokenizers | Apache-2.0 |
| safetensors | Apache-2.0 |
| huggingface-hub | Apache-2.0 |
| tiktoken | MIT |
| regex | Apache-2.0 and CNRI-Python |
| jinja2, markupsafe | BSD-3-Clause |
| pyyaml | MIT |
| packaging | Apache-2.0 or BSD-2-Clause |
| filelock | MIT |
| tqdm | MPL-2.0 and MIT |
| requests | Apache-2.0 |
| charset-normalizer | MIT |
| urllib3 | MIT |
| idna | BSD-3-Clause |
| certifi | MPL-2.0 |

The Inter typeface is used under the SIL Open Font License 1.1, included with the font files.
