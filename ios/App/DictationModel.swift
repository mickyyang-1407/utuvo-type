import Foundation
@preconcurrency import AVFAudio
@preconcurrency import Speech
import UTUVOTypeCore

/// 重辨識（雲端／本機 Qwen）的「等結果回來」狀態：每輪錄音只能有一筆 pending，
/// 回來時用 id 比對是同一輪才認，否則視為新一輪已開始、作廢。
/// 把 R2 的 tuple 升級成可單獨測試的小盒子（luna-review R3 2026-09-25）。
struct RerecognitionGate {
    struct Pending {
        let text: String
        let base: String
        let isEdit: Bool
    }
    private var pending: Pending?
    private var id: UUID?

    /// 開始新一輪：蓋掉舊的，回新 id。
    mutating func begin(text: String, base: String, isEdit: Bool) -> UUID {
        let newID = UUID()
        pending = Pending(text: text, base: base, isEdit: isEdit)
        id = newID
        return newID
    }

    /// 雲端／Qwen 回來時用 id 核對：是同一輪才回 pending 並清掉，否則 nil。
    mutating func finish(id: UUID) -> Pending? {
        guard self.id == id, let p = pending else { return nil }
        pending = nil
        self.id = nil
        return p
    }

    /// 使用者已開新一輪／切頁：清掉並回 pending。
    /// 編輯意圖（`isEdit`）時回 nil —— 開新一輪後舊的口頭指令不該改寫現在的輸出（luna-review R3）。
    mutating func flush() -> Pending? {
        guard let p = pending else { return nil }
        pending = nil
        id = nil
        return p.isEdit ? nil : p
    }
}

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
    static let preferCloudKey = "utuvo.type.ios.preferCloudRecognition"
    var preferCloudRecognition: Bool {
        get { UserDefaults.standard.bool(forKey: Self.preferCloudKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferCloudKey) }
    }
    @Published var language: DictationLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "utuvo.type.ios.language") }
    }

    private let audioEngine = AVAudioEngine()
    /// 目前這次辨識（新引擎或舊引擎，見 SpeechEngine）。
    private var stream: SpeechStream?
    /// 麥克風 → 辨識：引擎起來前的話先存著。
    private let feed = SpeechFeed()
    private var recognizer: SFSpeechRecognizer?
    private let pipeline = TextPipeline()
    private let cleanupTasks = CleanupTaskOwner()
    /// 同音校正中（畫面顯示「整理中…」用）。
    @Published var isCorrecting = false
    /// 這次錄音的音量紀錄（停頓斷句用）。
    private let levels = LevelLog()
    /// 本機 Qwen3-ASR 用的整段錄音（16 kHz）；只有模型已下載時才存。
    private let pcm = PCMAccumulator()
    /// R2-1（CodeX 複查 2026-09-25）→ R3（luna-review 2026-09-25）：等待中的雲端／Qwen 重辨識。
    /// 用獨立可測的 `RerecognitionGate` 取代 R2 的 tuple；多出 `isEdit` 讓編輯意圖在新一輪不會被 flush。
    private var gate = RerecognitionGate()
    /// R3-1（luna-review 2026-09-25）：每一輪錄音一個編號。`SpeechEngine.start` 的回呼帶 `myTake`，
    /// 舊輪的回呼一律不理，避免 Apple 定稿晚到時被寫進新一輪（空窗競態）。
    private var take = 0
    /// R3-1（luna-review 2026-09-25）：`stop()` 後等 Apple 定稿中。`ingest` 收到 isFinal／errorCode 時清。
    private var awaitingAppleFinal = false
    /// R3 orchestrator 補：toggle／startEdit 先等 Apple 定稿（最長 1.5 秒）才 start()，這段時間畫面仍是「沒在錄」；
    /// 使用者再按一次會排第二個 start()，兩次 installTap 同一個 bus＝AVAudioEngine 丟例外閃退。啟動中一律不再排。
    private var isStarting = false
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
        if isRecording { stop() } else {
            // R3-1（luna-review 2026-09-25）：先等上一輪 Apple 定稿（最長 1.5 秒）再 flush、開新輪，
            // 避免舊 Apple 定稿晚到被當成新一輪 partial／final。flush 仍保留 R2-1 防舊雲端結果寫進新一輪。
            guard !isStarting else { return }
            isStarting = true
            Task {
                defer { isStarting = false }
                await waitForAppleFinal()
                // R4（luna-review R3 第 2 點）：等不到上一輪 Apple 定稿就先把逐字稿存起來，否則下面 start()
                // 換輪後晚到的定稿會被丟、start() 若早退（權限、辨識器）上一句就不見了。
                if awaitingAppleFinal { settleUnfinishedTake(keepEdit: false) }
                flushPendingRerecognition()
                intent = .dictate
                await start()
            }
        }
    }

    /// 「說出要怎麼改」：對目前輸出下口頭指示。沒有輸出或正在錄就不做。
    func startEdit() {
        // R3-1（luna-review 2026-09-25）：同 toggle，先等 Apple 定稿再 flush 再開新輪，
        // 整段包進 Task，guard 才能讀到「flush 後」的最新 finalText。
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            await waitForAppleFinal()
            if awaitingAppleFinal { settleUnfinishedTake(keepEdit: false) }   // R4：同 toggle
            flushPendingRerecognition()
            guard !isRecording, !isRewriting, !finalText.isEmpty else { return }
            if KeyboardVoiceHost.shared.isActive { KeyboardVoiceHost.shared.endSession() }
            intent = .edit(original: finalText)
            await start()
        }
    }

    /// 還原到改寫前那一版。
    func undoEdit() {
        guard let previous = previousText else { return }
        finalText = previous
        previousText = nil
    }

    func start() async {
        cleanupTasks.cancelAll()
        isCorrecting = false
        // 任何一條早退（權限、辨識器、無輸入）都要把編輯意圖收掉，畫面才不會停在「說出要怎麼改」。
        defer { if !isRecording { intent = .dictate } }
        // R3-1（luna-review 2026-09-25）：每一輪錄音一個編號，舊輪的回呼一律不理。
        take += 1
        let myTake = take
        errorMessage = nil
        liveTranscript = ""
        SmartCleanup.warmUp()   // 講話的時候先連上智慧整理服務
        if !intent.isEdit {
            finalText = ""
            previousText = nil
        }
        appliedSteps = []
        route = nil

        // 麥克風授權（iOS 17 起用 AVAudioApplication；AVAudioSession 版已 deprecated）
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else {
            errorMessage = String(localized: "需要麥克風權限才能聽寫；請到系統設定開啟。")
            return
        }
        // 語音辨識授權（必須走 nonisolated 包裝，見下方 requestSpeechAuthorization 註解）
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorMessage = String(localized: "需要語音辨識權限；請到系統設定開啟。")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
              recognizer.isAvailable else {
            errorMessage = String(localized: "這個語言的辨識器目前不可用。")
            return
        }
        self.recognizer = recognizer

        do {
            // 跟鍵盤語音同一份設定：不打斷使用者正在聽的音樂、藍牙耳機繼續出聲。
            try VoiceAudioSession.activate()

            // IOS2：裝置端優先，但「退回雲端」必須看得見，而且使用者可以直接禁止。
            let decision = RecognitionRoutePolicy.decide(
                supportsOnDevice: recognizer.supportsOnDeviceRecognition,
                onDeviceOnly: onDeviceOnly,
                preferCloud: preferCloudRecognition
            )
            guard case .allow(let chosenRoute) = decision else {
                errorMessage = String(localized: "你開了「只用裝置端辨識」，但這台裝置在\(language.localizedName(zh: true))沒有裝置端辨識可用。關掉這個開關才會改用雲端辨識（音訊會送到 Apple 伺服器）。")
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            route = chosenRoute

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            // 沒有可用輸入裝置時 sampleRate 會是 0，直接 installTap 會在 AVAudioEngine
            // 內部 assert（整個 app 掛掉）。先擋下來，給人看得懂的訊息。
            guard format.sampleRate > 0, format.channelCount > 0 else {
                errorMessage = String(localized: "找不到可用的麥克風輸入（模擬器通常沒有）。請改用實機，或接上輸入裝置再試。")
                route = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            // 音訊執行緒回呼：閉包不能在 @MainActor 方法裡直接寫，否則繼承 MainActor 隔離，
            // Swift 6 執行期在音訊執行緒上 SIGTRAP（2026-09-18 真機：主 app 一點麥克風就閃退）。
            levels.reset()
            feed.arm()
            let qwenReady = LocalQwenASR.shared.isReady && LocalQwenASR.qwenLanguage(for: language.rawValue) != nil
            let cloudReady = CloudASR.isReady(language: language.rawValue)
            let rerecog = Rerecognition.choose(qwenReady: qwenReady, cloudReady: cloudReady)
            pcm.reset(enabled: rerecog != .none)
            if rerecog == .localQwen { LocalQwenASR.shared.prewarm() }
            Self.installTap(on: input, format: format, feed: feed, levels: levels, pcm: pcm)
            audioEngine.prepare()
            try audioEngine.start()

            // 新引擎（SpeechTranscriber）優先、舊引擎備援；建引擎期間講的話 feed 先存著。
            let started = await SpeechEngine.start(language: language.rawValue, legacy: recognizer, onDevice: chosenRoute == .onDevice,
                                                   contextualStrings: KeyboardVoiceHost.contextualStrings()) { [weak self] text, isFinal, errorCode, errorText, tokens in
                // R3-1（luna-review 2026-09-25）：帶 myTake 進去，舊輪的回呼一律不理。
                self?.ingest(take: myTake, text: text, isFinal: isFinal, errorCode: errorCode, errorText: errorText, tokens: tokens)
            }
            guard let started else {
                errorMessage = String(localized: "這個語言的辨識器目前不可用。")
                stop()
                return
            }
            stream = started
            feed.attach(started)
            if started.engineName == "analyzer" { route = .onDevice }
            AIPunctuator.shared.prewarm()
            SmartCleanup.warmUp()
            isRecording = true
        } catch {
            errorMessage = String(localized: "無法啟動錄音：\(error.localizedDescription)")
            cleanupAfterStop()
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        feed.disarm()
        // R3-1（luna-review 2026-09-25）：有接著 stream 就標記等 Apple 定稿，給 toggle／startEdit 用 waitForAppleFinal 等。
        let hadStream = stream != nil
        stream?.endAudio()
        isRecording = false
        if hadStream { awaitingAppleFinal = true }
    }

    /// 手動把目前逐字稿定稿（例如切頁時）。
    func finalizeNow() {
        // R2-1（CodeX 複查 2026-09-25）：切頁時若還在等重辨識，先用 Apple 結果定稿；
        // flush 後就不必再 commit(liveTranscript) — 否則歷史會出現兩筆。
        if let p = gate.flush() {
            ingestFinal(text: p.text, base: p.base)
            if isRecording { stop() }
            return
        }
        // R4→R5（luna-review R4）：還在錄音就停，但**不要**馬上拿 partial 定稿——Apple 的完整定稿隨後就到，
        // 照正常流程 ingest（這個 model 不隨頁面消失）；立刻定稿會把句尾切掉。等 1.5 秒還沒到才用 partial 收尾，
        // 而且只在還是同一輪時（使用者可能已經開始下一輪，不能把新的一輪作廢）。
        if isRecording { stop() }
        if awaitingAppleFinal {
            let myTake = take
            Task {
                await waitForAppleFinal()
                if awaitingAppleFinal, take == myTake { settleUnfinishedTake(keepEdit: true) }
            }
        } else if !liveTranscript.isEmpty && (finalText.isEmpty || intent.isEdit) {
            commit(liveTranscript)
        }
    }

    /// R4（luna-review R3）：上一輪的 Apple 定稿等不到（逾時或要立刻切頁）時收尾：目前逐字稿還沒定稿就存起來，
    /// 然後 take += 1 讓這一輪之後才到的回呼作廢。`keepEdit` 為 false 時，編輯意圖的口頭指令直接作廢
    /// （使用者已經開新一輪，同 RerecognitionGate.flush 的規則）。
    private func settleUnfinishedTake(keepEdit: Bool) {
        if !liveTranscript.isEmpty && (finalText.isEmpty || intent.isEdit) && (keepEdit || !intent.isEdit) {
            commit(liveTranscript)
        }
        awaitingAppleFinal = false
        take += 1
    }

    private func ingest(take thisTake: Int, text: String?, isFinal: Bool, errorCode: Int?, errorText: String?, tokens: [TimedToken] = []) {
        // R3-1（luna-review 2026-09-25）：舊輪的回呼一律不理，避免 Apple 定稿晚到被寫進新一輪。
        guard thisTake == take else { return }
        if let text {
            liveTranscript = text
            if isFinal {
                awaitingAppleFinal = false
                let silences = SilenceDetector.intervals(levels.snapshot)
                let paused = tokens.isEmpty ? text : PausePunctuator.punctuate(tokens, silences: silences)
                let appleBase = PunctuationGuard.preservesText(original: text, candidate: paused) ? paused : text
                let samples = pcm.snapshot
                // 定稿當下再選一次：開始錄音後 App 可能已切到背景，qwenReady 因此會變 false。
                let qwenReadyNow = LocalQwenASR.shared.isReady && LocalQwenASR.qwenLanguage(for: language.rawValue) != nil
                let cloudReadyNow = CloudASR.isReady(language: language.rawValue)
                let rerecog = Rerecognition.choose(qwenReady: qwenReadyNow, cloudReady: cloudReadyNow)
                if !samples.isEmpty, rerecog != .none {
                    // 與鍵盤同一條路：最後文字用本機 Qwen3-ASR 或雲端重辨識，失敗或逾時用 Apple 的。
                    pcm.reset(enabled: false)
                    let lang = language.rawValue
                    let hotwords = Array(SpeechEngine.unifiedHints(personal: KeyboardVoiceHost.contextualStrings()).prefix(80))
                    // R2-1 → R3（luna-review 2026-09-25）：用可測的 `RerecognitionGate` 取代 R2 的 tuple，
                    // 多帶 isEdit 讓編輯意圖在新一輪 flush 時作廢。
                    let pendingID = gate.begin(text: text, base: appleBase, isEdit: intent.isEdit)
                    Task { @MainActor [weak self] in
                        let refined: String?
                        switch rerecog {
                        case .localQwen:
                            refined = await LocalQwenASR.shared.transcribe(samples, language: lang, hotwords: hotwords)
                        case .cloud:
                            let provider = SmartCleanup.provider
                            refined = await CloudASR.transcribe(samples, language: lang, hotwords: hotwords,
                                                                 provider: provider, key: SmartCleanup.key(for: provider))
                        case .none:
                            refined = nil
                        }
                        guard let self, let p = self.gate.finish(id: pendingID) else { return }
                        self.ingestFinal(text: refined ?? p.text, base: refined ?? p.base)
                    }
                    return
                }
                ingestFinal(text: text, base: appleBase)
            }
        }
        if let errorCode {
            // 使用者按停止造成的「finished」不是錯誤
            // R6（luna-review R5）：按停止後 Apple 沒給 final、直接回 216／1110／301（使用者停止／沒偵測到語音／已取消）時，
            // 已經拿到的逐字稿就是定稿——跟 KeyboardVoiceHost 同一條規則；原本這裡不存，下一輪 start() 一清就不見了。
            // 只在「停止後還沒收到 final」時才做（awaitingAppleFinal），final 之後才到的 216 不會重複存。
            let stoppedWithoutFinal = awaitingAppleFinal
            awaitingAppleFinal = false
            if stoppedWithoutFinal, [216, 1110, 301].contains(errorCode),
               !liveTranscript.isEmpty, finalText.isEmpty || intent.isEdit {
                ingestFinal(text: liveTranscript, base: liveTranscript)
            }
            if errorCode != 216 {
                errorMessage = String(localized: "辨識中斷：\(errorText ?? String(localized: "錯誤 \(errorCode)"))")
            }
            if isRecording { stop() }
        }
    }

    /// 定稿（Apple 或本機 Qwen 的結果）→ 同音校正／智慧整理 → commit。
    private func ingestFinal(text: String, base: String) {
        // 同音錯字校正：先出字，背景校正完有改、而且畫面上還是這段才換（不讓使用者等）。
        let lang = language.rawValue
        let smart = SmartCleanup.isEnabled
        if !AIPunctuator.refineEnabled, !intent.isEdit,
           smart || (HomophoneCorrector.applies(to: lang) && HomophoneCorrector.isAvailable && base.count >= HomophoneCorrector.minimumLength) {
            commit(base)
            let shown = finalText
            isCorrecting = true
            let budget = CleanupBudget(seconds: SmartCleanup.backgroundTimeout)
            cleanupTasks.start(id: UUID(), work: {
                await SmartCleanup.refine(text, fallbackText: base, language: lang, smart: smart,
                                          budget: budget, validationSource: shown)
            }, apply: { [weak self] fixed in
                guard let self else { return }
                self.isCorrecting = self.cleanupTasks.pendingCount > 0
                guard let fixed, fixed != base, self.finalText == shown else { return }
                self.finalText = self.pipeline.clean(fixed).output
            })
            return
        }
        if AIPunctuator.refineEnabled, AIPunctuator.shared.isAvailable, base.count >= AIPunctuator.minimumLength {
            Task { @MainActor [weak self] in
                let better = await AIPunctuator.shared.refine(base)
                self?.commit(better ?? base)
            }
        } else {
            commit(base)
        }
    }

    /// R2-1（CodeX 複查 2026-09-25）→ R3（luna-review 2026-09-25）：等待中的重辨識回來之前，使用者又
    /// 開始新一輪／要編輯／切頁，把現在拿到的 Apple 結果定稿貼上，並讓 pending 失效（Task 回來看到
    /// id 不對就直接 return）。編輯意圖（`isEdit`）直接作廢，不再被 flush 成改寫。
    private func flushPendingRerecognition() {
        guard let p = gate.flush() else { return }
        ingestFinal(text: p.text, base: p.base)
    }

    /// R3-1（luna-review 2026-09-25）：等 `stop()` 之後的 Apple 定稿回來或逾時；給 toggle／startEdit
    /// 在開新一輪之前呼叫，避免舊 Apple 定稿晚到被當成新一輪 partial／final。
    private func waitForAppleFinal(timeout: Double = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while awaitingAppleFinal, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat,
                                               feed: SpeechFeed, levels: LevelLog, pcm: PCMAccumulator) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            feed.feed(buffer)
            levels.record(buffer)
            pcm.append(buffer)
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
                    self.errorMessage = String(localized: "改寫引擎回了空白，輸出沒有動。")
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
        feed.disarm()
        stream = nil
    }
}
