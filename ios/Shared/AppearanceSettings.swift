import SwiftUI

/// App 內的介面語言（每個 App 各自覆寫，值寫進這個 App 自己的 `AppleLanguages`）。
///
/// 為什麼不用 `LocaleManager`／`Bundle`：iOS 沒有公開 API 可以在執行期換 App 的語言，
/// 標準做法就是寫 `AppleLanguages`（`UserDefaults.standard`），**重開 App 後** Bundle 才讀得到新的值。
/// 這個開關因此必須提示「重開 App 才會生效」，而且「跟隨系統」是**移除覆寫**、不是寫入系統語言
/// （寫入會讓使用者離開那個語言後再也跟不回去）。
///
/// 鍵盤 extension 是另一個 process、另一個 Bundle，它的介面語言跟著**系統**走——
/// 這件事在設定頁要誠實寫出來，不要讓使用者以為鍵盤也會變。
enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// 寫進 `AppleLanguages` 的值；`system` 是 nil＝不覆寫。
    var appleLanguages: [String]? {
        self == .system ? nil : [rawValue]
    }

    func displayName(traditional: Bool) -> String {
        switch self {
        case .system: return traditional ? String(localized: "跟隨系統") : "System"
        case .zhHant: return traditional ? String(localized: "繁體中文") : "繁體中文"
        case .zhHans: return traditional ? String(localized: "简体中文") : "简体中文"
        case .en: return traditional ? String(localized: "English") : "English"
        }
    }
}

/// 介面語言的讀寫。App Group 是**只寫入介面語言自己的偏好**（讓設定頁重開時讀得回來），
/// `AppleLanguages` 則一定要寫在這個 App 自己的 `UserDefaults.standard`（Bundle 只讀自己的）。
enum InterfaceLanguageStore {
    static let settingKey = "utuvo.type.ios.interfaceLanguage"
    /// 設定頁讀寫用（App Group：主 app 與鍵盤共用同一份設定存檔慣例）。
    static var defaults: UserDefaults { KeyboardPresence.defaults }

    static var current: InterfaceLanguage {
        get { InterfaceLanguage(rawValue: defaults.string(forKey: settingKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: settingKey) }
    }

    /// 把覆寫寫進**這個 App 自己**的 `UserDefaults.standard`。
    /// - 參數 `store`：測試用；正式呼叫一律是 `UserDefaults.standard`。
    /// - 回傳是否需要重開 App（＝選的語言跟**上次實際套用的**不一樣）。
    @discardableResult
    static func apply(_ language: InterfaceLanguage, to store: UserDefaults = .standard) -> Bool {
        // 「上次實際套用的」存**同一個 store**（`store` 自己），不能拿 App Group 的值來比：
        // `AppleLanguages` 寫在 `store`（=.standard）、`appliedKey` 卻寫在 App Group 會讓兩邊狀態不一致；
        // 使用者選「跟隨系統」時若 `previous == .system`（App Group 缺值 → 預設 .system）就**提早 return**，
        // 根本不會呼叫 `removeObject`，上一次寫進去的 `AppleLanguages` 就**殘留**下來，
        // 使用者看到「跟隨系統」但實際還是上一個語言（review-agy-ios-C finding 4）。
        //
        // 更保險的一層：`appliedKey` 缺值（或壞值）時**不看它、直接重寫一次**，
        // 寧可多重寫一次 `AppleLanguages`（結果相同），也不要因為「以為已經是這個值」而漏掉移除。
        let stored = store.string(forKey: appliedKey).flatMap(InterfaceLanguage.init(rawValue:))
        if let previous = stored, previous == language { return false }
        if let languages = language.appleLanguages {
            store.set(languages, forKey: "AppleLanguages")
        } else {
            // 跟隨系統＝**移除覆寫**。移除之後讀到的會回到系統寫進來的那份（`en-TW`、`zh-Hant-TW`…），
            // 那正是「跟隨系統」該有的樣子——所以這裡不是把 key 刪成 nil。
            store.removeObject(forKey: "AppleLanguages")
        }
        store.set(language.rawValue, forKey: appliedKey)
        return true
    }

    /// 記錄「上次實際套用的語言」，跟 `AppleLanguages` 的實際值分開存。
    static let appliedKey = "utuvo.type.ios.appliedInterfaceLanguage"

    /// 這個 App 現在實際會讀到的介面語言（`Bundle.preferredLocalizations.first`）。
    /// 設定頁用它顯示「現在生效的是什麼」——寫入之後當下還是舊值，重開才是新的。
    static func effectiveLocalization(bundle: Bundle = .main) -> String {
        bundle.preferredLocalizations.first ?? "zh-Hant"
    }

    /// 重開後會變成什麼（讓使用者確認自己選的真的會生效）。
    static func projectedLocalization(for language: InterfaceLanguage) -> String {
        language.appleLanguages?.first ?? effectiveLocalization()
    }
}

/// App 內的外觀（淺色／深色／跟隨系統）。
///
/// 這個**要**存 App Group：鍵盤 extension 讀不到主 app 的偏好，兩邊要跟著同一個外觀走。
/// 鍵盤那邊不是用 `preferredColorScheme`（extension 沒有 SwiftUI Scene），而是讀同一個值
/// 設 `UIInputViewController.overrideUserInterfaceStyle`。
enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 鍵盤 extension 要設的 `overrideUserInterfaceStyle`。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    func displayName(traditional: Bool) -> String {
        switch self {
        case .system: return traditional ? String(localized: "跟隨系統") : "System"
        case .light: return traditional ? String(localized: "淺色") : "Light"
        case .dark: return traditional ? String(localized: "深色") : "Dark"
        }
    }
}

enum AppearanceStore {
    static let settingKey = "utuvo.type.ios.appearance"

    /// App Group 共用值（主 app 與鍵盤 extension 同一份）。
    static var defaults: UserDefaults { KeyboardPresence.defaults }

    static var current: AppearancePreference {
        get { AppearancePreference(rawValue: defaults.string(forKey: settingKey) ?? "") ?? .system }
        // 設定值一改就通知鍵盤：**已經開著的鍵盤也要立刻換外觀**（review-agy-ios-C finding 3）。
        // 只靠鍵盤的 `viewWillAppear` 的話，使用者在主 app 換了外觀、鍵盤還開著就完全不動。
        set {
            guard newValue != current else { return }
            defaults.set(newValue.rawValue, forKey: settingKey)
            VoiceBridge.post(.appearance)
        }
    }
}
