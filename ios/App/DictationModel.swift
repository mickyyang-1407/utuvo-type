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

    override init() {
        let saved = UserDefaults.standard.string(forKey: "utuvo.type.ios.language")
        self.language = saved.flatMap(DictationLanguage.init(rawValue:)) ?? .traditionalChinese
        super.init()
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        errorMessage = nil
        liveTranscript = ""
        finalText = ""
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

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
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.ingest(result: result, error: error)
                }
            }
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
        if !liveTranscript.isEmpty && finalText.isEmpty {
            commit(liveTranscript)
        }
        if isRecording { stop() }
    }

    private func ingest(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                liveTranscript = text
                commit(text)
            } else {
                liveTranscript = text
            }
        }
        if let error {
            // 使用者按停止造成的「finished」不是錯誤
            if (error as NSError).code != 216 {
                errorMessage = "辨識中斷：\(error.localizedDescription)"
            }
            if isRecording { stop() }
        }
    }

    /// 逐字稿定稿：跑 core 管線清理＋寫歷史。
    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (output, steps) = pipeline.clean(trimmed)
        finalText = output
        appliedSteps = steps
        HistoryStore.shared.append(DictationRecord(raw: trimmed, cleaned: output, source: .app))
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        request = nil
        task = nil
    }
}
