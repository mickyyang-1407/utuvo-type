import UIKit
@preconcurrency import AVFAudio
@preconcurrency import Speech

/// 主 app 端的鍵盤語音工作階段：替鍵盤開麥克風、辨識、把逐字稿寫回 App Group。
/// 協定見 `VoiceBridge`。工作階段期間 app 靠 UIBackgroundModes audio 留在背景（狀態列會有橘點）。
@MainActor
final class KeyboardVoiceHost: ObservableObject {
    static let shared = KeyboardVoiceHost()

    @Published private(set) var isActive = false
    @Published private(set) var phase: VoiceBridge.State.Phase = .ended
    @Published private(set) var lastError: String?
    @Published private(set) var idleEndsAt: Date?
    /// 叫起主 app 的那個 app（能解析到才有）；工作階段畫面用它顯示「回到剛剛的 app」。
    @Published private(set) var returnTarget: String?

    private let engine = AVAudioEngine()
    private let box = RequestBox()
    /// 目前這次辨識（新引擎或舊引擎，見 SpeechEngine）。
    private var stream: SpeechStream?
    /// 這次辨識的語言（同音校正只做中文）。
    private var currentLanguage = ""
    private var state = VoiceBridge.State(phase: .ended, heartbeat: .distantPast)
    private var heartbeat: Timer?
    private var commandObserver: DarwinObserver?
    private var keyboardActivityObserver: DarwinObserver?
    private var lastActivity = Date()
    private var finalizeWatchdog: Task<Void, Never>?
    private let cleanupTasks = CleanupTaskOwner()
    private var interruptionObserver: NSObjectProtocol?
    #if DEBUG && targetEnvironment(simulator)
    private var fakeTask: Task<Void, Never>?
    #endif

    var idleTimeout: TimeInterval = VoiceBridge.userIdleTimeout()

    private init() {}

    // MARK: - 入口

    /// `utuvotype://voice?lang=…&id=…`：鍵盤叫起主 app。
    func handle(url: URL) {
        guard let parsed = VoiceBridge.parseSessionURL(url) else { return }
        Task { await begin(language: parsed.language, autostart: parsed.commandID, returnTo: parsed.returnTo) }
    }

    func begin(language: String, autostart commandID: UUID?, returnTo hostBundleID: String? = nil) async {
        lastError = nil
        if !isActive {
            guard await Self.requestMicrophone() else {
                fail(String(localized: "需要麥克風權限：設定 → UTUVO Type → 麥克風"), commandID: commandID)
                return
            }
            guard await Self.requestSpeechAuthorization() == .authorized else {
                fail(String(localized: "需要語音辨識權限：設定 → UTUVO Type → 語音辨識"), commandID: commandID)
                return
            }
            do {
                try startEngine()
            } catch {
                fail(String(localized: "無法開啟麥克風：\(error.localizedDescription)"), commandID: commandID)
                return
            }
            isActive = true
            lastActivity = Date()
            state = VoiceBridge.State(phase: .ready, heartbeat: Date())
            startHeartbeat()
            commandObserver = DarwinObserver(.command) { [weak self] in self?.commandArrived() }
            keyboardActivityObserver = DarwinObserver(.keyboardActivity) { [weak self] in self?.keyboardActivityArrived() }
            publish()
        }
        // 鍵盤寫好的 start 指令（URL 帶來的 id 要對得上，避免執行到舊指令）
        if let commandID, let cmd = VoiceBridge.readCommand(), cmd.id == commandID,
           cmd.action == .start, VoiceBridge.isFresh(cmd) {
            startRecognition(id: cmd.id, language: cmd.language, translateTo: cmd.translateTo, contextText: cmd.contextText)
            returnTarget = hostBundleID
            if let hostBundleID { returnToPreviousApp(hostBundleID) }
        }
    }

