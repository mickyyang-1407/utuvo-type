import Foundation
import UIKit

/// 鍵盤的純邏輯（無 UI、可測）：模式判定、送出鍵文案、用量統計。
/// 對齊 Typeless：有選取文字＝「說出要怎麼改」；長按麥克風選語言＝「放開就翻譯」；其餘＝聽寫。
enum KeyboardMode: Equatable, Sendable {
    case dictate
    case edit(selection: String)
    case translate(target: TranslationTarget)

    /// 決策順序：翻譯（使用者剛剛長按選了語言）> 編輯（有選取）> 聽寫。
    static func decide(selectedText: String?, translateTarget: TranslationTarget?) -> KeyboardMode {
        if let translateTarget { return .translate(target: translateTarget) }
        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .edit(selection: selectedText)
        }
        return .dictate
    }

    /// 鍵盤光球停止錄音後會進入「整理中…」（等主 app 重辨識回來）。這時如果再按一次光球開新一段，
    /// 主 app 還在為前一段做雲端／Qwen 重辨識，最長等 6 秒；前一段定稿回來時 activeCommandID 已經被
    /// 換成新的，`guard self.state.commandID == id` 不成立就整句丟掉——上一句整句不見。
    /// 修法：開始下一段前，若條件成立，把目前拿到的辨識結果當上一段定稿貼上，再開始下一段。
    /// 翻譯／編輯模式不適用（它們根本沒有「整理中」階段）。
    static func shouldFlushPendingBeforeStart(isDictating: Bool, hasPendingCommand: Bool,
                                              isRecording: Bool, lastTranscript: String) -> Bool {
        guard isDictating else { return false }
        guard hasPendingCommand else { return false }
        guard !isRecording else { return false }
        return !lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// R2-2（CodeX 複查 2026-09-25）→ R3-3（luna-review 2026-09-25）：主 app 已經把 Apple 定稿寫進共享
    /// state（partial／final），但鍵盤 bridgeUpdated 還沒收到通知時，使用者又按一次光球開新一段。鍵盤
    /// 自己的 `lastRawTranscript` 這時是空的，舊結果就會被丟。改讀主 app 的 shared state 撐場：
    /// - `pendingID` 為 nil 或跟 shared 的 commandID 不符 → 回 local（不要拿錯段的文字）。
    /// - 同 ID 且 sharedFinal 去空白非空 → 直接回 sharedFinal（R3-3：定稿權威最高，不比長度；
    ///   定稿可能比 partial 短，但已是主 app 走過字典的最終版）。
    /// - 否則 sharedPartial 比 local 長 → 回 sharedPartial；shared 全空白也視為沒有。
    static func pendingTranscript(local: String, pendingID: UUID?, sharedCommandID: UUID?,
                                  sharedPartial: String, sharedFinal: String?) -> String {
        guard let pendingID, pendingID == sharedCommandID else { return local }
        if let sharedFinal, !sharedFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sharedFinal
        }
        let candidateTrimmed = sharedPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        let localTrimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidateTrimmed.isEmpty && candidateTrimmed.count >= localTrimmed.count {
            return sharedPartial
        }
        return local
    }

    /// R3-4（luna-review 2026-09-25）：合併 `shouldFlushPendingBeforeStart` 與 `pendingTranscript`，
    /// 給 `micTapped()` 當唯一入口，回要貼的文字或 nil（不 flush）。
    /// 非聽寫／錄音中／沒 pending → nil；否則用主 app shared state 撐場算出文字，去空白後非空才回。
    static func flushText(isDictating: Bool, isRecording: Bool, pendingID: UUID?,
                          local: String, sharedCommandID: UUID?, sharedPartial: String, sharedFinal: String?) -> String? {
        guard isDictating, !isRecording, pendingID != nil else { return nil }
        let transcript = pendingTranscript(local: local, pendingID: pendingID,
                                           sharedCommandID: sharedCommandID,
                                           sharedPartial: sharedPartial, sharedFinal: sharedFinal)
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : transcript
    }

    /// 錄音前的提示（Typeless：Tap to speak／Speak to edit／Release to translate）。
    var idleHint: String {
        switch self {
        case .dictate: return String(localized: "點一下開始說")
        case .edit: return String(localized: "說出要怎麼改")
        case .translate(let target): return String(localized: "說中文，貼上\(target.displayName)")
        }
    }

    var recordingHint: String {
        switch self {
        case .dictate: return String(localized: "再點一下完成")
        case .edit: return String(localized: "說完再點一下，改寫會取代選取")
        case .translate(let target): return String(localized: "再點一下完成，翻成\(target.displayName)")
        }
    }

    /// 講話中的逐字稿只在字幕帶預覽，一律等按停止、定稿才動文件（2026-09-18 真機回報：邊講邊插會讓人
    /// 在講完、還沒按停止時就能送出，按停止後定稿又插一次＝重複送出）。三種模式都不邊講邊插。
    var insertsPartials: Bool { false }
}

