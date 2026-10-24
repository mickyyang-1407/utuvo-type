import Combine
import Darwin
import Foundation
import UTUVOTypeCore

// 語言選項：auto＝交給 Qwen3-ASR 偵測，
// 其餘明確指定。rawValue 沿用 BCP-47 樣式，舊值 zh-TW／en-US 不搬家。
enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto = "auto"
    case traditionalChinese = "zh-TW"
    case english = "en-US"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case arabic = "ar"
    case hindi = "hi"
    case dutch = "nl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto detect"
        case .traditionalChinese: return "Chinese (Traditional)"
        case .english: return "English"
        default: return asrLanguageName
        }
    }

    func localizedName(zh: Bool) -> String {
        switch self {
        case .auto: return zh ? "自動偵測（可混語）" : "Auto detect (mixed OK)"
        case .traditionalChinese: return zh ? "中文（繁體）" : "Chinese (Traditional)"
        case .english: return "English"
        case .japanese: return zh ? "日文" : "Japanese"
        case .korean: return zh ? "韓文" : "Korean"
        case .french: return zh ? "法文" : "French"
        case .german: return zh ? "德文" : "German"
        case .spanish: return zh ? "西班牙文" : "Spanish"
        case .italian: return zh ? "義大利文" : "Italian"
        case .portuguese: return zh ? "葡萄牙文" : "Portuguese"
        case .russian: return zh ? "俄文" : "Russian"
        case .thai: return zh ? "泰文" : "Thai"
        case .vietnamese: return zh ? "越南文" : "Vietnamese"
        case .indonesian: return zh ? "印尼文" : "Indonesian"
        case .arabic: return zh ? "阿拉伯文" : "Arabic"
        case .hindi: return zh ? "印地文" : "Hindi"
        case .dutch: return zh ? "荷蘭文" : "Dutch"
        }
    }

    /// 給本機 ASR wrapper 的語言名（mlx_audio 端點吃英文語言名）；auto＝省略欄位讓模型偵測。
    var asrLanguageName: String {
        switch self {
        case .auto: return "auto"
        case .traditionalChinese: return "Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .thai: return "Thai"
        case .vietnamese: return "Vietnamese"
        case .indonesian: return "Indonesian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .dutch: return "Dutch"
        }
    }

    /// on-device Speech fallback 的 locale；auto 與無對應區域的語言退 zh-TW。
    var speechLocaleIdentifier: String {
        switch self {
        case .auto: return "zh-TW"
        case .traditionalChinese: return "zh-TW"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .thai: return "th-TH"
        case .vietnamese: return "vi-VN"
        case .indonesian: return "id-ID"
        case .arabic: return "ar-SA"
        case .hindi: return "hi-IN"
        case .dutch: return "nl-NL"
        }
    }
}

