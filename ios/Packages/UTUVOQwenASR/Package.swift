// swift-tools-version: 5.10
// UTUVO Type 精簡版：只取 soniqo/speech-swift（Apache 2.0，commit 231f8eb）的 Qwen3-ASR 與其必要 target，
// 不帶伺服器／TTS／LLM 等用不到的相依（完整套件會拉進 swift-nio 等 40 個套件）。
import PackageDescription

let package = Package(
    name: "UTUVOQwenASR",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [.library(name: "Qwen3ASR", targets: ["Qwen3ASR"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .target(name: "AudioCommon", dependencies: [.product(name: "Hub", package: "swift-transformers")]),
        .target(name: "MLXCommon", dependencies: ["AudioCommon",
            .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"), .product(name: "MLXFFT", package: "mlx-swift")]),
        .target(name: "SpeechVAD", dependencies: ["AudioCommon", "MLXCommon",
            .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift")]),
        .target(name: "Qwen3ASR", dependencies: ["AudioCommon", "MLXCommon", "SpeechVAD",
            .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift")]),
    ]
)
