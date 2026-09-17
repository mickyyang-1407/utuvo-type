import Foundation
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

    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var state = VoiceBridge.State(phase: .ended, heartbeat: .distantPast)
    private var heartbeat: Timer?
    private var commandObserver: DarwinObserver?
    private var lastActivity = Date()
    private var finalizeWatchdog: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    #if DEBUG && targetEnvironment(simulator)
    private var fakeTask: Task<Void, Never>?
    #endif

    var idleTimeout: TimeInterval = VoiceBridge.defaultIdleTimeout

    private init() {}

    // MARK: - 入口

    /// `utuvotype://voice?lang=…&id=…`：鍵盤叫起主 app。
    func handle(url: URL) {
        guard let parsed = VoiceBridge.parseSessionURL(url) else { return }
        Task { await begin(language: parsed.language, autostart: parsed.commandID) }
    }

    func begin(language: String, autostart commandID: UUID?) async {
        lastError = nil
        if !isActive {
            guard await Self.requestMicrophone() else {
                fail("需要麥克風權限：設定 → UTUVO Type → 麥克風", commandID: commandID)
                return
            }
            guard await Self.requestSpeechAuthorization() == .authorized else {
                fail("需要語音辨識權限：設定 → UTUVO Type → 語音辨識", commandID: commandID)
                return
            }
            do {
                try startEngine()
            } catch {
                fail("無法開啟麥克風：\(error.localizedDescription)", commandID: commandID)
                return
            }
            isActive = true
            lastActivity = Date()
            state = VoiceBridge.State(phase: .ready, heartbeat: Date())
            startHeartbeat()
            commandObserver = DarwinObserver(.command) { [weak self] in self?.commandArrived() }
            publish()
        }
        // 鍵盤寫好的 start 指令（URL 帶來的 id 要對得上，避免執行到舊指令）
        if let commandID, let cmd = VoiceBridge.readCommand(), cmd.id == commandID,
           cmd.action == .start, VoiceBridge.isFresh(cmd) {
            startRecognition(id: cmd.id, language: cmd.language)
        }
    }

    /// 使用者在主 app 按「結束」、閒置逾時、或來電中斷。
    func endSession() {
        guard isActive else { return }
        finalizeWatchdog?.cancel()
        task?.cancel()
        task = nil
        box.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        heartbeat?.invalidate()
        heartbeat = nil
        commandObserver = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        isActive = false
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
        case .start: startRecognition(id: cmd.id, language: cmd.language)
        case .stop: stopRecognition(id: cmd.id)
        case .cancel: cancelRecognition(id: cmd.id)
        case .endSession: endSession()
        }
    }

    private func startRecognition(id: UUID, language: String) {
        // 同一個 id 已經在錄（URL 與 Darwin 通知都送到）→ 不重來
        if state.commandID == id, state.phase == .recording { return }
        if task != nil { task?.cancel(); task = nil; box.set(nil) }
        finalizeWatchdog?.cancel()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            #if DEBUG && targetEnvironment(simulator)
            // 模擬器沒有語音辨識：Debug 用假逐字稿把「鍵盤 ↔ 主 app ↔ 插字」整條橋接跑一遍。
            startFakeRecognition(id: id)
            return
            #else
            fail("這個語言的辨識器目前不可用", commandID: id)
            return
            #endif
        }
        let onDeviceOnly = UserDefaults.standard.bool(forKey: DictationModel.onDeviceOnlyKey)
        guard case .allow(let route) = RecognitionRoutePolicy.decide(
            supportsOnDevice: recognizer.supportsOnDeviceRecognition, onDeviceOnly: onDeviceOnly) else {
            fail("你開了「只用裝置端辨識」，但這個語言在這台裝置沒有裝置端辨識", commandID: id)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = route == .onDevice
        box.set(request)
        task = Self.makeTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, errorCode, errorText in
            self?.ingest(id: id, text: text, isFinal: isFinal, errorCode: errorCode, errorText: errorText)
        }
        lastError = nil
        state.phase = .recording
        state.commandID = id
        state.partial = ""
        state.final = nil
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
        box.request?.endAudio()
        box.set(nil)
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
        guard state.commandID == id else { return }
        finalizeWatchdog?.cancel()
        task?.cancel()
        task = nil
        box.set(nil)
        state.phase = .ready
        state.commandID = nil
        state.partial = ""
        state.final = nil
        publish()
    }

    private func ingest(id: UUID, text: String?, isFinal: Bool, errorCode: Int?, errorText: String?) {
        guard state.commandID == id, state.phase == .recording || state.phase == .finishing else { return }
        if let text {
            state.partial = text
            if isFinal { deliverFinal(id: id, text: text); return }
            publish()
        }
        if let errorCode {
            // 216＝使用者停止／取消；1110＝沒偵測到語音；301＝請求已取消：都不是錯，照已有文字定稿。
            if [216, 1110, 301].contains(errorCode) || state.phase == .finishing {
                deliverFinal(id: id, text: state.partial)
            } else {
                fail("辨識中斷：\(errorText ?? "錯誤 \(errorCode)")", commandID: id)
            }
        }
    }

    private func deliverFinal(id: UUID, text: String) {
        finalizeWatchdog?.cancel()
        task = nil
        box.set(nil)
        state.final = text
        state.phase = .ready
        lastActivity = Date()
        publish()
    }

    private func fail(_ message: String, commandID: UUID?) {
        lastError = message
        task?.cancel()
        task = nil
        box.set(nil)
        state.commandID = commandID
        state.error = message
        state.phase = .failed
        state.heartbeat = isActive ? Date() : .distantPast
        publish()
        if isActive { state.phase = .ready } // 下一個指令可以再試
    }

    // MARK: - 音訊

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：不把使用者正在聽的音樂停掉。
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "UTUVOType", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到麥克風輸入"])
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
            box.request?.append(buffer)
        }
    }

    nonisolated private static func makeTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping @MainActor @Sendable (String?, Bool, Int?, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let code = (error as NSError?)?.code
            let message = error?.localizedDescription
            Task { @MainActor in onResult(text, isFinal, code, message) }
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

/// 音訊執行緒與主執行緒共用的「目前辨識請求」。
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    var request: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        return _request
    }
    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); _request = request; lock.unlock()
    }
}
