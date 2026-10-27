import Foundation
import UIKit
import UTUVOTypeCore

/// 鍵盤模式鍵的四個檔位（照 Android `VoiceModes.VoiceMode` 的同一組）。
/// `dictate` 是預設；使用者點模式鍵才會換到別的三個。
enum VoiceModeKind: String, CaseIterable, Equatable, Sendable {
    case dictate, helpWrite, speakToEdit, askAnything

    /// 模式鍵上顯示的短名。
    var shortName: String {
        switch self {
        case .dictate: return String(localized: "聽寫")
        case .helpWrite: return String(localized: "幫我寫")
        case .speakToEdit: return String(localized: "改寫")
        case .askAnything: return String(localized: "問問題")
        }
    }

    /// 下拉選單裡每個模式底下的一行說明（10-15 Micky：循環切換看不出現在在哪個模式）。
    var detail: String {
        switch self {
        case .dictate: return String(localized: "講什麼就打什麼")
        case .helpWrite: return String(localized: "說主題，幫你寫好")
        case .speakToEdit: return String(localized: "說要怎麼改")
        case .askAnything: return String(localized: "答案可以直接插入")
        }
    }

    /// 模式鍵與選單的圖示（SF Symbols）。
    var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .helpWrite: return "pencil.and.scribble"
        case .speakToEdit: return "wand.and.stars"
        case .askAnything: return "questionmark.bubble"
        }
    }

    /// 點一下模式鍵換到哪一個（循環）。翻譯不在這裡——長按光球才是翻譯。
    var next: VoiceModeKind {
        let all = VoiceModeKind.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

/// 鍵盤的純邏輯（無 UI、可測）：模式判定、送出鍵文案、用量統計。
/// 對齊 Typeless：有選取文字＝「說出要怎麼改」；長按麥克風選語言＝「放開就翻譯」；其餘＝聽寫。
enum KeyboardMode: Equatable, Sendable {
    case dictate
    case edit(selection: String)
    case translate(target: TranslationTarget)
    /// Help me write：替使用者寫一段可送出的文字（沒有選取文字時才走這條）。
    case helpWrite
    /// Speak to edit：沒有選取文字時先選「這一段／全部文字」，再講指令。
    case speakToEdit
    /// Ask anything：講問題得到回答卡。帶著送出當下的選取文字（沒選就是 nil），
    /// 回來時要確認它沒變，變了就不取代（Android 審查抓到的坑）。
    case askAnything(selection: String?)

    /// 決策順序：翻譯（使用者剛剛長按選了語言）> 使用者選的模式 > 編輯（有選取）> 聽寫。
    /// - `preferred`：鍵盤上那顆模式鍵選的模式。nil＝使用者沒動過模式鍵，走原本的行為。
    ///   Ask anything 即使有選取也照自己走（有選取時由模型判斷改寫或回答）；
    ///   Help me write／Speak to edit 有選取時還是改寫選取（那是它們本來就有的行為）。
    static func decide(selectedText: String?, translateTarget: TranslationTarget?,
                       preferred: VoiceModeKind? = nil) -> KeyboardMode {
        if let translateTarget { return .translate(target: translateTarget) }
        let hasSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch preferred {
        case .askAnything:
            return .askAnything(selection: hasSelection ? selectedText : nil)
        case .helpWrite where !hasSelection:
            return .helpWrite
        case .speakToEdit where !hasSelection:
            return .speakToEdit
        case .dictate, .none, .helpWrite, .speakToEdit:
            break
        }
        if let selectedText, hasSelection {
            return .edit(selection: selectedText)
        }
        return .dictate
    }

    /// 這段語音結束後，這個模式要做的事（鍵盤模式鍵顯示用的短名）。
    var modeKind: VoiceModeKind {
        switch self {
        case .dictate: return .dictate
        case .edit: return .dictate
        case .translate: return .dictate
        case .helpWrite: return .helpWrite
        case .speakToEdit: return .speakToEdit
        case .askAnything: return .askAnything
        }
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
        case .helpWrite: return String(localized: "說你要寫什麼，我幫你寫")
        case .speakToEdit: return String(localized: "點一下先選範圍，再說出要怎麼改")
        case .askAnything: return String(localized: "說出你的問題")
        }
    }

    var recordingHint: String {
        switch self {
        case .dictate: return String(localized: "再點一下完成")
        case .edit: return String(localized: "說完再點一下，改寫會取代選取")
        case .translate(let target): return String(localized: "再點一下完成，翻成\(target.displayName)")
        case .helpWrite: return String(localized: "說完再點一下，寫好的文字插在游標處")
        case .speakToEdit: return String(localized: "說完再點一下，會改寫選好的範圍")
        case .askAnything(let selection):
            return selection.map { _ in String(localized: "說完再點一下，問問題或說要怎麼改") }
                ?? String(localized: "說完再點一下，答案會出成回答卡")
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

    /// 從鍵盤長按弧的「＋語言」加一個語言（工單 ios-C 第 5 點）。
    /// 與 `toggled` 不同：這個是**新增**語意，已經有就不動；滿 5 個時擠掉**最舊的一個**（弧上選的
    /// 語言要真的能用，不能因為清單滿了就不加）。
    static func adding(_ code: String, to current: [String]) -> [String] {
        guard !current.contains(code) else { return current }
        guard current.count < maxCount else { return Array(current.dropFirst()) + [code] }
        return current + [code]
    }

    /// 鍵盤語言選擇器裡要**排除**的那一個目標：譯成自己正在講的語言沒意義。
    ///
    /// 舊版在選擇器裡寫死 `target.code != "zh-Hant"`，等於繁中**永遠**不能從鍵盤加入，
    /// 使用者在主 app 把它移出快選之後就再也加不回來（review-agy-ios-C finding 2）。
    /// 正確做法是只排除「當下的輸入語言」——換了聽寫語言，繁中就重新可選。
    ///
    /// 回 nil 表示沒有可排除的目標（未知語言 → 什麼都顯示，不要藏掉任何語言）。
    static func identityTargetCode(for language: DictationLanguage) -> String? {
        switch language {
        case .traditionalChinese, .simplifiedChinese: return "zh-Hant"
        case .englishUS: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        }
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
        case .join: return String(localized: "加入鍵")
        case .next: return String(localized: "下一個")
        case .continue: return String(localized: "繼續")
        case .route: return String(localized: "路線")
        case .emergencyCall: return String(localized: "撥打")
        default: return String(localized: "換行")
        }
    }

    /// 在 `width` 內放得下 `title` 的字級：預設 13 pt，放不下等比縮，最小 8 pt。
    static func fittingFontSize(for title: String, width: CGFloat, preferred: CGFloat = 13) -> CGFloat {
        let measured = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: preferred, weight: .semibold)]).width
        guard measured > width, measured > 0 else { return preferred }
        var size = (preferred * width / measured).rounded(.down)
        while size > 8, (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width > width {
            size -= 0.5
        }
        return max(8, size)
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
    /// 插入換行可能直接觸發送出；完整條列僅在一般文字欄增加例外，其他段落沿用原規則。
    static func allowsLineBreaks(returnKeyType: UIReturnKeyType?, keyboardType: UIKeyboardType? = nil,
                                 text: String? = nil) -> Bool {
        if let text, OutputShape.hasCompleteNumberedList(text) {
            switch keyboardType {
            case .URL, .emailAddress, .numberPad, .phonePad, .namePhonePad, .decimalPad, .asciiCapableNumberPad, .webSearch:
                return false
            default: break
            }
            switch returnKeyType {
            case .search, .go, .join, .route, .google, .yahoo, .emergencyCall: return false
            default: return true
            }
        }
        guard let returnKeyType else { return true }
        return returnKeyType == .default
    }

    /// 最後一句不加句號（2026-10-02 Micky：不要每句、最後都用句號，很 AI）。以前只在聊天框的單句訊息拿掉；
    /// 現在所有輸入框都拿掉，分段長文（有換行）照原樣。緊接著再講時由鍵盤補回句號（SentenceMood.continuationPrefix）。
    static func apply(_ text: String, tone: ToneHint) -> String {
        SentenceMood.dropFinalPeriod(text)
    }
}

