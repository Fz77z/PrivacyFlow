---
license: mit
base_model: mlx-community/whisper-large-v3-turbo
library_name: mlx
pipeline_tag: automatic-speech-recognition
language:
- en
tags:
- whisper
- mlx
---

# Whisper large-v3-turbo, 8-bit MLX, for PrivacyFlow

OpenAI's Whisper large-v3-turbo, quantised to 8 bits at group size 64 from `mlx-community/whisper-large-v3-turbo`, for the speech recognition in [PrivacyFlow](https://github.com/Fz77z/privacyflow).

On 111 real dictations, its transcripts were word-identical to the full-precision build on 103, and every routing decision made from them was unchanged, at 833 MB against 1543 MB.
