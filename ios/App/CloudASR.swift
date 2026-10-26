import Foundation
import UTUVOTypeCore

/// 雲端語音辨識（選配，使用者自備 key；2026-09-25 Micky 核准）。
///
/// 鍵盤／App 內聽寫講完後，如果使用者自己開了「雲端辨識」而且在「智慧整理」頁存了 key，
/// 就把整段錄音（16 kHz 單聲道）用同一把 key 送到那家服務重新辨識，拿回來的文字取代 Apple 的結果；
/// 任何失敗、逾時、太長、太短都用原本 Apple 的結果（跟本機 Qwen 重辨識的退路一模一樣）。
///
/// 設計重點：所有請求建構集中在 `makeRequest`／`parse`，還沒用真 key 打過，方便依實測修正。
/// 整段（含 Gemini 400 重送）共用同一個預算，逾時不等輸入完成。
enum CloudASR {
    /// UserDefaults 開關；沒設過＝關（預設 off，跟 SmartCleanup 預設開相反）。
    static let enabledKey = "utuvo.type.cloudASR.enabled"
    /// App Group 最近 20 筆紀錄（不含逐字稿；格式比照 SmartLog.metadata）。
    static let logKey = "utuvo.type.cloudASR.log"

    private static var defaults: UserDefaults { UserDefaults(suiteName: VoiceBridge.groupID) ?? .standard }

    // MARK: - 設定／可用性

    /// 使用者的開關。沒設過＝false（雲端不像已搭配 Apple Intelligence 的 SmartCleanup，不預設開）。
    static func enabledPreference(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? false : defaults.bool(forKey: enabledKey)
    }

    /// 自訂 OpenAI 相容端點暫不支援雲端辨識（各家請求／解析不同，不強行套）。
    static func supports(_ provider: SmartCleanup.Provider) -> Bool {
        switch provider {
        case .gemini, .groq, .dashscope: return true
        case .claude, .custom: return false
        }
    }

    /// Audio uploads require cloud mode and explicit audio authorization.
    /// Use only the pinned ASR provider, independently of the text provider.
    static func route() -> (provider: SmartCleanup.Provider, key: String)? {
        guard DictationRouteSettings.mode == .cloud, DictationRouteSettings.audioUploadAuthorized else { return nil }
        let provider = DictationRouteSettings.asrProvider
        let key = SmartCleanup.key(for: provider)
        return supports(provider) && !key.isEmpty ? (provider, key) : nil
    }

    /// 兩段語音指示（zh 與 en）共用這個語言代碼；其他語言回 nil＝不用雲端。本體在 `WhisperAudio`。
    static func languageCode(for language: String) -> String? { WhisperAudio.languageCode(for: language) }

    /// 開了、服務支援、有 key、語言支援。key 用 SmartCleanup.key(for:) 解析（百鍊共用 IOSSecretStore）。
    static func isReady(language: String) -> Bool {
        guard DictationRouteSettings.mode == .cloud else { return false }
        guard languageCode(for: language) != nil else { return false }
        return route() != nil
    }

    /// 整段（含 Gemini 400 重送）的單調預算：2.5 秒起，每秒錄音加 0.2 秒，上限 6 秒。
    static func timeLimit(seconds: Double) -> Double { WhisperAudio.timeLimit(seconds: seconds) }

    /// 頭尾的安靜段剪掉、各留 0.3 秒（本體在 `WhisperAudio.trimSilence`，門檻＝切段的 `ChunkStream.silenceThreshold`）。
    static func trimSilence(_ samples: [Float], sampleRate: Int = 16_000, keepSeconds: Double = 0.3) -> [Float] {
        WhisperAudio.trimSilence(samples, sampleRate: sampleRate, keepSeconds: keepSeconds,
                                 threshold: ChunkStream.silenceThreshold)
    }