    /// 鍵盤叫起主 app、麥克風開好之後，自動把使用者送回剛剛打字的 app。
    /// iOS 沒有公開 API，也無法從 app 內觸發狀態列「◀ 返回」（iOS 26 由系統層處理，lldb 實測 app 內斷點不觸發）。
    /// 這裡只接受鍵盤傳來、且已知的公開 URL scheme；沒有 scheme 就留在主 app，
    /// 提示條教使用者手動點左上角。這樣送審 binary 不需要任何私有 API。
    /// 工作階段畫面的「回到剛剛的 app」按鈕。
    func returnNow() {
        guard let returnTarget else { return }
        _ = Self.reopen(returnTarget)
    }

    /// 使用者明確選擇本次較長的工作階段；下一次回到設定裡選的長度。
    func extendIdleSession() {
        guard isActive else { return }
        idleTimeout = max(idleTimeout, VoiceBridge.extendedIdleTimeout)
        tick()
    }

    /// 叫回宿主：有已知 URL scheme 就走公開的 `UIApplication.open`；沒有就保留在主 app。
    private static func reopen(_ bundleID: String) -> String {
        if let url = KnownAppSchemes.returnURL(forHostId: bundleID) {
            UIApplication.shared.open(url)
            return "scheme:\(url.absoluteString)"
        }
        return "no-known-scheme"
    }

