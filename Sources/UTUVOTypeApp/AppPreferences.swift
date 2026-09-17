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

    @Published var appendTrailingSpace: Bool {
        didSet { defaults.set(appendTrailingSpace, forKey: Keys.appendTrailingSpace) }
    }

    @Published var voiceActivityDetection: Bool {
        didSet { defaults.set(voiceActivityDetection, forKey: Keys.voiceActivityDetection) }
    }

    @Published var includeSurroundingContext: Bool {
        didSet { defaults.set(includeSurroundingContext, forKey: Keys.includeSurroundingContext) }
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
            defaults.set(max(1, min(historyLimit, 500)), forKey: Keys.historyLimit)
            trimHistoryIfNeeded()
        }
    }

    @Published var autoDeletePolicy: AutoDeletePolicy {
        didSet {
            defaults.set(autoDeletePolicy.rawValue, forKey: Keys.autoDeletePolicy)
            trimHistoryIfNeeded()
        }
    }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        self.voiceActivityDetection = defaults.object(forKey: Keys.voiceActivityDetection) as? Bool ?? true
        self.includeSurroundingContext = defaults.object(forKey: Keys.includeSurroundingContext) as? Bool ?? false
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
        self.historyLimit = max(1, min(defaults.object(forKey: Keys.historyLimit) as? Int ?? 20, 500))
        self.autoDeletePolicy = AutoDeletePolicy(
            rawValue: defaults.string(forKey: Keys.autoDeletePolicy) ?? AutoDeletePolicy.latestLimit.rawValue
        ) ?? .latestLimit
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
        // Default ⌥Space: portable across laptops and mechanical keyboards that
        // do not have F13–F19, and matches the launchpad apps users already
        // know how to free up if it gets taken. 2026-08-22.
        self.globalShortcut = defaults.string(forKey: Keys.globalShortcut) ?? Self.factoryDefaultShortcut
        self.activeFallbackShortcut = nil
        self.hotkeyConflict = nil
        self.postProcessingShortcut = defaults.string(forKey: Keys.postProcessingShortcut) ?? "⌘⌥P"
        self.deepMinCharacters = defaults.object(forKey: Keys.deepMinCharacters) as? Int ?? 400
        self.deepMinAudioSeconds = defaults.object(forKey: Keys.deepMinAudioSeconds) as? Int ?? 90
        self.historyRecords = Self.decode([HistoryRecord].self, from: defaults.string(forKey: Keys.historyJSON))
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
        var entries = dictionary
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[source] = output.isEmpty ? source : output
        saveDictionary(entries)
    }

    func removeDictionaryTerm(source: String) {
        var entries = dictionary
        entries.removeValue(forKey: source)
        saveDictionary(entries)
    }

    private func saveDictionary(_ entries: [String: String]) {
        guard let data = try? JSONEncoder().encode(entries),
              let value = String(data: data, encoding: .utf8) else { return }
        dictionaryJSON = value
    }

    var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppBrand.displayName, isDirectory: true)
    }

    var recordingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    var logDirectory: URL {
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

    func appendHistory(_ record: HistoryRecord) {
        historyRecords.insert(record, at: 0)
        trimHistoryIfNeeded()
        saveHistory()
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

    private func trimHistoryIfNeeded() {
        let before = historyRecords
        let now = Date()
        let cutoff: Date?
        switch autoDeletePolicy {
        case .keepAll, .latestLimit:
            cutoff = nil
        case .afterOneDay:
            cutoff = now.addingTimeInterval(-86_400)
        case .afterOneWeek:
            cutoff = now.addingTimeInterval(-604_800)
        case .afterOneMonth:
            cutoff = now.addingTimeInterval(-2_592_000)
        }

        var filtered = historyRecords
        if let cutoff {
            filtered = filtered.filter { $0.isStarred || $0.date >= cutoff }
        }
        if autoDeletePolicy != .keepAll {
            let starred = filtered.filter(\.isStarred)
            let unstarred = filtered.filter { !$0.isStarred }
            let remaining = max(0, historyLimit - starred.count)
            filtered = starred + Array(unstarred.prefix(remaining))
                .sorted { $0.date > $1.date }
        }
        historyRecords = filtered.sorted { $0.date > $1.date }
        let retainedIDs = Set(historyRecords.map(\.id))
        for record in before where !retainedIDs.contains(record.id) {
            deleteRecording(for: record)
        }
    }

    private func deleteRecording(for record: HistoryRecord) {
        guard let audioPath = record.audioPath else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: audioPath))
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(historyRecords),
              let value = String(data: data, encoding: .utf8) else { return }
        defaults.set(value, forKey: Keys.historyJSON)
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
        static let voiceActivityDetection = "utuvo.type.transcription.voiceActivityDetection"
        static let includeSurroundingContext = "utuvo.type.context.includeSurrounding"
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
        static let globalShortcut = "utuvo.type.globalShortcut"
        static let postProcessingShortcut = "utuvo.type.postProcessingShortcut"
        static let deepMinCharacters = "utuvo.type.deepMinCharacters"
        static let deepMinAudioSeconds = "utuvo.type.deepMinAudioSeconds"
        static let historyJSON = "utuvo.type.history.json"
        static let appPresetsJSON = "utuvo.type.appPresets.json"
    }
}
