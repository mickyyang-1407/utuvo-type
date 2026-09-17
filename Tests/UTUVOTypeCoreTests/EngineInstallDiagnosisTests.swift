import XCTest
@testable import UTUVOTypeCore

/// 安裝失敗診斷：每條規則都要有一個「會讓它命中的真實 log 片段」，加一個「不該命中」的乾淨 log。
final class EngineInstallDiagnosisTests: XCTestCase {

    /// 2026-09-17 第二台機器實踩的 pip 輸出（節錄）。
    private let xcodeLicenseLog = """
    [bootstrap] 安裝相依套件（requirements.txt）
      error: subprocess-exited-with-error
      × Building wheel for webrtcvad (pyproject.toml) did not run successfully.
      │ exit code: 1
        clang -fno-strict-overflow -Wsign-compare -DNDEBUG -g -O3 -Wall -arch arm64 ... -c cbits/pywebrtcvad.c
        You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license.
        error: Command '['clang', ...]' returned non-zero exit status 69.
      ERROR: Failed building wheel for webrtcvad
    [bootstrap] ERROR: pip 安裝失敗；請檢查網路後重跑本腳本
    """

    func testXcodeLicenseWinsOverGenericWheelFailure() {
        let d = EngineInstallDiagnosis.diagnose(log: xcodeLicenseLog)
        XCTAssertEqual(d.kind, .xcodeLicense, "同一份 log 同時有 wheel 失敗與 license 字樣，要指到真因")
        XCTAssertEqual(d.command, "sudo xcodebuild -license accept")
        XCTAssertTrue(d.retryable)
        XCTAssertFalse(d.needsReport)
    }

    func testMissingCommandLineTools() {
        let d = EngineInstallDiagnosis.diagnose(log: "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun")
        XCTAssertEqual(d.kind, .missingCompiler)
        XCTAssertEqual(d.command, "xcode-select --install")
    }

    func testNoPrebuiltWheelUnderOnlyBinary() {
        let d = EngineInstallDiagnosis.diagnose(log: "ERROR: No matching distribution found for webrtcvad==2.0.10")
        XCTAssertEqual(d.kind, .noPrebuiltWheel)
        XCTAssertTrue(d.needsReport)
        XCTAssertFalse(d.retryable)
        XCTAssertNil(d.command)
    }

    func testNetworkSignatures() {
        for snippet in [
            "curl: (28) Failed to connect to github.com port 443 after 30001 ms",
            "ReadTimeoutError: HTTPSConnectionPool(host='files.pythonhosted.org', port=443): Read timed out.",
            "[bootstrap] ERROR: 模型下載失敗；請檢查網路後重跑本腳本（會從斷點續傳）",
        ] {
            XCTAssertEqual(EngineInstallDiagnosis.diagnose(log: snippet).kind, .network, snippet)
        }
    }

    func testDiskPermissionPlatform() {
        XCTAssertEqual(EngineInstallDiagnosis.diagnose(log: "OSError: [Errno 28] No space left on device").kind, .diskFull)
        XCTAssertEqual(EngineInstallDiagnosis.diagnose(log: "mkdir: /Library/Application Support/UTUVO Type: Permission denied").kind, .permissionDenied)
        let arch = EngineInstallDiagnosis.diagnose(log: "[bootstrap] ERROR: 本機引擎需要 Apple Silicon（偵測到 x86_64）。")
        XCTAssertEqual(arch.kind, .notAppleSilicon)
        XCTAssertFalse(arch.retryable)
    }

    func testCancelledOverridesLog() {
        let d = EngineInstallDiagnosis.diagnose(log: xcodeLicenseLog, cancelled: true)
        XCTAssertEqual(d.kind, .cancelled)
    }

    func testUnknownAsksForReport() {
        let d = EngineInstallDiagnosis.diagnose(log: "[bootstrap] ERROR: something new happened")
        XCTAssertEqual(d.kind, .unknown)
        XCTAssertTrue(d.needsReport)
    }

    /// 反向：一份成功／進行中的 log 不該被判成任何錯誤（誤擋＝缺陷）。
    func testCleanLogIsUnknownNotMisdiagnosed() {
        let clean = """
        [bootstrap] venv 已存在，跳過建立
        [bootstrap] 安裝相依套件（requirements.txt）
        [bootstrap] 下載 ASR 模型 mlx-community/Qwen3-ASR-0.6B-6bit
        [bootstrap] 完成。開啟 UTUVO Type.app 按快捷鍵即可聽寫（完全本機，不需網路）。
        """
        XCTAssertEqual(EngineInstallDiagnosis.diagnose(log: clean).kind, .unknown)
    }

    func testReportExcerptMasksHomeAndKeepsTail() {
        let log = (1...100).map { "line \($0) /Users/someone/Library/x" }.joined(separator: "\n")
        let excerpt = EngineInstallDiagnosis.reportExcerpt(log: log, maxLines: 5)
        XCTAssertEqual(excerpt.split(separator: "\n").count, 5)
        XCTAssertFalse(excerpt.contains("/Users/someone"))
        XCTAssertTrue(excerpt.contains("~/Library/x"))
        XCTAssertTrue(excerpt.contains("line 100"))
    }
}