    private func returnToPreviousApp(_ bundleID: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            let result = Self.reopen(bundleID)
            #if DEBUG
            VoiceBridge.write(["returnTo": bundleID, "result": result], name: "debug-return.json")
            #endif
        }
    }

    /// 使用者在主 app 按「結束」、閒置逾時、或來電中斷。
    /// 工作階段畫面的光球讀：目前麥克風音量（dBFS），沒在錄回 nil。
    func liveLevel() -> Float? { box.levels.latest() }

    func endSession() {
        cleanupTasks.cancelAll()
        state.refining = []
        cleanupContextByCommand.removeAll()
        guard isActive else {
            // 還沒開成功就失敗（例如權限被拒）：清掉錯誤，工作階段畫面才會收起來。
            lastError = nil
            returnTarget = nil
            return
        }
        returnTarget = nil
        finalizeWatchdog?.cancel()
        stream?.cancel()
        stream = nil
        box.end()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        heartbeat?.invalidate()
        heartbeat = nil
        commandObserver = nil
        keyboardActivityObserver = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        isActive = false
        idleTimeout = VoiceBridge.userIdleTimeout()
        state.phase = .ended
        state.heartbeat = .distantPast
        state.idleEndsAt = nil
        idleEndsAt = nil
        publish()
    }

    // MARK: - 指令

    private func commandArrived() {
        guard isActive, let cmd = VoiceBridge.readCommand(), VoiceBridge.isFresh(cmd) else { return }
        lastActivity = Date()
        switch cmd.action {
        case .start: startRecognition(id: cmd.id, language: cmd.language, translateTo: cmd.translateTo, contextText: cmd.contextText)
        case .stop: stopRecognition(id: cmd.id)
        case .cancel: cancelRecognition(id: cmd.id)
        case .endSession: endSession()
        }
    }

    private func keyboardActivityArrived() {
        guard isActive else { return }
        lastActivity = Date()
    }

    /// 這個指令要翻成哪個語言（nil＝不翻）、辨識語言是什麼。
    private var pendingTranslation: (id: UUID, target: String, source: String)?
    private var cleanupContextByCommand: [UUID: String] = [:]

    private func startRecognition(id: UUID, language: String, translateTo: String? = nil, contextText: String? = nil) {
        // URL 與 Darwin notification 可能把同一個 start 送兩次；保留第一次帶來的 field context。
        if state.commandID == id, state.phase == .recording { return }
        currentLanguage = language
        cleanupContextByCommand[id] = SmartCleanup.includeAppContext ? String((contextText ?? "").suffix(500)) : ""
        VoiceBridge.clearCommandContext(for: id)
        if let translateTo {
            pendingTranslation = (id, translateTo, language)
            Task { await FastTranslator.shared.prewarm(sourceRaw: language, targetCode: translateTo) }
        } else {
            pendingTranslation = nil
            SmartCleanup.warmUp()   // 講話的時候先連上智慧整理服務
        }
        if stream != nil { stream?.cancel(); stream = nil; box.end() }
        finalizeWatchdog?.cancel()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            #if DEBUG && targetEnvironment(simulator)
            // 模擬器沒有語音辨識：Debug 用假逐字稿把「鍵盤 ↔ 主 app ↔ 插字」整條橋接跑一遍。
            startFakeRecognition(id: id)
            return
            #else
            fail(String(localized: "這個語言的辨識器目前不可用"), commandID: id)
            return
            #endif
        }
        let onDeviceOnly = UserDefaults.standard.bool(forKey: DictationModel.onDeviceOnlyKey)
        guard case .allow(let route) = RecognitionRoutePolicy.decide(
            supportsOnDevice: recognizer.supportsOnDeviceRecognition,
            onDeviceOnly: onDeviceOnly,
            preferCloud: UserDefaults.standard.bool(forKey: DictationModel.preferCloudKey)) else {
            fail(String(localized: "你開了「只用裝置端辨識」，但這個語言在這台裝置沒有裝置端辨識"), commandID: id)
            return
        }
        // 先開始收音（引擎起來前的話先存著），再非同步建引擎：新引擎（SpeechTranscriber）優先、舊引擎備援。
        // 講完後用哪個引擎重辨識：本機 Qwen3-ASR 優先（不上傳、免費），不行才走雲端；都不行就用 Apple 的結果。
        let qwenReady = LocalQwenASR.shared.isReady && LocalQwenASR.qwenLanguage(for: language) != nil
        let cloudReady = CloudASR.isReady(language: language)
        let rerecog = Rerecognition.choose(qwenReady: qwenReady, cloudReady: cloudReady)
        box.begin(captureAudio: rerecog != .none)
        if rerecog == .localQwen { LocalQwenASR.shared.prewarm() }
        let contextual = Self.contextualStrings()
        Task { @MainActor [weak self] in
            let started = await SpeechEngine.start(language: language, legacy: recognizer, onDevice: route == .onDevice,
                                                   contextualStrings: contextual) { [weak self] text, isFinal, errorCode, errorText, tokens in
                self?.ingest(id: id, text: text, isFinal: isFinal, errorCode: errorCode, errorText: errorText, tokens: tokens)
            }
            guard let self, self.state.commandID == id, self.state.phase == .recording || self.state.phase == .finishing else {
                started?.cancel(); return
            }
            guard let started else {
                self.fail(String(localized: "這個語言的辨識器目前不可用"), commandID: id); return
            }
            self.stream = started
            self.box.attach(started)
            if started.engineName == "analyzer" { self.state.route = RecognitionRoute.onDevice.rawValue }
            // 引擎還沒好之前就按了停止：存的音訊已補送，現在收尾。
            if self.state.phase == .finishing { self.box.end(); started.endAudio() }
        }
        AIPunctuator.shared.prewarm()
        lastError = nil
        state.phase = .recording
        state.commandID = id
        state.partial = ""
        state.final = nil
        state.translated = nil
        state.error = nil
        state.route = route.rawValue
        lastActivity = Date()
        publish()
    }

    #if DEBUG && targetEnvironment(simulator)
    private func startFakeRecognition(id: UUID) {
        lastError = nil
        state.phase = .recording
        state.commandID = id
        state.partial = ""
        state.final = nil
        state.error = nil
        state.route = "simulator"
        publish()
        fakeTask?.cancel()
        fakeTask = Task { [weak self] in
            let words = ["明天", "下午", "三點", "在錄音室", "對 Atmos 母帶"]
            var text = ""
            for word in words {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self, self.state.commandID == id, self.state.phase == .recording else { return }
                text += word
                self.state.partial = text
                self.publish()
            }
        }
    }
    #endif

    private func stopRecognition(id: UUID) {
        #if DEBUG && targetEnvironment(simulator)
        fakeTask?.cancel()
        #endif
        guard state.commandID == id, state.phase == .recording else { return }
        // 引擎已接上就收尾；還在啟動的話，接上時會看到 .finishing 自己收尾（存的話不會丟）。
        if let stream { box.end(); stream.endAudio() }
        state.phase = .finishing
        publish()
        // 有些情況 final 不會來（沒講話、辨識器卡住）：逾時就拿最後的 partial 定稿。
        finalizeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VoiceBridge.finalizeTimeout))
            guard !Task.isCancelled, let self, self.state.commandID == id, self.state.phase == .finishing else { return }
            self.deliverFinal(id: id, text: self.state.partial)
        }
    }

    private func cancelRecognition(id: UUID) {
        cleanupTasks.cancel(id: id)
        cleanupContextByCommand.removeValue(forKey: id)
        state.refining = (state.refining ?? []).filter { $0 != id }
        guard state.commandID == id else { publish(); return }
        finalizeWatchdog?.cancel()
        stream?.cancel()
        stream = nil
        box.end()
        state.phase = .ready
        state.commandID = nil
        state.partial = ""
        state.final = nil
        publish()
    }

    private func ingest(id: UUID, text: String?, isFinal: Bool, errorCode: Int?, errorText: String?, tokens: [TimedToken] = []) {
        guard state.commandID == id, state.phase == .recording || state.phase == .finishing else { return }
        if let text {
            state.partial = text
            if isFinal {
                // 停頓補標點（零延遲）；片段拼不回原文時保留辨識器原樣。
                let silences = SilenceDetector.intervals(box.levels.snapshot)
                let paused = tokens.isEmpty ? text : PausePunctuator.punctuate(tokens, silences: silences)
                let base = PunctuationGuard.preservesText(original: text, candidate: paused) ? paused : text
                let samples = box.pcm.snapshot
                // 定稿當下再選一次：開始錄音後 App 可能已切到背景，qwenReady 因此會變 false。
                let qwenReadyNow = LocalQwenASR.shared.isReady && LocalQwenASR.qwenLanguage(for: currentLanguage) != nil
                let cloudReadyNow = CloudASR.isReady(language: currentLanguage)
                let rerecog = Rerecognition.choose(qwenReady: qwenReadyNow, cloudReady: cloudReadyNow)
                if !samples.isEmpty, rerecog != .none {
                    // 即時字幕是 Apple 的；最後貼出的用本機 Qwen3-ASR 或雲端重辨識（雲端適合鍵盤：Qwen 無法在背景用）。
                    // 失敗或逾時一律用 Apple 的結果。
                    finalizeWatchdog?.cancel()   // 重辨識引擎自己都有逾時上限（見 LocalQwenASR.transcribe／CloudASR.timeLimit），不讓看門狗先送一次
                    state.phase = .finishing
                    publish()
                    let language = currentLanguage
                    let hotwords = Array(SpeechEngine.unifiedHints(personal: Self.contextualStrings()).prefix(80))
                    Task { @MainActor [weak self] in
                        let refined: String?
                        switch rerecog {
                        case .localQwen:
                            refined = await LocalQwenASR.shared.transcribe(samples, language: language, hotwords: hotwords)
                        case .cloud:
                            let provider = SmartCleanup.provider
                            refined = await CloudASR.transcribe(samples, language: language, hotwords: hotwords,
                                                                 provider: provider, key: SmartCleanup.key(for: provider))
                        case .none:
                            refined = nil
                        }
                        guard let self, self.state.commandID == id, self.state.phase == .finishing else { return }
                        self.deliverFinal(id: id, text: refined ?? base)
                    }
                    return
                }
                deliverFinal(id: id, text: base)
                return
            }
            publish()
        }
        if let errorCode {
            // 216＝使用者停止／取消；1110＝沒偵測到語音；301＝請求已取消：都不是錯，照已有文字定稿。
            if [216, 1110, 301].contains(errorCode) || state.phase == .finishing {
                deliverFinal(id: id, text: state.partial)
            } else {
                fail(String(localized: "辨識中斷：\(errorText ?? String(localized: "錯誤 \(errorCode)"))"), commandID: id)
            }
        }
    }

    private func deliverFinal(id: UUID, text: String, refined: Bool = false) {
        finalizeWatchdog?.cancel()
        stream = nil
        box.end()
        // Apple Intelligence 補標點（已預熱；1.4 s 上限；改到任何字就不用）。
        if !refined, AIPunctuator.refineEnabled, AIPunctuator.shared.isAvailable, text.count >= AIPunctuator.minimumLength {
            state.phase = .finishing
            publish()
            Task { @MainActor [weak self] in
                let better = await AIPunctuator.shared.refine(text)
                guard let self, self.state.commandID == id else { return }
                self.deliverFinal(id: id, text: better ?? text, refined: true)
            }
            return
        }
        if let pending = pendingTranslation, pending.id == id, !text.isEmpty {
            cleanupContextByCommand.removeValue(forKey: id)
            pendingTranslation = nil
            state.phase = .finishing
            publish()
            Task { @MainActor [weak self] in
                // 主 app 翻（已預熱，實測約 0.65 s）；失敗就不帶 translated，鍵盤自己翻。
                let translated = try? await FastTranslator.shared.translate(text, sourceRaw: pending.source, targetCode: pending.target)
                guard let self, self.state.commandID == id else { return }
                self.state.translated = translated
                self.state.final = text
                self.state.phase = .ready
                self.lastActivity = Date()
                self.publish()
            }
            return
        }
        state.translated = nil
        state.final = text
        state.phase = .ready
        lastActivity = Date()
        publish()
        // 定稿已經送出（鍵盤馬上貼），背景再整理；有改才送 corrected，鍵盤確認游標前還是原文才換。
        // 有設定智慧整理（使用者自備 key）→ 整理逐字稿；欄位文字只有在 context 開關開啟時才另附。
        // 沒有雲端整理時，才使用裝置端同音校正。
        let language = currentLanguage
        let smart = SmartCleanup.isEnabled
        let fieldText = cleanupContextByCommand.removeValue(forKey: id) ?? ""
        let promptContext = SmartCleanup.PromptContext(surroundingText: fieldText)
        if smart || (HomophoneCorrector.applies(to: language) && HomophoneCorrector.isAvailable && text.count >= HomophoneCorrector.minimumLength) {
            state.refining = (state.refining ?? []).filter { $0 != id } + [id]
            publish()
            let budget = CleanupBudget(seconds: SmartCleanup.backgroundTimeout)
            cleanupTasks.start(id: id, work: {
                await SmartCleanup.refine(text, fallbackText: text,
                                          language: language, smart: smart, budget: budget,
                                          validationSource: TextPipeline().clean(text).output,
                                          context: promptContext)
            }, apply: { [weak self] fixed in
                guard let self else { return }
                self.state.refining = (self.state.refining ?? []).filter { $0 != id }
                if let fixed, fixed != text {
                    let kept = (self.state.corrections ?? []).filter { $0.id != id }.suffix(5)
                    self.state.corrections = Array(kept) + [VoiceBridge.State.Correction(id: id, text: fixed)]
                }
                self.publish()
            })
        }
    }

    /// 個人字典（來源詞與輸出詞）去重，再補 iPhone 文字替換／聯絡人姓名（鍵盤讀 UILexicon 存下來的），最多 100 條。
    static func contextualStrings() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for (k, v) in DictionaryStore.shared.dictionary {
            for term in [v, k] where !term.isEmpty && seen.insert(term).inserted {
                out.append(term)
                if out.count == 100 { return out }
            }
        }
        for term in LearnedVocabulary.lexicon where seen.insert(term).inserted {
            out.append(term)
            if out.count == 100 { return out }
        }
        return out
    }

    private func fail(_ message: String, commandID: UUID?) {
        if let commandID { cleanupContextByCommand.removeValue(forKey: commandID) }
        lastError = message
        stream?.cancel()
        stream = nil
        box.end()
        state.commandID = commandID
        state.error = message
        state.phase = .failed
        state.heartbeat = isActive ? Date() : .distantPast
        publish()
        if isActive { state.phase = .ready } // 下一個指令可以再試
    }

    // MARK: - 音訊

    private func startEngine() throws {
        // 不打斷使用者正在聽的音樂、藍牙耳機繼續出聲（見 VoiceAudioSession）。
        try VoiceAudioSession.activate()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "UTUVOType", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "找不到麥克風輸入")])
        }
        Self.installTap(on: input, format: format, box: box)
        engine.prepare()
        try engine.start()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            guard began else { return }
            MainActor.assumeIsolated { self?.endSession() }
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isActive else { return }
        let now = Date()
        if VoiceBridge.shouldEndIdleSession(phase: state.phase, lastActivity: lastActivity, now: now, timeout: idleTimeout) {
            endSession()
            return
        }
        state.heartbeat = now
        state.idleEndsAt = lastActivity.addingTimeInterval(idleTimeout)
        idleEndsAt = state.idleEndsAt
        VoiceBridge.writeState(state) // 心跳不發通知，避免鍵盤每秒被叫醒
    }

    private func publish() {
        if isActive { state.heartbeat = Date() }
        phase = state.phase
        VoiceBridge.writeState(state)
        VoiceBridge.post(.update)
    }

    // MARK: - nonisolated 包裝（音訊執行緒／TCC 背景回呼不能繼承 MainActor，否則 Swift 6 執行期 SIGTRAP）

    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, box: RequestBox) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.feed(buffer)
        }
    }

    nonisolated private static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
    }
}

