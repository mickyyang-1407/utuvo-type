import SwiftUI
@preconcurrency import AVFAudio

/// 智慧整理（選配）：選服務、照步驟申請免費 key、貼上、測試。
/// key 輸入放在獨立子頁（跟字典欄同表單會被 iOS 當登入表單，2026-09-18 實測）。
struct SmartCleanupScreen: View {
    @AppStorage(SmartCleanup.enabledKey, store: SmartCleanup.settingsDefaults) private var enabled = true   // 沒動過＝開（與 SmartCleanup.enabledPreference 一致）
    @State private var processingMode = DictationRouteSettings.mode
    @State private var asrProvider = DictationRouteSettings.asrProvider
    @State private var audioAuthorized = DictationRouteSettings.audioUploadAuthorized
    @AppStorage(SmartCleanup.autoListKey, store: SmartCleanup.settingsDefaults) private var autoList = true   // 沒設過＝開（與 SmartCleanup.autoListEnabled 一致）
    @State private var provider = SmartCleanup.provider
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var testing = false
    @State private var cloudASRTesting = false
    @State private var cloudMessage: String?
    @State private var cloudMessageIsError = false
    @State private var logSummary: SmartLog.Summary?
    @State private var customEndpoint = SmartCleanup.customEndpoint
    @State private var customModel = SmartCleanup.customModel
    @AppStorage(SmartCleanup.includeAppContextKey, store: UserDefaults(suiteName: VoiceBridge.groupID))
    private var includeAppContext = false

    static let sample = "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。"

