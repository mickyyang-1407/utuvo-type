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
    private var permissionOnboardingInFlight = false
    private let legacyFirstUsePermissionKey = "utuvo.type.firstUsePermissionPrompted"
    private let permissionOnboardingAttemptedKey = "utuvo.type.permissionOnboardingAttempted"
    private let permissionOnboardingCompletedKey = "utuvo.type.permissionOnboardingCompleted"

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        statusMessage = preferences.tr("準備就緒", "Ready")
        refreshPermissionState()
    }

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
        unloadTask?.cancel()
        unloadTask = nil
        activeMode = mode
        preferences.mode = mode
        Task { [weak self] in
            await self?.beginRecording()
        }
    }

    func cancelProcessing() {
        activeTranslationTarget = .off
        guard isProcessing else { return }
        operationToken = UUID()
        cloudASRTask?.cancel()
        capture?.cancel()
        capture = nil
        pushToTalkActive = false
        isRecording = false
        isProcessing = false
        statusMessage = preferences.tr("已取消；沒有貼上新文字", "Cancelled; no new text was pasted")
        notify()
    }

    /// Escape cancel behaviour: stop an active capture first;
    /// if formatting is already running, cancel it without discarding the
    /// latest raw transcript.
    func cancelRecording() {
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
        operationToken = UUID()

        guard await PermissionGate.requestMicrophone() else {
            fail(preferences.tr(
                "麥克風權限未開啟；請到系統設定 → 隱私權與安全性 → 麥克風允許 \(AppBrand.displayName)",
                "Microphone permission is off; allow \(AppBrand.displayName) in System Settings → Privacy & Security → Microphone"
            ))
            return
        }

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
        statusMessage = preferences.tr("聆聽中…點選停止以整理並貼上", "Listening… click stop to format and paste")
        notify()

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
                    hotwords: Array(preferences.dictionary.keys.prefix(50)),
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
            cloudASRTask = nil
            isProcessing = false
            scheduleRuntimeUnload()
            notify()
        }
        guard let result else {
            fail(preferences.tr("沒有取得錄音結果；未貼上文字", "No recording result was received; no text was pasted"))
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
                    asrLanguage: preferences.transcriptionLanguage.asrLanguageName
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
        let context = selectedContext ?? AccessibilitySupport.readCurrentContext(
            includeSurrounding: preferences.includeSurroundingContext
        )
        let dictionary = preferences.dictionary
        let normalized = Normalizer(options: NormalizerOptions(dictionary: dictionary)).normalize(transcript)
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
                let prompt = try makePrompt(transcript: transcript, context: context, dictionary: dictionary)
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
    ) throws -> String {
        let dictionaryText = dictionary
            .sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: "\n")
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

    private func scheduleRuntimeUnload() {
        unloadTask?.cancel()
        guard preferences.unloadPolicy != .never else { return }
        let seconds: UInt64
        switch preferences.unloadPolicy {
        case .never: return
        case .afterFiveMinutes: seconds = 300
        case .afterFifteenMinutes: seconds = 900
        case .afterOneHour: seconds = 3_600
        }
        unloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Int(seconds)))
            guard let self, !self.isRecording, !self.isProcessing else { return }
            self.preferences.stopLocalRuntimeServers()
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
