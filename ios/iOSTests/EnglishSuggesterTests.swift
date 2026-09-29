import XCTest
import UTUVOTypeCore
@testable import UTUVOTypeiOS

/// 英文建議列在 iOS 上的真實來源（UITextChecker）：補完、拼字建議、大小寫、效能。
@MainActor
final class EnglishSuggesterTests: XCTestCase {
    func testCompletionsAndGuesses() throws {
        let s = EnglishSuggester()
        let hel = s.suggestions(for: "hel")
        XCTAssertTrue(hel.contains("hello") || hel.contains("help"), "hel → hello／help，得到 \(hel)")
        let tomor = s.suggestions(for: "Tomor")
        XCTAssertTrue(tomor.contains("Tomorrow"), "照打的大小寫：Tomor → Tomorrow，得到 \(tomor)")
        let recieve = s.suggestions(for: "recieve")
        XCTAssertTrue(recieve.contains("receive"), "拼錯 → 拼字建議，得到 \(recieve)")
        XCTAssertEqual(s.suggestions(for: ""), [])
        XCTAssertLessThanOrEqual(hel.count, EnglishSuggestions.defaultLimit)
        XCTAssertFalse(hel.contains("hel"), "不重複列出打的字本身")
    }

    func testSuggestionLatencyPerKey() throws {
        let s = EnglishSuggester()
        _ = s.suggestions(for: "a")            // 第一次載入字典
        let words = ["t", "th", "the", "ther", "there", "q", "qu", "qui", "quic", "quick", "b", "br", "bro", "brow", "brown"]
        var worst = 0.0
        for w in words {
            let t = CFAbsoluteTimeGetCurrent()
            _ = s.suggestions(for: w)
            worst = max(worst, CFAbsoluteTimeGetCurrent() - t)
        }
        print("ENGLISH-SUGGEST worst per key \(worst * 1000) ms")
        XCTAssertLessThan(worst, 0.050, "最慢一鍵 \(worst * 1000) ms")
    }
}
