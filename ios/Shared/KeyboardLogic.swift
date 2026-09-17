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

    /// 錄音前的提示（Typeless：Tap to speak／Speak to edit／Release to translate）。
    var idleHint: String {
        switch self {
        case .dictate: return "點一下開始說"
        case .edit: return "說出要怎麼改"
        case .translate(let target): return "說中文，貼上\(target.zh)"
        }
    }

    var recordingHint: String {
        switch self {
        case .dictate: return "再點一下完成"
        case .edit: return "說完再點一下，改寫會取代選取"
        case .translate(let target): return "再點一下完成，翻成\(target.zh)"
        }
    }

    /// 聽寫模式邊講邊把逐字稿插進文件；編輯／翻譯模式只在膠囊裡預覽，定稿才動文件。
    var insertsPartials: Bool {
        if case .dictate = self { return true }
        return false
    }
}

/// 翻譯目標：與主 app 的 TranslationService.targets 同一份。
struct TranslationTarget: Equatable, Sendable, Identifiable {
    let code: String
    let zh: String
    let en: String
    var id: String { code }

    static let all: [TranslationTarget] = TranslationService.targets.map {
        TranslationTarget(code: $0.code, zh: $0.zh, en: $0.en)
    }
    /// 長按弧形選單預設放前五個（英、日、韓、繁中、法），中間是英文。
    static let quickPick: [TranslationTarget] = {
        let order = ["ja", "ko", "en", "zh-Hant", "fr"]
        return order.compactMap { code in all.first { $0.code == code } }
    }()
}

enum ReturnKeyLabel {
    /// 送出鍵跟著宿主 app 的 returnKeyType 走（Typeless 的 "send" 膠囊）。
    static func text(for type: UIReturnKeyType?) -> String {
        switch type {
        case .send: return "送出"
        case .search, .google, .yahoo: return "搜尋"
        case .go: return "前往"
        case .done: return "完成"
        case .join: return "加入"
        case .next: return "下一個"
        case .continue: return "繼續"
        case .route: return "路線"
        case .emergencyCall: return "撥打"
        default: return "換行"
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
}
