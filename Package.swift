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
        // 詞庫包（catalog.json + 各包 .txt）打包成 bundle 資源，啟動時只載 metadata，
        // terms 依 cleanup/UI 需求延遲讀取（VocabularyPacks.BundlePackTermsSource）。
        .executableTarget(
            name: "UTUVOTypeApp",
            dependencies: ["UTUVOTypeCore"],
            path: "Sources/UTUVOTypeApp",
            resources: [
                .copy("Resources/vocabulary"),
            ]
        ),
        // 測試：normalizer、routing、prompt safety、fixtures、衛生、短句禁大模型。
        // fixtures 與 prompt 範本走 repo 真實檔案，由 TestSupport.repoRoot() 定位。
        .testTarget(
            name: "UTUVOTypeCoreTests",
            dependencies: ["UTUVOTypeCore"],
            path: "Tests/UTUVOTypeCoreTests"
        ),
        // App tests：跑 production 的 AppModel／AppPreferences／SmartCleanup／AXAdapter／AXReplacementGate。
        // 隔離：每個 case 透過 IsolatedContext 注入 UserDefaults + storage 資料夾；
        // 跳過 iCloud / hotkey / mic / real network / real Keychain。
        // 依賴 executable target 是 SwiftPM 允許的，這樣測試能拿到 production 程式碼而不需要複製。
        .testTarget(
            name: "UTUVOTypeAppTests",
            dependencies: ["UTUVOTypeApp"],
            path: "Tests/UTUVOTypeAppTests"
        )
    ]
)