/// 翻譯目標：與主 app 的 TranslationService.targets 同一份。
struct TranslationTarget: Equatable, Sendable, Identifiable {
    let code: String
    /// 繁中原名：送進語言模型的提示詞用這個（提示詞不跟介面語言走）。
    let zh: String
    let en: String
    var id: String { code }

    /// 介面上顯示的語言名（跟系統語言走：繁中介面＝原名，简中介面＝简体名）。
    /// 逐一寫成 String(localized:) 字面值，編譯器才抽得到 key。
    var displayName: String {
        switch code {
        case "zh-Hant": return String(localized: "繁體中文")
        case "zh-Hans": return String(localized: "簡體中文")
        case "en": return String(localized: "英文")
        case "ja": return String(localized: "日文")
        case "ko": return String(localized: "韓文")
        case "fr": return String(localized: "法文")
        case "de": return String(localized: "德文")
        case "es": return String(localized: "西班牙文")
        case "it": return String(localized: "義大利文")
        case "pt": return String(localized: "葡萄牙文")
        case "nl": return String(localized: "荷蘭文")
        case "ru": return String(localized: "俄文")
        case "uk": return String(localized: "烏克蘭文")
        case "pl": return String(localized: "波蘭文")
        case "tr": return String(localized: "土耳其文")
        case "ar": return String(localized: "阿拉伯文")
        case "hi": return String(localized: "印地文")
        case "id": return String(localized: "印尼文")
        case "th": return String(localized: "泰文")
        case "vi": return String(localized: "越南文")
        default: return zh
        }
    }

    static let all: [TranslationTarget] = TranslationService.targets.map {
        TranslationTarget(code: $0.code, zh: $0.zh, en: $0.en)
    }
    /// 鍵盤長按弧上的語言：使用者在主 app 選的（最多 5 個，照選的順序）；沒選過用預設。
    static var quickPick: [TranslationTarget] { QuickPickStore.targets() }
}

/// 鍵盤長按翻譯要出現哪些語言（App Group，主 app 寫、鍵盤讀）。
enum QuickPickStore {
    static let key = "utuvo.type.translate.quickPick"
    static let maxCount = 5
    static let defaultCodes = ["ja", "ko", "en", "zh-Hant", "fr"]

    static var defaults: UserDefaults { KeyboardPresence.defaults }

    static func codes(in defaults: UserDefaults = QuickPickStore.defaults) -> [String] {
        resolve(defaults.stringArray(forKey: key))
    }

    static func setCodes(_ codes: [String], in defaults: UserDefaults = QuickPickStore.defaults) {
        defaults.set(resolve(codes), forKey: key)
    }

    static func targets(in defaults: UserDefaults = QuickPickStore.defaults) -> [TranslationTarget] {
        codes(in: defaults).compactMap { code in TranslationTarget.all.first { $0.code == code } }
    }

    /// 清掉不認得的代碼與重複、最多 5 個；清完是空的就回預設（鍵盤長按不能沒有語言）。
    static func resolve(_ stored: [String]?) -> [String] {
        let known = Set(TranslationTarget.all.map(\.code))
        var seen = Set<String>()
        let cleaned = (stored ?? []).filter { known.contains($0) && seen.insert($0).inserted }.prefix(maxCount)
        return cleaned.isEmpty ? defaultCodes : Array(cleaned)
    }

