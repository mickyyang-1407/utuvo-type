import Foundation
@preconcurrency import AVFAudio
@preconcurrency import Speech
import UTUVOTypeCore

/// app 內聽寫模型：錄音 → Apple Speech 辨識（優先裝置端）→ core Normalizer 清理 → 歷史。
/// v1：「講話 → 出乾淨文字」主幹。
@MainActor
final class DictationModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var finalText = ""
    @Published var appliedSteps: [String] = []
    @Published var errorMessage: String?
    /// 這次錄音是「聽寫」還是「說出要怎麼改」（Typeless 的 Speak to edit，主 app 版）。
    /// 編輯模式：講的話是指示，不是內容；定稿後拿 OnDeviceAssistant 改寫 `original`，結果取代輸出。
    enum Intent: Equatable {
        case dictate
        case edit(original: String)
        var isEdit: Bool { if case .edit = self { return true } else { return false } }
    }
    @Published private(set) var intent: Intent = .dictate
    /// 改寫引擎正在跑（錄音已停、結果未回）。
    @Published private(set) var isRewriting = false
    /// 上一版輸出（改寫前），給「還原」用；只保留一步。
    @Published private(set) var previousText: String?
    /// 這次辨識實際走哪條路（IOS2）。錄音開始才確定，停止後保留給使用者看。
    @Published private(set) var route: RecognitionRoute?
    /// 「只用裝置端辨識」：開啟後，不支援裝置端的語言／機型會直接拒絕錄音，
    /// 而不是靜默上雲。單一正本是 UserDefaults——設定頁用 @AppStorage 綁同一個 key，
    /// 這裡每次錄音前讀當下值，不快取。
    var onDeviceOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onDeviceOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onDeviceOnlyKey) }
    }

    static let onDeviceOnlyKey = "utuvo.type.ios.onDeviceOnly"
    @Published var language: DictationLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "utuvo.type.ios.language") }
    }

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private let pipeline = TextPipeline()
    /// 這次錄音的音量紀錄（停頓斷句用）。
    private let levels = LevelLog()
    /// 主畫面光球讀：目前麥克風音量（dBFS），沒在錄回 nil。
    func liveLevel() -> Float? { levels.latest() }

    override init() {
        let saved = UserDefaults.standard.string(forKey: "utuvo.type.ios.language")
        self.language = saved.flatMap(DictationLanguage.init(rawValue:)) ?? .traditionalChinese
        super.init()
        #if DEBUG
        // 截圖用：模擬器沒麥克風，`simctl launch … -utuvo.type.ios.previewOutput "文字"` 直接種一段輸出。
        if let seed = UserDefaults.standard.string(forKey: "utuvo.type.ios.previewOutput"), !seed.isEmpty {
            finalText = seed
        }
        #endif
    }

    func toggle() {
        // 主 app 自己要錄音：先收掉替鍵盤開的語音工作階段（兩邊搶同一個 AVAudioSession）。
        if !isRecording, KeyboardVoiceHost.shared.isActive { KeyboardVoiceHost.shared.endSession() }
        if isRecording { stop() } else { intent = .dictate; Task { await start() } }
    }

    /// 「說出要怎麼改」：對目前輸出下口頭指示。沒有輸出或正在錄就不做。
    func startEdit() {
        guard !isRecording, !isRewriting, !finalText.isEmpty else { return }
        if KeyboardVoiceHost.shared.isActive { KeyboardVoiceHost.shared.endSession() }
        intent = .edit(original: finalText)
        Task { await start() }
    }

    /// 還原到改寫前那一版。
    func undoEdit() {
        guard let previous = previousText else { return }
        finalText = previous
        previousText = nil
    }

    func start() async {
        // 任何一條早退（權限、辨識器、無輸入）都要把編輯意圖收掉，畫面才不會停在「說出要怎麼改」。
        defer { if !isRecording { intent = .dictate } }
        errorMessage = nil
        liveTranscript = ""
        if !intent.isEdit {
            finalText = ""
            previousText = nil
        }
        appliedSteps = []
        route = nil

        // 麥克風授權（iOS 17 起用 AVAudioApplication；AVAudioSession 版已 deprecated）
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else {
            errorMessage = "需要麥克風權限才能聽寫；請到系統設定開啟。"
            return
        }
        // 語音辨識授權（必須走 nonisolated 包裝，見下方 requestSpeechAuthorization 註解）
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorMessage = "需要語音辨識權限；請到系統設定開啟。"
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
              recognizer.isAvailable else {
            errorMessage = "這個語言的辨識器目前不可用。"
            return
        }
        self.recognizer = recognizer

        do {
            // 跟鍵盤語音同一份設定：不打斷使用者正在聽的音樂、藍牙耳機繼續出聲。
            try VoiceAudioSession.activate()

            // IOS2：裝置端優先，但「退回雲端」必須看得見，而且使用者可以直接禁止。
            let decision = RecognitionRoutePolicy.decide(
                supportsOnDevice: recognizer.supportsOnDeviceRecognition,
                onDeviceOnly: onDeviceOnly
            )
            guard case .allow(let chosenRoute) = decision else {
                errorMessage = "你開了「只用裝置端辨識」，但這台裝置在\(language.localizedName(zh: true))"
                    + "沒有裝置端辨識可用。關掉這個開關才會改用雲端辨識（音訊會送到 Apple 伺服器）。"
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            route = chosenRoute

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true // 標點由辨識器直接給（iOS 16+），不靠後處理猜
            request.contextualStrings = KeyboardVoiceHost.contextualStrings()
            request.requiresOnDeviceRecognition = chosenRoute == .onDevice
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            // 沒有可用輸入裝置時 sampleRate 會是 0，直接 installTap 會在 AVAudioEngine
            // 內部 assert（整個 app 掛掉）。先擋下來，給人看得懂的訊息。
            guard format.sampleRate > 0, format.channelCount > 0 else {
                errorMessage = "找不到可用的麥克風輸入（模擬器通常沒有）。請改用實機，或接上輸入裝置再試。"
                self.request = nil
                route = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            // 音訊執行緒回呼：閉包不能在 @MainActor 方法裡直接寫，否則繼承 MainActor 隔離，
            // Swift 6 執行期在音訊執行緒上 SIGTRAP（2026-09-18 真機：主 app 一點麥克風就閃退）。
            levels.reset()
            Self.installTap(on: input, format: format, request: request, levels: levels)
            audioEngine.prepare()
            try audioEngine.start()

            task = Self.makeTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, errorCode, errorText, tokens in
                self?.ingest(text: text, isFinal: isFinal, errorCode: errorCode, errorText: errorText, tokens: tokens)
            }
            AIPunctuator.shared.prewarm()
            isRecording = true
        } catch {
            errorMessage = "無法啟動錄音：\(error.localizedDescription)"
            cleanupAfterStop()
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        isRecording = false
    }

    /// 手動把目前逐字稿定稿（例如切頁時）。
    func finalizeNow() {
        if !liveTranscript.isEmpty && (finalText.isEmpty || intent.isEdit) {
            commit(liveTranscript)
        }
        if isRecording { stop() }
    }

    private func ingest(text: String?, isFinal: Bool, errorCode: Int?, errorText: String?, tokens: [TimedToken] = []) {
        if let text {
            liveTranscript = text
            if isFinal {
                let silences = SilenceDetector.intervals(levels.snapshot)
                let paused = tokens.isEmpty ? text : PausePunctuator.punctuate(tokens, silences: silences)
                let base = PunctuationGuard.preservesText(original: text, candidate: paused) ? paused : text
                if AIPunctuator.refineEnabled, AIPunctuator.shared.isAvailable, base.count >= AIPunctuator.minimumLength {
                    Task { @MainActor [weak self] in
                        let better = await AIPunctuator.shared.refine(base)
                        self?.commit(better ?? base)
                    }
                } else {
                    commit(base)
                }
            }
        }
        if let errorCode {
            // 使用者按停止造成的「finished」不是錯誤
            if errorCode != 216 {
                errorMessage = "辨識中斷：\(errorText ?? "錯誤 \(errorCode)")"
            }
            if isRecording { stop() }
        }
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest, levels: LevelLog) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            levels.record(buffer)
        }
    }

    nonisolated private static func makeTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping @MainActor @Sendable (String?, Bool, Int?, String?, [TimedToken]) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let code = (error as NSError?)?.code
            let message = error?.localizedDescription
            let tokens: [TimedToken] = isFinal ? (result?.bestTranscription.segments.map {
                TimedToken(text: $0.substring, start: $0.timestamp, duration: $0.duration)
            } ?? []) : []
            Task { @MainActor in onResult(text, isFinal, code, message, tokens) }
        }
    }

    /// 逐字稿定稿：聽寫＝跑 core 管線清理＋寫歷史；編輯＝把講的話當指示丟給改寫引擎。
    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let finishedIntent = intent
        intent = .dictate
        guard !trimmed.isEmpty else { return }
        switch finishedIntent {
        case .dictate:
            let (output, steps) = pipeline.clean(trimmed)
            finalText = output
            appliedSteps = steps
            HistoryStore.shared.append(DictationRecord(raw: trimmed, cleaned: output, source: .app))
        case .edit(let original):
            let instruction = pipeline.clean(trimmed).output
            rewrite(original, instruction: instruction)
        }
    }

    /// 改寫：引擎順序在 OnDeviceAssistant（Apple Intelligence → 雲端 key → 明講不可用）。
    private func rewrite(_ original: String, instruction: String) {
        isRewriting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRewriting = false }
            do {
                let result = try await OnDeviceAssistant.editSelection(original, instruction: instruction)
                guard !result.isEmpty else {
                    self.errorMessage = "改寫引擎回了空白，輸出沒有動。"
                    return
                }
                self.previousText = original
                self.finalText = result
                self.liveTranscript = ""
                HistoryStore.shared.append(DictationRecord.edit(instruction: instruction, result: result, source: .app))
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// `SFSpeechRecognizer.requestAuthorization` 的 completion 由 TCC 從背景執行緒呼叫。
    /// 如果包它的 `withCheckedContinuation` 寫在 @MainActor 方法裡，closure 會繼承
    /// MainActor isolation，Swift 6 執行期的 `swift_task_checkIsolatedSwift` 會直接
    /// SIGTRAP 把整個 app 打掛（2026-09-11 在模擬器抓到，crash report 指到這裡）。
    /// 標成 nonisolated 就沒有這個隱含 isolation。
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
    }

    private func cleanupAfterStop() {
        isRecording = false
        intent = .dictate
        request = nil
        task = nil
    }
}