enum AppBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case local
    case bailian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "本機優先"
        case .bailian: return "百鍊"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    var onShortcutChange: (() -> Void)?
    var onPostProcessingShortcutChange: (() -> Void)?
    var onAppBehaviorChange: (() -> Void)?
    /// 衝突卡上「重試」按鈕會回呼到 AppDelegate 重掛快捷鍵；不持久化。
    var onShortcutRetry: (() -> Void)?

    /// 隔離 context（測試／preview）。nil ＝真實 production 環境。
    /// 設進來之後：
    /// 1) 用 `userDefaults` 而非 `.standard`；
    /// 2) `applicationSupportDirectory` 指到暫存資料夾；
    /// 3) `disableCloudSync = true` → DictionaryCloud 會跳過；
    /// 4) `skipGlobalShortcut = true` → GlobalShortcut 不會被註冊。
    var isolation: IsolatedContext?

    @Published var backend: AppBackend {
        didSet { defaults.set(backend.rawValue, forKey: Keys.backend) }
    }

    @Published var mode: FormatterMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    @Published var pushToTalkEnabled: Bool {
        didSet { defaults.set(pushToTalkEnabled, forKey: Keys.pushToTalkEnabled) }
    }

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { defaults.set(transcriptionLanguage.rawValue, forKey: Keys.transcriptionLanguage) }
    }

    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    @Published var inputChannel: AudioInputChannel {
        didSet { defaults.set(inputChannel.rawValue, forKey: Keys.inputChannel) }
    }

    @Published var outputDeviceUID: String {
        didSet { defaults.set(outputDeviceUID, forKey: Keys.outputDeviceUID) }
    }

    @Published var muteWhileRecording: Bool {
        didSet { defaults.set(muteWhileRecording, forKey: Keys.muteWhileRecording) }
    }

    @Published var audioFeedback: Bool {
        didSet { defaults.set(audioFeedback, forKey: Keys.audioFeedback) }
    }

    @Published var audioFeedbackVolume: Double {
        didSet { defaults.set(audioFeedbackVolume, forKey: Keys.audioFeedbackVolume) }
    }

    @Published var startHidden: Bool {
        didSet {
            defaults.set(startHidden, forKey: Keys.startHidden)
            onAppBehaviorChange?()
        }
    }

    @Published var launchOnStartup: Bool {
        didSet {
            defaults.set(launchOnStartup, forKey: Keys.launchOnStartup)
            onAppBehaviorChange?()
        }
    }

    @Published var showTrayIcon: Bool {
        didSet {
            defaults.set(showTrayIcon, forKey: Keys.showTrayIcon)
            onAppBehaviorChange?()
        }
    }

    @Published var overlayStyle: OverlayStyle {
        didSet {
            defaults.set(overlayStyle.rawValue, forKey: Keys.overlayStyle)
            onAppBehaviorChange?()
        }
    }

    @Published var outputScript: OutputScript {
        didSet {
            defaults.set(outputScript.rawValue, forKey: Keys.outputScript)
        }
    }

    /// 語言變體（app-shell-7，對齊 iOS／Typeless）：每個聽寫語言各記一個（語言 rawValue → 變體 rawValue），沒記＝`.none`。
    @Published private(set) var languageVariants: [String: String] {
        didSet { defaults.set(languageVariants, forKey: Keys.languageVariants) }
    }

    func languageVariant(for language: TranscriptionLanguage) -> CleanupVariant {
        let stored = languageVariants[language.rawValue].flatMap(CleanupVariant.init(rawValue:)) ?? .none
        return CleanupVariant.options(forLanguage: language.rawValue).contains(stored) ? stored : .none
    }

    /// 選中文變體時順便把輸出字形對上（台灣／香港＝繁體、中國大陸＝簡體），提示詞與後處理才不會打架。
    func setLanguageVariant(_ variant: CleanupVariant, for language: TranscriptionLanguage) {
        guard CleanupVariant.options(forLanguage: language.rawValue).contains(variant) else { return }
        languageVariants[language.rawValue] = variant.rawValue
        if let script = variant.outputScriptRawValue.flatMap(OutputScript.init(rawValue:)), script != outputScript {
            outputScript = script
        }
    }

    /// 這次聽寫真正套用的變體（選了但跟目前輸出字形對不上＝`.none`）。
    var effectiveLanguageVariant: CleanupVariant {
        CleanupVariant.effective(languageVariant(for: transcriptionLanguage),
                                 language: transcriptionLanguage.rawValue, outputScript: outputScript.rawValue)
    }

    // 即時翻譯：⇧／⌘／⌥＋聽寫快捷鍵各對應一個語言 slot；
    // 改 slot 要重掛變體熱鍵，走 onShortcutChange。
    @Published var translationSlotShift: TranslationTarget {
        didSet {
            defaults.set(translationSlotShift.rawValue, forKey: Keys.translationSlotShift)
            onShortcutChange?()
        }
    }

    @Published var translationSlotCommand: TranslationTarget {
        didSet {
            defaults.set(translationSlotCommand.rawValue, forKey: Keys.translationSlotCommand)
            onShortcutChange?()
        }
    }

    // ⌥＋F14 會觸發 macOS 螢幕選項，第三 slot 改用 ⌃（2026-08-21 產品決定）。
    // 儲存 key 沿用舊字串，值不搬家。
    @Published var translationSlotControl: TranslationTarget {
        didSet {
            defaults.set(translationSlotControl.rawValue, forKey: Keys.translationSlotControl)
            onShortcutChange?()
        }
    }

    @Published var overlayPosition: OverlayPosition {
        didSet {
            defaults.set(overlayPosition.rawValue, forKey: Keys.overlayPosition)
            onAppBehaviorChange?()
        }
    }

    @Published var unloadPolicy: UnloadPolicy {
        didSet { defaults.set(unloadPolicy.rawValue, forKey: Keys.unloadPolicy) }
    }

    @Published var clipboardHandling: ClipboardHandling {
        didSet { defaults.set(clipboardHandling.rawValue, forKey: Keys.clipboardHandling) }
    }

    @Published var pasteMethod: PasteMethod {
        didSet { defaults.set(pasteMethod.rawValue, forKey: Keys.pasteMethod) }
    }

    @Published var autoSubmit: AutoSubmit {
        didSet { defaults.set(autoSubmit.rawValue, forKey: Keys.autoSubmit) }
    }

    /// 雲端辨識（Groq Whisper，用智慧整理頁存的 Groq key）：本機優先模式下取代本機 Qwen3-ASR，失敗退回本機。預設關。
    @Published var cloudASREnabled: Bool {
        didSet { defaults.set(cloudASREnabled, forKey: Keys.cloudASREnabled) }
    }
    @Published var appendTrailingSpace: Bool {
        didSet { defaults.set(appendTrailingSpace, forKey: Keys.appendTrailingSpace) }
    }

    @Published var voiceActivityDetection: Bool {
        didSet { defaults.set(voiceActivityDetection, forKey: Keys.voiceActivityDetection) }
    }

    @Published var includeSurroundingContext: Bool {
        didSet { defaults.set(includeSurroundingContext, forKey: Keys.includeSurroundingContext) }
    }

    /// 2026-10-13：這些網站（含子網域）不抓任何脈絡，只留 App 名稱。
    @Published var contextBlockedSites: [String] {
        didSet { defaults.set(contextBlockedSites, forKey: Keys.contextBlockedSites) }
    }

    /// 插入後追蹤修改（2026-10-13）：只在本機比對，留下「原字→改後」短詞當字典建議；
    /// 2026-10-22 起過得了讀音／拼法關的直接加進字典（標成自動、可復原），見 `learn(fromEdits:)`。關掉就兩種都不做。
    @Published var learnFromEdits: Bool {
        didSet { defaults.set(learnFromEdits, forKey: Keys.learnFromEdits) }
    }
    @Published private(set) var dictionarySuggestions: [EditTracker.Correction] {
        didSet { if let data = try? JSONEncoder().encode(dictionarySuggestions) { defaults.set(data, forKey: Keys.dictionarySuggestions) } }
    }
    private var ignoredSuggestions: Set<String> {
        didSet { defaults.set(Array(ignoredSuggestions), forKey: Keys.ignoredSuggestions) }
    }

    /// 新建議：已在字典、已忽略、已在清單的不加；清單最多 20 筆（新的在前）。
    func addSuggestions(_ found: [EditTracker.Correction]) {
        guard learnFromEdits else { return }
        var list = dictionarySuggestions
        for c in found where dictionary[c.from] != c.to && !ignoredSuggestions.contains("\(c.from)→\(c.to)")
            && !list.contains(c) {
            list.insert(c, at: 0)
        }
        dictionarySuggestions = Array(list.prefix(20))
    }

    func acceptSuggestion(_ c: EditTracker.Correction) {
        addDictionaryTerm(source: c.from, output: c.to)
        dictionarySuggestions.removeAll { $0 == c }
    }

    func ignoreSuggestion(_ c: EditTracker.Correction) {
        ignoredSuggestions.insert(Self.ignoreKey(c.from, c.to))
        dictionarySuggestions.removeAll { $0 == c }
    }

    // MARK: - 從修改自動學字（2026-10-22 delivery-learning-4、asr-vocab-4）

    /// 忽略清單的 key：「原字→改後」；詞彙模式的詞用「詞→詞」（EditTracker 不會產生原字＝改後的配對，不會撞）。
    static func ignoreKey(_ from: String, _ to: String) -> String { "\(from)→\(to)" }

    private func isIgnored(_ c: EditTracker.Correction) -> Bool {
        ignoredSuggestions.contains(Self.ignoreKey(c.from, c.to)) || ignoredSuggestions.contains(Self.ignoreKey(c.to, c.to))
    }

    /// 自動加進字典的一筆（提示卡的「復原」用）。詞彙模式＝聽到和輸出都是那個詞。
    struct LearnedTerm: Equatable {
        let correction: EditTracker.Correction
        let source: String
        let output: String
        var isVocabulary: Bool { source == output }
    }

    struct EditLearningResult: Equatable {
        /// 這次自動加進字典的（標成「自動」）。
        var added: [LearnedTerm] = []
        /// 這次新進建議清單、等使用者決定的。
        var suggested: [EditTracker.Correction] = []
        var isEmpty: Bool { added.isEmpty && suggested.isEmpty }
    }

    /// 修改追蹤找到的配對：過得了讀音／拼法關的自動加（`EditLearning.decide`），其他照舊進建議清單。
    /// 已經在字典裡的詞不覆蓋（使用者自己設定的寫法優先）；忽略過的不再出現；關掉「從你的修改學字典」就什麼都不做。
    @discardableResult
    func learn(fromEdits found: [EditTracker.Correction]) -> EditLearningResult {
        guard learnFromEdits else { return EditLearningResult() }
        var result = EditLearningResult()
        var state = dictionarySync
        var live = state.live
        var toSuggest: [EditTracker.Correction] = []
        let now = Date().timeIntervalSince1970
        // 英文只有改成「詞庫包的詞」或品牌寫法才自動加（2026-10-22 修補）；全大寫是不是常用字另外問系統拼字字典。
        let knownTerms = Set(VocabularyPacks.latinTermsForFixer(personalValues: [], enabled: enabledVocabularyPackIDs))
        for c in found where !isIgnored(c) {
            switch EditLearning.decide(c, knownTerms: knownTerms, isCommonWord: EnglishSpelling.isCommonWord) {
            case let .replacement(from, to) where live[from] == nil:
                state.set(from, to, at: now, origin: .auto)
                live[from] = to
                result.added.append(LearnedTerm(correction: c, source: from, output: to))
            case let .vocabulary(term) where live[term] == nil && !live.values.contains(term):
                state.set(term, "", at: now, origin: .auto)
                live[term] = term
                result.added.append(LearnedTerm(correction: c, source: term, output: term))
            default:
                toSuggest.append(c)
            }
        }
        if !result.added.isEmpty { writeDictionarySync(state) }
        let before = dictionarySuggestions
        addSuggestions(toSuggest)
        result.suggested = dictionarySuggestions.filter { !before.contains($0) }
        return result
    }

    /// 提示卡的「復原」：還是自動、寫法沒被改過的就刪掉，並記進忽略清單（同一組修正不會馬上又被學回來）。
    func undoLearned(_ terms: [LearnedTerm]) {
        guard !terms.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        updateDictionarySync { state in
            for t in terms where state.source(of: t.source) == .auto && state.live[t.source] == t.output {
                state.remove(t.source, at: now)
            }
        }
        for t in terms {
            ignoredSuggestions.insert(Self.ignoreKey(t.correction.from, t.correction.to))
            if t.isVocabulary { ignoredSuggestions.insert(Self.ignoreKey(t.output, t.output)) }
        }
    }

    /// 自動加入的詞（字典頁「自動」分頁與標籤）。
    var dictionaryAutoTerms: Set<String> { dictionarySync.autoTerms }

    /// 使用數據（只存每天的字數／秒數／次數，不存文字）。
    @Published private(set) var usageStats: UsageStats {
        didSet {
            if let data = try? JSONEncoder().encode(usageStats) { defaults.set(data, forKey: Keys.usageStats) }
        }
    }

    @Published var postProcessingEnabled: Bool {
        didSet { defaults.set(postProcessingEnabled, forKey: Keys.postProcessingEnabled) }
    }

    @Published var experimentalFeatures: Bool {
        didSet { defaults.set(experimentalFeatures, forKey: Keys.experimentalFeatures) }
    }

    @Published var appLanguage: AppLanguageChoice {
        didSet { defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage) }
    }

    /// UI 是否用繁體中文；.system 跟隨 macOS 偏好語言。
    var isChineseUI: Bool {
        switch appLanguage {
        case .traditionalChinese: return true
        case .english: return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }

    /// 內聯雙語：每個呼叫點同時帶中英文，避免「字表綠、畫面英文」型的漏翻。
    func tr(_ zh: String, _ en: String) -> String {
        isChineseUI ? zh : en
    }

    @Published var appTheme: AppThemeChoice {
        didSet {
            defaults.set(appTheme.rawValue, forKey: Keys.appTheme)
            AppBrand.themeChoice = appTheme
        }
    }

    @Published var historyLimit: Int {
        didSet {
            // app-shell-1：記憶體裡也夾值。以前只有寫進 defaults 時才夾成 1…500，欄位打 0 會用 0 去刪。
            let clamped = Self.clampLimit(historyLimit)
            if historyLimit != clamped { historyLimit = clamped }
            defaults.set(historyLimit, forKey: Keys.historyLimit)
            trimHistoryIfNeeded()
        }
    }

    /// 文字歷史紀錄的保留期限（設定頁「歷史紀錄保留」）。從沒動過的人預設「全部保留」（app-shell-1）。
    @Published var autoDeletePolicy: AutoDeletePolicy {
        didSet {
            defaults.set(autoDeletePolicy.rawValue, forKey: Keys.autoDeletePolicy)
            trimHistoryIfNeeded()
        }
    }

    /// 錄音檔的保留期限（app-shell-1）：超出時只刪錄音、文字留著。
    @Published var audioRetentionPolicy: AutoDeletePolicy {
        didSet {
            defaults.set(audioRetentionPolicy.rawValue, forKey: Keys.audioRetentionPolicy)
            trimHistoryIfNeeded()
        }
    }

    /// 錄音保留「只留最新上限」時的筆數（1…500）。
    @Published var audioRetentionLimit: Int {
        didSet {
            let clamped = Self.clampLimit(audioRetentionLimit)
            if audioRetentionLimit != clamped { audioRetentionLimit = clamped }
            defaults.set(audioRetentionLimit, forKey: Keys.audioRetentionLimit)
            trimHistoryIfNeeded()
        }
    }

    static func clampLimit(_ value: Int) -> Int { max(1, min(value, 500)) }

    /// 設定頁要不要顯示「文字紀錄筆數上限」那一列（全部保留時筆數沒有作用，不顯示）。
    var showsTextHistoryLimit: Bool { autoDeletePolicy != .keepAll }

    @Published var formatterPromptPath: String {
        didSet { defaults.set(formatterPromptPath, forKey: Keys.formatterPromptPath) }
    }

    @Published var bailianASREndpoint: String {
        didSet { defaults.set(bailianASREndpoint, forKey: Keys.bailianASREndpoint) }
    }

    @Published var bailianFormatterEndpoint: String {
        didSet { defaults.set(bailianFormatterEndpoint, forKey: Keys.bailianFormatterEndpoint) }
    }

    @Published var bailianWorkspaceID: String {
        didSet { defaults.set(bailianWorkspaceID, forKey: Keys.bailianWorkspaceID) }
    }

    @Published var localASRCommand: String {
        didSet { defaults.set(localASRCommand, forKey: Keys.localASRCommand) }
    }

    @Published var localASRArguments: String {
        didSet { defaults.set(localASRArguments, forKey: Keys.localASRArguments) }
    }

    @Published var localEditorCommand: String {
        didSet { defaults.set(localEditorCommand, forKey: Keys.localEditorCommand) }
    }

    @Published var localEditorModel: String {
        didSet { defaults.set(localEditorModel, forKey: Keys.localEditorModel) }
    }

    @Published var localDeepModel: String {
        didSet { defaults.set(localDeepModel, forKey: Keys.localDeepModel) }
    }

    @Published var dictionaryJSON: String {
        didSet { defaults.set(dictionaryJSON, forKey: Keys.dictionaryJSON) }
    }

    /// 開啟的詞庫包 id（iOS 同款鍵名，方便測試互通）：catalog 六包＋內建三包（ai／tw／audio，core `BuiltInVocabulary`）。
    /// catalog 預設全關，使用者必須明確開啟才生效；內建包預設 ai、tw 開，audio 關（同 iOS／Android）。
    @Published var enabledVocabularyPackIDs: Set<String> {
        didSet {
            defaults.set(Array(enabledVocabularyPackIDs), forKey: Keys.enabledVocabularyPackIDs)
        }
    }

    /// 自訂 cleanup provider 設定（與 ASR backend 解耦；見 SmartCleanup.swift）。
    @Published var cleanupProvider: SmartCleanupProvider {
        didSet {
            defaults.set(cleanupProvider.rawValue, forKey: Keys.cleanupProvider)
        }
    }

    @Published var cleanupEnabled: Bool {
        didSet {
            defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled)
        }
    }

    /// 自動條列：講步驟／重點的長段落整理成 1. 2. 3.（CleanupPromptRules）；預設開。
    @Published var cleanupAutoList: Bool {
        didSet {
            defaults.set(cleanupAutoList, forKey: Keys.cleanupAutoList)
        }
    }

    @Published var customCleanupEndpoint: String {
        didSet {
            defaults.set(customCleanupEndpoint, forKey: Keys.customCleanupEndpoint)
        }
    }

    @Published var customCleanupModel: String {
        didSet {
            defaults.set(customCleanupModel, forKey: Keys.customCleanupModel)
        }
    }

    @Published var globalShortcut: String {
        didSet {
            defaults.set(globalShortcut, forKey: Keys.globalShortcut)
            onShortcutChange?()
        }
    }

    /// 主快捷鍵被搶走時自動接上的退路鍵；nil＝沒退路。記憶體狀態，不進 UserDefaults。
    @Published var activeFallbackShortcut: String?

    /// Carbon 註冊失敗且對手是另一個 App 時填這個；UI 用它畫衝突卡。
    /// 記憶體狀態，不進 UserDefaults——重開 app 會重新探測一次。
    @Published var hotkeyConflict: HotkeyConflictInfo?

    /// 本次啟動已被搶走、自動取回的次數。純記憶體，給衝突卡顯示用。
    /// 重開 app 重新計數。
    @Published var hotkeyStealCount: Int = 0

    /// 選字後「白話解釋」／「翻譯」快捷鍵（2026-10-19，帶進 UTUVO Explain 的兩個動作）。空字串＝不註冊。
    /// 預設刻意避開 UTUVO Explain 的 ⌥D／⌥⇧D，兩個 App 同時裝不打架。
    @Published var explainShortcut: String {
        didSet {
            defaults.set(explainShortcut, forKey: Keys.explainShortcut)
            onPostProcessingShortcutChange?()
        }
    }
    @Published var translateSelectionShortcut: String {
        didSet {
            defaults.set(translateSelectionShortcut, forKey: Keys.translateSelectionShortcut)
            onPostProcessingShortcutChange?()
        }
    }

    /// Ask anything 快捷鍵（2026-10-13）。空字串＝不註冊。
    @Published var askShortcut: String {
        didSet {
            defaults.set(askShortcut, forKey: Keys.askShortcut)
            onPostProcessingShortcutChange?()   // 同一個重新註冊鉤子（兩個附屬快捷鍵一起重裝）
        }
    }

    @Published var postProcessingShortcut: String {
        didSet {
            defaults.set(postProcessingShortcut, forKey: Keys.postProcessingShortcut)
            onPostProcessingShortcutChange?()
        }
    }

    @Published var deepMinCharacters: Int {
        didSet { defaults.set(deepMinCharacters, forKey: Keys.deepMinCharacters) }
    }

    @Published var deepMinAudioSeconds: Int {
        didSet { defaults.set(deepMinAudioSeconds, forKey: Keys.deepMinAudioSeconds) }
    }

    @Published private(set) var historyRecords: [HistoryRecord]
    @Published private(set) var appPresets: [AppPreset]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, isolation: IsolatedContext? = nil) {
        let defaults = isolation?.userDefaults ?? defaults
        self.defaults = defaults
        self.isolation = isolation
        self.backend = AppBackend(rawValue: defaults.string(forKey: Keys.backend) ?? "local") ?? .local
        self.mode = FormatterMode(rawValue: defaults.string(forKey: Keys.mode) ?? "fast") ?? .fast
        self.pushToTalkEnabled = defaults.object(forKey: Keys.pushToTalkEnabled) as? Bool ?? false
        self.transcriptionLanguage = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? "zh-TW"
        ) ?? .traditionalChinese
        self.inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID) ?? ""
        self.inputChannel = AudioInputChannel(
            rawValue: defaults.string(forKey: Keys.inputChannel) ?? AudioInputChannel.average.rawValue
        ) ?? .average
        self.outputDeviceUID = defaults.string(forKey: Keys.outputDeviceUID) ?? ""
        self.muteWhileRecording = defaults.object(forKey: Keys.muteWhileRecording) as? Bool ?? false
        self.audioFeedback = defaults.object(forKey: Keys.audioFeedback) as? Bool ?? false
        self.audioFeedbackVolume = defaults.object(forKey: Keys.audioFeedbackVolume) as? Double ?? 0.16
        self.startHidden = defaults.object(forKey: Keys.startHidden) as? Bool ?? false
        self.launchOnStartup = defaults.object(forKey: Keys.launchOnStartup) as? Bool ?? false
        self.showTrayIcon = defaults.object(forKey: Keys.showTrayIcon) as? Bool ?? true
        self.overlayStyle = OverlayStyle(
            rawValue: defaults.string(forKey: Keys.overlayStyle) ?? OverlayStyle.live.rawValue
        ) ?? .live
        self.overlayPosition = OverlayPosition(
            rawValue: defaults.string(forKey: Keys.overlayPosition) ?? OverlayPosition.bottom.rawValue
        ) ?? .bottom
        self.translationSlotShift = TranslationTarget(
            rawValue: defaults.string(forKey: Keys.translationSlotShift) ?? TranslationTarget.english.rawValue
        ) ?? .english
        self.translationSlotCommand = TranslationTarget(
            rawValue: defaults.string(forKey: Keys.translationSlotCommand) ?? TranslationTarget.japanese.rawValue
        ) ?? .japanese
        self.translationSlotControl = TranslationTarget(
            rawValue: defaults.string(forKey: Keys.translationSlotControl) ?? TranslationTarget.off.rawValue
        ) ?? .off
        self.outputScript = OutputScript(
            rawValue: defaults.string(forKey: Keys.outputScript) ?? OutputScript.traditional.rawValue
        ) ?? .traditional
        self.languageVariants = defaults.dictionary(forKey: Keys.languageVariants) as? [String: String] ?? [:]
        self.unloadPolicy = UnloadPolicy(
            rawValue: defaults.string(forKey: Keys.unloadPolicy) ?? UnloadPolicy.afterFiveMinutes.rawValue
        ) ?? .afterFiveMinutes
        self.clipboardHandling = ClipboardHandling(
            rawValue: defaults.string(forKey: Keys.clipboardHandling) ?? ClipboardHandling.restore.rawValue
        ) ?? .restore
        self.pasteMethod = PasteMethod(
            rawValue: defaults.string(forKey: Keys.pasteMethod) ?? PasteMethod.clipboard.rawValue
        ) ?? .clipboard
        self.autoSubmit = AutoSubmit(
            rawValue: defaults.string(forKey: Keys.autoSubmit) ?? AutoSubmit.off.rawValue
        ) ?? .off
        self.appendTrailingSpace = defaults.object(forKey: Keys.appendTrailingSpace) as? Bool ?? false
        self.cloudASREnabled = defaults.object(forKey: Keys.cloudASREnabled) as? Bool ?? false
        // 2026-09-24 實機（苑涵）：講長句時停下來想下一句，0.9 秒靜音就被切斷。預設改關（對齊 Typeless：再按一次才結束）；
        // 沒動過設定的 0.1.5 使用者升級後也會套用新預設，自己開過的保留。
        self.voiceActivityDetection = defaults.object(forKey: Keys.voiceActivityDetection) as? Bool ?? false
        self.includeSurroundingContext = defaults.object(forKey: Keys.includeSurroundingContext) as? Bool ?? false
        self.contextBlockedSites = defaults.stringArray(forKey: Keys.contextBlockedSites) ?? ContextBounds.defaultBlockedSites
        self.learnFromEdits = defaults.object(forKey: Keys.learnFromEdits) as? Bool ?? true
        self.dictionarySuggestions = defaults.data(forKey: Keys.dictionarySuggestions)
            .flatMap { try? JSONDecoder().decode([EditTracker.Correction].self, from: $0) } ?? []
        self.ignoredSuggestions = Set(defaults.stringArray(forKey: Keys.ignoredSuggestions) ?? [])
        self.usageStats = (defaults.data(forKey: Keys.usageStats)).flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) } ?? UsageStats()
        self.postProcessingEnabled = defaults.object(forKey: Keys.postProcessingEnabled) as? Bool ?? true
        self.experimentalFeatures = defaults.object(forKey: Keys.experimentalFeatures) as? Bool ?? false
        self.appLanguage = AppLanguageChoice(
            rawValue: defaults.string(forKey: Keys.appLanguage) ?? AppLanguageChoice.system.rawValue
        ) ?? .system
        // 舊值 "retro"（已移除的二次元選項）會 fallback 成 .system。
        let storedTheme = AppThemeChoice(
            rawValue: defaults.string(forKey: Keys.appTheme) ?? AppThemeChoice.system.rawValue
        ) ?? .system
        self.appTheme = storedTheme
        AppBrand.themeChoice = storedTheme
        let storedLimit = Self.clampLimit(defaults.object(forKey: Keys.historyLimit) as? Int ?? 20)
        self.historyLimit = storedLimit
        // app-shell-1：從沒動過這個設定（兩個 key 都不存在）＝文字紀錄全部保留（Typeless 預設永遠）；
        // 明確選過的（包括「只留最新上限」）照原設定。不寫回 defaults：沒動過的人永遠吃目前的預設。
        // repair-batch1：b8817d8 的「歷史筆數上限」欄位一直顯示、不用先選期限——只打過筆數（期限 key 沒寫過）的人，
        // 當時生效的是「只留最新 N 筆」，升級後照舊（不能悄悄變成全部保留）。
        let textPolicyTouched = defaults.object(forKey: Keys.autoDeletePolicy) != nil
        let limitTouched = defaults.object(forKey: Keys.historyLimit) != nil
        let textPolicy: AutoDeletePolicy = textPolicyTouched
            ? AutoDeletePolicy(rawValue: defaults.string(forKey: Keys.autoDeletePolicy) ?? "") ?? .latestLimit
            : limitTouched ? .latestLimit : .keepAll
        self.autoDeletePolicy = textPolicy
        // 錄音保留第一次出現時轉換一次並寫回（之後改文字的期限不會連帶改到錄音）：
        // - 明確設定過文字保留的人：錄音跟以前一樣（同一個期限、同一個筆數），一個錄音都不多刪；
        // - 沒動過的人：以前文字＋錄音都只留最新 N 筆（預設 20），錄音照舊只留最新 N 筆，文字改成全部保留。
        if defaults.object(forKey: Keys.audioRetentionPolicy) == nil {
            let migrated: AutoDeletePolicy = textPolicyTouched || limitTouched ? textPolicy : .latestLimit
            self.audioRetentionPolicy = migrated
            self.audioRetentionLimit = storedLimit
            defaults.set(migrated.rawValue, forKey: Keys.audioRetentionPolicy)
            defaults.set(storedLimit, forKey: Keys.audioRetentionLimit)
        } else {
            self.audioRetentionPolicy = AutoDeletePolicy(
                rawValue: defaults.string(forKey: Keys.audioRetentionPolicy) ?? "") ?? .latestLimit
            self.audioRetentionLimit = Self.clampLimit(defaults.object(forKey: Keys.audioRetentionLimit) as? Int ?? storedLimit)
        }
        self.formatterPromptPath = defaults.string(forKey: Keys.formatterPromptPath) ?? ""
        self.bailianASREndpoint = defaults.string(forKey: Keys.bailianASREndpoint)
            ?? "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        self.bailianFormatterEndpoint = defaults.string(forKey: Keys.bailianFormatterEndpoint)
            ?? "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        self.bailianWorkspaceID = defaults.string(forKey: Keys.bailianWorkspaceID) ?? ""
        let storedASRCommand = defaults.string(forKey: Keys.localASRCommand)
        self.localASRCommand = storedASRCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? storedASRCommand!
            : Self.defaultRuntimeExecutable(named: "utuvo-type-asr")
        self.localASRArguments = defaults.string(forKey: Keys.localASRArguments) ?? "{audio}"
        let storedEditorCommand = defaults.string(forKey: Keys.localEditorCommand)
        self.localEditorCommand = storedEditorCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? storedEditorCommand!
            : Self.defaultRuntimeExecutable(named: "utuvo-type-editor.py")
        self.localEditorModel = defaults.string(forKey: Keys.localEditorModel) ?? ""
        self.localDeepModel = defaults.string(forKey: Keys.localDeepModel) ?? ""
        self.dictionaryJSON = defaults.string(forKey: Keys.dictionaryJSON) ?? "{}"
        // 詞庫包預設空（所有 catalog 詞庫預設全關；使用者必須明確開啟才生效）。
        let storedPacks = defaults.stringArray(forKey: Keys.enabledVocabularyPackIDs) ?? []
        self.enabledVocabularyPackIDs = Self.migratingBuiltInPacks(Set(storedPacks), defaults: defaults)
        // 智慧整理服務預設關閉，使用者須明確開啟。
        self.cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? false
        self.cleanupAutoList = defaults.object(forKey: Keys.cleanupAutoList) as? Bool ?? true
        self.cleanupProvider = SmartCleanupProvider(
            rawValue: defaults.string(forKey: Keys.cleanupProvider) ?? SmartCleanupProvider.gemini.rawValue
        ) ?? .gemini
        self.customCleanupEndpoint = defaults.string(forKey: Keys.customCleanupEndpoint) ?? ""
        self.customCleanupModel = defaults.string(forKey: Keys.customCleanupModel) ?? ""
        // Default ⌥Space: portable across laptops and mechanical keyboards that
        // do not have F13–F19, and matches the launchpad apps users already
        // know how to free up if it gets taken. 2026-08-22.
        self.globalShortcut = defaults.string(forKey: Keys.globalShortcut) ?? Self.factoryDefaultShortcut
        self.activeFallbackShortcut = nil
        self.hotkeyConflict = nil
        self.postProcessingShortcut = defaults.string(forKey: Keys.postProcessingShortcut) ?? "⌘⌥P"
        self.askShortcut = defaults.string(forKey: Keys.askShortcut) ?? "⌘⌥A"
        self.explainShortcut = defaults.string(forKey: Keys.explainShortcut) ?? "⌃⌥E"
        self.translateSelectionShortcut = defaults.string(forKey: Keys.translateSelectionShortcut) ?? "⌃⌥T"
        self.deepMinCharacters = defaults.object(forKey: Keys.deepMinCharacters) as? Int ?? 400
        self.deepMinAudioSeconds = defaults.object(forKey: Keys.deepMinAudioSeconds) as? Int ?? 90
        let historyFile = (isolation?.applicationSupportDirectory ?? Self.liveApplicationSupportDirectory)
            .appendingPathComponent(Self.historyFileName)
        self.historyRecords = HistoryStorage.load(fileURL: historyFile, defaults: defaults, legacyKey: Keys.historyJSON)
        self.appPresets = Self.decode([AppPreset].self, from: defaults.string(forKey: Keys.appPresetsJSON))
        trimHistoryIfNeeded()
    }

    var dictionary: [String: String] {
        guard let data = dictionaryJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    func resetDictionaryToEmpty() {
        dictionaryJSON = "{}"
    }

    func addDictionaryTerm(source: String, output: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        updateDictionarySync { $0.set(source, output, at: Date().timeIntervalSince1970) }
    }

    func removeDictionaryTerm(source: String) {
        // 刪掉自動學到的詞＝不要它：記進忽略清單，同一組修正之後不會又被自動加回來（同 iOS LearnedVocabulary.removeFromDictionary）。
        let state = dictionarySync
        if state.source(of: source) == .auto, let output = state.live[source] {
            ignoredSuggestions.insert(Self.ignoreKey(source, output))
        }
        updateDictionarySync { $0.remove(source, at: Date().timeIntervalSince1970) }
    }

    // MARK: - 跨裝置同步（iCloud 跟 iPhone、匯出／匯入跟 Android；格式見 core DictionarySync）

    /// 同步紀錄（每筆時間＋刪除墓碑）；dictionaryJSON 被直接改過（清空全部、舊版）就先對齊。
    var dictionarySync: DictionarySync {
        let stored = defaults.data(forKey: Keys.dictionarySync).flatMap { try? DictionarySync.decode($0) }
        guard var state = stored else { return DictionarySync(plain: dictionary) }
        state.reconcile(with: dictionary, at: Date().timeIntervalSince1970)
        return state
    }

    func writeDictionarySync(_ state: DictionarySync) {
        defaults.set(state.encoded(), forKey: Keys.dictionarySync)
        if state.live != dictionary { saveDictionary(state.live) }
    }

    private func updateDictionarySync(_ change: (inout DictionarySync) -> Void) {
        var state = dictionarySync
        change(&state)
        writeDictionarySync(state)
    }

    /// 匯出檔（含時間與刪除紀錄；另一台匯入時最後改的贏）。
    func exportDictionaryData() -> Data {
        dictionarySync.pruned(now: Date().timeIntervalSince1970).encoded()
    }

    /// 匯入／從 iCloud 合併；回傳有幾個詞因此新增、修改或刪除。
    @discardableResult
    func mergeDictionary(_ incoming: DictionarySync) -> Int {
        let before = dictionary
        writeDictionarySync(dictionarySync.merged(with: incoming))
        let after = dictionary
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.count
    }

    // MARK: - 字典頁確認／復原／詞表匯入（2026-10-22 app-shell-2、app-shell-6）

    /// 「清空全部」的確認文案：寫出筆數，並說明會經 iCloud 一起刪掉其他裝置的詞、無法復原。
    struct DictionaryClearPrompt: Equatable {
        let count: Int
        let title: String
        let message: String
    }

    /// 字典是空的就不必確認（按鈕也不會出現）。只產生文案，不動字典。
    func dictionaryClearPrompt() -> DictionaryClearPrompt? {
        let n = dictionary.count
        guard n > 0 else { return nil }
        return DictionaryClearPrompt(
            count: n,
            title: tr("刪除個人字典的全部 \(n) 個詞？", "Delete all \(n) dictionary terms?"),
            message: tr("登入同一個 iCloud 帳號的 iPhone 和其他 Mac 也會一起刪掉這些詞。這個動作無法復原。",
                        "iPhones and other Macs signed in to the same iCloud account lose them too. This can't be undone.")
        )
    }

    /// 單字移除後的「復原」：把剛刪掉的那筆原樣放回（時間取現在，同步時蓋過刪除紀錄）。
    func restoreDictionaryTerm(source: String, output: String) {
        restoreDictionaryTerm(source: source, output: output, origin: .manual)
    }

    /// 復原時連來源一起放回；放回的是自動詞就把剛才記的忽略拿掉。
    func restoreDictionaryTerm(source: String, output: String, origin: DictionarySync.Source) {
        updateDictionarySync {
            $0.entries[source] = DictionarySync.Entry(output: output, at: Date().timeIntervalSince1970, source: origin)
        }
        if origin == .auto { ignoredSuggestions.remove(Self.ignoreKey(source, output)) }
    }

    /// 匯入純詞表前的確認文案：找到幾個詞、其中幾個是新的。
    struct WordListImportPrompt: Equatable {
        let words: [String]
        let newCount: Int
        let title: String
        let message: String
    }

    enum DictionaryImportResult: Equatable {
        /// 字典檔（JSON）：照舊直接合併，回傳有幾個詞變動。
        case merged(Int)
        /// 一行一詞的詞表：還沒動字典，要先問使用者。
        case confirmWords(WordListImportPrompt)
    }

    /// 匯入檔案：看起來像 JSON 的走原本的字典檔合併（壞掉的 JSON 照舊丟 notDictionaryFile）；
    /// 其他內容當成一行一詞的詞表，先回傳確認文案，使用者按「加入」才呼叫 `addDictionaryWords`。
    func prepareDictionaryImport(_ data: Data, fileName: String) throws -> DictionaryImportResult {
        if DictionarySync.looksLikeJSON(data) {
            return .merged(mergeDictionary(try DictionarySync.decode(data)))
        }
        let words = try DictionarySync.parseWordList(data)
        let n = words.count, k = dictionarySync.newWords(words).count
        let message: String
        if k == n {
            message = tr("會加入 \(k) 個新詞，輸出寫法就是詞本身。", "\(k) new words will be added, each spelled as written.")
        } else {
            message = tr("會加入 \(k) 個新詞；已經在字典裡的 \(n - k) 個不會變動。",
                         "\(k) new words will be added; the \(n - k) already in the dictionary stay unchanged.")
        }
        return .confirmWords(WordListImportPrompt(
            words: words, newCount: k,
            title: tr("在「\(fileName)」找到 \(n) 個詞，要加入字典嗎？", "Found \(n) words in “\(fileName)”. Add them to the dictionary?"),
            message: message
        ))
    }

    /// 把詞表加進字典：只加字典裡沒有的詞（寫法＝詞本身、時間取現在），已經有的不動。回傳加了幾個。
    @discardableResult
    func addDictionaryWords(_ words: [String]) -> Int {
        var added: [String] = []
        updateDictionarySync { added = $0.addWords(words, at: Date().timeIntervalSince1970) }
        return added.count
    }

    private func saveDictionary(_ entries: [String: String]) {
        guard let data = try? JSONEncoder().encode(entries),
              let value = String(data: data, encoding: .utf8) else { return }
        dictionaryJSON = value
    }

    var applicationSupportDirectory: URL {
        if let isolation {
            return isolation.applicationSupportDirectory
        }
        return Self.liveApplicationSupportDirectory
    }

    private static var liveApplicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppBrand.displayName, isDirectory: true)
    }

    /// 歷史紀錄的檔案（app-shell-1）：文字紀錄預設不限筆數，不能再整份塞在 UserDefaults 的一個字串裡。
    static let historyFileName = "history.json"
    var historyFileURL: URL { applicationSupportDirectory.appendingPathComponent(Self.historyFileName) }

    var recordingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    var logDirectory: URL {
        if let isolation { return isolation.logDirectory }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
    }

    func storeRecording(from sourceURL: URL, id: UUID) -> String? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            let destination = recordingsDirectory.appendingPathComponent("\(id.uuidString).caf")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }

    func appendHistory(_ record: HistoryRecord, countsTowardStats: Bool = true) {
        // 使用數據：同一筆（背景整理換字也是同一個 id）只算一次；歷史會被刪，數據另外累計。
        // Ask anything 的回答不是使用者說的字，不算。
        if countsTowardStats, !historyRecords.contains(where: { $0.id == record.id }) {
            usageStats.record(text: record.output, seconds: record.duration, on: record.date)
        }
        historyRecords.insert(record, at: 0)
        if !trimHistoryIfNeeded() { saveHistory() }
    }

    func toggleHistoryStar(id: UUID) {
        guard let index = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        historyRecords[index].isStarred.toggle()
        saveHistory()
    }

    func deleteHistory(id: UUID) {
        guard let index = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        let record = historyRecords.remove(at: index)
        deleteRecording(for: record)
        saveHistory()
    }

    func clearHistory() {
        let records = historyRecords
        historyRecords.removeAll()
        for record in records { deleteRecording(for: record) }
        saveHistory()
        // 讀不出來而改名留著的舊歷史檔（HistoryStorage）也是歷史文字：清空歷史一起刪。
        let folder = applicationSupportDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("history.unreadable-") && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// 背景 cleanup 完成時用：只更新對應 history 的 output（不改 rawTranscript /
    /// duration / mode / app / audio），讓 history 與「實際貼出去」的字一致。
    /// 不存在的 id 靜默忽略（cleanup 比 cancel 慢到達時會發生）。
    func replaceHistoryOutput(id: UUID, with output: String) {
        guard let index = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        let updated = HistoryRecord(
            id: historyRecords[index].id,
            date: historyRecords[index].date,
            rawTranscript: historyRecords[index].rawTranscript,
            output: output,
            duration: historyRecords[index].duration,
            mode: historyRecords[index].mode,
            appName: historyRecords[index].appName,
            bundleIdentifier: historyRecords[index].bundleIdentifier,
            audioPath: historyRecords[index].audioPath,
            isStarred: historyRecords[index].isStarred,
            note: historyRecords[index].note
        )
        historyRecords[index] = updated
        saveHistory()
    }

    /// 歷史重試（app-shell-v1）：就地更新同一筆的輸出與原因；不新增一筆、不碰使用數據，
    /// id／日期／逐字稿／錄音／模式／App／星標都不變。不存在的 id 靜默忽略。
    func replaceHistoryEntry(id: UUID, output: String, note: String?) {
        replaceHistoryEntry(id: id, output: output, note: note, rawTranscript: nil, countsTowardStats: false)
    }

    /// 同上，重試有了結果＝這筆完成了：狀態清掉（失敗／取消 → 正常）。重新辨識（delivery-learning-1）時
    /// 連逐字稿一起換；`countsTowardStats`＝這筆當初沒算過使用數據（失敗／取消的紀錄），現在算一次。
    func replaceHistoryEntry(id: UUID, output: String, note: String?, rawTranscript: String?, countsTowardStats: Bool) {
        guard let index = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        historyRecords[index].output = output
        historyRecords[index].note = note
        if let rawTranscript { historyRecords[index].rawTranscript = rawTranscript }
        historyRecords[index].status = nil
        if countsTowardStats {
            usageStats.record(text: output, seconds: historyRecords[index].duration, on: historyRecords[index].date)
        }
        saveHistory()
    }

    /// 只改那一筆的原因（例如結果沒送到輸入欄位，delivery-learning-2）。不存在的 id 靜默忽略。
    func setHistoryNote(id: UUID, note: String?) {
        guard let index = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        historyRecords[index].note = note
        saveHistory()
    }

    func preset(for bundleIdentifier: String?) -> AppPreset? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return appPresets.first { $0.enabled && $0.bundleIdentifier == bundleIdentifier }
    }

    func saveAppPreset(_ preset: AppPreset) {
        if let index = appPresets.firstIndex(where: { $0.id == preset.id }) {
            appPresets[index] = preset
        } else {
            appPresets.append(preset)
        }
        savePresets()
    }

    func removeAppPreset(id: UUID) {
        appPresets.removeAll { $0.id == id }
        savePresets()
    }

    func stopLocalRuntimeServers() {
        let roots = [
            ProcessInfo.processInfo.environment["UTUVO_TYPE_ROOT"],
            RuntimeBootstrap.locateRepoRoot()
        ].compactMap { $0 }.map { URL(fileURLWithPath: RuntimeBootstrap.engineHome(for: $0)) }
        for root in roots {
            for path in [
                root.appendingPathComponent(".models/asr-server/server.pid"),
                root.appendingPathComponent(".models/editor-server/server.pid")
            ] {
                guard let value = try? String(contentsOf: path, encoding: .utf8),
                      let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                      pid > 1 else { continue }
                if kill(pid, 0) == 0 {
                    _ = kill(pid, SIGTERM)
                }
                try? FileManager.default.removeItem(at: path)
            }
        }
    }

    /// 保留設定（文字＋錄音）。設定頁改短之前先用 `retentionImpact` 算要刪多少、問過再套用。
    struct RetentionSettings: Equatable {
        var text: AutoDeletePolicy
        var textLimit: Int
        var audio: AutoDeletePolicy
        var audioLimit: Int
    }

    struct RetentionImpact: Equatable {
        /// 會整筆刪掉的紀錄數（錄音一起刪）。
        var removedEntries: Int
        /// 會刪掉的錄音檔數（含整筆刪的）。
        var removedRecordings: Int
        var isEmpty: Bool { removedEntries == 0 && removedRecordings == 0 }
    }

    var retentionSettings: RetentionSettings {
        RetentionSettings(text: autoDeletePolicy, textLimit: historyLimit,
                          audio: audioRetentionPolicy, audioLimit: audioRetentionLimit)
    }

    /// 套用 `settings` 會刪掉多少（只算、不刪）。
    func retentionImpact(of settings: RetentionSettings, now: Date = Date()) -> RetentionImpact {
        let plan = HistoryRetention.plan(historyRecords, text: settings.text, textLimit: Self.clampLimit(settings.textLimit),
                                         audio: settings.audio, audioLimit: Self.clampLimit(settings.audioLimit), now: now)
        return RetentionImpact(removedEntries: plan.removed.count, removedRecordings: plan.deletedAudioPaths.count)
    }

    /// 一次套用四個值、只 trim 一次：一個一個設的話，中間狀態（例如筆數先變小、期限還沒改成全部保留）會先刪掉紀錄。
    func applyRetention(_ settings: RetentionSettings) {
        retentionBatch = true
        historyLimit = Self.clampLimit(settings.textLimit)
        autoDeletePolicy = settings.text
        audioRetentionLimit = Self.clampLimit(settings.audioLimit)
        audioRetentionPolicy = settings.audio
        retentionBatch = false
        trimHistoryIfNeeded()
    }

    private var retentionBatch = false

    /// 依保留設定刪紀錄／錄音；有變就寫回（以前整筆刪掉後沒寫回，重開 App 紀錄又回來、錄音卻已刪）。
    /// 回傳有沒有寫回。
    @discardableResult
    private func trimHistoryIfNeeded() -> Bool {
        guard !retentionBatch else { return false }
        let plan = HistoryRetention.plan(historyRecords, text: autoDeletePolicy, textLimit: historyLimit,
                                         audio: audioRetentionPolicy, audioLimit: audioRetentionLimit, now: Date())
        guard plan.kept != historyRecords else { return false }
        historyRecords = plan.kept
        for path in plan.deletedAudioPaths { deleteRecording(atPath: path) }
        saveHistory()
        return true
    }

    private func deleteRecording(for record: HistoryRecord) {
        guard let audioPath = record.audioPath else { return }
        deleteRecording(atPath: audioPath)
    }

    private func deleteRecording(atPath audioPath: String) {
        let path = URL(fileURLWithPath: audioPath).standardizedFileURL
        if let isolation, !path.path.hasPrefix(isolation.recordingsDirectory.standardizedFileURL.path + "/") { return }
        try? FileManager.default.removeItem(at: path)
    }

    /// 存下來、但最後沒有任何一筆紀錄指著它的錄音（Ask 失敗、這次沒寫紀錄…）：刪掉，不留孤兒檔（app-shell-3）。
    func discardRecordingIfUnreferenced(_ audioPath: String?) {
        guard let audioPath, !historyRecords.contains(where: { $0.audioPath == audioPath }) else { return }
        deleteRecording(atPath: audioPath)
    }

    private func saveHistory() {
        HistoryStorage.save(historyRecords, to: historyFileURL)
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(appPresets),
              let value = String(data: data, encoding: .utf8) else { return }
        defaults.set(value, forKey: Keys.appPresetsJSON)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String?) -> T {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(type, from: data) else {
            if type == [HistoryRecord].self { return [] as! T }
            if type == [AppPreset].self { return [] as! T }
            fatalError("Unsupported preference decode type")
        }
        return decoded
    }

    /// 一次性 migration（asr-vocab-1，2026-10-22）：舊版 Mac 只存 catalog id，AI 名稱是寫死、一直開著的。
    /// 內建三包改成跟 iOS／Android 一樣存在同一份集合後，第一次升級把預設開的包（ai、tw）補進去，
    /// 否則已經存過 catalog 的使用者會默默失去 AI 名稱。之後使用者自己關掉就不再補。
    static func migratingBuiltInPacks(_ stored: Set<String>, defaults: UserDefaults) -> Set<String> {
        guard !defaults.bool(forKey: Keys.builtInVocabularyPacksMigrated) else { return stored }
        let migrated = stored.union(BuiltInVocabulary.defaultOnIDs)
        defaults.set(Array(migrated).sorted(), forKey: Keys.enabledVocabularyPackIDs)
        defaults.set(true, forKey: Keys.builtInVocabularyPacksMigrated)
        return migrated
    }

    private static func defaultRuntimeExecutable(named name: String) -> String {
        // 開源後不能有任何人的家目錄：repo root 走 RuntimeBootstrap（env → Info.plist 烙印 → bundle 相對 → cwd）。
        var candidates = [FileManager.default.currentDirectoryPath + "/runtime/\(name)"]
        if let root = RuntimeBootstrap.locateRepoRoot() {
            candidates.insert(URL(fileURLWithPath: root).appendingPathComponent("runtime/\(name)").path, at: 0)
        }
        if let root = ProcessInfo.processInfo.environment["UTUVO_TYPE_ROOT"], !root.isEmpty {
            candidates.insert(URL(fileURLWithPath: root).appendingPathComponent("runtime/\(name)").path, at: 0)
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
    }

    /// 退路鍵使用上的對偶：用工單點名 ⌥\`。宣告成常數讓退路決定與 UI 預設按鈕共用一個真值來源。
    static let factoryDefaultShortcut = "⌥Space"
    /// ⌥Space 被搶時自動接上的退路；Carbon 不容易跟 Gemini/ChatGPT/Raycast/Alfred 撞到。
    static let conflictFallbackShortcut = "⌥`"

    enum Keys {
        static let backend = "utuvo.type.backend"
        static let mode = "utuvo.type.mode"
        static let pushToTalkEnabled = "utuvo.type.pushToTalkEnabled"
        static let transcriptionLanguage = "utuvo.type.transcriptionLanguage"
        static let languageVariants = "utuvo.type.languageVariants"
        static let inputDeviceUID = "utuvo.type.audio.inputDeviceUID"
        static let inputChannel = "utuvo.type.audio.inputChannel"
        static let outputDeviceUID = "utuvo.type.audio.outputDeviceUID"
        static let muteWhileRecording = "utuvo.type.audio.muteWhileRecording"
        static let audioFeedback = "utuvo.type.audio.feedback"
        static let audioFeedbackVolume = "utuvo.type.audio.feedbackVolume"
        static let startHidden = "utuvo.type.app.startHidden"
        static let launchOnStartup = "utuvo.type.app.launchOnStartup"
        static let showTrayIcon = "utuvo.type.app.showTrayIcon"
        static let overlayStyle = "utuvo.type.app.overlayStyle"
        static let outputScript = "utuvo.type.outputScript"
        static let translationSlotShift = "utuvo.type.translation.slotShift"
        static let translationSlotCommand = "utuvo.type.translation.slotCommand"
        static let translationSlotControl = "utuvo.type.translation.slotOption"
        static let overlayPosition = "utuvo.type.app.overlayPosition"
        static let unloadPolicy = "utuvo.type.app.unloadPolicy"
        static let clipboardHandling = "utuvo.type.output.clipboardHandling"
        static let pasteMethod = "utuvo.type.output.pasteMethod"
        static let autoSubmit = "utuvo.type.output.autoSubmit"
        static let appendTrailingSpace = "utuvo.type.output.appendTrailingSpace"
        static let cloudASREnabled = "utuvo.type.cloudASR.enabled"
        static let voiceActivityDetection = "utuvo.type.transcription.voiceActivityDetection"
        static let includeSurroundingContext = "utuvo.type.context.includeSurrounding"
        static let contextBlockedSites = "utuvo.type.context.blockedSites"
        static let usageStats = "utuvo.type.usageStats"
        static let learnFromEdits = "utuvo.type.learnFromEdits"
        static let dictionarySuggestions = "utuvo.type.dictionarySuggestions"
        static let ignoredSuggestions = "utuvo.type.ignoredSuggestions"
        static let postProcessingEnabled = "utuvo.type.postProcessing.enabled"
        static let experimentalFeatures = "utuvo.type.experimentalFeatures"
        static let appLanguage = "utuvo.type.app.language"
        /// 首次啟動硬體判定卡看過即 true（MenuPopoverView hardwareCard）。
        static let hardwareCardDismissed = "utuvo.type.app.hardwareCardDismissed"
        static let appTheme = "utuvo.type.app.theme"
        static let historyLimit = "utuvo.type.history.limit"
        static let autoDeletePolicy = "utuvo.type.history.autoDelete"
        static let formatterPromptPath = "utuvo.type.prompt.path"
        static let bailianASREndpoint = "utuvo.type.bailian.asrEndpoint"
        static let bailianFormatterEndpoint = "utuvo.type.bailian.formatterEndpoint"
        static let bailianWorkspaceID = "utuvo.type.bailian.workspaceID"
        static let localASRCommand = "utuvo.type.local.asrCommand"
        static let localASRArguments = "utuvo.type.local.asrArguments"
        static let localEditorCommand = "utuvo.type.local.editorCommand"
        static let localEditorModel = "utuvo.type.local.editorModel"
        static let localDeepModel = "utuvo.type.local.deepModel"
        static let dictionaryJSON = "utuvo.type.dictionaryJSON"
        static let dictionarySync = "utuvo.type.dictionarySync"
        static let enabledVocabularyPackIDs = "utuvo.type.vocabularyPacks.enabled"
        static let builtInVocabularyPacksMigrated = "utuvo.type.vocabularyPacks.builtInMigrated"
        static let cleanupEnabled = "utuvo.type.smart.enabled"
        static let cleanupAutoList = "utuvo.type.smart.autoList"
        static let cleanupProvider = "utuvo.type.smart.provider"
        static let customCleanupEndpoint = "utuvo.type.smart.customEndpoint"
        static let customCleanupModel = "utuvo.type.smart.customModel"
        static let globalShortcut = "utuvo.type.globalShortcut"
        static let postProcessingShortcut = "utuvo.type.postProcessingShortcut"
        static let askShortcut = "utuvo.type.askShortcut"
        static let explainShortcut = "utuvo.type.explainShortcut"
        static let translateSelectionShortcut = "utuvo.type.translateSelectionShortcut"
        static let deepMinCharacters = "utuvo.type.deepMinCharacters"
        static let deepMinAudioSeconds = "utuvo.type.deepMinAudioSeconds"
        /// 舊版整份歷史存在這個 UserDefaults 字串；現在只用來搬一次到 history.json（app-shell-1）。
        static let historyJSON = "utuvo.type.history.json"
        static let audioRetentionPolicy = "utuvo.type.history.audioRetention"
        static let audioRetentionLimit = "utuvo.type.history.audioLimit"
        static let appPresetsJSON = "utuvo.type.appPresets.json"
    }
}
