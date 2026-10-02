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
    @Published private(set) var isProcessing = false
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
            guard !isProcessing else { return }
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

    func startRecording(mode: FormatterMode) {
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
        preferences.mode = mode
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
        guard isProcessing else { return }
        operationToken = UUID()
        cloudASRTask?.cancel()
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
        if isRecording {
            operationToken = UUID()
            cloudASRTask?.cancel()
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
                includeSurrounding: preferences.includeSurroundingContext
            )
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
                    includeSurrounding: preferences.includeSurroundingContext
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
        }
    }

    private func stopRecording() {
        guard isRecording, let capture else { return }
        isRecording = false
        isProcessing = true
        statusMessage = preferences.tr("正在完成轉錄…", "Finishing transcription…")
        notify()

        let cloudTask = cloudASRTask
        let token = operationToken
        self.capture = nil
        Task { [weak self] in
            let result = await capture.stop()
            self?.playAudioFeedbackIfEnabled()
            await self?.finishCapture(result, cloudTask: cloudTask, capture: capture, token: token)
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

        var transcript = ""
        var asrError: Error?
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
                transcript = try await LocalASRProcessClient(
                    command: preferences.localASRCommand,
                    argumentsTemplate: preferences.localASRArguments,
                    outputScript: preferences.outputScript.rawValue,
                    asrLanguage: preferences.transcriptionLanguage.asrLanguageName,
                    hotwords: VocabularyPacks.contextualHints(personal: preferences.dictionary,
                                                              enabled: preferences.enabledVocabularyPackIDs, limit: 80)
                ).transcribe(audioURL: result.audioURL)
            } catch {
                asrError = asrError ?? error
            }
        }

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = result.speechTranscript
        }
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

    /// 讀走並歸零本次翻譯目標：只有「這一次錄音」消費得到，
    /// reprocess／retry 永遠拿 .off（F1：殘留目標會把重跑結果偷翻譯）。
    private func consumeTranslationTarget() -> TranslationTarget {
        let target = activeTranslationTarget
        activeTranslationTarget = .off
        return target
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
        let context = preferences.isolation != nil ? LimitedAppContext() : (selectedContext ?? AccessibilitySupport.readCurrentContext(
            includeSurrounding: preferences.includeSurroundingContext
        ))
        let dictionary = preferences.dictionary
        // 詞庫包：個人字典的寫法 + 已開啟 catalog 包的拉丁字母 seeds（給 LatinNameFixer 比對用）。
        let latinTerms = VocabularyPacks.latinTermsForFixer(
            personalValues: Array(dictionary.values),
            enabled: preferences.enabledVocabularyPackIDs
        )
        let normalized = Normalizer(options: NormalizerOptions(dictionary: dictionary, latinTerms: latinTerms)).normalize(transcript)
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
            await deliverImmediate(normalized.cleaned, raw: transcript, duration: audioDuration,
                                   historyID: historyID, audioPath: audioPath, token: token, context: context,
                                   dictionary: dictionary, useLocalFormatter: localBackgroundCleanup)
            return
        }
        // Edit Selection commands are often short (“改正式一點”), but the
        // selected text is the actual editing payload, so local editor use is
        // still allowed for that mode.
        let localEditorAllowed = activeMode == .editSelection
            || !Router.isShortSentence(editorInput)

        var output = normalized.cleaned
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
        let original = moodApplies ? SentenceMood.finish(original) : original   // 先貼的本機版也照句尾語氣
        let trailing = preferences.appendTrailingSpace ? " " : ""
        let promptContext = preferences.includeSurroundingContext
            ? CleanupPromptContext(
                appName: context.appName ?? "",
                styleHint: preferences.preset(for: context.foregroundBundleIdentifier)?.promptHint ?? "",
                surroundingText: context.surroundingText ?? ""
            )
            : .init()
        let config = CleanupConfig(enabled: true, provider: preferences.cleanupProvider,
            customEndpoint: preferences.customCleanupEndpoint, customModel: preferences.customCleanupModel,
            language: preferences.transcriptionLanguage.rawValue, personal: dictionary,
            enabledPacks: preferences.enabledVocabularyPackIDs, bailianEndpoint: preferences.bailianFormatterEndpoint,
            context: promptContext, validationSource: original)
        guard token == operationToken else { return }
        guard let target = destination, await target.insert(original + trailing) else {
            // 2026-09-24 實機（苑涵 0.1.5）：Chrome／LINE／Electron 等欄位不是原生 AX 文字框，或錄音中按了鍵／點了滑鼠，
            // 這裡原本直接 return——不貼字、不寫歷史。改成跟 Fast 一樣走剪貼簿貼上（仍檢查前景 App 沒換）；
            // 貼之前先在同一個時限內整理，能整理就貼整理版，否則貼本機整理版。
            await pasteWithoutCapture(original: original, raw: raw, duration: duration, historyID: historyID,
                                      audioPath: audioPath, token: token, context: context, dictionary: dictionary,
                                      config: config, useLocalFormatter: useLocalFormatter)
            return
        }
        guard token == operationToken else { return }
        lastOutput = original
        preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: raw, output: original,
            duration: duration, mode: activeMode, appName: context.appName,
            bundleIdentifier: context.foregroundBundleIdentifier, audioPath: audioPath))
        isProcessing = false
        statusMessage = preferences.tr("已貼上", "Inserted")
        onDeliveryEvent?("inserted")
        notify()
        guard target.supportsCorrection else { onDeliveryEvent?("refused"); target.invalidate(); return }
        let run = cleanupRunner
        let localRun = localBackgroundRunner
        pendingCleanupTask = Task { [weak self] in
            let cleaned: String?
            if useLocalFormatter {
                cleaned = await SmartCleanup.localCorrectionWithinDeadline { [weak self] in
                    if let localRun { return await localRun(raw, context, dictionary) }
                    guard let self else { return nil }
                    return await self.localBackgroundCleanup(raw, context: context, dictionary: dictionary)
                }
            } else {
                cleaned = await run(raw, config)
            }
            guard let self else { target.invalidate(); return }
            // 整理模型讀的是原始逐字稿（「三點」），先貼出的版本已轉成「3點」：數字格式先對齊，否則把關會把整段擋掉。
            guard !Task.isCancelled, token == self.operationToken, !self.isRecording,
                  let checked = cleaned.map(Normalizer.normalizeNumbers), SmartCleanup.accepts(original: original, cleaned: checked),
                  case let cleaned = self.moodApplies ? SentenceMood.finish(checked) : checked,
                  target.replaceInsertedText(with: cleaned + trailing) else {
                target.invalidate()
                if token == self.operationToken { self.onDeliveryEvent?("refused") }
                return
            }
            self.lastOutput = cleaned
            self.preferences.replaceHistoryOutput(id: historyID, with: cleaned)
            self.statusMessage = self.preferences.tr("背景整理已套用", "Background cleanup applied")
            self.onDeliveryEvent?("applied")
            self.notify()
        }
    }

    /// Smart 模式的目的地不能安全插入／事後替換時的退路：整理（有時限）→ 寫歷史 → 剪貼簿貼一次。
    private func pasteWithoutCapture(original: String, raw: String, duration: TimeInterval, historyID: UUID,
                                     audioPath: String?, token: UUID, context: LimitedAppContext,
                                     dictionary: [String: String], config: CleanupConfig, useLocalFormatter: Bool) async {
        destination?.invalidate(); destination = nil
        statusMessage = preferences.tr("整理中…", "Cleaning up…")
        let started = Date()
        let rawCleaned: String?
        if useLocalFormatter {
            let localRun = localBackgroundRunner
            rawCleaned = await SmartCleanup.localCorrectionWithinDeadline { [weak self] in
                if let localRun { return await localRun(raw, context, dictionary) }
                guard let self else { return nil }
                return await self.localBackgroundCleanup(raw, context: context, dictionary: dictionary)
            }
        } else {
            rawCleaned = await cleanupRunner(raw, config)
        }
        guard token == operationToken else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var output = original
        var note: String? = preferences.tr("此欄位不支援背景替換，已用剪貼簿貼上", "Field doesn't support background replacement; pasted via clipboard")
        if let cleaned = rawCleaned.map(Normalizer.normalizeNumbers), SmartCleanup.accepts(original: original, cleaned: cleaned) {
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
        guard preferences.isolation == nil,
              capturedPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == capturedPID else {
            statusMessage = preferences.tr("目的地已變更；可複製最後結果", "Destination changed; copy the last result")
            deliveryLog.error("smart fallback paste: destination app changed; result kept for copy")
            return
        }
        do {
            try ClipboardPaster.paste(pasteOutput, method: preferences.pasteMethod, handling: preferences.clipboardHandling)
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
        return prompt
    }

    private func fail(_ message: String) {
        isRecording = false
        isProcessing = false
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
