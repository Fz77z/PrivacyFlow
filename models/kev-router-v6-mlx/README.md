---
license: apache-2.0
base_model: Qwen/Qwen2.5-0.5B
library_name: mlx
pipeline_tag: text-classification
language:
- en
tags:
- mlx
- dictation
- router
---

# PrivacyFlow router (Kev, router_v6), MLX fp16

The router in [PrivacyFlow](https://github.com/Fz77z/privacyflow).
It reads a dictated transcript and decides what it needs: inserting as spoken (`PASS_THROUGH`), or a rewrite (`LIGHT_CLEANUP`, `TRANSFORM`, `COMPLEX`), and whether the result is prose or a list.
It never writes text itself.

It is a Kev decision model: `Qwen/Qwen2.5-0.5B` with a LoRA adapter merged into its weights, plus a small pointer head (`head.safetensors`) that scores each option's closing token against the decide token.
`kev.json` records the base revision and the facts the serving code checks at load.

Served in fp16, it reproduces every route and structure decision of the fp32 reference on the 314 held-out cases it was gated against.
