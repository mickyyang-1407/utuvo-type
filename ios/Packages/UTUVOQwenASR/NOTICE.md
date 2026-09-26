# UTUVOQwenASR — vendored subset of soniqo/speech-swift

- Source: https://github.com/soniqo/speech-swift at commit `231f8eb9f0971fee335fef49f42d2975e4fbf8bc` (2026-09-23)
- License: Apache License 2.0 (`LICENSE`, unchanged)
- Copied targets, unmodified: `Qwen3ASR`, `AudioCommon`, `MLXCommon`, `SpeechVAD`
- UTUVO change: `Package.swift` only lists those four targets and their two dependencies
  (mlx-swift, swift-transformers). The upstream package pulls ~40 packages (server, TTS, LLM)
  that UTUVO Type does not use.
- Model weights are not bundled; the app downloads `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` on request.