    /// 在已選清單裡切換一個語言：已選就移除（最後一個不能移除），未選就加到最後（滿 5 個不加）。
    static func toggled(_ code: String, in current: [String]) -> [String] {
        if let i = current.firstIndex(of: code) {
            guard current.count > 1 else { return current }
            var next = current
            next.remove(at: i)
            return next
        }
        guard current.count < maxCount else { return current }
        return current + [code]
    }
}

enum ReturnKeyLabel {
    /// 送出鍵跟著宿主 app 的 returnKeyType 走（Typeless 的 "send" 膠囊）。
    static func text(for type: UIReturnKeyType?) -> String {
        switch type {
        case .send: return String(localized: "送出")
        case .search, .google, .yahoo: return String(localized: "搜尋")
        case .go: return String(localized: "前往")
        case .done: return String(localized: "完成")
        case .join: return String(localized: "加入")
        case .next: return String(localized: "下一個")
        case .continue: return String(localized: "繼續")
        case .route: return String(localized: "路線")
        case .emergencyCall: return String(localized: "撥打")
        default: return String(localized: "換行")
        }
    }
}

/// 依 app 的語氣（Typeless「different tones for each app」的鍵盤版）：
/// 鍵盤 extension 看不到宿主 app 是誰，但看得到 return 鍵是「送出」還是「換行」——
/// 送出＝聊天框（LINE／訊息／Slack），單句訊息不加句號；換行／完成＝文件，照原樣。
enum ToneHint: Equatable, Sendable {
    case chat
    case document

    static func infer(returnKeyType: UIReturnKeyType?) -> ToneHint {
        returnKeyType == .send ? .chat : .document
    }

    /// Return 鍵是一般換行（或拿不到）才保留分段換行；送出／搜尋／前往／完成等＝單行框，
    /// 插入換行可能直接觸發送出（2026-09-19 長文分段一起加）。
    static func allowsLineBreaks(returnKeyType: UIReturnKeyType?) -> Bool {
        guard let returnKeyType else { return true }
        return returnKeyType == .default
    }

    private static let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]

    /// 聊天：一句話（只有結尾一個句號、40 字以內）就把句號拿掉；多句或長訊息不動。
    static func apply(_ text: String, tone: ToneHint) -> String {
        guard tone == .chat, let last = text.last, last == "。" else { return text }
        let body = text.dropLast()
        guard body.count <= 40, !body.contains(where: { terminators.contains($0) }) else { return text }
        return String(body)
    }
}

/// 主 app 首頁的用量統計（Typeless 2.6 的 Home insights）。
/// 字數：CJK 每字算一，其他以空白切詞；省下時間＝打字 36 wpm 與口說 150 wpm 的差。
struct UsageInsights: Equatable, Sendable {
    var totalWords: Int
    var weekWords: Int
    var sessions: Int
    var minutesSaved: Double

    static func wordCount(_ text: String) -> Int {
        var cjk = 0
        var latinWords = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
            if isCJK {
                cjk += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if !inWord { latinWords += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return cjk + latinWords
    }

    static func compute(records: [DictationRecord], now: Date = Date()) -> UsageInsights {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        var total = 0
        var week = 0
        for record in records {
            let n = wordCount(record.cleaned)
            total += n
            if record.date >= weekAgo { week += n }
        }
        let minutes = Double(total) * (1.0 / 36.0 - 1.0 / 150.0)
        return UsageInsights(totalWords: total, weekWords: week, sessions: records.count, minutesSaved: max(0, minutes))
    }
}

/// 鍵盤是否已經被開啟過（鍵盤第一次載入時寫進 App Group）；主 app 用它決定要不要顯示啟用教學。
enum KeyboardPresence {
    static let key = "utuvo.type.keyboard.seen"
    static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard }
    static var seen: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    /// 「繁」鍵盤用注音還是拼音打（值 "zhuyin"／"pinyin"；沒設＝注音）。鍵盤與主 app 設定頁共用。
    static let hantInputKey = "utuvo.type.keyboard.hantInput"
    static var hantUsesPinyin: Bool {
        get { defaults.string(forKey: hantInputKey) == "pinyin" }
        set { defaults.set(newValue ? "pinyin" : "zhuyin", forKey: hantInputKey) }
    }
}
