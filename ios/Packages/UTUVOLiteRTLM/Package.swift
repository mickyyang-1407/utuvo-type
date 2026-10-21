// swift-tools-version: 5.10
// UTUVO Type 精簡版：google-ai-edge/LiteRT-LM v0.18.0（Apache 2.0）的 Swift 包裝層（swift/ 下非測試檔，原樣未改）
// ＋官方預編 xcframework。直接相依整個 LiteRT-LM repo 要 clone 好幾 GB 的 git 歷史，這裡只取用到的部分。
// 2026-10-11：沒有 Apple Intelligence 的 iPhone 用的手機上整理（Gemma 4 E2B）。只給主 app，鍵盤 extension 不連。
import PackageDescription

let package = Package(
    name: "UTUVOLiteRTLM",
    platforms: [.iOS("18.0")],
    products: [.library(name: "LiteRTLM", targets: ["LiteRTLM"])],
    targets: [
        // checksum 與上游 v0.18.0 Package.swift 相同（2026-10-11 下載比對過）。
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM.xcframework.zip",
            checksum: "d765b99592d4ec3d0c9e2bd69469454af06c834861340672da1891c0c121c347"
        ),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM"]),
    ]
)
