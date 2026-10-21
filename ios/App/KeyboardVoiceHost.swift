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

    /// 媒體服務重置（mediaServicesWereReset）後舊的引擎不能再用，要換一個新的。
    private var engine = AVAudioEngine()
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
    private var audioObservers: [NSObjectProtocol] = []
    /// 麥克風被拿走了（來電、別的 app 的語音對話、引擎被系統停掉）。工作階段還在，等拿回來；
    /// 這段期間不發心跳，鍵盤點光球就會走「叫起主 app」，而不是把指令送進沒有聲音的麥克風。
    private var micLost = false
    /// 這一句收到全零時已經試過一次要回麥克風。
    private var mutedRetried = false
    /// Q3 雲端「邊錄邊傳」：錄音中先送前面的段，講完只等最後一段（nil＝沒走分段，走整段一次送）。
    private var liveCloud: LiveCloudASR?
    /// 送段的序號發號器（保證段落順序，見 `LiveChunkSubmitter`）。
    private var liveSubmitter: LiveChunkSubmitter?
    #if DEBUG && targetEnvironment(simulator)
    private var fakeTask: Task<Void, Never>?
    #endif
    #if DEBUG
    private var debugObservers: [DarwinObserver] = []
    private var debugDenyReclaim = false
    #endif

    var idleTimeout: TimeInterval = VoiceBridge.userIdleTimeout()

    #if DEBUG
    private var debugBeginObserver: DarwinObserver?
    private init() {
        // 介面震動每一下也記進診斷：實機「沒感覺」時看得出是沒觸發、開關關著、還是當下正在錄音。
        UIFeedback.onRecord = { [weak self] source in
            self?.diag("ui-haptic", ["source": source])
        }
        debugBeginObserver = DarwinObserver(.debugBegin) { [weak self] in
            guard let cmd = VoiceBridge.readCommand() else { return }
            Task { await self?.begin(language: cmd.language, autostart: cmd.id) }
        }
    }
    #else
    private init() {}
    #endif

    // MARK: - 入口

    /// `utuvotype://voice?lang=…&id=…`：鍵盤叫起主 app。
    func handle(url: URL) {
        guard let parsed = VoiceBridge.parseSessionURL(url) else { return }
        Task { await begin(language: parsed.language, autostart: parsed.commandID, returnTo: parsed.returnTo) }
    }

    func begin(language: String, autostart commandID: UUID?, returnTo hostBundleID: String? = nil) async {
        diag("begin", ["active": "\(isActive)", "micLost": "\(micLost)", "engine": "\(engine.isRunning)", "returnTo": hostBundleID ?? "-"])
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
            observeAudio()
            startHeartbeat()
            commandObserver = DarwinObserver(.command) { [weak self] in self?.commandArrived() }
            keyboardActivityObserver = DarwinObserver(.keyboardActivity) { [weak self] in self?.keyboardActivityArrived() }
            publish()
        } else if micLost || !engine.isRunning {
            // 講完電話／跟別的 app 語音對話完，鍵盤把主 app 叫回來：工作階段還在，但麥克風早就停了。
            // 以前這裡直接跳過，之後每一句都錄到空白，只能滑掉 app 重開（10-06 Micky 回報）。
            guard reclaimMic() else {
                micTaken()
                fail(String(localized: "麥克風正被通話或其他 App 使用，結束後再點一次光球"), commandID: commandID)
                return
            }
        }
        // 鍵盤寫好的 start 指令（URL 帶來的 id 要對得上，避免執行到舊指令）
        if let commandID, let cmd = VoiceBridge.readCommand(), cmd.id == commandID,
           cmd.action == .start, VoiceBridge.isFresh(cmd) {
            startRecognition(id: cmd.id, language: cmd.language, translateTo: cmd.translateTo,
                             contextText: cmd.contextText, contextAfter: cmd.contextAfter,
                             contextHint: cmd.contextHint, contextBlocked: cmd.contextBlocked == true,
                             fieldKind: cmd.contextFieldKind)
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
        stopLiveCloud()
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
        audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioObservers = []
        #if DEBUG
        debugObservers = []
        #endif
        micLost = false
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
        case .start where micLost || !engine.isRunning:
            // 主 app 還在背景，但麥克風被拿走過：先試著拿回來；系統不讓（背景不能重新開始錄音）
            // 就收掉工作階段，下一次點光球會叫起主 app 重開。
            guard reclaimMic() else {
                endSession()
                fail(String(localized: "麥克風被通話或其他 App 拿走了，再點一次光球重新開啟"), commandID: cmd.id)
                return
            }
            startRecognition(id: cmd.id, language: cmd.language, translateTo: cmd.translateTo,
                             contextText: cmd.contextText, contextAfter: cmd.contextAfter,
                             contextHint: cmd.contextHint, contextBlocked: cmd.contextBlocked == true,
                             fieldKind: cmd.contextFieldKind)
        case .start:
            startRecognition(id: cmd.id, language: cmd.language, translateTo: cmd.translateTo,
                             contextText: cmd.contextText, contextAfter: cmd.contextAfter,
                             contextHint: cmd.contextHint, contextBlocked: cmd.contextBlocked == true,
                             fieldKind: cmd.contextFieldKind)
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
    /// 這次要送整理的欄位脈絡（游標前／游標後／欄位提示）。組裝邏輯在 `FieldContext`（純函式、可測）。
    private var cleanupContextByCommand: [UUID: SmartCleanup.PromptContext] = [:]

    /// 從指令裡的欄位資訊組出提示詞脈絡。開關關掉、或欄位是密碼／一次性密碼／信用卡 → 整份空白。
    /// 密碼判定在**鍵盤那端**就先擋一次（見 `FieldContext.allowsContext`），這裡用鍵盤送來的
    /// `fieldKind` **再判一次**：兩邊都擋才不會因為其中一邊改壞就把密碼送出去。
    ///
    /// `fieldKind` 是舊版缺的東西——那時這裡傳的是預設的 `Field()`（`isSecure=false`、`contentType=nil`），
    /// `allowsContext` 恆為 true，**第二道攔截形同虛設**，實際只有 `contextBlocked` 旗標在擋
    /// （review-agy-ios-C finding 6）。現在改成拿鍵盤真的判過的欄位長相來判；
    /// 拿不到欄位資訊（舊版指令檔／鍵盤版本較舊）就退回旗標，行為與舊版一致、不會更鬆。
    static func promptContext(language: String, before: String?, after: String?, hint: String?,
                              contextBlocked: Bool, fieldKind: VoiceBridge.Command.FieldKind? = nil,
                              enabled: Bool) -> SmartCleanup.PromptContext {
        let hostAllows = fieldKind.map { FieldContext.allowsContext($0.field()) } ?? !contextBlocked
        let assembled = FieldContext.assemble(
            enabled: enabled && !contextBlocked && hostAllows,
            field: fieldKind?.field() ?? FieldContext.Field(),
            before: before, after: after, hintText: hint)
        return SmartCleanup.PromptContext(surroundingText: assembled.surroundingText,
                                          textAfterCursor: assembled.textAfterCursor,
                                          fieldHint: assembled.hint,
                                          variant: LanguageVariantStore.currentVariant(language: language))
    }

    private func startRecognition(id: UUID, language: String, translateTo: String? = nil,
                                  contextText: String? = nil, contextAfter: String? = nil,
                                  contextHint: String? = nil, contextBlocked: Bool = false,
                                  fieldKind: VoiceBridge.Command.FieldKind? = nil) {
        // URL 與 Darwin notification 可能把同一個 start 送兩次；保留第一次帶來的 field context。
        if state.commandID == id, state.phase == .recording { return }
        currentLanguage = language
        cleanupContextByCommand[id] = Self.promptContext(
            language: language, before: contextText, after: contextAfter, hint: contextHint,
            contextBlocked: contextBlocked, fieldKind: fieldKind,
            enabled: SmartCleanup.includeAppContext)
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
        startLiveCloudIfNeeded(rerecog: rerecog, language: language)
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
        mutedRetried = false
        diag("start", ["id": String(id.uuidString.prefix(8))])
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

    /// Q3：走雲端重辨識時，錄音中就把停頓切出來的段先送去辨識（背景並行）；講完只等最後一段。
    private func startLiveCloudIfNeeded(rerecog: Rerecognition, language: String) {
        stopLiveCloud()
        guard rerecog == .cloud else { return }
        guard let route = CloudASR.route() else { return }
        let live = LiveCloudASR(provider: route.provider, key: route.key, language: language,
                                hotwords: Array(SpeechEngine.cloudHints(personal: Self.contextualStrings(), language: language).prefix(80)))
        liveCloud = live
        liveSubmitter = LiveChunkSubmitter(live: live)
        // 走發號器：Task 排程不保證 FIFO，直接 `Task { await live.submit(chunk) }` 會讓後段先到（Q3-repair1 ③）。
        if let liveSubmitter { box.pcm.setChunkSink { chunk in liveSubmitter.submit(chunk) } }
    }

    /// 收掉背景分段工作（定稿、取消、結束工作階段都會走到）。
    private func stopLiveCloud() {
        box.pcm.setChunkSink(nil)
        liveSubmitter = nil
        if let liveCloud {
            let live = liveCloud
            Task { await live.abandon() }
        }
        liveCloud = nil
    }

    private func stopRecognition(id: UUID) {
        #if DEBUG && targetEnvironment(simulator)
        fakeTask?.cancel()
        #endif
        guard state.commandID == id, state.phase == .recording else { return }
        diag("stop", ["id": String(id.uuidString.prefix(8))])
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
        stopLiveCloud()
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
                let silences = SilenceDetector.intervals(box.levels.snapshot, quiet: QuietMode.isEnabled)
                let paused = tokens.isEmpty ? text : PausePunctuator.punctuate(tokens, silences: silences)
                let base = PunctuationGuard.preservesText(original: text, candidate: paused) ? paused : text
                let samples = box.pcm.snapshot
                // 定稿當下再選一次：開始錄音後 App 可能已切到背景，qwenReady 因此會變 false。
                let qwenReadyNow = LocalQwenASR.shared.isReady && LocalQwenASR.qwenLanguage(for: currentLanguage) != nil
                let cloudReadyNow = CloudASR.isReady(language: currentLanguage)
                let rerecog = Rerecognition.choose(qwenReady: qwenReadyNow, cloudReady: cloudReadyNow)
                // Q3 邊錄邊傳：把還沒講完的最後一段取出來（前面送過的段已經在 live 裡了）。
                let finalChunk = rerecog == .cloud ? box.pcm.takeFinalChunk() : nil
                let live = rerecog == .cloud ? liveCloud : nil
                let submitter = rerecog == .cloud ? liveSubmitter : nil
                if rerecog == .cloud { liveCloud = nil; liveSubmitter = nil }
                if !samples.isEmpty, rerecog != .none {
                    // 即時字幕是 Apple 的；最後貼出的用本機 Qwen3-ASR 或雲端重辨識（雲端適合鍵盤：Qwen 無法在背景用）。
                    // 失敗或逾時一律用 Apple 的結果。
                    finalizeWatchdog?.cancel()   // 重辨識引擎自己都有逾時上限（見 LocalQwenASR.transcribe／CloudASR.timeLimit），不讓看門狗先送一次
                    state.phase = .finishing
                    publish()
                    let language = currentLanguage
                    let hotwords = Array(SpeechEngine.cloudHints(personal: Self.contextualStrings(), language: language).prefix(80))
                    Task { @MainActor [weak self] in
                        let refined: String?
                        switch rerecog {
                        case .localQwen:
                            refined = await LocalQwenASR.shared.transcribe(samples, language: language, hotwords: hotwords)
                        case .cloud:
                            if let live {
                                // 分段：前面幾段錄音中就送完了，這裡只等最後一段。
                                // 先 drain：錄音中已經丟出去、還沒進 actor 的 submit Task 要先到齊，
                                // 否則 finish() 讀到的 chain 少一段，尾端就接在錯的段落後面。
                                await submitter?.drain()
                                refined = await live.finish(last: finalChunk, whole: samples,
                                                           log: CloudASR.defaultLog)
                            } else {
                                if let route = CloudASR.route() {
                                    refined = await CloudASR.transcribe(samples, language: language, hotwords: hotwords,
                                                                         provider: route.provider, key: route.key)
                                } else {
                                    refined = nil
                                }
                            }
                        case .none:
                            refined = nil
                        }
                        guard let self, self.state.commandID == id, self.state.phase == .finishing else { return }
                        // Whisper 補的「謝謝大家收看」：裝置端逐字稿沒有這句才去掉（說出要怎麼改時，這句會被當成指示）。
                        let kept = refined.map { TranscriptGuard.dropOutroHallucination($0, reference: base) }
                        self.deliverFinal(id: id, text: kept.flatMap { $0.isEmpty ? nil : $0 } ?? base)
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
        diag("final", ["chars": "\(text.count)", "refined": "\(refined)"])
        finalizeWatchdog?.cancel()
        stopLiveCloud()
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
        // 游標前／游標後／欄位提示／語言變體都在這裡組好（密碼欄位在 KeyboardVoiceHost.promptContext 就整份清空）。
        let promptContext = cleanupContextByCommand.removeValue(forKey: id) ?? SmartCleanup.PromptContext()
        if smart || (HomophoneCorrector.applies(to: language) && HomophoneCorrector.isAvailable && text.count >= HomophoneCorrector.minimumLength) {
            state.refining = (state.refining ?? []).filter { $0 != id } + [id]
            publish()
            let budget = CleanupBudget(seconds: SmartCleanup.backgroundBudgetSeconds(for: text))
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
        diag("fail", ["message": message])
        stopLiveCloud()
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

    /// 開麥克風；可重複呼叫（重開時先拆掉舊的 tap，格式可能已經換了，例如接上耳機）。
    private func startEngine(exclusive: Bool = false) throws {
        // 不打斷使用者正在聽的音樂、藍牙耳機繼續出聲（見 VoiceAudioSession）。
        try VoiceAudioSession.activate(exclusive: exclusive)
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "UTUVOType", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "找不到麥克風輸入")])
        }
        Self.installTap(on: input, format: format, box: box)
        engine.prepare()
        try engine.start()
        micLost = false
        diag("engine-started", ["exclusive": "\(exclusive)", "format": "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"])
    }

    /// 來電、別的 app 開始語音對話、音訊路徑改變、媒體服務重置：麥克風被拿走時不要整個收掉工作階段，
    /// 能拿回來就自己接回去（以前來電一來就 endSession，講完電話鍵盤要重新叫起 app；
    /// 沒有中斷通知、只是引擎被停掉的情況更糟：工作階段看起來活著，之後全錄到空白）。
    private func observeAudio() {
        let center = NotificationCenter.default
        audioObservers.forEach { center.removeObserver($0) }
        audioObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).map { "\($0)" } ?? "-"
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { "\($0)" } ?? "-"
                MainActor.assumeIsolated {
                    self?.diag(began ? "interruption-began" : "interruption-ended", ["reason": reason, "options": options])
                    if began { self?.micTaken() } else { self?.micReturned() }
                }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
                let source = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, source == ObjectIdentifier(self.engine) else { return }
                    self.diag("engine-config-change")
                    self.engineConfigurationChanged()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.diag("media-reset"); self?.mediaServicesReset() }
            },
        ]
        #if DEBUG
        audioObservers += [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map { "\($0)" } ?? "-"
                MainActor.assumeIsolated { self?.diag("route-change", ["reason": reason]) }
            },
            center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt).map { "\($0)" } ?? "-"
                MainActor.assumeIsolated { self?.diag("secondary-hint", ["type": type]) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.diag("did-enter-background") }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.diag("will-enter-foreground") }
            },
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.diag("will-terminate") }
            },
        ]
        #endif
        #if DEBUG
        func interruption(_ type: AVAudioSession.InterruptionType) {
            center.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                   AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        }
        debugObservers = [
            DarwinObserver(.debugInterruptBegan) { interruption(.began) },
            DarwinObserver(.debugInterruptEnded) { interruption(.ended) },
            DarwinObserver(.debugEngineStop) { [weak self] in self?.engine.stop(); self?.debugAudio("debug-stopped") },
            DarwinObserver(.debugDenyReclaim) { [weak self] in
                guard let self else { return }
                self.debugDenyReclaim.toggle()
                self.debugAudio("deny-reclaim=\(self.debugDenyReclaim)")
            },
        ]
        #endif
    }

    /// 中斷開始（來電、別的 app 搶走麥克風）：講到一半的照常定稿，停掉引擎、停發心跳。
    private func micTaken() {
        guard isActive else { return }
        micLost = true
        if state.phase == .recording, let id = state.commandID { stopRecognition(id: id) }
        engine.stop()
        debugAudio("taken")
        publish()
    }

    /// 中斷結束：馬上把麥克風拿回來，講完電話回到原本的 app 直接點光球就能講。
    /// 系統不讓（背景不能重新開始錄音）就收掉工作階段——鍵盤下次點光球會叫起主 app 重開，跟以前一樣。
    private func micReturned() {
        guard isActive, micLost else { return }
        if !reclaimMic() { endSession() }
    }

    /// 音訊路徑改變（接耳機、別的 app 開了語音模式）會讓引擎自己停掉，而且不一定有中斷通知。
    private func engineConfigurationChanged() {
        guard isActive, !micLost, !engine.isRunning else { return }
        if !reclaimMic() { micTaken() }
    }

    /// 媒體服務重置：所有音訊物件都失效，換一個新引擎重開。
    private func mediaServicesReset() {
        guard isActive else { return }
        if state.phase == .recording, let id = state.commandID { stopRecognition(id: id) }
        engine = AVAudioEngine()
        micLost = true
        if !reclaimMic() { endSession() }
    }

    /// 重開麥克風；成功就恢復心跳。失敗時呼叫端決定要等（micTaken）還是收掉（endSession）。
    private func reclaimMic(exclusive: Bool = false) -> Bool {
        engine.stop()
        do {
            #if DEBUG
            if debugDenyReclaim {
                throw NSError(domain: "UTUVOType", code: 2, userInfo: [NSLocalizedDescriptionKey: "debug: background record denied"])
            }
            #endif
            try startEngine(exclusive: exclusive)
        } catch {
            diag("reclaim-failed", ["error": error.localizedDescription])
            debugAudio("reclaim-failed: \(error.localizedDescription)")
            return false
        }
        debugAudio("reclaimed")
        publish()
        return true
    }

    /// 錄音中連續收到全零：麥克風被別的 App（ChatGPT 語音、通話、遠端遙控）佔著。
    /// 先試一次不混音地要回輸入；還是全零就明講，不要默默貼出空白（10-06 Micky：講完 AI 對話後光球錄到的全是空的）。
    private func inputMuted(id: UUID) {
        diag("input-muted", ["retried": "\(mutedRetried)"])
        if !mutedRetried {
            mutedRetried = true
            box.resetSilence()
            if reclaimMic(exclusive: true) { return }
        }
        if !state.partial.isEmpty { stopRecognition(id: id); return }
        fail(String(localized: "收不到麥克風的聲音：可能被通話、其他 App 的語音模式佔著，或 iPhone 正被電腦鏡像；先結束它再點光球"), commandID: id)
    }

    /// 開發版：把語音工作階段的每一步記進 App Group（真機用 devicectl 撈），無線 log 會斷、這份不會。
    private func diag(_ event: String, _ extra: [String: String] = [:]) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        var line = extra
        line["event"] = event
        line["at"] = ISO8601DateFormatter.diag.string(from: Date())
        line["app"] = ["active", "inactive", "background"][min(UIApplication.shared.applicationState.rawValue, 2)]
        line["phase"] = state.phase.rawValue
        line["engine"] = engine.isRunning ? "on" : "off"
        line["micLost"] = "\(micLost)"
        line["cat"] = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        line["opts"] = "\(session.categoryOptions.rawValue)"
        line["otherPlaying"] = "\(session.isOtherAudioPlaying)"
        line["silenceHint"] = "\(session.secondaryAudioShouldBeSilencedHint)"
        line["in"] = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        line["out"] = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        VoiceDiagLog.append(line)
        #endif
    }

    private func debugAudio(_ event: String) {
        #if DEBUG
        VoiceBridge.write(["event": event, "running": engine.isRunning ? "yes" : "no",
                           "at": ISO8601DateFormatter().string(from: Date())], name: "debug-audio.json")
        #endif
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
        state.idleEndsAt = lastActivity.addingTimeInterval(idleTimeout)
        idleEndsAt = state.idleEndsAt
        if state.phase == .recording, let id = state.commandID {
            let silence = box.silence()
            diag("tick", ["db": box.levels.latest().map { String(format: "%.0f", $0) } ?? "-",
                          "zeroRun": String(format: "%.1f", silence.zeroRun), "heard": String(format: "%.1f", silence.heard)])
            #if !targetEnvironment(simulator)
            // 模擬器沒有真的麥克風，收到的本來就全是 0（UI 測試靠假逐字稿跑）；只在真機判斷。
            if silence.isMuted { inputMuted(id: id) }
            #endif
        }
        // 麥克風被拿走時不發心跳（講到一半的定稿除外），鍵盤才知道要叫起主 app 重開。
        guard !micLost || state.phase == .finishing else { return }
        state.heartbeat = now
        VoiceBridge.writeState(state) // 心跳不發通知，避免鍵盤每秒被叫醒
    }

    private func publish() {
        if isActive { state.heartbeat = (micLost && state.phase != .finishing) ? .distantPast : Date() }
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
    private var silenceMeter = DigitalSilenceMeter()
    /// 鍵盤光球的即時音量通道（App Group 小檔案）；只在主執行緒建立。
    private lazy var channel = VoiceLevelChannel(writable: true)

    /// 開始一次辨識：清音量紀錄、開始存音訊、音量寫給鍵盤光球。
    func begin(captureAudio: Bool = false) {
        levels.reset()
        pcm.reset(enabled: captureAudio)
        levels.setLiveSink(channel)
        speech.arm()
        lock.lock(); recording = true
        // 小聲模式：全零判定放寬（輕聲講時麥克風自動增益會讓無聲段更容易湊出整批精確的 0）。
        silenceMeter = DigitalSilenceMeter(holdSeconds: QuietMode.muteHoldSeconds(enabled: QuietMode.isEnabled))
        silenceMeter.reset(); lock.unlock()
    }

    func attach(_ stream: SpeechStream) { speech.attach(stream) }

    func silence() -> DigitalSilenceMeter { lock.lock(); defer { lock.unlock() }; return silenceMeter }
    func resetSilence() { lock.lock(); silenceMeter.reset(); lock.unlock() }

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
        // 小聲說話模式的數位前級增益 + 限幅在**這裡**套（單一入口：Apple 裝置端／雲端辨識、
        // Qwen 重辨識與雲端 ASR 吃的都是這一份 buffer，所以不會有「某條路徑沒套到」的情況）。
        let processed = QuietMode.processed(buffer)
        if processed.format.sampleRate > 0, let data = processed.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(processed.frameLength) { peak = max(peak, abs(data[i])) }
            let duration = Double(processed.frameLength) / processed.format.sampleRate
            lock.lock(); silenceMeter.add(peak: peak, duration: duration); lock.unlock()
        }
        speech.feed(processed)
        levels.record(processed)
        pcm.append(processed)
    }
}

#if DEBUG
/// 開發版診斷紀錄：App Group `Library/VoiceBridge/debug-voice-diag.log`，一行一筆 JSON，超過 256 KB 砍掉前半。
enum VoiceDiagLog {
    static let name = "debug-voice-diag.log"
    private static let lock = NSLock()

    static func append(_ line: [String: String]) {
        guard let dir = VoiceBridge.containerURL,
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let url = dir.appendingPathComponent(name)
        lock.lock(); defer { lock.unlock() }
        var all = (try? Data(contentsOf: url)) ?? Data()
        if all.count > 256 * 1024 {
            // 從換行處切，不留半行（10-07 撈回來的檔第一行是半筆 JSON）。
            let tail = all.suffix(128 * 1024)
            all = tail.firstIndex(of: 0x0A).map { Data(tail[tail.index(after: $0)...]) } ?? Data()
        }
        all.append(data)
        all.append(0x0A)
        try? all.write(to: url, options: .atomic)
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let diag: ISO8601DateFormatter = {   // 只在主執行緒用
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f
    }()
}
#endif
