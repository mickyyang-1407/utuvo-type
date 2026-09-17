import XCTest
@testable import UTUVOTypeCore

/// 不準把秘密／個資／憑證 commit 進 repo 的衛生測試。
/// 這是「閘門要有紅燈輸入」的具體落實——沒有這條測試，整個 verify-scaffold
/// 可能一直綠、但其實根本沒在檢查。
final class HygieneTests: XCTestCase {

    /// 掃 source tree 裡的「看起來像 secret」的字面。
    /// 規則保守：常見 API key prefix、email、webhook URL、token 形狀。
    /// 已知 false-positive 風險高，所以只挑高訊號的形狀。
    func testSourceTreeHasNoSecretLikeLiterals() throws {
        let repoRoot = TestSupport.repoRoot()
        let scanner = SecretLiteralScanner()
        let findings = try scanner.scan(repoRoot: repoRoot)
        XCTAssertTrue(findings.isEmpty,
                      "發現 secret-like literal：\n" +
                      findings.map { "  \($0.path):\($0.line): \($0.snippet)" }.joined(separator: "\n"))
    }

    /// 任何 config/*.example.json 都不應該含真實的金鑰形狀。
    func testExampleConfigsHaveNoRealKeys() throws {
        let repoRoot = TestSupport.repoRoot()
        let configDir = URL(fileURLWithPath: repoRoot).appendingPathComponent("config")
        let entries = try FileManager.default.contentsOfDirectory(atPath: configDir.path)
        for entry in entries where entry.hasSuffix(".json") {
            let url = configDir.appendingPathComponent(entry)
            let body = try String(contentsOf: url, encoding: .utf8)
            // 確認沒有真的金鑰 prefix（example 應只有 placeholder）
            XCTAssertFalse(body.contains("sk-"), "\(entry) 含 sk- 前綴")
            XCTAssertFalse(body.contains("Bearer "), "\(entry) 含 Bearer token")
            // email shape 簡易掃
            let emailRegex = try NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            XCTAssertEqual(emailRegex.numberOfMatches(in: body, range: range), 0,
                           "\(entry) 含 email 字面")
            // webhook URL 簡易掃
            XCTAssertFalse(body.contains("hooks.slack.com"), "\(entry) 含 slack webhook")
            XCTAssertFalse(body.contains("script.google.com"), "\(entry) 含 Apps Script webhook")
        }
    }

    /// Prompt 可以、也必須提到模型不應輸出的 JSON／think 政策；
    /// 但不能真的含有 Markdown code fence 結構。
    func testPromptContainsOutputPolicyWithoutStructuralFence() throws {
        let repoRoot = TestSupport.repoRoot()
        let promptsDir = URL(fileURLWithPath: repoRoot).appendingPathComponent("prompts")
        let entries = try FileManager.default.contentsOfDirectory(atPath: promptsDir.path)
        for entry in entries where entry.hasSuffix(".txt") {
            let url = promptsDir.appendingPathComponent(entry)
            let body = try String(contentsOf: url, encoding: .utf8)
            let required = "不要輸出分析、推理、JSON、Markdown code fence 或 <think> 標籤。"
            XCTAssertTrue(body.contains(required), "\(entry) 缺少輸出政策")
            XCTAssertNoThrow(try PromptLoader.parseTemplate(name: entry, body: body),
                             "\(entry) 含真正的 structural fence")
        }
    }

    /// 不准在 repo 內印出或寫出任何 secret 字面。
    func testNoSecretsInReports() throws {
        let repoRoot = TestSupport.repoRoot()
        let reportPath = URL(fileURLWithPath: repoRoot).appendingPathComponent("benchmarks/report.json")
        // report.json 不一定存在（M0 還沒跑），存在時也要乾淨。
        guard FileManager.default.fileExists(atPath: reportPath.path) else { return }
        let body = try String(contentsOf: reportPath, encoding: .utf8)
        XCTAssertFalse(body.contains("sk-"), "report.json 含 sk- 前綴")
        XCTAssertFalse(body.contains("Bearer "), "report.json 含 Bearer token")
    }
}
