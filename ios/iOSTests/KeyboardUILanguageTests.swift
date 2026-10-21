import XCTest
import UIKit
@testable import UTUVOTypeiOS

/// 鍵盤介面語言：主 app 明選的介面語言 → 聽寫語言 → 系統（10-15 英文系統＋中文聽寫看到中英混雜）。
final class KeyboardUILanguageTests: XCTestCase {
    func testExplicitInterfaceLanguageWins() {
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .en, dictation: "zh-TW"), "en")
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .zhHans, dictation: "en-US"), "zh-Hans")
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .zhHant, dictation: nil), "zh-Hant")
    }

    func testSystemFollowsDictationLanguage() {
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .system, dictation: "zh-TW"), "zh-Hant")
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .system, dictation: "zh-CN"), "zh-Hans")
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .system, dictation: "en-US"), "en")
        // 沒有介面翻譯的聽寫語言、沒設定：交回系統。
        XCTAssertNil(KeyboardUILanguage.resolve(interface: .system, dictation: "ja-JP"))
        // 沒設過＝鍵盤預設的繁中聽寫，介面跟著繁中（不然英文系統會又是中英混雜）。
        XCTAssertEqual(KeyboardUILanguage.resolve(interface: .system, dictation: nil), "zh-Hant")
    }

    /// 從 App Group 讀設定、寫進（鍵盤自己的）AppleLanguages；跟隨系統＝移除覆寫。
    func testCurrentReadsGroupAndApplyWritesAppleLanguages() throws {
        let suite = "KeyboardUILanguageTests-\(UUID().uuidString)"
        let group = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = try XCTUnwrap(UserDefaults(suiteName: suite + "-store"))
        defer { group.removePersistentDomain(forName: suite); store.removePersistentDomain(forName: suite + "-store") }
        group.set("zh-TW", forKey: "utuvo.type.keyboard.language")
        XCTAssertEqual(KeyboardUILanguage.current(group: group), "zh-Hant")
        group.set("en", forKey: InterfaceLanguageStore.settingKey)
        XCTAssertEqual(KeyboardUILanguage.current(group: group), "en")
        KeyboardUILanguage.apply("en", to: store)
        XCTAssertEqual(store.persistentDomain(forName: suite + "-store")?["AppleLanguages"] as? [String], ["en"])
        KeyboardUILanguage.apply(nil, to: store)
        XCTAssertNil(store.persistentDomain(forName: suite + "-store")?["AppleLanguages"])
    }

    func testReturnTitleShrinksToFit() {
        XCTAssertEqual(ReturnKeyLabel.fittingFontSize(for: "換行", width: 40), 13)
        XCTAssertEqual(ReturnKeyLabel.fittingFontSize(for: "return", width: 40), 13)
        let long = ReturnKeyLabel.fittingFontSize(for: "New line", width: 40)
        XCTAssertLessThan(long, 13)
        let width = ("New line" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: long, weight: .semibold)]).width
        XCTAssertLessThanOrEqual(width, 40, "縮完要放得進圓鍵")
    }
}

/// 教學裡「貼上」Groq key 的檢查與錯誤說明。
final class GroqKeyCheckTests: XCTestCase {
    func testLooksLikeGroqKey() {
        XCTAssertTrue(GroqKeyCheck.looksLikeGroqKey("gsk_" + String(repeating: "a", count: 52)))
        XCTAssertFalse(GroqKeyCheck.looksLikeGroqKey("hello"))
        XCTAssertFalse(GroqKeyCheck.looksLikeGroqKey("gsk_short"))
        XCTAssertFalse(GroqKeyCheck.looksLikeGroqKey("gsk_" + String(repeating: "a", count: 30) + " " + String(repeating: "b", count: 20)))
        XCTAssertFalse(GroqKeyCheck.looksLikeGroqKey("sk-" + String(repeating: "a", count: 52)), "OpenAI 的 key 不是 Groq 的")
    }

    func testMessagesTellWhatToDo() {
        XCTAssertTrue(GroqKeyCheck.message(for: SmartCleanup.Failure.http(401)).contains("不對"))
        XCTAssertTrue(GroqKeyCheck.message(for: SmartCleanup.Failure.rateLimited(retryAfter: 3)).contains("額度"))
        XCTAssertTrue(GroqKeyCheck.message(for: SmartCleanup.Failure.timeout).contains("已存好"))
    }
}