    var body: some View {
        Form {
            Section {
                Toggle("智慧整理", isOn: $enabled)
                    .feedbackOnChange(of: enabled)
            } footer: {
                Text("辨識後先整理，再一次貼入。雲端失敗會回退本機完整整理；本機模型也不可用時保留辨識結果。診斷會分別記錄模型產出與文字交付。")
            }

            Section("語音處理路徑") {
                Picker("處理方式", selection: $processingMode) {
                    ForEach(DictationProcessingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("dictationProcessingMode")
                .onChange(of: processingMode) { _, mode in
                        if mode != DictationRouteSettings.mode { DictationRouteSettings.mode = mode }
                        audioAuthorized = DictationRouteSettings.audioUploadAuthorized
                    }
            }

            if GemmaCleanup.isOffered {
                GemmaSection()
            }
            #if DEBUG
            DebugNoAISection()
            #endif

            Section {
                Toggle("自動條列", isOn: $autoList)
                    .feedbackOnChange(of: autoList)
            } footer: {
                Text("講步驟、流程或幾個重點時，整理成 1. 2. 3.；關掉就只分段。")
            }

            Section("整理脈絡") {
                Toggle("整理時參考前文（最多 500 字）", isOn: $includeAppContext)
                    .feedbackOnChange(of: includeAppContext)
                Text("開啟後，會把目前欄位游標前最多 500 個字和辨識文字一起送到所選整理服務，只用來理解指涉與語氣。iOS 鍵盤無法讀取宿主 App 名稱，因此不會傳送 App 名稱。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if processingMode == .cloud {
            Section("雲端文字整理服務") {
                Picker("服務", selection: $provider) {
                    Text("Groq").tag(SmartCleanup.Provider.groq)
                    Text("Claude").tag(SmartCleanup.Provider.claude)
                    Text("Google Gemini").tag(SmartCleanup.Provider.gemini)
                    Text("阿里雲百鍊").tag(SmartCleanup.Provider.dashscope)
                    Text("自訂（OpenAI 相容）").tag(SmartCleanup.Provider.custom)
                }
                .feedbackOnChange(of: provider)
                .onChange(of: provider) { _, new in
                    SmartCleanup.provider = new
                    refresh()
                }
                if provider == .custom {
                    TextField("端點網址（…/chat/completions）", text: $customEndpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型名稱", text: $customModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("儲存端點") { _ = saveCustomEndpoint() }
                }
            }

            Section(provider == .claude ? LocalizedStringKey("申請 API key") : LocalizedStringKey("申請免費 key")) {
                if provider == .groq {
                    NavigationLink {
                        GuidedTutorialView(kind: .groqKey)
                            .pushHaptic()
                            .onDisappear { refresh() }
                    } label: {
                        Label("一步一步教我申請（約 3 分鐘）", systemImage: "hand.point.up.left.fill")
                            .foregroundStyle(Aurora.orange)
                    }
                    .accessibilityIdentifier("groqTutorialRow")
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
                if let url = provider.signupURL {
                    Link(destination: url) { Label("打開申請頁面", systemImage: "arrow.up.right.square") }
                }
                Text(privacyNote).font(.footnote).foregroundStyle(.secondary)
            }

            Section("API key") {
                if provider == .dashscope {
                    NavigationLink {
                        CloudKeyScreen()
                            .pushHaptic()
                    } label: {
                        LabeledContent("阿里雲百鍊 key", value: hasKey ? String(localized: "已設定") : String(localized: "未設定"))
                    }
                    Text("點上方管理阿里雲百鍊 key，辨識與文字整理共用同一把 key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField(hasKey ? String(localized: "輸入新的 key 以取代") : "API key", text: $keyDraft)
                        .textContentType(nil)
                        .accessibilityIdentifier("smartKey")
                    HStack {
                        Button("儲存") {
                            TapPulse.shared.fire()
                            guard saveCustomEndpoint() else { return }
                            if SmartCleanup.saveKey(keyDraft, for: provider) {
                                keyDraft = ""
                                message = String(localized: "已存進這支手機的鑰匙圈。")
                                messageIsError = false
                                enabled = true
                            } else {
                                message = String(localized: "key 是空的或存不進鑰匙圈。")
                                messageIsError = true
                            }
                            refresh()
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Button("清除", role: .destructive) {
                            TapPulse.shared.fire()
                            SmartCleanup.deleteKey(for: provider)
                            message = String(localized: "已刪除。")
                            messageIsError = false
                            refresh()
                        }
                        .disabled(!hasKey)
                    }
                    .buttonStyle(.borderless)
                }
            }
            }
            Section("測試與診斷") {
                Button {
                    TapPulse.shared.fire()
                    Task { await test() }
                } label: {
                    if testing { ProgressView() } else { Text("測試") }
                }
                .disabled((processingMode == .local ? !OnDeviceCleanup.available : !hasKey) || testing)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(messageIsError ? .red : .secondary)
                }
                if let logSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近交付 \(logSummary.ok) 次、異常事件 \(logSummary.failed) 次")
                        if let lastFailure = logSummary.lastFailure, let lastProvider = logSummary.lastFailureProvider {
                            Text("最後一次失敗：\(lastFailure)（\(SmartLog.providerName(lastProvider))）")
                                .foregroundStyle(logSummary.failed > logSummary.ok ? .red : .secondary)
                            if logSummary.lastFailureOutcome == "http(429)" {
                                Text("這把 key 的免費額度用完了。可以到服務後台查看額度、換一家服務，或按「清除」改用 Apple Intelligence（在手機上整理）。")
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if processingMode == .cloud {
            Section {
                if !audioAuthorized {
                    Text("舊設定只允許文字整理，錄音仍留在本機。啟用後才會將錄音送到選定的辨識服務。")
                    Button("啟用雲端辨識") {
                        DictationRouteSettings.audioUploadAuthorized = true
                        audioAuthorized = true
                    }
                }
                Picker("雲端辨識服務", selection: $asrProvider) {
                    Text("Groq").tag(SmartCleanup.Provider.groq)
                    Text("Google Gemini").tag(SmartCleanup.Provider.gemini)
                    Text("阿里雲百鍊").tag(SmartCleanup.Provider.dashscope)
                }
                .onChange(of: asrProvider) { _, provider in DictationRouteSettings.asrProvider = provider }
                Text("辨識與文字整理可選不同服務。辨識只使用這裡選定的服務，不會自動改用其他已儲存的 key。")
                Button {
                    TapPulse.shared.fire()
                    Task { await testCloudASR() }
                } label: {
                    if cloudASRTesting { ProgressView() } else { Text("測試雲端辨識") }
                }
                .disabled(!cloudASRAvailable || cloudASRTesting)
                if let cloudMessage {
                    Text(cloudMessage).font(.footnote).foregroundStyle(cloudMessageIsError ? .red : .secondary)
                }
            } header: {
                Text("雲端辨識（選配）")
            } footer: {
                Text(cloudASRFooter)
            }
            }
        }
        .navigationTitle("智慧整理（選配）")
        .onAppear(perform: refresh)
    }

    private var steps: [String] {
        switch provider {
        case .gemini:
            return [String(localized: "按下面「打開申請頁面」，用你的 Google 帳號登入 Google AI Studio。"),
                    String(localized: "按「Create API key」（建立 API 金鑰）。"),
                    String(localized: "複製產生的 key，回到這裡貼上、按「儲存」。"),
                    String(localized: "按「測試」確認可以用。")]
        case .groq:
            return [String(localized: "按下面「打開申請頁面」，用 Email 或 Google 帳號登入 GroqCloud。"),
                    String(localized: "按「Create API Key」，取個名字。"),
                    String(localized: "複製產生的 key（只會顯示一次），回到這裡貼上、按「儲存」。"),
                    String(localized: "按「測試」確認可以用。")]
        case .dashscope:
            return [String(localized: "打開阿里雲百鍊主控台，開通模型服務（需要實名認證）。"),
                    String(localized: "在「API-KEY」頁建立 key。"),
                    String(localized: "複製 key，回到設定裡的阿里雲百鍊頁貼上；回到這裡按「測試」。")]
        case .claude:
            return [String(localized: "按下面「打開申請頁面」，登入 Anthropic Console（Claude 的開發者後台）。"),
                    String(localized: "在「API Keys」按「Create Key」，取個名字。"),
                    String(localized: "複製產生的 key（只會顯示一次），回到這裡貼上、按「儲存」。"),
                    String(localized: "按「測試」確認可以用。")]
        case .custom:
            return [String(localized: "填入任何 OpenAI 相容服務的端點網址與模型名稱（例如自己架的伺服器）。"),
                    String(localized: "貼上 key、按「儲存」，再按「測試」。")]
        }
    }

    private var privacyNote: String {
        switch provider {
        case .gemini:
            return String(localized: "免費版額度很少：2026-09 實測 Gemini 3.8 Flash 每天只有 20 次，智慧整理和雲端辨識共用，用完會回 429、當天就不會再整理（可在 AI Studio 的 rate limit 頁查看；綁定付款帳戶後依用量計費）。免費版送出的文字 Google 可能用來改進模型；在 Google Cloud 綁定付款帳戶（不一定會被收費）就不會。")
        case .groq:
            return String(localized: "有免費額度（上限依模型，可在 Groq 後台查看），速度很快；預設不保留送出的資料。")
        case .dashscope:
            return String(localized: "新用戶有免費額度，之後依用量計費。")
        case .claude:
            return String(localized: "依用量計費，要在 Anthropic Console 加值或有 API 額度；Claude Pro／Max 訂閱本身不能直接用，要另外申請 API key。Anthropic 預設不拿 API 送出的資料訓練模型。Claude 不能辨識語音：雲端辨識會改用你存的 Groq／Gemini key。")
        case .custom:
            return String(localized: "文字會送到你填的端點。")
        }
    }

    private var cloudASRAvailable: Bool {
        processingMode == .cloud && audioAuthorized && !SmartCleanup.key(for: asrProvider).isEmpty
    }

    private var cloudASRFooter: String {
        String(localized: "本機模式不傳送錄音。雲端模式使用選定辨識服務的 key；尚未儲存時，請在上方選擇該服務儲存 key，再選回文字整理服務。失敗時保留 Apple 裝置端辨識結果。")
    }

    private func refresh() {
        processingMode = DictationRouteSettings.mode
        audioAuthorized = DictationRouteSettings.audioUploadAuthorized
        hasKey = !SmartCleanup.key(for: provider).isEmpty
        let entries = SmartLog.recentEntries()
        logSummary = entries.isEmpty ? nil : SmartLog.summary(entries)
    }

    private func testCloudASR() async {
        cloudASRTesting = true
        defer { cloudASRTesting = false }
        // 用 TTS 念一段固定的測試句（zh-TW 聲音），用 PCMAccumulator 收 16 kHz 單聲道再送雲端。
        let samples = await Self.synthesizeTestSamples()
        guard !samples.isEmpty else {
            cloudMessage = String(localized: "TTS 沒有產生音訊，請確認裝置。")
            cloudMessageIsError = true
            return
        }
        let start = Date()
        guard let route = CloudASR.route() else { return }
        let result = await CloudASR.transcribe(samples, language: "zh-TW", hotwords: [],
                                                provider: route.provider, key: route.key)
        let elapsed = Date().timeIntervalSince(start)
        if let text = result, !text.isEmpty {
            cloudMessage = String(localized: "辨識結果：\(text)（\(String(format: "%.1f", elapsed)) 秒）")
            cloudMessageIsError = false
        } else {
            cloudMessage = String(localized: "失敗，會改用手機辨識。")
            cloudMessageIsError = true
        }
    }

    /// R1-5：TTS 收樣本要拿到完整 buffer 才能繼續。`AVSpeechSynthesizer.write` 的 callback 跑在背景執行緒，
    /// 閉包原本寫在 `@MainActor` 的 View 方法裡，會繼承 MainActor 隔離 → Swift 6 執行期 SIGTRAP
    /// （與 DictationModel.swift:287 installTap 同型）。提到 nonisolated static func，自己持有 synthesizer
    /// 直到收到 frameLength 為 0 的結束 buffer 或 10 秒逾時；不再用固定 sleep(1)。
    nonisolated private static func synthesizeTestSamples() async -> [Float] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Float], Never>) in
            let utterance = AVSpeechUtterance(string: "UTUVO Type 雲端辨識測試，明天下午三點在錄音室對 Atmos 母帶。")
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
            let pcm = PCMAccumulator()
            pcm.reset(enabled: true)
            let synth = AVSpeechSynthesizer()
            let done = DoneFlag()
            let timeout = TimeoutFlag()
            synth.write(utterance) { buffer in
                guard !timeout.fired else { return }
                if let pcmBuffer = buffer as? AVAudioPCMBuffer {
                    if pcmBuffer.frameLength == 0 {
                        // 與逾時共用同一個一次性旗標：兩邊同時到也只 resume 一次（重複 resume 會直接當掉）。
                        if done.flipIfNotYet() { cont.resume(returning: pcm.snapshot) }
                    } else {
                        pcm.append(pcmBuffer)
                    }
                }
            }
            // 10 秒逾時保險（語音資源故障時不會永遠卡住）
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                // 這個閉包持有 synth 到逾時為止：區域變數沒人引用的話 ARC 會在 write 回來後就釋放、合成中斷。
                withExtendedLifetime(synth) {}
                timeout.fired = true
                if done.flipIfNotYet() { cont.resume(returning: pcm.snapshot) }
            }
        }
    }

    private func saveCustomEndpoint() -> Bool {
        guard provider == .custom else { return true }
        do {
            try SmartCleanup.saveCustom(endpoint: customEndpoint, model: customModel)
            message = String(localized: "端點已儲存。")
            messageIsError = false
            return true
        } catch {
            message = String(localized: "端點須為 HTTPS，且不能包含帳密、金鑰參數或 #。")
            messageIsError = true
            return false
        }
    }

    private func test() async {
        guard processingMode == .local || saveCustomEndpoint() else { return }
        testing = true
        defer { testing = false }
        let start = Date()
        do {
            if processingMode == .local {
                // Use the same explicit local route as dictation.
                guard let out = await SmartCleanup.clean(Self.sample, language: "zh-TW", timeout: 8, log: { _, _, _, _ in }) else {
                    message = String(localized: "本機模型這次沒有產生可用結果。")
                    messageIsError = true
                    return
                }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                message = String(localized: "本機整理可以用（\(ms) 毫秒）：\(out)")
                messageIsError = false
                return
            }
            let out = try await SmartCleanup.run(Self.sample, provider: provider, key: SmartCleanup.key(for: provider),
                                                  traditional: true, timeout: 8)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            message = String(localized: "可以用（\(ms) 毫秒）：\(out)")
            messageIsError = false
        } catch SmartCleanup.Failure.http(let code) {
            message = code == 401 || code == 403 ? String(localized: "key 不對或沒有權限（\(code)）。") : String(localized: "服務回應錯誤（\(code)）。")
            messageIsError = true
        } catch SmartCleanup.Failure.timeout {
            message = String(localized: "連線逾時，請檢查網路。")
            messageIsError = true
        } catch {
            message = String(localized: "失敗：\(error.localizedDescription)")
            messageIsError = true
        }
    }
}

/// R1-5：TTS 結束旗標。一次性的旗標，原子地把「未完成」翻成「完成」並回傳是否真的翻了；
/// 真正完成（buffer frameLength==0）或逾時都呼叫 flipIfNotYet，誰先到誰送 continuation。
private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// 翻並回傳是否真的翻了（true = 本次呼叫把 false 變 true）。
    func flipIfNotYet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// R1-5：TTS callback 還在跑時逾時已先觸發，這個旗標告訴 callback 別再交樣本。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fired }
        set { lock.lock(); _fired = newValue; lock.unlock() }
    }
}

#if DEBUG
/// 只在開發版：當作沒有 Apple Intelligence（有 Apple Intelligence 的手機也能試 Gemma）。切換後回上一頁再進來就會看到。
private struct DebugNoAISection: View {
    @AppStorage(OnDeviceAssistant.debugManualDisableKey, store: KeyboardPresence.defaults) private var pretend = false

    var body: some View {
        Section {
            Toggle("當作沒有 Apple Intelligence", isOn: $pretend)
                .onChange(of: pretend) { _, _ in GemmaCleanup.shared.refreshOffer() }
        } header: {
            Text("開發版測試")
        } footer: {
            Text("只有開發版有這個開關。打開後這支手機的智慧整理會改用 Gemma（要先下載），正式版不會出現。")
        }
    }
}
#endif