/// 主 app 首頁的用量統計（Typeless 2.6 的 Home insights）。
/// 字數：CJK 每字算一，其他以空白切詞（口徑的單一正本在 `UsageText.wordCount`）。
/// 這是**從歷史紀錄現算**的舊版；首頁現在改讀每日計數（`UsageStats`），歷史被刪掉數字也不掉。
/// 保留這份是給「只有歷史、還沒累積每日計數」的舊安裝與測試。
struct UsageInsights: Equatable, Sendable {
    var totalWords: Int
    var weekWords: Int
    var sessions: Int
    var minutesSaved: Double

    static func wordCount(_ text: String) -> Int {
        UsageText.wordCount(text)
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

/// 跳主 app 錄音期間要跨 process 帶著的東西（鍵盤被系統回收後回來是新的 process）。
enum VoicePending {
    /// 這次的指令 id（主 app 回來時要對上）。
    static let idKey = "utuvo.type.voice.pendingID"
    /// 翻譯目標語言。
    static let translateKey = "utuvo.type.voice.pendingTranslate"
    /// **這次用哪個語音模式**。少了這個，跳主 app 錄音再回來時 `preferred` 會是 nil，
    /// `KeyboardMode.decide` 就會把 askAnything 的選取判成「有選取＝改寫」，
    /// 使用者在模式鍵上選的模式被舊行為搶走（B 票審查點 2）。
    static let modeKey = "utuvo.type.voice.pendingMode"

    static func setMode(_ mode: VoiceModeKind?) {
        if let mode { defaults.set(mode.rawValue, forKey: modeKey) }
        else { defaults.removeObject(forKey: modeKey) }
    }

    /// 讀回上次那個模式；沒有（或值認不出）回 nil，呼叫端就照「沒選過模式」走。
    static var mode: VoiceModeKind? {
        defaults.string(forKey: modeKey).flatMap(VoiceModeKind.init(rawValue:))
    }

    static func clear() {
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: translateKey)
        defaults.removeObject(forKey: modeKey)
    }

    private static var defaults: UserDefaults { KeyboardPresence.defaults }
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
