import XCTest
@testable import UTUVOTypeCore

/// 證明 SecretLiteralScanner 不是「永遠綠燈」的測試。
/// 這條不過的話，衛生檢查等於沒做。
final class SecretLiteralScannerTests: XCTestCase {

    func testScannerDetectsKnownBadShapes() {
        let samples = [
            ("aws", "A" + "KIAIOSFODNN7EXAMPLE"),
            ("openai", "s" + "k-abcdefghijklmnopqrstuv"),
            ("slack-bot", "xoxb-" + "1234567890-abcdef"),
            ("email", "contact: someone" + "@example.com"),
            ("email-2x-domain", "ops" + "@2x.com"),
            ("slack-webhook", "POST https://hooks.slack.com/" + "services/T0/B0/XXX"),
            ("apps-script", "https://script.google.com/" + "macros/s/AKfycbwXXX/exec"),
            ("bearer", "Authorization: Bearer " + "abcdefghijklmnopqrstuv")
        ]
        for (name, line) in samples {
            var hit = false
            for rule in SecretLiteralScanner.rules {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if rule.regex.numberOfMatches(in: line, range: range) > 0 {
                    hit = true
                    break
                }
            }
            XCTAssertTrue(hit, "scanner should detect \(name) in: \(line)")
        }
    }

    func testScannerIgnoresNormalCode() {
        let cleanSamples = [
            "let x = 42",
            "// 這是一個普通的註解",
            "let name = \"UTUVO Type\"",
            "let count = 1_200_000",
            "let text = \"hello world\"",
            // Apple 圖檔倍率命名不是 email
            "Image.open(\"icon_512x512@2x.png\")",
            "\"filename\": \"BrandMark@3x.png\""
        ]
        for line in cleanSamples {
            var hit = false
            for rule in SecretLiteralScanner.rules {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if rule.regex.numberOfMatches(in: line, range: range) > 0 {
                    hit = true
                    break
                }
            }
            XCTAssertFalse(hit, "scanner false-positived on: \(line)")
        }
    }

    /// 反向：確保 HygieneTests.testSourceTreeHasNoSecretLikeLiterals 在真實
    /// 乾淨 repo 上能通過。如果這條開始紅，就是 repo 內真的出現了可疑 literal。
    func testScannerAcceptsCleanRepo() throws {
        let scanner = SecretLiteralScanner()
        let findings = try scanner.scan(repoRoot: TestSupport.repoRoot())
        XCTAssertTrue(findings.isEmpty, "發現 secret-like literal:\n" +
                      findings.map { "  \($0.path):\($0.line): \($0.snippet)" }.joined(separator: "\n"))
    }
}
