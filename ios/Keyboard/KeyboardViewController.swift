import UIKit
@preconcurrency import AVFAudio
@preconcurrency import Speech
import UTUVOTypeCore

/// UTUVO Type 鍵盤：任何 app 都能按麥克風講話 → core 管線清理 → 直接插入游標處。
/// 這是 macOS「全域熱鍵＋貼回」的 iOS 對應物。
///
/// 2026-09-11（D8-4）：鍵盤終於接上主 app 的三樣東西——
/// 1. `TextPipeline`（同一份 core Normalizer）：定稿時把已插入的逐字稿換成清理後版本。
/// 2. `DictionaryStore`：個人字典在鍵盤也生效（需「允許完整存取」才讀得到 App Group）。
/// 3. `HistoryStore`：鍵盤打的字寫回歷史，主 app 看得到。
///
/// 辨識仍是 server-mode（鍵盤 extension 記憶體上限吃不住裝置端模型），
/// 這件事直接寫在狀態列上，不靜默上雲。
final class KeyboardViewController: UIInputViewController {
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRecording = false

    /// 目前由本鍵盤插進文件、還沒定稿的那段文字。
    private var insertedText = ""
    /// 最後一次收到的原始逐字稿（寫歷史用）。
    private var lastRawTranscript = ""

    // MARK: - UI

    private let micButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        let stack = UIStackView(arrangedSubviews: [micButton, spaceButton, returnButton, deleteButton])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.heightAnchor.constraint(equalToConstant: 44)
        ])

        statusLabel.text = ""
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        view.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            view.bottomAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 2)
        ])

        style(micButton, symbol: "mic.fill")
        style(spaceButton, title: "空格")
        style(returnButton, title: "換行")
        style(deleteButton, symbol: "delete.left")

        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        spaceButton.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
        returnButton.addTarget(self, action: #selector(insertNewline), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(backspace), for: .touchUpInside)
    }

    private func style(_ button: UIButton, symbol: String? = nil, title: String? = nil) {
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
        } else {
            button.setTitle(title, for: .normal)
        }
        button.tintColor = .systemOrange
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
    }

    // MARK: - Actions

    /// 使用者自己編輯文字時，本鍵盤就不再擁有那段文字——放棄增量替換，
    /// 避免 deleteBackward 刪到使用者的字。
    @objc private func insertSpace() {
        releaseOwnership()
        textDocumentProxy.insertText(" ")
    }

    @objc private func insertNewline() {
        releaseOwnership()
        textDocumentProxy.insertText("\n")
    }

    @objc private func backspace() {
        releaseOwnership()
        textDocumentProxy.deleteBackward()
    }

    private func releaseOwnership() {
        insertedText = ""
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecognition()
        } else {
            Task { await startRecognition() }
        }
    }

    // MARK: - Speech

    private var hasAccess: Bool {
        hasFullAccess // RequestsOpenAccess；沒開＝無法用 server 辨識，也讀不到字典／歷史
    }

    private func startRecognition() async {
        guard !isRecording else { return }
        guard hasAccess else {
            setStatus("請在設定 → 鍵盤 → UTUVO Type 開啟「允許完整存取」", error: true)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // 同 DictationModel：TCC 從背景執行緒回呼，continuation 不能綁在 MainActor
            // （UIInputViewController 是 @MainActor），否則 Swift 6 執行期直接 SIGTRAP。
            let auth = await Self.requestSpeechAuthorization()
            guard auth == .authorized else {
                setStatus("需要語音辨識權限", error: true)
                return
            }

            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")),
                  recognizer.isAvailable else {
                setStatus("辨識器不可用", error: true)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            // sampleRate 為 0（無可用輸入）時 installTap 會在引擎內部 assert，
            // 那會連宿主 app 一起帶走。先擋。
            guard format.sampleRate > 0, format.channelCount > 0 else {
                setStatus("找不到麥克風輸入，無法錄音", error: true)
                self.request = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            try audioEngine.start()

            insertedText = ""
            lastRawTranscript = ""

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let result {
                        self.handle(result: result)
                    }
                    if let error, (error as NSError).code != 216 {
                        self.setStatus("辨識中斷：\(error.localizedDescription)", error: true)
                        if self.isRecording { self.stopRecognition() }
                    }
                }
            }
            isRecording = true
            micButton.tintColor = .systemRed
            setStatus("錄音中・雲端辨識（音訊會送到 Apple 伺服器）", error: false)
        } catch {
            setStatus("無法啟動：\(error.localizedDescription)", error: true)
        }
    }

    /// 部分結果邊講邊出字；定稿時整段換成 core 清理後的版本並寫歷史。
    private func handle(result: SFSpeechRecognitionResult) {
        let raw = result.bestTranscription.formattedString
        lastRawTranscript = raw

        if result.isFinal {
            let (cleaned, _) = TextPipeline().clean(raw)
            applyEdit(to: cleaned)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                HistoryStore.shared.append(
                    DictationRecord(raw: trimmed, cleaned: cleaned, source: .keyboard)
                )
            }
            insertedText = ""
            setStatus("", error: false)
        } else {
            applyEdit(to: raw)
            setStatus(String(raw.suffix(24)), error: false)
        }
    }

    /// 用最小編輯把文件裡那段文字換成 `target`（IncrementalInsert 是純函式，有測試）。
    private func applyEdit(to target: String) {
        let plan = IncrementalInsert.plan(previous: insertedText, current: target)
        guard !plan.isNoop else { return }
        for _ in 0..<plan.deleteCount { textDocumentProxy.deleteBackward() }
        if !plan.insert.isEmpty { textDocumentProxy.insertText(plan.insert) }
        insertedText = target
    }

    /// 見 DictationModel.requestSpeechAuthorization 的註解：必須 nonisolated。
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
    }

    private func stopRecognition() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        isRecording = false
        micButton.tintColor = .systemOrange
        setStatus("整理中…", error: false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setStatus(_ text: some StringProtocol, error: Bool) {
        statusLabel.text = String(text)
        statusLabel.textColor = error ? .systemRed : .secondaryLabel
    }
}
