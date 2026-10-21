@preconcurrency import AVFoundation
@preconcurrency import Speech
import AppKit
import Combine
import Foundation
import OSLog
import UTUVOTypeCore

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.utuvo.type", category: "permissions")
    /// 投遞／整理結果（`log show --predicate 'subsystem == "com.utuvo.type"'` 查得到；不含逐字稿內容）。
    private let deliveryLog = Logger(subsystem: "com.utuvo.type", category: "delivery")
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false {
        didSet {
            // 上一句還在轉錄時按的「開始」先記著，貼出（isProcessing 變 false）就立刻開錄。
            guard oldValue, !isProcessing, let pending = pendingStart else { return }
            pendingStart = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRecording, !self.isProcessing else { return }
                self.activeTranslationTarget = pending
                self.startRecording(mode: self.preferences.mode)
            }
        }
    }
    /// 2026-10-19 Typeless 對打：上一句還在轉錄時按熱鍵會被 `guard !isProcessing` 靜默吃掉，
    /// 連續講話時下一句就沒錄到（Typeless 不會）。改成排隊：處理完自動開始，期間再按一次＝取消排隊。
    private(set) var pendingStart: TranslationTarget?
    #if DEBUG
    /// 測試用：模擬「上一句還在轉錄」。
    func setProcessingForTesting(_ value: Bool) { isProcessing = value }
    #endif
    @Published private(set) var statusMessage = "準備就緒"
    @Published private(set) var partialTranscript = ""
    @Published private(set) var lastRawTranscript = ""
    @Published private(set) var lastOutput = ""
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var needsPermissionSetup = false
    @Published private(set) var microphonePermissionReady = false
    @Published private(set) var accessibilityPermissionReady = false
    @Published private(set) var currentAppName = "未偵測"
    @Published private(set) var currentBundleIdentifier = ""
    @Published private(set) var playingHistoryID: UUID?

    let preferences: AppPreferences
    var onStateChange: (() -> Void)?

    private var capture: AudioCaptureSession?
    private let feedbackTonePlayer = FeedbackTonePlayer()
    private var cloudASRTask: Task<String, Error>?
    /// 錄音中收齊 16 kHz PCM（本機 Qwen／Groq 雲端辨識都用）：停頓時先辨識，Groq 模式停下來整段送。
    private var pcmTask: Task<Data, Never>?
    private var pcmEngineIsGroq = false
    /// 出字時間拆解（停止 → 錄音收尾 → 辨識 → 整理 → 送達），寫 delivery log。
    private var stopPressedAt: Date?
    /// 停頓預先處理（Groq 模式）：講完一段停下來時先辨識、先整理；按停止時錄音沒有新聲音就直接沿用。
    private struct Speculation {
        let token: UUID
        let pcmBytes: Int
        let asr: Task<String?, Never>
        var cleanup: (raw: String, config: CleanupConfig, task: Task<String?, Never>)?
    }
    private var speculation: Speculation?
    private var activeMode: FormatterMode = .fast
    private var selectedContext: LimitedAppContext?
    private var operationToken = UUID()
    private var pushToTalkActive = false
    // 即時翻譯：由按下的修飾鍵變體決定，停止那一下按的變體優先。
    private var activeTranslationTarget: TranslationTarget = .off
    // PTT 放開事件被忽略（主鍵仍壓著）後的看門狗：若使用者放開主鍵時按著一顆
    // 沒註冊變體的修飾鍵（例如 ⌥），Carbon 不會再送任何事件，沒有它錄音會永遠不停。
    private var pttKeyWatchdog: Task<Void, Never>?
    private var historyAudioPlayer: NSSound?
    private var unloadTask: Task<Void, Never>?
    private var inputChangedDuringRecording = false
    private var permissionOnboardingInFlight = false
    // 背景智慧整理（SmartCleanup）：先送 deterministic 出去、捕捉 AXInsertionTicket；
    // cleanup 完成後用 AXReplacementGate 確認「同一欄位、同一內容、同一前綴」才覆寫。
    private var pendingCleanupTask: Task<Void, Never>?
    private var destination: (any DictationDestination)?
    private var capturedPID: Int32?
    /// Ask anything（2026-10-13）：這次錄音是問問題／對選取文字下指令，不是聽寫。
    private var askActive = false
    private var askSelection: String?
    private var askPID: Int32?
    /// 問問題當下的焦點欄位：回答要貼回去時必須還是同一個欄位（luna-review r2：同 App 換欄位會貼錯地方）。
    private var askElement: AXUIElement?
    /// 問問題當下的選取範圍／游標位置；貼回去前要一模一樣（luna-review r3：同欄位改選別段或移動游標會貼錯位置）。
    private var askRange: CFRange?

    private func stillAtAskField(expectSelection: String? = nil) -> Bool {
        guard let askPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == askPID else { return false }
        guard let askElement, let askRange else { return false }
        guard let now = AccessibilitySupport.focusedElement(), CFEqual(now, askElement),
              let range = AccessibilitySupport.selectedRange(of: now),
              range.location == askRange.location, range.length == askRange.length else { return false }
        if let expectSelection {
            let current = AccessibilitySupport.selectedText(of: now)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return current == expectSelection
        }
        return true
    }
    /// 插入後追蹤修改 → 字典建議（2026-10-13）。
    let editWatcher = EditWatcher()

    private func watchEdits(_ inserted: String) {
        guard preferences.learnFromEdits, preferences.isolation == nil else { return }
        editWatcher.onSuggestions = { [weak self] found in self?.preferences.addSuggestions(found) }
        editWatcher.watch(inserted: inserted)
    }
    var captureDestination: (Int32?) -> (any DictationDestination)?
    var cleanupRunner: @Sendable (String, CleanupConfig) async -> String?
    /// Isolated tests can verify local Smart output is inserted before its slower formatter completes.
    var localBackgroundRunner: (@Sendable (String, LimitedAppContext, [String: String]) async -> String?)?
    // Isolated fixtures can exercise the actual one-shot branch without starting a provider.
    var legacyFormatterRunner: ((String) async throws -> String)?
    var onDeliveryEvent: ((String) -> Void)?
    private let legacyFirstUsePermissionKey = "utuvo.type.firstUsePermissionPrompted"
    private let permissionOnboardingAttemptedKey = "utuvo.type.permissionOnboardingAttempted"
    private let permissionOnboardingCompletedKey = "utuvo.type.permissionOnboardingCompleted"

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        if preferences.isolation != nil {
            captureDestination = { _ in nil }
            cleanupRunner = { _, _ in nil }
            legacyFormatterRunner = { _ in throw URLError(.notConnectedToInternet) }
        } else {
            captureDestination = { AXAdapter.shared.capture(expectedPID: $0) }
            cleanupRunner = { text, config in await SmartCleanup.clean(text, config: config) }
        }
        statusMessage = preferences.tr("準備就緒", "Ready")
        refreshPermissionState()
    }

    /// Display-only scalar; polling does not publish changes or alter recording.
    func liveVoiceLevel() -> Float? { isRecording ? capture?.currentVoiceLevel : nil }

    var modeDisplayName: String {
        switch activeMode {
        case .fast: return "Fast Dictate"
        case .smart: return "Smart Dictate"
        case .editSelection: return "Edit Selection"
        case .deep: return "Deep / Long Note"
        }
    }

    func toggleRecording() {
        if isRecording {
            pushToTalkActive = false
            stopRecording()
        } else {
            pushToTalkActive = preferences.pushToTalkEnabled
            startRecording(mode: preferences.mode)
        }
    }

    /// menu bar 按鈕走這裡：一律原文輸出。
    func toggleRecordingFromUI() {
        activeTranslationTarget = .off
        toggleRecording()
    }

    func shortcutPressed(translation: TranslationTarget = .off) {
        if !isRecording && !isProcessing { askActive = false; askSelection = nil }   // 一般聽寫開始：清掉殘留的 Ask
        if preferences.pushToTalkEnabled {
            guard !isProcessing else { return }
            if isRecording {
                // PTT 按住期間補按／放開修飾鍵：Carbon 會送「舊組合 released＋新組合 pressed」。
                // 這裡只改翻譯目標，不開新錄音——規則與 toggle 一致：放開主鍵那一刻按著什麼就翻成什麼。
                // 錄音是 toggle 起的（pushToTalkActive=false）也走這裡，絕不重入 beginRecording（F2）。
                pushToTalkActive = true
                activeTranslationTarget = translation
                logger.info("ptt retarget -> \(translation.rawValue, privacy: .public)")
                return
            }
            pushToTalkActive = true
            activeTranslationTarget = translation
            startRecording(mode: preferences.mode)
        } else {
            // toggle：停止那一下按的修飾鍵決定翻譯語言（先講後選語言）；
            // 處理中按變體不改目標（F6）。
            if isProcessing {
                if pendingStart != nil {
                    pendingStart = nil
                    statusMessage = preferences.tr("已取消排隊的錄音", "Queued recording cancelled")
                } else {
                    pendingStart = translation
                    statusMessage = preferences.tr("上一句處理完就開始錄…", "Recording starts as soon as the last one is done…")
                }
                notify()
                return
            }
            activeTranslationTarget = translation
            toggleRecording()
        }
    }

    /// - Parameter mainKeyStillDown: 主鍵（非修飾鍵）此刻是否仍被壓著；
    ///   仍壓著＝只是修飾鍵變了（Carbon 會送 released），不是真的放開，忽略。
    func shortcutReleased(mainKeyStillDown: Bool = false, mainKeyCode: UInt32? = nil) {
        guard preferences.pushToTalkEnabled else { return }
        logger.info("ptt release mainKeyDown=\(mainKeyStillDown, privacy: .public) recording=\(self.isRecording, privacy: .public) active=\(self.pushToTalkActive, privacy: .public)")
        if mainKeyStillDown, isRecording, pushToTalkActive {
            logger.info("ptt release ignored (main key still down)")
            startPTTKeyWatchdog(keyCode: mainKeyCode)
            return
        }
        pttKeyWatchdog?.cancel()
        pttKeyWatchdog = nil
        pushToTalkActive = false
        if isRecording {
            stopRecording()
        }
    }

    /// 每 50ms 查一次主鍵硬體狀態，放開就補送真正的 release（F1）；上限 120s 防呆。
    private func startPTTKeyWatchdog(keyCode: UInt32?) {
        guard let keyCode else { return }
        pttKeyWatchdog?.cancel()
        pttKeyWatchdog = Task { [weak self] in
            for _ in 0..<2_400 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) {
                    await MainActor.run {
                        guard let self, self.isRecording, self.pushToTalkActive else { return }
                        self.logger.info("ptt watchdog: main key up without Carbon release -> stop")
                        self.pttKeyWatchdog = nil
                        self.shortcutReleased(mainKeyStillDown: false)
                    }
                    return
                }
            }
        }
    }

    func ensureFirstUsePermissions() async {
        guard preferences.isolation == nil else { return }
        guard !permissionOnboardingInFlight else { return }
        permissionOnboardingInFlight = true
        defer { permissionOnboardingInFlight = false }

        refreshPermissionState()
        if !needsPermissionSetup {
            UserDefaults.standard.set(true, forKey: permissionOnboardingCompletedKey)
            statusMessage = preferences.tr("系統權限已就緒", "System permissions are ready")
            notify()
            return
        }

        // The old key meant "the prompt was shown". Treat it as an attempted
        // onboarding flow, not as permission completion, so an upgraded app
        // cannot reopen the native prompt on every menu-bar click.
        let alreadyAttempted = UserDefaults.standard.bool(forKey: permissionOnboardingAttemptedKey)
            || UserDefaults.standard.bool(forKey: legacyFirstUsePermissionKey)
        guard !alreadyAttempted else {
            updatePermissionStatus()
            notify()
            return
        }
        UserDefaults.standard.set(true, forKey: permissionOnboardingAttemptedKey)

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await PermissionGate.requestMicrophone()
        }
        refreshPermissionState()

        // The defensive flow is an explicit System Settings handoff. Do
        // not call AXIsProcessTrustedWithOptions here: macOS can show its native
        // "control this computer" alert again after an ad-hoc rebuild, even
        // though the user already authorized this app. The card remains visible
        // until TCC reports the permission as ready, and the user can click the
        // exact pane again deliberately.
        openMissingPermissionSettings()
        refreshPermissionState()
        if !needsPermissionSetup {
            UserDefaults.standard.set(true, forKey: permissionOnboardingCompletedKey)
        }
        updatePermissionStatus()
        notify()
    }

    func openMissingPermissionSettings() {
        guard preferences.isolation == nil else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AccessibilitySupport.openPrivacySettings(section: "Microphone")
            return
        }
        if !AccessibilitySupport.isTrusted() {
            AccessibilitySupport.openPrivacySettings(section: "Accessibility")
        }
    }

    /// 截圖模式用：固定示範中的前景 app 名稱，不讓 loginwindow／Finder 之類進行銷圖。
    func overrideCurrentAppNameForSnapshot(_ name: String) {
        currentAppName = name
    }

    func refreshPermissionState() {
        guard preferences.isolation == nil else { return }
        microphonePermissionReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityPermissionReady = AccessibilitySupport.isTrusted()
        needsPermissionSetup = !microphonePermissionReady || !accessibilityPermissionReady
        let context = AccessibilitySupport.readCurrentContext()
        currentAppName = context.appName ?? preferences.tr("未偵測", "Not detected")
        currentBundleIdentifier = context.foregroundBundleIdentifier ?? ""
        logger.info(
            "permission state microphone=\(self.microphonePermissionReady, privacy: .public) accessibility=\(self.accessibilityPermissionReady, privacy: .public)"
        )
    }

    /// 翻譯：用本機小型 editor 翻譯整段輸出。
    /// 翻譯結果與原文重疊度天然很低，不能過 FormatterOutputGuard 的幻覺重疊檢查，
    /// 只做 code fence 剝除與 trim。失敗回 nil（呼叫端出 notice＋留 log，不無聲吞掉）。
    private func translateOutput(_ text: String, target: TranslationTarget) async -> String? {
        let command = preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        // 字形轉換只對中文目標有意義；日文漢字會被 OpenCC s2t 誤改（国→國），
        // 非中文目標一律關掉 wrapper 的轉換。
        let script: String
        switch target {
        case .traditionalChinese: script = OutputScript.traditional.rawValue
        case .simplifiedChinese: script = OutputScript.simplified.rawValue
        default: script = OutputScript.asIs.rawValue
        }
        let prompt = """
        You are a professional translator. Translate the text below into \(target.promptName). \
        Output ONLY the translation. No explanations, no quotes, no labels.

        \(text)
        """
        do {
            let client = LocalFormatterProcessClient(command: command, outputScript: script)
            let candidate = try await client.format(
                prompt: prompt,
                model: preferences.localEditorModel.isEmpty ? "local-qwen3-editor" : preferences.localEditorModel
            )
            let cleaned = candidate
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            logger.info("translation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func startRecording(mode: FormatterMode, persistMode: Bool = true) {
        guard !isProcessing else { return }
        prepareDictation(mode: mode)
        guard preferences.isolation == nil else { return }
        // 2026-09-24 實機（苑涵 0.1.5）：安裝中按聽寫＝錄完才靜靜失敗，使用者以為壞了。開始前就講清楚。
        if preferences.backend == .local, EngineInstaller.shared.isInstalling {
            let step = EngineInstaller.shared.lastLine
            fail(preferences.tr("本機引擎還在安裝，完成前無法轉文字。\(step)",
                                "The local engine is still installing; dictation works once it finishes. \(step)"))
            return
        }
        let generation = operationToken
        unloadTask?.cancel()
        unloadTask = nil
        activeMode = mode
        if persistMode { preferences.mode = mode }
        if mode == .smart, preferences.postProcessingEnabled, preferences.cleanupEnabled {
            let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) ?? .gemini
            SmartCleanup.warmUp(provider: provider,
                                customEndpoint: preferences.customCleanupEndpoint,
                                bailianEndpoint: preferences.bailianFormatterEndpoint)
        } else if mode == .smart, preferences.postProcessingEnabled, preferences.backend == .local {
            LocalEditorPrewarmer.warmUp(command: preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Task { [weak self] in
            guard let self, self.operationToken == generation else { return }
            await self.beginRecording()
        }
    }

    func cancelProcessing() {
        invalidateBackground()
        activeTranslationTarget = .off
        askActive = false
        askSelection = nil
        guard isProcessing else { return }
        operationToken = UUID()
        cloudASRTask?.cancel()
        pcmTask?.cancel(); pcmTask = nil
        capture?.cancel()
        capture = nil
        pushToTalkActive = false
        isRecording = false
        isProcessing = false
        // 背景 cleanup 不准在取消後還把 lastOutput / history 蓋掉。
        pendingCleanupTask?.cancel()
        pendingCleanupTask = nil
        statusMessage = preferences.tr("已取消；沒有貼上新文字", "Cancelled; no new text was pasted")
        notify()
    }

    /// Escape cancel behaviour: stop an active capture first;
    /// if formatting is already running, cancel it without discarding the
    /// latest raw transcript.
    func cancelRecording() {
        invalidateBackground()
        activeTranslationTarget = .off
        askActive = false
        askSelection = nil
        if isRecording {
            operationToken = UUID()
            cloudASRTask?.cancel()
            pcmTask?.cancel(); pcmTask = nil
            capture?.cancel()
            capture = nil
            pushToTalkActive = false
            isRecording = false
            isProcessing = false
            statusMessage = preferences.tr("已取消錄音；沒有貼上新文字", "Recording cancelled; no new text was pasted")
            notify()
            return
        }
        cancelProcessing()
    }

    func copyLastOutput() {
        guard !lastOutput.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastOutput, forType: .string)
        statusMessage = preferences.tr("已複製最後整理結果", "Copied the last formatted result")
        notify()
    }

    func copyHistory(_ record: HistoryRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.output, forType: .string)
        statusMessage = preferences.tr("已複製歷史結果", "Copied history result")
        notify()
    }

    func toggleHistoryStar(_ record: HistoryRecord) {
        preferences.toggleHistoryStar(id: record.id)
        notify()
    }

    func deleteHistory(_ record: HistoryRecord) {
        preferences.deleteHistory(id: record.id)
        statusMessage = preferences.tr("已刪除歷史紀錄", "History entry deleted")
        notify()
    }

    func clearHistory() {
        preferences.clearHistory()
        statusMessage = preferences.tr("已清空歷史紀錄", "History cleared")
        notify()
    }

    func openRecordingsFolder() {
        do {
            try FileManager.default.createDirectory(
                at: preferences.recordingsDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(preferences.recordingsDirectory)
        } catch {
            statusMessage = preferences.tr("無法開啟錄音資料夾", "Could not open the recordings folder")
            lastErrorMessage = error.localizedDescription
        }
        notify()
    }

    func playHistory(_ record: HistoryRecord) {
        guard let audioPath = record.audioPath,
              FileManager.default.fileExists(atPath: audioPath) else {
            statusMessage = preferences.tr("這筆紀錄沒有可播放的錄音", "This entry has no playable recording")
            notify()
            return
        }
        if playingHistoryID == record.id {
            historyAudioPlayer?.stop()
            historyAudioPlayer = nil
            playingHistoryID = nil
            notify()
            return
        }
        guard let player = NSSound(contentsOfFile: audioPath, byReference: true) else {
            statusMessage = preferences.tr("無法播放這筆錄音", "Could not play this recording")
            notify()
            return
        }
        historyAudioPlayer?.stop()
        historyAudioPlayer = player
        playingHistoryID = record.id
        player.play()
        statusMessage = preferences.tr("播放歷史錄音中", "Playing history recording")
        notify()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, Int(record.duration.rounded()) + 1)))
            guard let self, self.playingHistoryID == record.id else { return }
            self.playingHistoryID = nil
            self.historyAudioPlayer = nil
            self.notify()
        }
    }

    func retryHistory(_ record: HistoryRecord) {
        // 決策集中在 core 的 RetryPolicy（MAC2）：重試永遠用既有 rawTranscript，
        // 不重新錄音；順序是「忙碌先擋」再看模式。
        switch RetryPolicy.decide(mode: record.mode, isRecording: isRecording, isProcessing: isProcessing) {
        case .ignoreBusy:
            return
        case .needsReselection:
            statusMessage = preferences.tr(
                "Edit Selection 需要重新選取原文字後再執行",
                "Edit Selection requires selecting the original text again before retrying"
            )
            notify()
            return
        case .reformatFromRawTranscript:
            break
        }
        activeMode = record.mode
        preferences.mode = record.mode
        selectedContext = nil
        operationToken = UUID()
        isProcessing = true
        statusMessage = preferences.tr("重新整理歷史紀錄…", "Reformatting history entry…")
        let token = operationToken
        notify()
        Task { [weak self] in
            await self?.formatAndPaste(
                transcript: record.rawTranscript,
                audioDuration: record.duration,
                asrError: nil,
                token: token,
                historyID: UUID()
            )
            guard let self else { return }
            self.isProcessing = false
            self.scheduleRuntimeUnload()
            self.notify()
        }
    }

    func reprocessLastResult() {
        guard preferences.postProcessingEnabled,
              !isRecording,
              !isProcessing,
              !lastRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        activeMode = .smart
        operationToken = UUID()
        isProcessing = true
        statusMessage = preferences.tr("重新整理最後一段…", "Reformatting the last passage…")
        let token = operationToken
        let transcript = lastRawTranscript
        notify()
        Task { [weak self] in
            await self?.formatAndPaste(
                transcript: transcript,
                audioDuration: 0,
                asrError: nil,
                token: token,
                historyID: UUID()
            )
            guard let self else { return }
            self.isProcessing = false
            self.scheduleRuntimeUnload()
            self.notify()
        }
    }

    func requestAccessibility() {
        refreshPermissionState()
        AccessibilitySupport.openPrivacySettings(section: "Accessibility")
        statusMessage = accessibilityPermissionReady
            ? preferences.tr(
                "輔助使用已完成；若功能仍未更新，請回到 \(AppBrand.displayName) 再試一次",
                "Accessibility is granted; if features still lag, return to \(AppBrand.displayName) and try again"
            )
            : preferences.tr(
                "請在系統設定中允許 \(AppBrand.displayName) 輔助使用",
                "Please allow \(AppBrand.displayName) under Accessibility in System Settings"
            )
        notify()
    }

    private func updatePermissionStatus() {
        if !needsPermissionSetup {
            statusMessage = preferences.tr("系統權限已就緒", "System permissions are ready")
        } else if !microphonePermissionReady && !accessibilityPermissionReady {
            statusMessage = preferences.tr(
                "尚缺麥克風與輔助使用權限；只會提示一次",
                "Microphone and Accessibility permissions are still missing; you will only be prompted once"
            )
        } else if !microphonePermissionReady {
            statusMessage = preferences.tr(
                "輔助使用已完成；尚缺麥克風權限",
                "Accessibility is granted; Microphone permission is still missing"
            )
        } else {
            statusMessage = preferences.tr(
                "麥克風已完成；尚缺輔助使用權限",
                "Microphone is granted; Accessibility permission is still missing"
            )
        }
    }

    func reportShortcutStatus(_ message: String) {
        statusMessage = message
        notify()
    }

    private func beginRecording() async {
        editWatcher.checkNow()   // 上一段已經改完了：先比對，再開始這一段
        lastErrorMessage = nil
        partialTranscript = ""
        selectedContext = nil
        let generation = operationToken

        guard await PermissionGate.requestMicrophone() else {
            fail(preferences.tr(
                "麥克風權限未開啟；請到系統設定 → 隱私權與安全性 → 麥克風允許 \(AppBrand.displayName)",
                "Microphone permission is off; allow \(AppBrand.displayName) in System Settings → Privacy & Security → Microphone"
            ))
            return
        }

        guard generation == operationToken else { return }
        if activeMode == .editSelection {
            guard AccessibilitySupport.isTrusted() else {
                fail(preferences.tr(
                    "Edit Selection 需要輔助使用權限；未讀取任何螢幕內容",
                    "Edit Selection needs Accessibility permission; no screen content was read"
                ))
                return
            }
            let context = AccessibilitySupport.readCurrentContext(
                includeSurrounding: preferences.includeSurroundingContext,
                blockedSites: preferences.contextBlockedSites
            )
            if context.contextBlocked {
                fail(preferences.tr(
                    "這個網站在「不讀脈絡的網站」清單裡；沒有讀取選取文字",
                    "This site is on your “never share context” list; the selection was not read"
                ))
                return
            }
            guard let selected = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty else {
                fail(preferences.tr(
                    "目前 App 沒有可讀取的選取文字；未替換任何內容",
                    "The current app has no readable selected text; nothing was replaced"
                ))
                return
            }
            selectedContext = context
        }

        // Local Qwen3-ASR remains the final transcript source. If the user has
        // already granted Speech permission, Apple's on-device recognizer adds
        // a low-latency preview. A configured Qwen runtime never triggers an
        // extra permission prompt; the Speech fallback is requested only when
        // no local ASR executable is available.
        let hasLocalASRCommand = !preferences.localASRCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let enableSpeechPreview: Bool
        if preferences.backend != .local {
            enableSpeechPreview = false
        } else if hasLocalASRCommand {
            enableSpeechPreview = SFSpeechRecognizer.authorizationStatus() == .authorized
        } else {
            enableSpeechPreview = await PermissionGate.requestSpeechRecognition()
        }

        let session = AudioCaptureSession(
            inputDeviceUID: preferences.inputDeviceUID.isEmpty ? nil : preferences.inputDeviceUID,
            inputChannel: preferences.inputChannel,
            transcriptionLanguageIdentifier: preferences.transcriptionLanguage.speechLocaleIdentifier,
            outputDeviceUID: preferences.outputDeviceUID.isEmpty ? nil : preferences.outputDeviceUID,
            muteWhileRecording: preferences.muteWhileRecording,
            voiceActivityDetection: preferences.voiceActivityDetection && !preferences.pushToTalkEnabled
        )
        session.onPartial = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.partialTranscript = text
                self.statusMessage = self.preferences.tr("聆聽中…", "Listening…")
                self.notify()
            }
        }
        session.onSilenceDetected = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.statusMessage = self.preferences.tr(
                    "偵測到停止說話，正在完成轉錄…",
                    "Detected silence; finishing transcription…"
                )
                self.stopRecording()
            }
        }

        let audioStream: AsyncThrowingStream<Data, Error>
        do {
            audioStream = try session.start(enableSpeechFallback: enableSpeechPreview)
        } catch {
            fail(error.localizedDescription)
            return
        }

        capture = session
        isRecording = true
        playAudioFeedbackIfEnabled()
        let micName = session.inputDeviceName
        statusMessage = micName.isEmpty
            ? preferences.tr("聆聽中…點選停止以整理並貼上", "Listening… click stop to format and paste")
            : preferences.tr("聆聽中（麥克風：\(micName)）…點選停止以整理並貼上", "Listening (mic: \(micName))… click stop to format and paste")
        notify()
        // 2026-09-24 實機（苑涵 0.1.5）：AirPods 搶走系統輸入，對著電腦講、錄到的全是靜音，使用者不知道。
        // 錄音中輸入裝置被換掉＝停下來講清楚；講了 3 秒還幾乎沒聲音＝當場提示用的是哪支麥克風。
        session.onInputDeviceChanged = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording, self.capture === session else { return }
                self.inputChangedDuringRecording = true
                self.stopRecording()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isRecording, self.capture === session,
                  session.peakDBFSSoFar < AudioCaptureResult.silentPeakDBFS else { return }
            self.statusMessage = self.preferences.tr(
                "好像沒收到聲音——目前使用的麥克風是「\(micName)」，可到設定換輸入裝置",
                "No sound detected yet — the current microphone is \"\(micName)\"; change the input in Settings")
            self.notify()
        }

        if preferences.pushToTalkEnabled && !pushToTalkActive {
            stopRecording()
            return
        }

        if preferences.backend == .bailian {
            do {
                let asr = try BailianASRTranscriber(
                    endpointString: preferences.bailianASREndpoint,
                    workspaceID: preferences.bailianWorkspaceID
                )
                let appContext = selectedContext ?? AccessibilitySupport.readCurrentContext(
                    includeSurrounding: preferences.includeSurroundingContext,
                blockedSites: preferences.contextBlockedSites
                )
                let asrContext = ASRContext(
                    languageIdentifier: preferences.transcriptionLanguage.speechLocaleIdentifier,
                    allowMixedChineseEnglish: true,
                    hotwords: VocabularyPacks.contextualHints(personal: preferences.dictionary,
                        enabled: preferences.enabledVocabularyPackIDs, limit: 50),
                    limitedContext: String((appContext.appName ?? "").prefix(120))
                )
                cloudASRTask = Task { [weak self] in
                    var finalized = ""
                    var latest = ""
                    for try await partial in asr.transcribe(audio: audioStream, context: asrContext) {
                        if partial.isFinal {
                            finalized.append(partial.text)
                            latest = finalized
                        } else {
                            latest = finalized + partial.text
                        }
                        if let self {
                            self.partialTranscript = latest
                            self.statusMessage = self.preferences.tr("即時轉錄中…", "Live transcribing…")
                            self.notify()
                        }
                    }
                    return finalized.isEmpty ? latest : finalized
                }
            } catch {
                statusMessage = preferences.tr(
                    "百鍊 ASR 尚未就緒；停止後會嘗試本機 adapter",
                    "Bailian ASR is not ready; the local adapter will be tried after you stop"
                )
                notify()
            }
        } else if groqASRActive || localASRConfigured {
            pcmEngineIsGroq = groqASRActive
            if pcmEngineIsGroq { MacCloudASR.warmUp() }
            let token = operationToken
            pcmTask = Task.detached(priority: .userInitiated) { [weak self] in
                var pcm = Data()
                var pauses = MacCloudASR.PauseDetector()
                do {
                    for try await chunk in audioStream {
                        pcm.append(chunk)
                        if pauses.feed(chunk) {
                            let snapshot = pcm
                            Task { @MainActor [weak self] in self?.speculate(pcm: snapshot, token: token) }
                        }
                    }
                } catch { }
                return pcm
            }
        }
    }

    private var localASRConfigured: Bool {
        preferences.backend == .local && !preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 本機優先模式＋開了雲端辨識＋有 Groq key＋語言是中／英。
    private var groqASRActive: Bool {
        preferences.backend == .local && preferences.cloudASREnabled
            && MacCloudASR.supports(language: preferences.transcriptionLanguage.rawValue)
            && !MacCloudASR.key().isEmpty
    }

    /// 停頓點：把目前為止的錄音先辨識；這次會走雲端背景整理的話，拿到文字就用跟停止後**完全相同的輸入**先整理。
    private func speculate(pcm: Data, token: UUID) {
        guard token == operationToken, isRecording, !askActive else { return }
        speculation?.asr.cancel(); speculation?.cleanup?.task.cancel()
        let language = preferences.transcriptionLanguage.rawValue
        let hotwords = VocabularyPacks.contextualHints(personal: preferences.dictionary,
                                                       enabled: preferences.enabledVocabularyPackIDs, limit: 80)
        let script = preferences.outputScript
        let asr: Task<String?, Never>
        if pcmEngineIsGroq {
            let key = MacCloudASR.key()
            asr = Task {
                if case .ok(let text) = await MacCloudASR.transcribe(pcm16: pcm, language: language, hotwords: hotwords,
                                                                     outputScript: script, key: key) { return text }
                return nil
            }
        } else {
            // 本機 Qwen：停頓前的錄音寫成暫存 WAV 先辨識（不上傳）。
            let client = localASRClient()
            asr = Task.detached(priority: .userInitiated) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("utuvo-type-pause-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: url) }
                guard (try? WhisperAudio.wav(MacCloudASR.samples(fromPCM16: pcm)).write(to: url)) != nil,
                      let text = try? await client.transcribe(audioURL: url),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }
        }
        speculation = Speculation(token: token, pcmBytes: pcm.count, asr: asr)
        deliveryLog.info("pause: speculating on \(pcm.count / 32, privacy: .public) ms of audio")
        Task { [weak self] in
            guard let text = await asr.value, let self, token == self.operationToken,
                  self.speculation?.asr == asr, !self.askActive,
                  self.preferences.cleanupEnabled, self.preferences.postProcessingEnabled,
                  Self.backgroundEligible(mode: self.activeMode, translation: self.activeTranslationTarget,
                                          autoSubmit: self.preferences.autoSubmit, enabled: true,
                                          language: self.preferences.transcriptionLanguage.rawValue) else { return }
            let context = self.deliveryContext()
            let dictionary = self.preferences.dictionary
            let original = self.deliveryOriginal(self.normalizedForDelivery(text, dictionary: dictionary))
            let config = self.cleanupConfig(original: original, context: context, dictionary: dictionary)
            let run = self.cleanupRunner
            self.speculation?.cleanup = (text, config, Task { await run(text, config) })
        }
    }

    private func localASRClient() -> LocalASRProcessClient {
        LocalASRProcessClient(
            command: preferences.localASRCommand,
            argumentsTemplate: preferences.localASRArguments,
            outputScript: preferences.outputScript.rawValue,
            asrLanguage: preferences.transcriptionLanguage.asrLanguageName,
            hotwords: VocabularyPacks.contextualHints(personal: preferences.dictionary,
                                                      enabled: preferences.enabledVocabularyPackIDs, limit: 80))
    }

    /// 停止後的整理：停頓時已經用同一份（逐字稿＋設定）先跑了就沿用，否則現在跑。
    private func cleanupWork(raw: String, config: CleanupConfig) -> @Sendable () async -> String? {
        if let pending = speculation?.cleanup, pending.raw == raw, pending.config == config {
            speculation = nil
            deliveryLog.info("pause: cleanup reused from pause")
            let task = pending.task
            return { await task.value }
        }
        let run = cleanupRunner
        return { await run(raw, config) }
    }

    private func stopRecording() {
        guard isRecording, let capture else { return }
        isRecording = false
        isProcessing = true
        statusMessage = preferences.tr("正在完成轉錄…", "Finishing transcription…")
        notify()

        let cloudTask = cloudASRTask
        let pcmTask = pcmTask
        self.pcmTask = nil
        let groqTask = pcmEngineIsGroq ? pcmTask : nil
        let token = operationToken
        self.capture = nil
        stopPressedAt = Date()
        // 有正式辨識（Groq／本機 Qwen）時，Apple 語音預覽只是最後的退路，不必再等它 350 ms 收尾。
        let speechGrace = groqTask == nil && cloudTask == nil
            && preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task { [weak self] in
            let result = await capture.stop(speechGrace: speechGrace)
            self?.playAudioFeedbackIfEnabled()
            await self?.finishCapture(result, cloudTask: cloudTask, pcmTask: pcmTask, groqTask: groqTask,
                                      capture: capture, token: token)
        }
    }

    private func playAudioFeedbackIfEnabled() {
        guard preferences.audioFeedback else { return }
        feedbackTonePlayer.play(
            outputDeviceUID: preferences.outputDeviceUID,
            frequency: isRecording ? 880 : 660,
            volume: preferences.audioFeedbackVolume
        )
    }

    private func finishCapture(
        _ result: AudioCaptureResult?,
        cloudTask: Task<String, Error>?,
        pcmTask: Task<Data, Never>? = nil,
        groqTask: Task<Data, Never>? = nil,
        capture: AudioCaptureSession,
        token: UUID
    ) async {
        guard token == operationToken else { return }
        defer {
            if token == operationToken {
                cloudASRTask = nil
                isProcessing = false
                scheduleRuntimeUnload()
                notify()
            }
        }
        guard let result else {
            fail(preferences.tr("沒有取得錄音結果；未貼上文字", "No recording result was received; no text was pasted"))
            return
        }
        let inputChanged = inputChangedDuringRecording
        inputChangedDuringRecording = false
        let micName = result.inputDeviceName
        if result.framesWritten == 0 {
            capture.deleteTemporaryAudio(at: result.audioURL)
            fail(inputChanged
                 ? preferences.tr("錄音中麥克風被切換（原本：\(micName)），這次沒有錄到聲音；請再講一次",
                                  "The microphone changed during recording (was: \(micName)); nothing was captured. Please try again")
                 : preferences.tr("沒有錄到任何聲音（麥克風：\(micName)）；請確認輸入裝置後再試",
                                  "Nothing was captured (mic: \(micName)); check the input device and try again"))
            return
        }

        let captureMs = stopPressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let asrStarted = Date()
        var asrEngine = "speech"
        var transcript = ""
        var asrError: Error?
        if let pcmTask {
            let pcm = await pcmTask.value
            if let pending = speculation, pending.token == token, MacCloudASR.isQuiet(pcm, from: pending.pcmBytes),
               let text = await pending.asr.value {
                transcript = text; asrEngine = groqTask == nil ? "local-pause" : "groq-pause"
            }
        }
        if let groqTask, transcript.isEmpty {
            let pcm = await groqTask.value
            let outcome = await MacCloudASR.transcribe(
                pcm16: pcm,
                language: preferences.transcriptionLanguage.rawValue,
                hotwords: VocabularyPacks.contextualHints(personal: preferences.dictionary,
                                                          enabled: preferences.enabledVocabularyPackIDs, limit: 80),
                outputScript: preferences.outputScript,
                key: MacCloudASR.key())
            if case .ok(let text) = outcome { transcript = text; asrEngine = "groq" }
            else { asrEngine = "groq-failed" }
        }
        if let cloudTask {
            do {
                transcript = try await cloudTask.value
            } catch {
                asrError = error
            }
        }

        // The local process is the preferred local Qwen3-ASR integration. It
        // is only invoked when the user has explicitly configured a command;
        // there is no download or model discovery side effect.
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                transcript = try await localASRClient().transcribe(audioURL: result.audioURL)
                asrEngine = asrEngine == "groq-failed" ? "groq-failed>local" : "local"
            } catch {
                asrError = asrError ?? error
            }
        }

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = result.speechTranscript
        }
        let asrMs = Int(Date().timeIntervalSince(asrStarted) * 1000)
        deliveryLog.info("timing: capture \(captureMs, privacy: .public) ms, asr[\(asrEngine, privacy: .public)] \(asrMs, privacy: .public) ms")
        let historyID = UUID()
        let historyAudioPath = preferences.storeRecording(from: result.audioURL, id: historyID)
        capture.deleteTemporaryAudio(at: result.audioURL)

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if result.soundsSilent {
                fail(preferences.tr("好像沒收到聲音（峰值 \(Int(result.peakDBFS)) dB）——目前使用的麥克風是「\(micName)」，可到設定換輸入裝置",
                                    "No sound was picked up (peak \(Int(result.peakDBFS)) dB) — the microphone was \"\(micName)\"; change the input in Settings"))
                return
            }
            fail(asrError?.localizedDescription ?? preferences.tr(
                "沒有收到轉錄文字；請設定本機 Qwen3-ASR command 或選擇百鍊 ASR",
                "No transcript was received; configure a local Qwen3-ASR command or choose Bailian ASR"
            ))
            return
        }
        guard token == operationToken else { return }
        if askActive {
            askActive = false
            await handleAsk(transcript: transcript, duration: result.duration, historyID: historyID,
                            audioPath: historyAudioPath, token: token)
            return
        }
        await formatAndPaste(
            transcript: transcript,
            audioDuration: result.duration,
            asrError: asrError,
            token: token,
            historyID: historyID,
            audioPath: historyAudioPath,
            translation: consumeTranslationTarget()
        )
    }

    // MARK: - 選字白話解釋／翻譯（2026-10-19，帶進 UTUVO Explain）

    /// 選好文字按快捷鍵：不錄音，直接把選取文字送整理服務，答案出現在回答卡（翻譯可插回原處取代選取）。
    func explainSelectionPressed(_ action: ExplainSelection) {
        guard !isRecording, !isProcessing else { return }
        guard AccessibilitySupport.isTrusted() else {
            fail(preferences.tr("要先在「系統設定 → 隱私權與安全性 → 輔助使用」允許 UTUVO Type，才讀得到選取的文字",
                                "Allow UTUVO Type in System Settings → Privacy & Security → Accessibility to read the selection"))
            return
        }
        let selected = AccessibilitySupport.readCurrentContext(blockedSites: preferences.contextBlockedSites)
            .selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !selected.isEmpty else {
            fail(preferences.tr("先選取一段文字，再按\(action.cardTitle(zh: true))快捷鍵", "Select some text first, then press the \(action.cardTitle(zh: false)) shortcut"))
            return
        }
        let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) ?? .groq
        let key = SmartCleanup.key(for: provider)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(preferences.tr("白話解釋／翻譯要用你的整理服務 key：到設定 → 智慧整理填一把 key",
                                "Explain / Translate uses your cleanup key: add one in Settings → Smart Cleanup"))
            return
        }
        let truncated = selected.count > ExplainSelection.maxCharacters
        let text = truncated ? String(selected.prefix(ExplainSelection.maxCharacters)) : selected
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let element = AccessibilitySupport.focusedElement()
        let range = element.flatMap(AccessibilitySupport.selectedRange(of:))
        AnswerCardController.shared.close()
        statusMessage = preferences.tr("\(action.cardTitle(zh: true))中…", "\(action.cardTitle(zh: false))…")
        notify()
        let zh = preferences.isChineseUI
        Task { [weak self] in
            guard let self else { return }
            let answer: String
            do {
                answer = try await SmartCleanup.ask(
                    system: action.systemPrompt(for: text), user: ExplainSelection.userMessage(text), provider: provider, key: key,
                    customEndpoint: provider == .dashscope ? self.preferences.bailianFormatterEndpoint : self.preferences.customCleanupEndpoint,
                    customModel: self.preferences.customCleanupModel,
                    transport: StrictCleanupSession.shared).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.fail(self.preferences.tr("\(action.cardTitle(zh: true))沒有完成：\(error.localizedDescription)",
                                              "\(action.cardTitle(zh: false)) didn't finish: \(error.localizedDescription)"))
                return
            }
            guard !answer.isEmpty else { self.fail(self.preferences.tr("服務沒有回傳內容", "The service returned nothing")); return }
            self.lastOutput = answer
            self.statusMessage = self.preferences.tr("已顯示\(action.cardTitle(zh: true))", "\(action.cardTitle(zh: false)) shown")
            self.notify()
            let preview = String(text.prefix(80)) + (text.count > 80 || truncated ? "…" : "")
            // 翻譯可以「插入」＝回原 App、選取還在就取代它；解釋只提供複製。
            let insert: (() -> Void)? = action == .translate ? { [weak self] in
                guard let self, let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string); return
                }
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let current = AccessibilitySupport.focusedElement()
                    guard let element, let current, CFEqual(element, current),
                          let range, let now = AccessibilitySupport.selectedRange(of: current),
                          now.location == range.location, now.length == range.length else {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string)
                        self.statusMessage = self.preferences.tr("選取已改變；譯文已複製", "Selection changed; translation copied")
                        self.notify()
                        return
                    }
                    try? ClipboardPaster.paste(answer, method: self.preferences.pasteMethod, handling: self.preferences.clipboardHandling)
                }
            } : nil
            AnswerCardController.shared.show(.init(
                question: "\(action.cardTitle(zh: zh))：\(preview)", answer: answer, zh: zh, onInsert: insert))
        }
    }

    // MARK: - Ask anything（2026-10-13，對齊 Typeless）

    /// Ask anything 快捷鍵：按一下開始講、再按一下送出。有選取文字＝對它下指令（改寫或問問題）。
    func askShortcutPressed() {
        if isRecording {
            if askActive { stopRecording() }
            return
        }
        guard !isProcessing else { return }
        AnswerCardController.shared.close()
        askActive = true
        askPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let selected = AccessibilitySupport.isTrusted()
            ? AccessibilitySupport.readCurrentContext(blockedSites: preferences.contextBlockedSites)
                .selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        askElement = AccessibilitySupport.focusedElement()
        askRange = askElement.flatMap(AccessibilitySupport.selectedRange(of:))
        askSelection = (selected?.isEmpty ?? true) ? nil : selected
        activeTranslationTarget = .off
        // 按住說話模式下 Ask 仍是「按一下開始、再按一下送出」：標成 active，beginRecording 才不會立刻停。
        if preferences.pushToTalkEnabled { pushToTalkActive = true }
        // 錄音本身照一般聽寫；不改使用者的預設模式。改選取模式要求先有選取，這裡不需要。
        startRecording(mode: preferences.mode == .editSelection ? .fast : preferences.mode, persistMode: false)
        if !isRecording && !isProcessing && lastErrorMessage != nil { askActive = false }
    }

    private func handleAsk(transcript: String, duration: TimeInterval, historyID: UUID,
                           audioPath: String?, token: UUID) async {
        let selection = askSelection
        askSelection = nil
        let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) ?? .groq
        let key = SmartCleanup.key(for: provider)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(preferences.tr("Ask anything 要用你的整理服務 key：到設定 → 雲端（選配）填一把 Groq／Gemini／百鍊 key",
                                "Ask anything uses your cleanup key: add a Groq / Gemini / Bailian key in Settings → Cloud"))
            return
        }
        statusMessage = preferences.tr("思考中…", "Thinking…")
        notify()
        let hasSelection = selection != nil
        let system = AskAnything.systemPrompt(hasSelection: hasSelection,
                                              languageHint: preferences.transcriptionLanguage.rawValue)
        let user = AskAnything.userMessage(instruction: transcript, selection: selection)
        let reply: AskAnything.Reply
        do {
            let raw = try await SmartCleanup.ask(
                system: system, user: user, provider: provider, key: key,
                customEndpoint: provider == .dashscope ? preferences.bailianFormatterEndpoint : preferences.customCleanupEndpoint,
                customModel: preferences.customCleanupModel,
                transport: StrictCleanupSession.shared)
            guard let parsed = AskAnything.parse(raw, hasSelection: hasSelection) else {
                throw SmartCleanup.Failure.malformed
            }
            reply = parsed
        } catch {
            guard token == operationToken else { return }
            fail(preferences.tr("Ask anything 沒有完成：\(error.localizedDescription)",
                                "Ask anything didn't finish: \(error.localizedDescription)"))
            return
        }
        guard token == operationToken else { return }
        lastOutput = reply.text
        preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: transcript, output: reply.text,
            duration: duration, mode: activeMode, appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, audioPath: audioPath,
            note: preferences.tr("Ask anything", "Ask anything")), countsTowardStats: false)
        if reply.action == .replace, let selection, stillAtAskField(expectSelection: selection) {
            do {
                try ClipboardPaster.paste(reply.text, method: preferences.pasteMethod, handling: preferences.clipboardHandling)
                statusMessage = preferences.tr("已改寫選取文字", "Rewrote the selection")
            } catch {
                statusMessage = preferences.tr("改寫好了但貼不回去；可從選單複製", "Rewritten, but couldn't paste; copy it from the menu")
            }
            notify()
            return
        }
        let pid = askPID
        AnswerCardController.shared.show(.init(
            question: transcript, answer: reply.text, zh: preferences.isChineseUI,
            onInsert: { [weak self] in
                guard let self else { return }
                // 只插回原本問問題的那個 App；它關掉了或切不回去，就改成複製（luna-review r1：答案曾可能貼進別的 App）。
                guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reply.text, forType: .string)
                    self.statusMessage = self.preferences.tr("原本的 App 已關閉；答案已複製", "The original app is gone; the answer was copied")
                    self.notify()
                    return
                }
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard self.askPID == pid, self.stillAtAskField() else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reply.text, forType: .string)
                        self.statusMessage = self.preferences.tr("切不回原本的輸入欄位；答案已複製", "Couldn't return to the original field; the answer was copied")
                        self.notify()
                        return
                    }
                    try? ClipboardPaster.paste(reply.text, method: self.preferences.pasteMethod,
                                               handling: self.preferences.clipboardHandling)
                }
            }))
        statusMessage = preferences.tr("已回答（回答卡）", "Answered (see the card)")
        notify()
    }

    /// 讀走並歸零本次翻譯目標：只有「這一次錄音」消費得到，
    /// reprocess／retry 永遠拿 .off（F1：殘留目標會把重跑結果偷翻譯）。
    private func consumeTranslationTarget() -> TranslationTarget {
        let target = activeTranslationTarget
        activeTranslationTarget = .off
        return target
    }

    private func deliveryContext() -> LimitedAppContext {
        preferences.isolation != nil ? LimitedAppContext() : (selectedContext ?? AccessibilitySupport.readCurrentContext(
            includeSurrounding: preferences.includeSurroundingContext,
            blockedSites: preferences.contextBlockedSites
        ))
    }

    private func normalizedForDelivery(_ transcript: String, dictionary: [String: String]) -> String {
        // 詞庫包：個人字典的寫法 + 已開啟 catalog 包的拉丁字母 seeds（給 LatinNameFixer 比對用）。
        let latinTerms = VocabularyPacks.latinTermsForFixer(
            personalValues: Array(dictionary.values),
            enabled: preferences.enabledVocabularyPackIDs
        )
        return Normalizer(options: NormalizerOptions(dictionary: dictionary, latinTerms: latinTerms)).normalize(transcript).cleaned
    }

    /// 先貼的本機版也照句尾語氣。
    private func deliveryOriginal(_ normalized: String) -> String {
        moodApplies ? SentenceMood.finish(normalized) : normalized
    }

    private func cleanupConfig(original: String, context: LimitedAppContext, dictionary: [String: String]) -> CleanupConfig {
        let promptContext = preferences.includeSurroundingContext
            ? CleanupPromptContext(
                appName: context.appName ?? "",
                styleHint: preferences.preset(for: context.foregroundBundleIdentifier)?.promptHint ?? "",
                surroundingText: context.surroundingText ?? "",
                windowTitle: context.windowTitle ?? "",
                pageLocation: context.pageLocation ?? "",
                fieldPlaceholder: context.fieldPlaceholder ?? ""
            )
            : .init()
        return CleanupConfig(enabled: true, provider: preferences.cleanupProvider,
            customEndpoint: preferences.customCleanupEndpoint, customModel: preferences.customCleanupModel,
            language: preferences.transcriptionLanguage.rawValue, personal: dictionary,
            enabledPacks: preferences.enabledVocabularyPackIDs, bailianEndpoint: preferences.bailianFormatterEndpoint,
            context: promptContext, validationSource: original, autoList: preferences.cleanupAutoList)
    }

    private func formatAndPaste(
        transcript: String,
        audioDuration: TimeInterval,
        asrError: Error?,
        token: UUID,
        historyID: UUID,
        audioPath: String? = nil,
        translation: TranslationTarget = .off
    ) async {
        guard token == operationToken else { return }
        lastRawTranscript = transcript
        let context = deliveryContext()
        let dictionary = preferences.dictionary
        let normalizedText = normalizedForDelivery(transcript, dictionary: dictionary)
        let combinedForFeatures = [transcript, context.selectedText ?? ""].joined(separator: "\n")
        let longTextThresholdReached = transcript.count >= max(1, preferences.deepMinCharacters)
            || audioDuration >= TimeInterval(max(1, preferences.deepMinAudioSeconds))
        let decision = Router.decide(RoutingInput(
            text: combinedForFeatures,
            mode: activeMode,
            hasListCues: InputFeatures.hasListCues(transcript),
            hasSelfCorrection: InputFeatures.hasSelfCorrection(transcript),
            hasMarkdown: InputFeatures.hasMarkdown(transcript),
            hasSelectedBlock: activeMode == .editSelection,
            highQuality: activeMode == .deep,
            deepOptIn: activeMode == .deep,
            localDeepAvailable: activeMode == .deep && !preferences.localDeepModel.isEmpty,
            longTextOptIn: longTextThresholdReached
        ))
        let editorInput = RoutingInput(
            text: transcript,
            mode: activeMode,
            hasListCues: InputFeatures.hasListCues(transcript),
            hasSelfCorrection: InputFeatures.hasSelfCorrection(transcript),
            hasMarkdown: InputFeatures.hasMarkdown(transcript)
        )
        let cloudBackgroundCleanup = preferences.cleanupEnabled && preferences.postProcessingEnabled
        let localBackgroundCleanup = !cloudBackgroundCleanup
            && preferences.postProcessingEnabled
            && preferences.backend == .local
            && activeMode == .smart
            && !decision.skipLLM
            && !Router.isShortSentence(editorInput)
            && (!preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !preferences.localEditorModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if Self.backgroundEligible(mode: activeMode, translation: translation, autoSubmit: preferences.autoSubmit,
                                   enabled: cloudBackgroundCleanup || localBackgroundCleanup,
                                   language: preferences.transcriptionLanguage.rawValue) {
            await deliverImmediate(normalizedText, raw: transcript, duration: audioDuration,
                                   historyID: historyID, audioPath: audioPath, token: token, context: context,
                                   dictionary: dictionary, useLocalFormatter: localBackgroundCleanup)
            return
        }
        // Edit Selection commands are often short (“改正式一點”), but the
        // selected text is the actual editing payload, so local editor use is
        // still allowed for that mode.
        let localEditorAllowed = activeMode == .editSelection
            || !Router.isShortSentence(editorInput)

        var output = normalizedText
        var formatterSucceeded = false
        var notice = asrError.map {
            preferences.tr("ASR fallback：\($0.localizedDescription)", "ASR fallback: \($0.localizedDescription)")
        }

        if preferences.postProcessingEnabled && !decision.skipLLM {
            do {
                let prompt = try await makePrompt(transcript: transcript, context: context, dictionary: dictionary)
                if let legacyFormatterRunner {
                    let candidate = try await legacyFormatterRunner(prompt)
                    guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                        throw ProviderError.malformedResponse
                    }
                    output = safe
                    formatterSucceeded = true
                } else {
                    switch preferences.backend {
                    case .bailian:
                        let client = try BailianFormatterClient(endpointString: preferences.bailianFormatterEndpoint)
                        let models = uniqueModels(from: decision)
                        for model in models {
                            do {
                                let candidate = try await client.format(prompt: prompt, model: model.rawValue)
                                guard let safe = FormatterOutputGuard.sanitize(
                                    candidate,
                                    source: editorInput.text,
                                    mode: activeMode
                                ) else {
                                    throw ProviderError.malformedResponse
                                }
                                output = safe
                                formatterSucceeded = true
                                break
                            } catch {
                                notice = preferences.tr(
                                    "百鍊 formatter fallback：\(error.localizedDescription)",
                                    "Bailian formatter fallback: \(error.localizedDescription)"
                                )
                            }
                        }
                    case .local:
                        if activeMode == .deep,
                           decision.useLocalDeep,
                           !preferences.localDeepModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let client = try OllamaFormatterClient(model: preferences.localDeepModel)
                            let candidate = try await client.format(prompt: prompt, model: preferences.localDeepModel)
                            guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                                throw ProviderError.malformedResponse
                            }
                            output = safe
                            formatterSucceeded = true
                        } else if !preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  localEditorAllowed {
                            let client = LocalFormatterProcessClient(
                                command: preferences.localEditorCommand,
                                outputScript: preferences.outputScript.rawValue
                            )
                            let candidate = try await client.format(
                                prompt: prompt,
                                model: preferences.localEditorModel.isEmpty ? "local-qwen3-editor" : preferences.localEditorModel
                            )
                            guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                                throw ProviderError.malformedResponse
                            }
                            output = safe
                            formatterSucceeded = true
                        } else if !preferences.localEditorModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  localEditorAllowed {
                            let client = try OllamaFormatterClient(model: preferences.localEditorModel)
                            let candidate = try await client.format(prompt: prompt, model: preferences.localEditorModel)
                            guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                                throw ProviderError.malformedResponse
                            }
                            output = safe
                            formatterSucceeded = true
                        } else {
                            notice = preferences.tr(
                                "本機沒有設定小型 editor，已使用 deterministic 整理",
                                "No local small editor is configured; deterministic formatting was used"
                            )
                        }
                    }
                }
            } catch {
                notice = preferences.tr(
                    "整理服務失敗，已使用 deterministic fallback：\(error.localizedDescription)",
                    "Formatting service failed; deterministic fallback was used: \(error.localizedDescription)"
                )
            }
        }

        // F5：翻譯前先驗 token——取消後的殘留 task 不准再改 statusMessage 或燒 editor。
        guard token == operationToken else { return }
        if translation != .off {
            statusMessage = preferences.tr("翻譯中…", "Translating…")
            if let translated = await translateOutput(output, target: translation) {
                output = translated
            } else {
                notice = preferences.tr(
                    "翻譯未完成（需要本機小型 editor），已輸出原文",
                    "Translation did not complete (a local small editor is required); original text was pasted"
                )
            }
        }

        guard token == operationToken else { return }

        // 句尾語氣（2026-10-02 Micky：不要每句都句號）：問句／感嘆改標點、最後一句不加句號。
        // 翻譯（日文也用「。」）與改選取（取代使用者原文）不動。
        if translation == .off && activeMode != .editSelection && moodApplies {
            output = SentenceMood.finish(output)
        }

        lastOutput = output

        preferences.appendHistory(HistoryRecord(
            id: historyID,
            rawTranscript: transcript,
            output: output,
            duration: audioDuration,
            mode: activeMode,
            appName: context.appName,
            bundleIdentifier: context.foregroundBundleIdentifier,
            audioPath: audioPath
        ))

        if activeMode == .editSelection && !formatterSucceeded {
            // Never replace a user's selected text with the spoken command
            // when an editor provider fails. The selected text remains intact.
            statusMessage = preferences.tr(
                "Edit Selection 未完成；原選取文字未變更。\(notice ?? "請稍後重試")",
                "Edit Selection did not complete; the original selection is unchanged. \(notice ?? "Please try again later")"
            )
            lastErrorMessage = notice
            return
        }

        let pasteOutput = preferences.appendTrailingSpace ? output + " " : output
        guard preferences.isolation == nil,
              capturedPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == capturedPID else {
            statusMessage = preferences.tr("目的地已變更；可複製最後結果", "Destination changed; copy the last result")
            return
        }
        do {
            try ClipboardPaster.paste(
                pasteOutput,
                method: preferences.pasteMethod,
                handling: preferences.clipboardHandling
            )
            ClipboardPaster.submit(preferences.autoSubmit)
            if activeMode != .editSelection, preferences.autoSubmit == .off { watchEdits(output) }
            statusMessage = notice.map {
                preferences.tr("已貼上 deterministic 結果（\($0)）", "Pasted deterministic result (\($0))")
            } ?? preferences.tr("已整理並貼上", "Formatted and pasted")
            lastErrorMessage = notice
        } catch {
            statusMessage = preferences.tr(
                "已整理但貼上失敗；可從選單複製最後結果",
                "Formatted, but pasting failed; you can copy the last result from the menu"
            )
            lastErrorMessage = error.localizedDescription
        }

    }

    static func backgroundEligible(mode: FormatterMode, translation: TranslationTarget, autoSubmit: AutoSubmit, enabled: Bool, language: String) -> Bool {
        enabled && mode == .smart && translation == .off && autoSubmit == .off && SmartCleanup.supportsLanguage(language)
    }

    func prepareDictation(mode: FormatterMode, expectedPID: Int32? = nil) {
        invalidateBackground()
        activeMode = mode
        capturedPID = expectedPID ?? (preferences.isolation == nil ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil)
        destination = captureDestination(capturedPID)
        onDeliveryEvent?(destination == nil ? "refused" : "capture")
    }

    private func invalidateBackground() {
        operationToken = UUID()
        speculation?.asr.cancel(); speculation?.cleanup?.task.cancel(); speculation = nil
        pendingCleanupTask?.cancel(); pendingCleanupTask = nil
        destination?.invalidate(); destination = nil
    }

    /// Test/QA entry: same production formatting and delivery, never records audio.
    func completeSyntheticDictation(_ text: String) async {
        guard preferences.isolation != nil else { return }
        await formatAndPaste(transcript: text, audioDuration: 0, asrError: nil,
                             token: operationToken, historyID: UUID())
    }

    func waitForBackgroundCleanup() async { await pendingCleanupTask?.value }

    /// 句尾語氣規則是中文／英文的（日文也用「。」、也有「誰」這類字）：其他轉錄語言、以及「自動偵測」
    /// （可能偵測成任何語言）照原樣。
    private var moodApplies: Bool {
        [.traditionalChinese, .english].contains(preferences.transcriptionLanguage)
    }

    private func deliverImmediate(_ original: String, raw: String, duration: TimeInterval,
                                  historyID: UUID, audioPath: String?, token: UUID, context: LimitedAppContext,
                                  dictionary: [String: String], useLocalFormatter: Bool) async {
        let original = deliveryOriginal(original)
        let trailing = preferences.appendTrailingSpace ? " " : ""
        let config = cleanupConfig(original: original, context: context, dictionary: dictionary)
        guard token == operationToken else { return }
        let lateCheck = destination
        guard let target = destination, await target.insert(original + trailing) else {
            // 2026-09-24 實機（苑涵 0.1.5）：Chrome／LINE／Electron 等欄位不是原生 AX 文字框，或錄音中按了鍵／點了滑鼠，
            // 這裡原本直接 return——不貼字、不寫歷史。改成跟 Fast 一樣走剪貼簿貼上（仍檢查前景 App 沒換）；
            // 貼之前先在同一個時限內整理，能整理就貼整理版，否則貼本機整理版。
            await pasteWithoutCapture(original: original, raw: raw, duration: duration, historyID: historyID,
                                      audioPath: audioPath, token: token, context: context, dictionary: dictionary,
                                      config: config, useLocalFormatter: useLocalFormatter,
                                      alreadyDelivered: { lateCheck?.textPresent(original + trailing) ?? false })
            return
        }
        guard token == operationToken else { return }
        lastOutput = original
        preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: raw, output: original,
            duration: duration, mode: activeMode, appName: context.appName,
            bundleIdentifier: context.foregroundBundleIdentifier, audioPath: audioPath))
        isProcessing = false
        statusMessage = preferences.tr("已貼上", "Inserted")
        logDeliveryTiming("ax-insert")
        watchEdits(original)
        onDeliveryEvent?("inserted")
        notify()
        guard target.supportsCorrection else { onDeliveryEvent?("refused"); target.invalidate(); return }
        let run = useLocalFormatter ? nil : cleanupWork(raw: raw, config: config)
        let localRun = localBackgroundRunner
        pendingCleanupTask = Task { [weak self] in
            let cleaned: String?
            if useLocalFormatter {
                cleaned = await SmartCleanup.withinDeadline { [weak self] in
                    if let localRun { return await localRun(raw, context, dictionary) }
                    guard let self else { return nil }
                    return await self.localBackgroundCleanup(raw, context: context, dictionary: dictionary)
                }
            } else {
                cleaned = await run?()
            }
            guard let self else { target.invalidate(); return }
            // 整理模型讀的是原始逐字稿（「三點」），先貼出的版本已轉成「3點」：數字格式先對齊，否則把關會把整段擋掉。
            guard !Task.isCancelled, token == self.operationToken, !self.isRecording,
                  let checked = cleaned.map(Normalizer.normalizeNumbers),
                  SmartCleanup.accepts(original: original, cleaned: checked,
                                       relaxed: !useLocalFormatter && config.provider == .claude),
                  case let cleaned = self.moodApplies ? SentenceMood.finish(checked) : checked,
                  target.replaceInsertedText(with: cleaned + trailing) else {
                target.invalidate()
                if token == self.operationToken { self.onDeliveryEvent?("refused") }
                return
            }
            self.lastOutput = cleaned
            self.watchEdits(cleaned)   // 背景整理換字後，追蹤的是換過的版本
            self.preferences.replaceHistoryOutput(id: historyID, with: cleaned)
            self.statusMessage = self.preferences.tr("背景整理已套用", "Background cleanup applied")
            self.onDeliveryEvent?("applied")
            self.notify()
        }
    }

    private func logDeliveryTiming(_ path: String) {
        guard let stopPressedAt else { return }
        let total = Int(Date().timeIntervalSince(stopPressedAt) * 1000)
        deliveryLog.info("timing: delivered[\(path, privacy: .public)] \(total, privacy: .public) ms after stop")
    }

    /// Smart 模式的目的地不能安全插入／事後替換時的退路：整理（有時限）→ 寫歷史 → 剪貼簿貼一次。
    private func pasteWithoutCapture(original: String, raw: String, duration: TimeInterval, historyID: UUID,
                                     audioPath: String?, token: UUID, context: LimitedAppContext,
                                     dictionary: [String: String], config: CleanupConfig, useLocalFormatter: Bool,
                                     alreadyDelivered: () -> Bool = { false }) async {
        destination?.invalidate(); destination = nil
        statusMessage = preferences.tr("整理中…", "Cleaning up…")
        let started = Date()
        let rawCleaned: String?
        if useLocalFormatter {
            let localRun = localBackgroundRunner
            rawCleaned = await SmartCleanup.withinDeadline { [weak self] in
                if let localRun { return await localRun(raw, context, dictionary) }
                guard let self else { return nil }
                return await self.localBackgroundCleanup(raw, context: context, dictionary: dictionary)
            }
        } else {
            // This destination cannot safely replace already inserted text, so the user waits for
            // this one paste. Fixed budget even for long transcripts (SmartCleanup.clipboardPasteTimeout).
            let work = cleanupWork(raw: raw, config: config)
            rawCleaned = await SmartCleanup.withinDeadline(seconds: SmartCleanup.clipboardPasteTimeout) { await work() }
        }
        guard token == operationToken else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var output = original
        var note: String? = preferences.tr("此欄位不支援背景替換，已用剪貼簿貼上", "Field doesn't support background replacement; pasted via clipboard")
        // 2026-10-19 Typeless 對打：這裡再跑一次嚴格把關，會把 Claude 已經用寬鬆把關收下的修正丟掉 → 同一個 provider 規則。
        if let cleaned = rawCleaned.map(Normalizer.normalizeNumbers),
           SmartCleanup.accepts(original: original, cleaned: cleaned, relaxed: !useLocalFormatter && config.provider == .claude) {
            output = moodApplies ? SentenceMood.finish(cleaned) : cleaned
            deliveryLog.info("smart fallback paste: cleanup applied in \(elapsed, privacy: .public) ms")
        } else {
            note = preferences.tr("智慧整理沒有在時限內完成（或被把關擋下），已貼上本機整理結果",
                                  "Smart cleanup didn't finish in time (or was rejected); pasted the local result")
            deliveryLog.error("smart fallback paste: cleanup unavailable after \(elapsed, privacy: .public) ms; pasted deterministic text")
        }
        lastOutput = output
        preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: raw, output: output,
            duration: duration, mode: activeMode, appName: context.appName,
            bundleIdentifier: context.foregroundBundleIdentifier, audioPath: audioPath, note: note))
        isProcessing = false
        onDeliveryEvent?("fallback")
        let pasteOutput = preferences.appendTrailingSpace ? output + " " : output
        // AX 寫入回報失敗、但字其實晚到了（整理等待的那幾秒內才出現）：不能再貼第二份。
        if alreadyDelivered() {
            // 欄位裡是先送出的原句，不是整理版：歷史與「最後結果」要記實際送達的那份。
            lastOutput = original
            preferences.replaceHistoryOutput(id: historyID, with: original)
            watchEdits(original)
            statusMessage = preferences.tr("已貼上", "Inserted")
            deliveryLog.info("smart fallback paste: AX text landed late; skipped clipboard paste")
            onDeliveryEvent?("delivered-late")
            return
        }
        guard preferences.isolation == nil,
              capturedPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == capturedPID else {
            statusMessage = preferences.tr("目的地已變更；可複製最後結果", "Destination changed; copy the last result")
            deliveryLog.error("smart fallback paste: destination app changed; result kept for copy")
            return
        }
        do {
            try ClipboardPaster.paste(pasteOutput, method: preferences.pasteMethod, handling: preferences.clipboardHandling)
            logDeliveryTiming("clipboard, cleanup \(elapsed) ms")
            watchEdits(output)
            statusMessage = output == original
                ? preferences.tr("已貼上（智慧整理未完成）", "Pasted (Smart cleanup didn't finish)")
                : preferences.tr("已整理並貼上", "Formatted and pasted")
            notify()
        } catch {
            statusMessage = preferences.tr("貼上失敗；可從選單複製最後結果", "Paste failed; you can copy the last result from the menu")
            lastErrorMessage = error.localizedDescription
            deliveryLog.error("smart fallback paste failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The caller bounds this background work without waiting for an uncooperative formatter to return.
    private func localBackgroundCleanup(_ text: String, context: LimitedAppContext,
                                        dictionary: [String: String]) async -> String? {
        let command = preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredModel = preferences.localEditorModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? "local-qwen3-editor" : configuredModel
        let script = preferences.outputScript.rawValue
        do {
            let prompt = try await makePrompt(transcript: text, context: context, dictionary: dictionary)
            try Task.checkCancellation()
            let candidate: String
            if !command.isEmpty {
                candidate = try await LocalFormatterProcessClient(command: command, outputScript: script)
                    .format(prompt: prompt, model: model)
            } else {
                candidate = try await OllamaFormatterClient(model: model).format(prompt: prompt, model: model)
            }
            try Task.checkCancellation()
            return FormatterOutputGuard.sanitize(candidate, source: text, mode: .smart)
        } catch {
            return nil
        }
    }

    private func uniqueModels(from decision: RoutingDecision) -> [BailianModel] {
        var result: [BailianModel] = []
        for model in [decision.primaryModel].compactMap({ $0 }) + decision.fallbackChain {
            if !result.contains(model) { result.append(model) }
        }
        return result
    }

    private func makePrompt(
        transcript: String,
        context: LimitedAppContext,
        dictionary: [String: String]
    ) async throws -> String {
        let dictionaryText = dictionary
            .sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: "\n")
        // 詞庫包：個人字典優先，再用 bigram／latin 相關度從已開啟 catalog 包篩入，上限 200。
        // pack terms 讀檔 + bigram score 在背景 actor 上跑，避免 408k 詞把 MainActor 卡住。
        let enabledPacks = preferences.enabledVocabularyPackIDs
        let cleanupTerms = await Task.detached(priority: .utility) {
            VocabularyPacks.termsForCleanup(text: transcript,
                                            personal: dictionary,
                                            enabled: enabledPacks)
        }.value
        let date = ISO8601DateFormatter().string(from: Date())
        let preferredPath = preferences.formatterPromptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = try PromptStore.loadTemplate(preferredPath: preferredPath.isEmpty ? nil : preferredPath)
        var prompt = try PromptLoader.fillPlaceholders(template: template, values: [
            "transcript": transcript,
            "app": context.appName ?? "未知 App",
            "dictionary": dictionaryText,
            "selected": context.selectedText ?? "",
            "date": date
        ])
        if !cleanupTerms.isEmpty {
            prompt += "\n\n使用者開啟的詞庫（接近全用 / 個人字典寫法已寫進上面 dictionary）：\n"
            prompt += cleanupTerms.joined(separator: "、")
        }
        if let preset = preferences.preset(for: context.foregroundBundleIdentifier),
           !preset.promptHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n目前 App preset（僅作語氣提示，不可新增事實）：\n"
            prompt += String(preset.promptHint.prefix(800))
        }
        if preferences.includeSurroundingContext,
           let surrounding = context.surroundingText,
           !surrounding.isEmpty {
            prompt += "\n\n目前輸入欄位的有限周邊文字（僅供格式判斷）：\n"
            prompt += String(surrounding.prefix(2_000))
        }
        if preferences.includeSurroundingContext {
            let where_ = [context.pageLocation.map { "網頁：\($0)" }, context.windowTitle.map { "視窗：\($0)" },
                          context.fieldPlaceholder.map { "欄位提示：\($0)" }].compactMap { $0 }
            if !where_.isEmpty {
                prompt += "\n\n目前輸入位置（僅供判斷語氣與格式，不可照抄進結果）：\n" + where_.joined(separator: "\n")
            }
        }
        return prompt
    }

    private func fail(_ message: String) {
        isRecording = false
        isProcessing = false
        askActive = false        // luna-review r1：失敗後不能讓下一次一般聽寫被當成 Ask
        askSelection = nil
        statusMessage = message
        lastErrorMessage = message
        notify()
    }

    /// Tests replace the delay and the stop action; production uses the preference and real server stop.
    var unloadDelayOverride: Duration?
    var stopRuntime: (() -> Void)?

    func scheduleRuntimeUnload() {
        guard preferences.isolation == nil || unloadDelayOverride != nil else { return }
        unloadTask?.cancel()
        guard preferences.unloadPolicy != .never else { return }
        let delay: Duration
        switch preferences.unloadPolicy {
        case .never: return
        case .afterFiveMinutes: delay = .seconds(300)
        case .afterFifteenMinutes: delay = .seconds(900)
        case .afterOneHour: delay = .seconds(3_600)
        }
        let wait = unloadDelayOverride ?? delay
        unloadTask = Task { @MainActor [weak self] in
            // 2026-09-24 實機（苑涵 0.1.5）：原本 `try? await Task.sleep`——被取消的舊計時器立刻醒來、
            // 當下 isProcessing 已經是 false，就把 server 殺掉 → 每次辨識完都重載模型。取消＝結束，不准往下跑。
            do { try await Task.sleep(for: wait) } catch { return }
            guard !Task.isCancelled, let self, !self.isRecording, !self.isProcessing else { return }
            if let stopRuntime = self.stopRuntime { stopRuntime() } else { self.preferences.stopLocalRuntimeServers() }
            self.statusMessage = self.preferences.tr(
                "本機模型已依設定卸載；下次使用會重新暖機",
                "Local models were unloaded per settings; the next use will warm up again"
            )
            self.notify()
        }
    }

    private func notify() {
        onStateChange?()
        objectWillChange.send()
    }
}
