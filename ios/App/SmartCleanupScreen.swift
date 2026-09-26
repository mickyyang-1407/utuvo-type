import SwiftUI
@preconcurrency import AVFAudio

/// 智慧整理（選配）：選服務、照步驟申請免費 key、貼上、測試。
/// key 輸入放在獨立子頁（跟字典欄同表單會被 iOS 當登入表單，2026-09-18 實測）。
struct SmartCleanupScreen: View {
    @AppStorage(SmartCleanup.enabledKey) private var enabled = true   // 沒動過＝開（與 SmartCleanup.enabledPreference 一致）
    @AppStorage(CloudASR.enabledKey) private var cloudASREnabled = false   // 沒設過＝關（與 CloudASR.enabledPreference 一致）
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
    @AppStorage(SmartCleanup.customEndpointKey) private var customEndpoint = ""
    @AppStorage(SmartCleanup.customModelKey) private var customModel = ""
    @AppStorage(SmartCleanup.includeAppContextKey, store: UserDefaults(suiteName: VoiceBridge.groupID))
    private var includeAppContext = false

    static let sample = "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。"

    var body: some View {
        Form {
            Section {
                Toggle("智慧整理", isOn: $enabled)
            } footer: {
                Text("講完先貼出辨識結果，大模型在背景整理改口、贅詞和錯字，再安全替換。沒有設定 key 時，用 Apple Intelligence 在這支手機上整理，文字不離機；設定 key 後改用下面選的雲端服務。是否使用 Apple 雲端辨識，請在「辨識與隱私」設定管理；雲端整理服務只會收到辨識文字與你選擇傳送的欄位脈絡。開了下面的「雲端辨識」時，錄音也會送到同一家服務。")
            }

            Section("整理脈絡") {
                Toggle("讓整理參考目前欄位文字", isOn: $includeAppContext)
                Text("開啟後，會把目前欄位游標前最多 500 個字和辨識文字一起送到所選整理服務，只用來理解指涉與語氣。iOS 鍵盤無法讀取宿主 App 名稱，因此不會傳送 App 名稱。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("服務") {
                Picker("服務", selection: $provider) {
                    Text("Google Gemini（推薦）").tag(SmartCleanup.Provider.gemini)
                    Text("Groq").tag(SmartCleanup.Provider.groq)
                    Text("阿里雲百鍊").tag(SmartCleanup.Provider.dashscope)
                    Text("自訂（OpenAI 相容）").tag(SmartCleanup.Provider.custom)
                }
                .onChange(of: provider) { _, new in
                    SmartCleanup.provider = new
                    refresh()
                }
                if provider == .custom {
                    TextField("端點網址（…/chat/completions）", text: $customEndpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型名稱", text: $customModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }

            Section("申請免費 key") {
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
                    } label: {
                        LabeledContent("阿里雲百鍊 key", value: hasKey ? String(localized: "已設定") : String(localized: "未設定"))
                    }
                    Text("這裡不重複輸入；請到「設定」裡的阿里雲百鍊頁管理同一把 key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField(hasKey ? String(localized: "輸入新的 key 以取代") : "API key", text: $keyDraft)
                        .textContentType(nil)
                        .accessibilityIdentifier("smartKey")
                    HStack {
                        Button("儲存") {
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
                            SmartCleanup.deleteKey(for: provider)
                            message = String(localized: "已刪除。")
                            messageIsError = false
                            refresh()
                        }
                        .disabled(!hasKey)
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    Task { await test() }
                } label: {
                    if testing { ProgressView() } else { Text("測試") }
                }
                .disabled((!hasKey && !OnDeviceAssistant.onDeviceAvailable) || testing)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(messageIsError ? .red : .secondary)
                }
                if let logSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近整理：成功 \(logSummary.ok) 次、失敗 \(logSummary.failed) 次")
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

            Section {
                Toggle("用這把 key 辨識語音", isOn: $cloudASREnabled)
                    .disabled(!cloudASRAvailable)
                Button {
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
        case .custom:
            return String(localized: "文字會送到你填的端點。")
        }
    }

    private var cloudASRAvailable: Bool {
        // 自訂端點不支援雲端辨識；其他三家需要有 key 才能開。
        if provider == .custom { return false }
        if !hasKey { return false }
        return CloudASR.supports(provider)
    }

    private var cloudASRFooter: String {
        let base = String(localized: "開啟後，講完的整段錄音會用你的 key 上傳到上面選的服務重新辨識，專有名詞通常比手機內建辨識準，大約多等 1–3 秒。上傳失敗、逾時或額度用完時，自動改用手機辨識的結果。App 內聽寫若已下載「高準確度辨識」模型，會優先用手機上的模型（不上傳）。")
        let extra: String
        switch provider {
        case .gemini: extra = String(localized: "Gemini 免費版送出的錄音，Google 可能用來改進模型；在 Google Cloud 綁定付款帳戶就不會。")
        case .groq: extra = String(localized: "使用 Whisper large-v3。")
        case .dashscope: extra = String(localized: "使用 Qwen3-ASR-Flash，依用量計費。")
        case .custom: extra = String(localized: "自訂服務目前不支援雲端辨識。")
        }
        if !hasKey { return base + "\n" + String(localized: "先在上面存好 key。") }
        return base + "\n" + extra
    }

    private func refresh() {
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
        let provider = SmartCleanup.provider
        let key = SmartCleanup.key(for: provider)
        let result = await CloudASR.transcribe(samples, language: "zh-TW", hotwords: [],
                                                provider: provider, key: key)
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

    private func test() async {
        testing = true
        defer { testing = false }
        let start = Date()
        do {
            if !hasKey {
                // 沒 key：測 Apple Intelligence 裝置端整理（與實際聽寫同一條路徑）。
                guard let out = await SmartCleanup.clean(Self.sample, language: "zh-TW", timeout: 8, log: { _, _, _, _ in }) else {
                    message = String(localized: "Apple Intelligence 這次沒有產生可用結果。")
                    messageIsError = true
                    return
                }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                message = String(localized: "Apple Intelligence 裝置端可以用（\(ms) 毫秒）：\(out)")
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
