import Foundation

/// 鍵盤 extension 的介面語言。
///
/// 鍵盤原本跟著**系統**語言走：系統是英文、講的是中文的人（10-15 Micky 的 17PMX）會看到
/// 「Dictation／Tap once to start talking／New line」跟「繁／简／EN」混在一起。
/// 順序：主 app 明確選的介面語言 → 聽寫語言（講中文就中文介面）→ 系統。
/// 日文／韓文聽寫沒有對應的介面翻譯，交回系統。
///
/// 換法：鍵盤 process 一載入（`KeyboardLanguageBootstrap.m` 的 constructor，任何字串查詢之前）
/// 就把結果寫進**鍵盤自己**的 `AppleLanguages`。攔 Bundle 的 `localizedString` 沒用——
/// iOS 18.4 起 `String(localized:)` 兩條 Bundle 方法都不經過（單元測試實測）。
enum KeyboardUILanguage {
    static func resolve(interface: InterfaceLanguage, dictation: String?) -> String? {
        if interface != .system { return interface.rawValue }
        // 沒設過聽寫語言＝鍵盤用預設的繁中聽寫（KeyboardViewController.language），介面也要跟著繁中。
        switch dictation.map({ DictationLanguage(rawValue: $0) }) ?? .traditionalChinese {
        case .traditionalChinese: return "zh-Hant"
        case .simplifiedChinese: return "zh-Hans"
        case .englishUS: return "en"
        default: return nil
        }
    }

    /// 目前設定下鍵盤該用的語言（讀 App Group）。
    static func current(group: UserDefaults = KeyboardPresence.defaults) -> String? {
        resolve(interface: InterfaceLanguage(rawValue: group.string(forKey: InterfaceLanguageStore.settingKey) ?? "") ?? .system,
                dictation: group.string(forKey: "utuvo.type.keyboard.language"))
    }

    /// 寫進 `store` 的 `AppleLanguages`；nil＝移除覆寫、回到系統。
    static func apply(_ code: String?, to store: UserDefaults) {
        if let code { store.set([code], forKey: "AppleLanguages") } else { store.removeObject(forKey: "AppleLanguages") }
    }
}

/// 給 `KeyboardLanguageBootstrap.m` 在載入時呼叫（只有鍵盤 target 會呼叫它）。
@objc(UTUVOKeyboardUILanguageLoader)
final class KeyboardUILanguageLoader: NSObject {
    @objc static func applyAtLaunch() {
        KeyboardUILanguage.apply(KeyboardUILanguage.current(), to: .standard)
    }
}
