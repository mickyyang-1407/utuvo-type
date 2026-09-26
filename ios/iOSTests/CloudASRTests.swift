import XCTest
import AVFAudio
@testable import UTUVOTypeiOS

/// 雲端語音辨識的純邏輯（WAV 編碼、請求建構、解析、退路）；全部用假 transport，不打真網路、不碰真 Keychain。
final class CloudASRTests: XCTestCase {
    /// Groq 實測輸出小寫全形逗號（U+FE50）：要轉成一般「，」，否則鍵盤的自我更正會把句子切壞。
    func testSmallFormPunctuationIsNormalised() {
        XCTAssertEqual(TranscriptGuard.clean("我們禮拜三\u{FE50}不對\u{FE50}禮拜四\u{FE56}", language: "zh-TW"), "我們禮拜三，不對，禮拜四？")
        XCTAssertEqual(TranscriptGuard.clean("A\u{FE51}B\u{FE52}", language: "en-US"), "A、B。")
    }


    // MARK: - WAV 編碼

    func testWavHeaderAndPCM() {
        let data = CloudASR.wav([0, 1.5, -1])
        // RIFF header 44 bytes
        XCTAssertEqual(data.count, 44 + 6, "44 bytes header + 3 samples × 2 bytes")
        let bytes = [UInt8](data.prefix(44))
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        let chunkSize = readUInt32(bytes, at: 4)
        XCTAssertEqual(chunkSize, UInt32(36 + 6))
        XCTAssertEqual(String(bytes: bytes[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(readUInt32(bytes, at: 16), 16, "fmt size = 16 (PCM)")
        XCTAssertEqual(readUInt16(bytes, at: 20), 1, "PCM format")
        XCTAssertEqual(readUInt16(bytes, at: 22), 1, "1 channel")
        XCTAssertEqual(readUInt32(bytes, at: 24), 16_000, "sample rate")
        XCTAssertEqual(readUInt32(bytes, at: 28), 32_000, "byte rate")
        XCTAssertEqual(readUInt16(bytes, at: 32), 2, "block align")
        XCTAssertEqual(readUInt16(bytes, at: 34), 16, "bits per sample")
        XCTAssertEqual(String(bytes: bytes[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(bytes, at: 40), UInt32(6), "data length = 2 × sample count")

        let pcm = dataInt16(data.dropFirst(44))
        XCTAssertEqual(pcm, [0, 32767, -32767])
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - Groq 請求

    func testGroqRequestShape() throws {
        let samples = [Float](repeating: 0, count: 4_000)
        let wav = CloudASR.wav(samples)
        let request = try CloudASR.makeRequest(provider: .groq, key: "fake-groq-key",
                                              wav: wav, language: "zh-TW", hotwords: ["Atmos", "Pro Tools"])
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-groq-key")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertFalse(boundary.isEmpty)

        let body = try XCTUnwrap(request.httpBody)
        // body 中段是二進位的 WAV bytes，不能直接整段 UTF-8 decode。
        // 先用 WAV magic 找出檔頭尾端，再分段檢查文字部分。
        let wavRange = try XCTUnwrap(body.range(of: wav), "WAV bytes 應在 body 裡")
        let textPart = body.subdata(in: 0..<wavRange.lowerBound)
        let textString = String(data: textPart, encoding: .utf8) ?? ""
        XCTAssertTrue(textString.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        // R1-4：要比對完整值（值後面緊接 \r\n），送出 "zh-TW" 時必須紅。
        XCTAssertTrue(textString.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(textString.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(textString.contains("name=\"temperature\"\r\n\r\n0"))
        let prompt = "以下是繁體中文（台灣）的語音。常用詞：Atmos、Pro Tools"
        XCTAssertTrue(textString.contains("name=\"prompt\"\r\n\r\n\(prompt)"))
        XCTAssertTrue(textString.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(textString.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(textString.contains("Content-Type: audio/wav"))
        // 收尾 boundary 在 WAV 之後。
        let closingPart = body.subdata(in: wavRange.upperBound..<body.count)
        let closingString = String(data: closingPart, encoding: .utf8) ?? ""
        XCTAssertTrue(closingString.contains("--\(boundary)--"))
    }

    // R1-4：100 個熱詞時 prompt 必須截到 ≤200 字元，且含第一個、不含最後一個。
    func testGroqPromptTruncatesAt200CharsWith100Hotwords() throws {
        let hotwords = (1...100).map { "Term\($0)" }
        let wav = CloudASR.wav([Float](repeating: 0, count: 4_000))
        let request = try CloudASR.makeRequest(provider: .groq, key: "k", wav: wav,
                                              language: "zh-TW", hotwords: hotwords)
        let body = try XCTUnwrap(request.httpBody)
        // 整段 body 中段是二進位的 WAV bytes，不能直接整段 UTF-8 decode。
        // 先用 WAV magic 找出檔頭尾端，再從前面的文字部分抓 prompt 欄位的值。
        let wavRange = try XCTUnwrap(body.range(of: wav), "WAV bytes 應在 body 裡")
        let textPart = body.subdata(in: 0..<wavRange.lowerBound)
        let textString = String(data: textPart, encoding: .utf8) ?? ""
        let marker = "name=\"prompt\"\r\n\r\n"
        guard let valueRange = textString.range(of: marker) else {
            XCTFail("找不到 prompt 欄位"); return
        }
        let valueStart = valueRange.upperBound
        let tail = textString[valueStart...]
        guard let lineEnd = tail.range(of: "\r\n") else {
            XCTFail("prompt 值沒結束"); return
        }
        let value = String(tail[..<lineEnd.lowerBound])
        XCTAssertLessThanOrEqual(value.count, 200, "prompt 必須 ≤ 200 字元")
        XCTAssertTrue(value.contains("Term1"), "含第一個詞")
        XCTAssertFalse(value.contains("Term100"), "不含最後一個詞（已被截掉）")
    }

    // R1-2：簡中（zh-CN）Groq prompt 是簡體、不含「繁體」。
    func testGroqPromptSimplifiedForZhCN() throws {
        let wav = CloudASR.wav([Float](repeating: 0, count: 4_000))
        let request = try CloudASR.makeRequest(provider: .groq, key: "k", wav: wav,
                                              language: "zh-CN", hotwords: ["Atmos"])
        let body = try XCTUnwrap(request.httpBody)
        let wavRange = try XCTUnwrap(body.range(of: wav), "WAV bytes 應在 body 裡")
        let textPart = body.subdata(in: 0..<wavRange.lowerBound)
        let textString = String(data: textPart, encoding: .utf8) ?? ""
        XCTAssertTrue(textString.contains("简体"), "含簡體指示")
        XCTAssertFalse(textString.contains("繁體"), "不應含繁體")
    }

    // R1-2／R1-3：簡中 Gemini 指示是簡體、不含「繁體」；英文指示不含任何中文字。
    func testGeminiInstructionSimplifiedForZhCN() throws {
        let wav = CloudASR.wav([Float](repeating: 0, count: 4_000))
        let request = try CloudASR.makeRequest(provider: .gemini, key: "k", wav: wav,
                                              language: "zh-CN", hotwords: ["Atmos"])
        let body = try XCTUnwrap(request.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let instruction = try XCTUnwrap(parts.compactMap { $0["text"] as? String }.first)
        XCTAssertTrue(instruction.contains("简体"), "含簡體指示")
        XCTAssertFalse(instruction.contains("繁體"), "不應含繁體")
    }

    func testGeminiInstructionEnglishHasNoChineseChars() throws {
        let wav = CloudASR.wav([Float](repeating: 0, count: 4_000))
        let request = try CloudASR.makeRequest(provider: .gemini, key: "k", wav: wav,
                                              language: "en-US", hotwords: ["Atmos", "Pro Tools"])
        let body = try XCTUnwrap(request.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let instruction = try XCTUnwrap(parts.compactMap { $0["text"] as? String }.first)
        // R1-3：英文指示後面不該再接中文字
        let hasChinese = instruction.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
        }
        XCTAssertFalse(hasChinese, "英文指示不應含中文字：\(instruction)")
    }

    // MARK: - Gemini 請求

    func testGeminiRequestShape() throws {
        let samples = [Float](repeating: 0, count: 4_000)
        let wav = CloudASR.wav(samples)
        let request = try CloudASR.makeRequest(provider: .gemini, key: "fake-gemini-key",
                                              wav: wav, language: "zh-TW", hotwords: ["Atmos"])
        let urlString = request.url?.absoluteString ?? ""
        XCTAssertTrue(urlString.hasPrefix("https://generativelanguage.googleapis.com/v1beta/models/"))
        XCTAssertTrue(urlString.hasSuffix(":generateContent"))
        XCTAssertTrue(urlString.contains(SmartCleanup.Provider.gemini.defaultModel))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fake-gemini-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Gemini 不用 Authorization")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap((contents.first?["parts"] as? [[String: Any]]))
        let inlineData = try XCTUnwrap(parts.compactMap { $0["inline_data"] as? [String: Any] }.first)
        XCTAssertEqual(inlineData["mime_type"] as? String, "audio/wav")
        let base64 = try XCTUnwrap(inlineData["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64), wav)
        let instruction = try XCTUnwrap(parts.compactMap { $0["text"] as? String }.first)
        XCTAssertTrue(instruction.contains("繁體中文"))
        XCTAssertTrue(instruction.contains("Atmos"))
        let config = try XCTUnwrap(obj["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["temperature"] as? Int, 0)
        XCTAssertNotNil(config["thinkingConfig"])
    }

    // MARK: - 百鍊請求

    func testDashscopeRequestShape() throws {
        let samples = [Float](repeating: 0, count: 4_000)
        let wav = CloudASR.wav(samples)
        let request = try CloudASR.makeRequest(provider: .dashscope, key: "fake-dash-key",
                                              wav: wav, language: "zh-TW", hotwords: ["Atmos"])
        XCTAssertEqual(request.url?.absoluteString, SmartCleanup.Provider.dashscope.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-dash-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "qwen3-asr-flash")
        XCTAssertEqual(obj["stream"] as? Bool, false)
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "Atmos")
        let user = try XCTUnwrap(messages.last)
        let userArray = try XCTUnwrap(user["content"] as? [[String: Any]])
        let audioPart = try XCTUnwrap(userArray.first)
        XCTAssertEqual(audioPart["type"] as? String, "input_audio")
        let inner = try XCTUnwrap(audioPart["input_audio"] as? [String: Any])
        let dataURI = try XCTUnwrap(inner["data"] as? String)
        XCTAssertTrue(dataURI.hasPrefix("data:audio/wav;base64,"))
        let base64 = String(dataURI.dropFirst("data:audio/wav;base64,".count))
        XCTAssertEqual(Data(base64Encoded: base64), wav)
        let asrOptions = try XCTUnwrap(obj["asr_options"] as? [String: Any])
        XCTAssertEqual(asrOptions["language"] as? String, "zh")
        XCTAssertEqual(asrOptions["enable_itn"] as? Bool, false)
    }

    func testDashscopeOmitsSystemWhenNoHotwords() throws {
        let wav = CloudASR.wav([Float](repeating: 0, count: 4_000))
        let request = try CloudASR.makeRequest(provider: .dashscope, key: "k", wav: wav,
                                              language: "en-US", hotwords: [])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "沒有 hotwords 就沒有 system message")
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    // MARK: - parse

    func testParseGroqSuccess() throws {
        let data = #"{"text":"明天見"}"#.data(using: .utf8)!
        XCTAssertEqual(try CloudASR.parse(data, provider: .groq), "明天見")
    }

    func testParseGeminiSuccess() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"明天"},{"text":"見"}]}}]}"#
        XCTAssertEqual(try CloudASR.parse(json.data(using: .utf8)!, provider: .gemini), "明天見")
    }

    func testParseDashscopeSuccessString() throws {
        let json = #"{"choices":[{"message":{"content":"明天下午三點"}}]}"#
        XCTAssertEqual(try CloudASR.parse(json.data(using: .utf8)!, provider: .dashscope), "明天下午三點")
    }

    func testParseDashscopeSuccessArray() throws {
        let json = #"{"choices":[{"message":{"content":[{"text":"明天下午"},{"text":"三點"}]}}]}"#
        XCTAssertEqual(try CloudASR.parse(json.data(using: .utf8)!, provider: .dashscope), "明天下午三點")
    }

    func testParseMalformedThrows() {
        XCTAssertThrowsError(try CloudASR.parse("not json".data(using: .utf8)!, provider: .groq))
        XCTAssertThrowsError(try CloudASR.parse(#"{"choices":[]}"#.data(using: .utf8)!, provider: .dashscope))
    }

    // MARK: - 失敗退路

    func testTranscribeReturnsNilOnHTTP401_429_500() async {
        for status in [401, 429, 500] {
            let transport: SmartCleanup.Transport = { _ in
                let data = "{}".data(using: .utf8) ?? Data()
                let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
            let result = await CloudASR.transcribe([Float](repeating: 0, count: 4_000), language: "zh-TW",
                                                   hotwords: [], provider: .groq, key: "k",
                                                   transport: transport, log: noLog)
            XCTAssertNil(result, "HTTP \(status) 應走 Apple 結果")
        }
    }

    func testTranscribeReturnsNilOnTransportTimeout() async {
        let transport: SmartCleanup.Transport = { _ in throw URLError(.timedOut) }
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 4_000), language: "zh-TW",
                                               hotwords: [], provider: .groq, key: "k",
                                               transport: transport, log: noLog)
        XCTAssertNil(result)
    }

    func testTranscribeReturnsNilWhenTransportExceedsBudget() async {
        // 30 秒錄音 → timeLimit(30) = min(6, 2.5 + 6) = 6 秒
        let transport: SmartCleanup.Transport = { _ in
            try? await Task.sleep(for: .seconds(7))
            let data = #"{"text":"晚了"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let start = Date()
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 16_000 * 30),
                                               language: "zh-TW", hotwords: [],
                                               provider: .groq, key: "k",
                                               transport: transport, log: noLog)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 6.5, "預算 6 秒，逾時回 nil 應在 6.5 秒內")
    }

    func testTranscribeRejectsLoopingOutput() async {
        let looping = "有 T O V O " + String(repeating: "T O ", count: 40)
        let escaped = looping.replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"{"text":"\#(escaped)"}"#
        let transport: SmartCleanup.Transport = { _ in
            let data = json.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 4_000), language: "zh-TW",
                                               hotwords: [], provider: .groq, key: "k",
                                               transport: transport, log: noLog)
        XCTAssertNil(result, "迴圈文字應回 nil")
    }

    func testTranscribeRejectsEmptyOutput() async {
        let transport: SmartCleanup.Transport = { _ in
            let data = #"{"text":"   "}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 4_000), language: "zh-TW",
                                               hotwords: [], provider: .groq, key: "k",
                                               transport: transport, log: noLog)
        XCTAssertNil(result)
    }

    // MARK: - Gemini 400 retry

    func testGeminiRetriesWithoutThinkingConfigOn400() async throws {
        let counter = CallCounter()
        let transport: SmartCleanup.Transport = { req in
            let n = counter.next()
            if n == 0 {
                let response = HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com")!,
                                                statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
            let json = #"{"candidates":[{"content":{"parts":[{"text":"辨識結果"}]}}]}"#
            let response = HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com")!,
                                            statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response)
        }
        let captured = RequestCollector()
        let capturingTransport: SmartCleanup.Transport = { req in
            captured.add(req)
            return try await transport(req)
        }
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 4_000), language: "zh-TW",
                                               hotwords: [], provider: .gemini, key: "k",
                                               transport: capturingTransport, log: noLog)
        XCTAssertEqual(result, "辨識結果")
        let requests = captured.snapshot()
        XCTAssertEqual(requests.count, 2)
        let secondBody = try XCTUnwrap(requests[1].httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let config = try XCTUnwrap(obj["generationConfig"] as? [String: Any])
        XCTAssertNil(config["thinkingConfig"], "第二次重送不應帶 thinkingConfig")
        XCTAssertEqual(config["temperature"] as? Int, 0)
    }

    // MARK: - 長度門檻

    func testTranscribeSkipsTransportWhenTooShort() async {
        let holder = BoolHolder()
        let transport: SmartCleanup.Transport = { _ in
            holder.set(true)
            let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        // 0.2 秒 < 0.25 秒
        let result = await CloudASR.transcribe([Float](repeating: 0, count: Int(0.2 * 16_000)),
                                               language: "zh-TW", hotwords: [],
                                               provider: .groq, key: "k",
                                               transport: transport, log: noLog)
        XCTAssertNil(result)
        XCTAssertFalse(holder.get())
    }

    func testTranscribeSkipsTransportWhenDashscopeTooLong() async {
        let holder = BoolHolder()
        let transport: SmartCleanup.Transport = { _ in
            holder.set(true)
            let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        // 211 秒 > 百鍊 210 秒上限
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 16_000 * 211),
                                               language: "zh-TW", hotwords: [],
                                               provider: .dashscope, key: "k",
                                               transport: transport, log: noLog)
        XCTAssertNil(result)
        XCTAssertFalse(holder.get())
    }

    // MARK: - 繁中簡轉繁

    func testTranscribeSimplifiedToTraditionalForZhTW() async {
        let transport: SmartCleanup.Transport = { _ in
            let data = #"{"text":"麻烦你把授权金钥寄到我的信箱"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let result = await CloudASR.transcribe([Float](repeating: 0, count: 4_000), language: "zh-TW",
                                               hotwords: [], provider: .groq, key: "k",
                                               transport: transport, log: noLog)
        XCTAssertEqual(result, "麻煩你把授權金鑰寄到我的信箱")
    }

    // MARK: - 純函式與選擇器

    func testSupports() {
        XCTAssertTrue(CloudASR.supports(.gemini))
        XCTAssertTrue(CloudASR.supports(.groq))
        XCTAssertTrue(CloudASR.supports(.dashscope))
        XCTAssertFalse(CloudASR.supports(.custom))
    }

    func testLanguageCode() {
        XCTAssertEqual(CloudASR.languageCode(for: "zh-TW"), "zh")
        XCTAssertEqual(CloudASR.languageCode(for: "zh-Hans"), "zh")
        XCTAssertEqual(CloudASR.languageCode(for: "en-US"), "en")
        XCTAssertNil(CloudASR.languageCode(for: "ja-JP"))
        XCTAssertNil(CloudASR.languageCode(for: ""))
    }

    func testTimeLimit() {
        XCTAssertEqual(CloudASR.timeLimit(seconds: 0), 2.5)
        XCTAssertEqual(CloudASR.timeLimit(seconds: 10), 4.5)
        XCTAssertEqual(CloudASR.timeLimit(seconds: 60), 6)
        XCTAssertEqual(CloudASR.timeLimit(seconds: 1_000), 6, "上限 6 秒")
    }

    func testRerecognitionChooseTruthTable() {
        XCTAssertEqual(Rerecognition.choose(qwenReady: false, cloudReady: false), .none)
        XCTAssertEqual(Rerecognition.choose(qwenReady: true, cloudReady: false), .localQwen)
        XCTAssertEqual(Rerecognition.choose(qwenReady: false, cloudReady: true), .cloud)
        XCTAssertEqual(Rerecognition.choose(qwenReady: true, cloudReady: true), .localQwen)
    }

    func testEnabledPreferenceDefaultsFalseWithIsolatedSuite() {
        let suite = UserDefaults(suiteName: "cloud-asr-enabled-\(UUID().uuidString)")!
        XCTAssertFalse(CloudASR.enabledPreference(suite))
        suite.set(true, forKey: CloudASR.enabledKey)
        XCTAssertTrue(CloudASR.enabledPreference(suite))
    }
}

private func dataInt16(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { raw -> [Int16] in
        let count = raw.count / MemoryLayout<Int16>.size
        let buffer = raw.bindMemory(to: Int16.self)
        return Array(UnsafeBufferPointer(start: buffer.baseAddress, count: count))
    }
}

/// 預設 log 太吵（寫 App Group），測試關掉。
private let noLog: CloudASR.Log = { _, _, _, _, _, _ in }

private final class BoolHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count - 1
    }
}

private final class RequestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) {
        lock.lock(); requests.append(request); lock.unlock()
    }
    func snapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}
