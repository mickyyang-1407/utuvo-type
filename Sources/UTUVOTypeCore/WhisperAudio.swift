import Foundation

/// Groq Whisper 雲端辨識的純函式部分（WAV、剪安靜段、請求、解析），iOS／Android 已上線的那份原封不動搬來，
/// 讓 Mac 共用同一份（2026-10-19）。iOS `CloudASR` 轉呼叫這裡；網路、key、預算各平台自己管。
public enum WhisperAudio {
    public static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    public static let groqModel = "whisper-large-v3"
    /// iOS 切段用的門檻（20 ms 一格的峰值）；`trimSilence` 預設也用它。
    public static let silenceThreshold: Float = 0.012

    /// 兩段語音指示（zh 與 en）共用這個語言代碼；其他語言回 nil＝不用雲端。
    public static func languageCode(for language: String) -> String? {
        if language.hasPrefix("zh") { return "zh" }
        if language.hasPrefix("en") { return "en" }
        return nil
    }

    /// zh-Hant／zh-HK／zh-TW 是繁體；其餘 zh（zh-Hans／zh-CN 等）走簡體。
    public static func isSimplifiedChinese(_ language: String) -> Bool {
        let lower = language.lowercased()
        guard lower.hasPrefix("zh") else { return false }
        if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") { return false }
        return true
    }

    /// 整段（含重送）的單調預算：2.5 秒起，每秒錄音加 0.2 秒，上限 6 秒。
    public static func timeLimit(seconds: Double) -> Double {
        min(6, 2.5 + 0.2 * seconds)
    }

    /// 頭尾的安靜段剪掉、各留 0.3 秒：講完到按停止之間的底噪，是 Whisper 補「謝謝大家收看」的主要來源。
    /// 20 ms 一格、峰值 < `threshold` 算安靜；整段都沒聲音就原樣回傳。
    public static func trimSilence(_ samples: [Float], sampleRate: Int = 16_000, keepSeconds: Double = 0.3,
                                   threshold: Float = silenceThreshold) -> [Float] {
        let frame = sampleRate / 50
        guard samples.count > frame * 2 else { return samples }
        func loud(_ i: Int) -> Bool {
            let end = min(samples.count, i + frame)
            var peak: Float = 0
            for j in i..<end { peak = max(peak, abs(samples[j])) }
            return peak >= threshold
        }
        var first = 0
        while first < samples.count, !loud(first) { first += frame }
        guard first < samples.count else { return samples }
        var last = ((samples.count - 1) / frame) * frame
        while last > first, !loud(last) { last -= frame }
        let keep = Int(keepSeconds * Double(sampleRate))
        let lo = max(0, first - keep), hi = min(samples.count, last + frame + keep)
        return (lo == 0 && hi == samples.count) ? samples : Array(samples[lo..<hi])
    }

    // MARK: - WAV（44 bytes 標頭＋16-bit PCM LE 單聲道）

