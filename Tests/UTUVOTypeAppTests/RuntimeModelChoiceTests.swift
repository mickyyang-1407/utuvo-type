import XCTest
@testable import UTUVOTypeApp

/// 2026-09-24：16 GB 以上用 Qwen3-ASR 1.7B。模型名單在 bash／Python／Swift 三處，這裡對齊它們並驗證完成判斷。
final class RuntimeModelChoiceTests: XCTestCase {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRecommendationFollowsMemory() {
        XCTAssertEqual(RuntimeBootstrap.recommendedASRModel(memoryGB: 8), "Qwen3-ASR-0.6B-6bit")
        XCTAssertEqual(RuntimeBootstrap.recommendedASRModel(memoryGB: 16), "Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(RuntimeBootstrap.recommendedASRModel(memoryGB: 512), "Qwen3-ASR-1.7B-8bit")
    }

    func testBashPythonAndSwiftListTheSameModels() throws {
        let bootstrap = try repoFile("scripts/bootstrap-runtime.sh")
        let wrapper = try repoFile("runtime/utuvo-type-asr.py")
        for name in RuntimeBootstrap.asrModelCandidates {
            XCTAssertTrue(bootstrap.contains("mlx-community/\(name)"), "bootstrap missing \(name)")
            XCTAssertTrue(wrapper.contains("\"\(name)\""), "wrapper missing \(name)")
        }
        XCTAssertTrue(bootstrap.contains("-ge 16"), "bootstrap threshold must match recommendedASRModel")
    }

    func testPartialDownloadIsNotInstalled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let asr = home.appendingPathComponent(".models/asr")
        let big = asr.appendingPathComponent("Qwen3-ASR-1.7B-8bit"), small = asr.appendingPathComponent("Qwen3-ASR-0.6B-6bit")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: big.appendingPathComponent("config.json"))   // 半套：沒有 .complete
        let root = home.path
        XCTAssertFalse(RuntimeBootstrap.asrModelReady(root: root, name: "Qwen3-ASR-1.7B-8bit"))
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: small.appendingPathComponent("config.json"))
        XCTAssertTrue(RuntimeBootstrap.asrModelReady(root: root, name: "Qwen3-ASR-0.6B-6bit"), "舊版 0.6B 沒有標記也算完整")
        try Data().write(to: big.appendingPathComponent(".complete"))
        XCTAssertTrue(RuntimeBootstrap.asrModelReady(root: root, name: "Qwen3-ASR-1.7B-8bit"))
    }
}