/// 音訊執行緒與主執行緒共用：麥克風 → 辨識引擎（SpeechFeed），加上音量紀錄與光球通道。
final class RequestBox: @unchecked Sendable {
    let speech = SpeechFeed()
    /// 這次辨識的音量紀錄（停頓斷句用）；開始新的辨識才清空，定稿後還讀得到。
    let levels = LevelLog()
    /// 本機 Qwen3-ASR 用的整段錄音（16 kHz）；只有模型已下載時才存。
    let pcm = PCMAccumulator()
    private let lock = NSLock()
    private var recording = false
    /// 鍵盤光球的即時音量通道（App Group 小檔案）；只在主執行緒建立。
    private lazy var channel = VoiceLevelChannel(writable: true)

    /// 開始一次辨識：清音量紀錄、開始存音訊、音量寫給鍵盤光球。
    func begin(captureAudio: Bool = false) {
        levels.reset()
        pcm.reset(enabled: captureAudio)
        levels.setLiveSink(channel)
        speech.arm()
        lock.lock(); recording = true; lock.unlock()
    }

    func attach(_ stream: SpeechStream) { speech.attach(stream) }

    /// 結束：之後的音訊丟掉；寫一筆立即過期的音量，鍵盤光球馬上收。
    func end() {
        lock.lock(); recording = false; lock.unlock()
        speech.disarm()
        levels.setLiveSink(nil)
    }

    /// 音訊執行緒：送進辨識並記錄音量（沒有在錄就丟掉）。
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let on = recording; lock.unlock()
        guard on else { return }
        speech.feed(buffer)
        levels.record(buffer)
        pcm.append(buffer)
    }
}