    public static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        // RIFF chunk descriptor
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        appendLE(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        // fmt sub-chunk（PCM，size = 16）
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)               // PCM
        appendLE(UInt16(1), to: &data)               // mono
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(sampleRate * 2), to: &data)   // byte rate
        appendLE(UInt16(2), to: &data)               // block align
        appendLE(UInt16(16), to: &data)              // bits per sample
        // data sub-chunk
        data.append(contentsOf: [UInt8]("data".utf8))
        appendLE(dataSize, to: &data)
        // PCM：先夾到 [-1, 1]，再 ×32767 取整數。
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            appendLE(value, to: &data)
        }
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    // MARK: - Groq 請求／解析

    /// `context`＝前一段的辨識結果（邊錄邊傳）；nil＝整段一次送。
    public static func groqRequest(key: String, wav: Data, language: String, hotwords: [String],
                                   context: String? = nil) -> URLRequest {
        let boundary = "----UTUVOCloudASR\(UUID().uuidString)"
        var request = URLRequest(url: groqEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let langCode = languageCode(for: language) ?? "zh"
        let prompt = groqPrompt(originalLanguage: language, hotwords: hotwords, context: context)
        var body = Data()
        appendField("model", groqModel, boundary: boundary, to: &body)
        appendField("language", langCode, boundary: boundary, to: &body)
        appendField("response_format", "json", boundary: boundary, to: &body)
        appendField("temperature", "0", boundary: boundary, to: &body)
        appendField("prompt", prompt, boundary: boundary, to: &body)
        // file part（filename 固定 audio.wav，Content-Type audio/wav）
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav)
        body.append(contentsOf: "\r\n".utf8)
        body.append(contentsOf: "--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }

    /// 簡中使用者要簡體版的指示。zh-TW／zh-Hant／zh-HK＝繁體；其他 zh（zh-CN、zh-Hans）＝簡體。
    public static func groqPrompt(originalLanguage: String, hotwords: [String], context: String? = nil) -> String {
        let prefix: String
        let separator: String
        if isSimplifiedChinese(originalLanguage) {
            prefix = "以下是简体中文的语音。常用词："
            separator = "、"
        } else if originalLanguage.lowercased().hasPrefix("zh") {
            prefix = "以下是繁體中文（台灣）的語音。常用詞："
            separator = "、"
        } else {
            prefix = "Vocabulary: "
            separator = ", "
        }
        let maxTotal = 200
        var words: [String] = []
        var current = prefix.count
        for word in hotwords {
            let add = (words.isEmpty ? 0 : separator.count) + word.count
            if current + add > maxTotal { break }
            words.append(word)
            current += add
        }
        var prompt = prefix + words.joined(separator: separator)
        // 邊錄邊傳：前一段的辨識結果當上下文（Whisper prompt），避免斷句處用字不一致。
        if let context, !context.isEmpty {
            prompt += "\n" + context
        }
        return prompt
    }

    private static func appendField(_ name: String, _ value: String, boundary: String, to data: inout Data) {
        data.append(contentsOf: "--\(boundary)\r\n".utf8)
        data.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
        data.append(contentsOf: "\(value)\r\n".utf8)
    }

    /// Groq 回 `{"text": …}`；格式不對回 nil。
    public static func parseGroq(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["text"] as? String
    }
}

/// Whisper 類重辨識的幻覺把關（iOS `TranscriptGuard` 搬來的純字串規則，Mac 共用）。
public enum WhisperHallucination {
    /// Whisper 在安靜的尾巴會自己補影片字幕的結尾句（2026-10-18 Micky 實機：每段後面都多一句「謝謝大家收看！」）。
    /// 比對前去掉空白標點、英文轉小寫。只認字幕腔的整句，「謝謝大家」這種平常也會講的不算。
    public static let outroPhrases: [String] = [
        "謝謝大家收看", "谢谢大家收看", "謝謝收看", "谢谢收看", "感謝收看", "感谢收看", "感謝您的收看", "感谢您的收看",
        "謝謝觀看", "谢谢观看", "謝謝大家觀看", "谢谢大家观看", "感謝觀看", "感谢观看", "感謝您的觀看", "感谢您的观看",
        "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目", "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "字幕由amaraorg社群提供", "字幕由amaraorg社区提供", "字幕by索兰娅", "字幕by索蘭婭",
        "優優獨播劇場yoyotelevisionseriesexclusive", "优优独播剧场yoyotelevisionseriesexclusive",
        "請訂閱我的頻道", "请订阅我的频道", "歡迎訂閱我的頻道", "欢迎订阅我的频道", "記得訂閱", "记得订阅",
        "thanksforwatching", "thankyouforwatching", "thankyouverymuchforwatching", "pleasesubscribe",
        "subtitlesbytheamaraorgcommunity",
    ]

    /// 去掉尾端（可連續好幾句）與整段都是字幕結尾句的幻覺。`reference`＝同一段錄音的裝置端逐字稿：
    /// 裝置端也聽到這句＝使用者真的講了（例如錄教學影片），就不動。全部被去掉回空字串。
    public static func dropOutro(_ text: String, reference: String? = nil) -> String {
        func key(_ s: Substring) -> String {
            String(s.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }).lowercased()
        }
        let heard = reference.map { key(Substring($0)) } ?? ""
        var out = Substring(text)
        var changed = true
        while changed {
            changed = false
            let tail = key(out)
            for phrase in outroPhrases where tail.hasSuffix(phrase) && !heard.contains(phrase) {
                // 從尾巴往回吃掉 phrase 對應的字（句尾與中間的空白標點一起吃；phrase 前面那句的句號留著）。
                var need = phrase.count
                var cut = out.endIndex
                while need > 0, cut > out.startIndex {
                    cut = out.index(before: cut)
                    let c = out[cut]
                    if !(c.isWhitespace || c.isPunctuation || c.isSymbol) { need -= 1 }
                }
                out = out[..<cut]
                changed = true
                break
            }
        }
        return out == Substring(text) ? text : String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Groq Whisper 的中文常輸出 Unicode「小寫」標點（﹐ U+FE50 等）→ 一般全形標點，後面的規則才認得。
    public static func normalizeSmallFormPunctuation(_ text: String) -> String {
        String(text.map { smallFormPunctuation[$0] ?? $0 })
    }

    private static let smallFormPunctuation: [Character: Character] = [
        "\u{FE50}": "，", "\u{FE51}": "、", "\u{FE52}": "。", "\u{FE54}": "；",
        "\u{FE55}": "：", "\u{FE56}": "？", "\u{FE57}": "！",
    ]

    /// 解碼迴圈（Mac 60 段實測：熱詞偶爾讓模型卡在「T O T O …」）：同一個 1–8 字單位連續 8 次以上，
    /// 或字數遠超過人能講的量（每秒 12 字）。
    public static func looksLooping(_ text: String, seconds: Double) -> Bool {
        if text.count > max(80, Int(seconds * 12)) { return true }
        return text.range(of: #"(.{1,8}?)(?:\s*\1){7,}"#, options: .regularExpression) != nil
    }
}
