// swift-tools-version: 6.0
import PackageDescription

// UTUVO Type — native menu-bar app plus benchmark-first core.

let package = Package(
    name: "UTUVOType",
    platforms: [
        .macOS(.v14), // 本機 ASR / 串流路徑的部署基準；M1 UI 也會以 .v14 為最低
        .iOS(.v17)    // iOS 線（ios/ 目錄，xcodegen 產生專案）；core 是純 Foundation 直接共用
    ],
    products: [
        .library(name: "UTUVOTypeCore", targets: ["UTUVOTypeCore"]),
        .executable(name: "utuvo-bench", targets: ["UTUVOBench"]),
        .executable(name: "utuvo-type", targets: ["UTUVOTypeApp"])
    ],
    targets: [
        // 純函式核心：normalizer / routing / prompt loader / fixtures loader。
        // 不准引進任何 SwiftPM dependency，連 XCTest 都隔離在 test target。
        .target(
            name: "UTUVOTypeCore",
            path: "Sources/UTUVOTypeCore"
        ),
        // Benchmark 執行檔：載入 fixtures、跑 deterministic 路徑、輸出機器可讀報告。
        .executableTarget(
            name: "UTUVOBench",
            dependencies: ["UTUVOTypeCore"],
            path: "Sources/UTUVOBench"
        ),
        // 原生 macOS menu bar app。所有 provider 與權限整合仍住在本產品 repo；
        // 核心 normalizer / routing 不反向依賴 AppKit。
        .executableTarget(
            name: "UTUVOTypeApp",
            dependencies: ["UTUVOTypeCore"],
            path: "Sources/UTUVOTypeApp"
        ),
        // 測試：normalizer、routing、prompt safety、fixtures、衛生、短句禁大模型。
        // fixtures 與 prompt 範本走 repo 真實檔案，由 TestSupport.repoRoot() 定位。
        .testTarget(
            name: "UTUVOTypeCoreTests",
            dependencies: ["UTUVOTypeCore"],
            path: "Tests/UTUVOTypeCoreTests"
        )
    ]
)