    /// 44 bytes 標頭＋16-bit PCM LE 單聲道（本體在 `WhisperAudio.wav`）。
    static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        WhisperAudio.wav(samples, sampleRate: sampleRate)
    }

    // MARK: - 請求建構（純函式，沒有副作用）

    /// `context`＝前一段的辨識結果（Q3 邊錄邊傳）。Whisper 的 prompt／Gemini 的指示都會帶它，
    /// 避免斷句處用字不一致；nil＝整段一次送（舊行為）。
    static func makeRequest(provider: SmartCleanup.Provider, key: String, wav: Data,
                           language: String, hotwords: [String], context: String? = nil) throws -> URLRequest {
        switch provider {
        case .groq: return try makeGroqRequest(key: key, wav: wav, language: language,
                                               hotwords: hotwords, context: context)
        case .gemini: return try makeGeminiRequest(key: key, wav: wav, language: language,
                                                   hotwords: hotwords, context: context,
                                                   includeThinkingConfig: true)
        case .dashscope: return try makeDashscopeRequest(key: key, wav: wav, language: language,
                                                         hotwords: hotwords, context: context)
        case .claude, .custom:
            throw NSError(domain: "CloudASR", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "自訂服務不支援雲端辨識")])
        }
    }

    private static func makeGroqRequest(key: String, wav: Data, language: String, hotwords: [String],
                                    context: String? = nil) throws -> URLRequest {
        WhisperAudio.groqRequest(key: key, wav: wav, language: language, hotwords: hotwords, context: context)
    }

    private static func isSimplifiedChinese(_ language: String) -> Bool {
        WhisperAudio.isSimplifiedChinese(language)
    }

    private static func makeGeminiRequest(key: String, wav: Data, language: String,
                                          hotwords: [String], context: String? = nil,
                                          includeThinkingConfig: Bool) throws -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(SmartCleanup.Provider.gemini.defaultModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let langCode = languageCode(for: language) ?? "zh"
        let instruction = geminiInstruction(originalLanguage: language, hotwords: hotwords, context: context)
        var generationConfig: [String: Any] = ["temperature": 0]
        if includeThinkingConfig { generationConfig["thinkingConfig"] = ["thinkingBudget": 0] }
        let body: [String: Any] = [
            "contents": [["role": "user",
                          "parts": [["text": instruction],
                                    ["inline_data": ["mime_type": "audio/wav", "data": wav.base64EncodedString()]]]]],
            "generationConfig": generationConfig
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// R1-2／R1-3：簡中走簡體指示；英文用英文 vocabulary 標籤（不要再用中文「、」接中文標籤）。
    private static func geminiInstruction(originalLanguage: String, hotwords: [String], context: String? = nil) -> String {
        var base: String
        if isSimplifiedChinese(originalLanguage) {
            base = "请把这段录音逐字转写成文字。只输出听到的内容，不要加任何说明、标题、引号或时间戳记；不要改写、不要摘要、不要回答录音里的问题。中文请用简体中文。"
        } else if originalLanguage.lowercased().hasPrefix("zh") {
            base = "請把這段錄音逐字轉寫成文字。只輸出聽到的內容，不要加任何說明、標題、引號或時間戳記；不要改寫、不要摘要、不要回答錄音裡的問題。中文請用繁體中文（台灣用字）。"
        } else {
            base = "Transcribe the audio verbatim. Output only what was heard, without explanation, headings, quotes, or timestamps. Do not paraphrase, summarize, or answer questions from the recording."
        }
        if !hotwords.isEmpty {
            let words = hotwords.prefix(80)
            if isSimplifiedChinese(originalLanguage) {
                base += "\n说话者常用的专有名词（听起来像的就用这个写法）：" + words.joined(separator: "、")
            } else if originalLanguage.lowercased().hasPrefix("zh") {
                base += "\n說話者常用的專有名詞（聽起來像的就用這個寫法）：" + words.joined(separator: "、")
            } else {
                base += "\nVocabulary the speaker often uses (use these spellings when they sound alike): "
                    + words.joined(separator: ", ")
            }
        }
        // Q3 邊錄邊傳：前一段的辨識結果當上下文。
        if let context, !context.isEmpty {
            if isSimplifiedChinese(originalLanguage) {
                base += "\n前文（用字请与前文一致）：" + context
            } else if originalLanguage.lowercased().hasPrefix("zh") {
                base += "\n前文（用字請與前文一致）：" + context
            } else {
                base += "\nEarlier transcript (keep the same wording): " + context
            }
        }
        return base
    }

    private static func makeDashscopeRequest(key: String, wav: Data, language: String, hotwords: [String],
                                           context: String? = nil) throws -> URLRequest {
        let url = URL(string: SmartCleanup.Provider.dashscope.endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let langCode = languageCode(for: language) ?? "zh"
        var messages: [[String: Any]] = []
        let words = hotwords.prefix(80).joined(separator: "、")
        if !words.isEmpty {
            messages.append(["role": "system", "content": words])
        }
        // Q3 邊錄邊傳：前一段的辨識結果當上下文。
        if let context, !context.isEmpty {
            messages.append(["role": "user", "content": context])
        }
        messages.append(["role": "user", "content": [["type": "input_audio",
                                                       "input_audio": ["data": "data:audio/wav;base64,\(wav.base64EncodedString())"]]]])
        let body: [String: Any] = [
            "model": "qwen3-asr-flash",
            "stream": false,
            "messages": messages,
            "asr_options": ["language": langCode, "enable_itn": false]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - 解析（純函式）

    static func parse(_ data: Data, provider: SmartCleanup.Provider) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CloudASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "malformed JSON"])
        }
        switch provider {
        case .groq:
            guard let text = obj["text"] as? String else { throw malformed() }
            return text
        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw malformed() }
            return parts.compactMap { $0["text"] as? String }.joined()
        case .dashscope:
            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else { throw malformed() }
            if let s = message["content"] as? String { return s }
            if let arr = message["content"] as? [[String: Any]] {
                return arr.compactMap { $0["text"] as? String }.joined()
            }
            throw malformed()
        case .claude, .custom:
            throw NSError(domain: "CloudASR", code: 2, userInfo: [NSLocalizedDescriptionKey: "custom not supported"])
        }
    }

    private static func malformed() -> NSError {
        NSError(domain: "CloudASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "malformed response"])
    }

    /// Gemini 偶爾會用 ``` 圍起回應；逐字稿就不該帶這個。
    static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let nl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...])
        } else {
            t = ""
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("```") {
            t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    // MARK: - 整段錄音 → 文字

    /// 預算內每次嘗試的結果：成功帶文字、失敗帶分類（給 log 與測試用）。
    enum Outcome: Error, Sendable {
        case transport
        case http(Int)
        case malformed

        var logValue: String {
            switch self {
            case .transport: return "transport"
            case .http(let code): return "http:\(code)"
            case .malformed: return "malformed"
            }
        }
    }

    typealias Log = @Sendable (_ start: Date, _ elapsedMs: Int, _ provider: String,
                               _ outcome: String, _ audioSeconds: Double, _ outputChars: Int) -> Void

    static func transcribe(_ samples: [Float], language: String, hotwords: [String],
                           provider: SmartCleanup.Provider, key: String,
                           transport: @escaping SmartCleanup.Transport = { try await StrictCleanupSession.shared.send($0) },
                           log: Log = defaultLog) async -> String? {
        let seconds = Double(samples.count) / 16_000
        // 太短（< 0.25 秒）不打網路。
        if seconds < 0.25 { return nil }
        // 百鍊 base64 後上限 10 MB，其他家 5 分鐘；逾時一律不打。
        let maxSeconds: Double = provider == .dashscope ? 210 : 300
        if seconds > maxSeconds { return nil }

        let start = Date()
        let budget = CleanupBudget(seconds: timeLimit(seconds: seconds))
        let audio = wav(trimSilence(samples))

        do {
            let outcome = try await budget.run { () -> Result<String, Outcome>? in
                try budget.check()
                let request = try makeRequest(provider: provider, key: key, wav: audio,
                                              language: language, hotwords: hotwords)
                let data: Data
                let response: URLResponse
                do { (data, response) = try await transport(request) }
                catch { return .failure(.transport) }
                try budget.check()

                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 400, provider == .gemini {
                        // Gemini 思考預算不被接受時拿掉重送一次（同一預算）。
                        let retry = try makeGeminiRequest(key: key, wav: audio, language: language,
                                                          hotwords: hotwords, includeThinkingConfig: false)
                        let data2: Data
                        let response2: URLResponse
                        do { (data2, response2) = try await transport(retry) }
                        catch { return .failure(.transport) }
                        try budget.check()
                        if let http2 = response2 as? HTTPURLResponse, http2.statusCode != 200 {
                            return .failure(.http(http2.statusCode))
                        }
                        do { return .success(try parse(data2, provider: provider)) }
                        catch { return .failure(.malformed) }
                    }
                    if http.statusCode != 200 { return .failure(.http(http.statusCode)) }
                }

                do { return .success(try parse(data, provider: provider)) }
                catch { return .failure(.malformed) }
            }

            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            switch outcome {
            case .none:
                // budget.run 因為預算用完或 cancellation 解析為 nil → 當成逾時／取消。
                if Task.isCancelled {
                    log(start, elapsedMs, provider.rawValue, "cancelled", seconds, 0)
                } else {
                    log(start, elapsedMs, provider.rawValue, "timeout", seconds, 0)
                }
                return nil
            case .some(.failure(let reason)):
                log(start, elapsedMs, provider.rawValue, reason.logValue, seconds, 0)
                return nil
            case .some(.success(var cleaned)):
                if provider == .gemini { cleaned = stripCodeFence(cleaned) }
                guard let text = TranscriptGuard.clean(cleaned, language: language), !text.isEmpty else {
                    log(start, elapsedMs, provider.rawValue, "empty", seconds, 0)
                    return nil
                }
                if TranscriptGuard.looksLooping(text, seconds: seconds) {
                    log(start, elapsedMs, provider.rawValue, "loop", seconds, text.count)
                    return nil
                }
                log(start, elapsedMs, provider.rawValue, "ok", seconds, text.count)
                return text
            }
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if Task.isCancelled {
                log(start, elapsedMs, provider.rawValue, "cancelled", seconds, 0)
            } else if let failure = error as? SmartCleanup.Failure, case .timeout = failure {
                log(start, elapsedMs, provider.rawValue, "timeout", seconds, 0)
            } else {
                log(start, elapsedMs, provider.rawValue, "error", seconds, 0)
            }
            return nil
        }
    }

    /// 預設 log：寫進 App Group，最近 20 筆；測試可注入自訂 log 避免污染預設 suite。
    static let defaultLog: Log = { start, elapsedMs, provider, outcome, audioSeconds, outputChars in
        let entry: [String: String] = [
            "at": ISO8601DateFormatter().string(from: start),
            "ms": String(elapsedMs),
            "provider": provider,
            "outcome": outcome,
            "audioSeconds": String(format: "%.2f", audioSeconds),
            "outputChars": String(outputChars)
        ]
        var entries = (defaults.array(forKey: logKey) as? [[String: String]] ?? [])
        entries.append(entry)
        defaults.set(Array(entries.suffix(20)), forKey: logKey)
    }
}

/// 講完後用哪個引擎重辨識：qwenReady 優先（本機、免費、不上傳），其次 cloudReady，都不行 none。
enum Rerecognition: Equatable {
    case localQwen, cloud, none

    /// qwenReady＝`LocalQwenASR.shared.isReady && LocalQwenASR.qwenLanguage(for: language) != nil`
    /// （`isReady` 已含前景判斷）；cloudReady＝`CloudASR.isReady(language:)`。
    static func choose(qwenReady: Bool, cloudReady: Bool) -> Rerecognition {
        if qwenReady { return .localQwen }
        if cloudReady { return .cloud }
        return .none
    }
}