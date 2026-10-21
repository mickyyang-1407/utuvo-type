import Foundation

/// 雲端辨識「邊錄邊傳」：Groq 只收整段檔案，不能真的串流，但它很快（實測講完後 0.51 秒中位／27 秒音檔）。
/// 所以錄音中偵測到停頓就把那一段先送去辨識、背景並行，講完時只送最後一段，再把各段結果依序接起來。
///
/// 這裡只放純邏輯（切段、接段去重、上下文 prompt、走哪一條），不打網路；
/// 真正的傳送在 `ChunkedASR.transcribeChunked`。Android 的同名檔 `ChunkedASR.kt` 是逐條對應的移植，
/// 兩邊用同一組測試案例（`ios/iOSTests/ChunkedASRTests.swift`／`android/.../ChunkedAsrChunkedTest.kt`）。

// MARK: - 切段

/// 錄音中累積樣本、偵測停頓、把已講完的段落交出去。
///
/// 規則（2026-10-14）：
/// - 停頓 ≥ `minSilenceSeconds`（0.6 秒）且這一段已經講滿 `minSegmentSeconds`（3 秒）才切；
/// - 相鄰兩段音訊重疊 `overlapSeconds`（0.3 秒），接文字時才去得掉重複；
/// - 一次聽寫最多 `maxChunks`（6）段：Groq 免費額度有每分鐘請求數限制，超過就把尾巴併進最後一段。
final class ChunkStream: @unchecked Sendable {
    /// 已完成的一段：樣本索引，`end` 為 exclusive。索引是「所有 push 進來的樣本接起來的絕對位置」。
    struct Cut: Equatable, Sendable {
        let start: Int
        let end: Int
    }

    static let sampleRate = 16_000
    static let maxChunks = 6
    static let minSilenceSeconds = 0.6
    static let minSegmentSeconds = 3.0
    static let overlapSeconds = 0.3
    /// 低於這個值算靜音（20 ms 視窗的峰值）。實麥克風底噪約 0.005～0.02，講話時峰值遠高於此。
    static let silenceThreshold: Float = 0.012
    /// 尾巴短到這個長度就不值得打網路（＝`transcribeSegment` 的 0.25 秒下限，兩邊同一組值）。
    ///
    /// 2026-10-14（Q3-repair1 review-agy ①）：這裡原本是 0.6 秒，於是「好。」「謝謝」這種
    /// 很短的結尾整段被丟掉（`ChunkStream.finish` 回 nil，連帶 `LiveCloudASR.finish` 也不送），
    /// 使用者講的最後一句不見。既然 `transcribeSegment` 本來就擋 < 0.25 秒，這裡再高一階只是
    /// 白白吃掉字，兩邊都收斂到 0.25。
    static let minChunkSeconds = 0.25

    private let lock = NSLock()
    private let sampleRate: Int
    private let maxChunks: Int
    private let minSilenceSeconds: Double
    private let minSegmentSeconds: Double
    private let overlapSeconds: Double
    private let silenceThreshold: Float
    private let frameSamples: Int          // 分析視窗（20 ms）
    private let silenceFramesNeeded: Int
    private let minSegmentSamples: Int
    private let overlapSamples: Int

    private var buffer: [Float] = []       // 只留「還沒切掉」的尾巴，記憶體不隨錄音長度成長
    private var base = 0                   // buffer[0] 對應的絕對索引
    private var framePos = 0               // 尚未分析的樣本起點（buffer 內索引）
    private var silenceFrames = 0
    private var segmentStart = 0           // 目前這一段的絕對起點
    private var emitted = 0
    private var closed = false

    init(sampleRate: Int = ChunkStream.sampleRate,
         maxChunks: Int = ChunkStream.maxChunks,
         minSilenceSeconds: Double = ChunkStream.minSilenceSeconds,
         minSegmentSeconds: Double = ChunkStream.minSegmentSeconds,
         overlapSeconds: Double = ChunkStream.overlapSeconds,
         silenceThreshold: Float = ChunkStream.silenceThreshold) {
        self.sampleRate = sampleRate
        self.maxChunks = maxChunks
        self.minSilenceSeconds = minSilenceSeconds
        self.minSegmentSeconds = minSegmentSeconds
        self.overlapSeconds = overlapSeconds
        self.silenceThreshold = silenceThreshold
        frameSamples = max(1, Int(Double(sampleRate) * 0.02))
        silenceFramesNeeded = max(1, Int((minSilenceSeconds / 0.02).rounded(.up)))
        minSegmentSamples = Int(minSegmentSeconds * Double(sampleRate))
        overlapSamples = Int(overlapSeconds * Double(sampleRate))
    }

    /// 丟進新錄到的樣本；回傳「這一次已經講完、可以先送去辨識」的段（最後還在講的那段不在裡面）。
    func push(_ samples: [Float]) -> [Cut] {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        var out: [Cut] = []
        while framePos + frameSamples <= buffer.count {
            var peak: Float = 0
            for i in framePos..<(framePos + frameSamples) {
                peak = max(peak, abs(buffer[i]))
            }
            framePos += frameSamples
            if peak < silenceThreshold {
                silenceFrames += 1
                continue
            }
            // 聲音回來了：剛才那段靜音夠長就切一刀，切在靜音中間。
            if silenceFrames >= silenceFramesNeeded, let cut = makeCut() {
                out.append(cut)
            }
            silenceFrames = 0
        }
        return out
    }

    /// 講完：把剩下的當最後一段（太短或已經送滿就不回）。
    func finish() -> Cut? {
        lock.lock(); defer { lock.unlock() }
        closed = true
        let start = segmentStart
        let end = base + buffer.count
        guard end > start, Double(end - start) / Double(sampleRate) >= Self.minChunkSeconds else { return nil }
        guard emitted < maxChunks else { return nil }
        emitted += 1
        return Cut(start: start, end: end)
    }

    /// 已送出的段數（給 log／測試看）。
    var emittedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return emitted
    }

    // 呼叫端已持有 lock。
    private func makeCut() -> Cut? {
        let silenceSamples = silenceFrames * frameSamples
        // framePos 已經吃掉了這個「有聲音」的視窗，靜音要從它前面算回來。
        let silenceStart = base + framePos - frameSamples - silenceSamples
        let cutPoint = silenceStart + silenceSamples / 2
        guard cutPoint - segmentStart >= minSegmentSamples else { return nil }
        guard emitted < maxChunks - 1 else { return nil }   // 最後一段留給 finish()
        let result = Cut(start: segmentStart, end: cutPoint)
        emitted += 1
        // 下一段從切點前 overlapSamples 開始：音訊重疊 0.3 秒，文字才去得掉重複。
        segmentStart = max(0, cutPoint - overlapSamples)
        // 已消耗掉的樣本丟掉，記憶體不會隨錄音長度成長。
        let keep = max(0, segmentStart - base)
        if keep > 0 {
            buffer.removeFirst(keep)
            base += keep
            framePos -= keep
        }
        return result
    }

    /// 一次規劃（純函式版本）：整段樣本 → 段範圍。錄音中用 `push`／`finish`，測試與離線分析用這個。
    static func plan(_ samples: [Float],
                     sampleRate: Int = sampleRate,
                     maxChunks: Int = maxChunks,
                     minSilenceSeconds: Double = minSilenceSeconds,
                     minSegmentSeconds: Double = minSegmentSeconds,
                     overlapSeconds: Double = overlapSeconds,
                     silenceThreshold: Float = silenceThreshold) -> [Cut] {
        let stream = ChunkStream(sampleRate: sampleRate, maxChunks: maxChunks,
                                 minSilenceSeconds: minSilenceSeconds, minSegmentSeconds: minSegmentSeconds,
                                 overlapSeconds: overlapSeconds, silenceThreshold: silenceThreshold)
        var cuts = stream.push(samples)
        if let tail = stream.finish() { cuts.append(tail) }
        return cuts
    }

    /// 段範圍 → 音訊樣本。
    static func slice(_ samples: [Float], _ cut: Cut) -> [Float] {
        let lower = max(0, min(cut.start, samples.count))
        let upper = max(lower, min(cut.end, samples.count))
        return Array(samples[lower..<upper])
    }
}

// MARK: - 接段

/// 雲端辨識切段的純邏輯（切段、接段去重、上下文 prompt、走哪一條）；不打網路。
enum ChunkedASR {
    /// 接段時最多往回比對幾個字（Whisper 兩段邊界最多重複這麼多）。
    static let maxOverlapChars = 24
    /// 帶給下一段的上下文 prompt 長度上限（Whisper 的 prompt 欄位有長度限制）。
    static let contextPromptChars = 120

    /// 前段結果當下一段的上下文（Whisper prompt）：取尾巴，避免斷句處用字不一致。
    static func contextPrompt(previous: String, maxChars: Int = contextPromptChars) -> String {
        let trimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.suffix(maxChars))
    }

    private static let boundaryPunctuation: Set<Character> = [
        "，", "、", "。", "！", "？", "；", "：", "…", "．",
        ",", ".", "!", "?", ";", ":", "、",
    ]

    private static func isPunctuation(_ c: Character) -> Bool { boundaryPunctuation.contains(c) }

    /// 兩段文字接起來：相鄰段音訊重疊 0.3 秒，這裡在文字層面把重複去掉；
    /// 標點不重複（上一段已經有句號，下一段開頭的句號丟掉），而且不吃字（一定要真的對得上才砍）。
    static func join(previous: String, next: String) -> String {
        let head = previous
        var tail = next
        guard !tail.isEmpty else { return head }
        // 1) 邊界標點不重複。
        if let last = head.last, isPunctuation(last), let first = tail.first, isPunctuation(first) {
            tail.removeFirst()
        }
        guard !tail.isEmpty else { return head }
        let a = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        // 2) 最長重疊：前段結尾 == 後段開頭（比對時忽略空白與大小寫，英文才接得起來）。
        var overlap = 0
        let maxK = min(maxOverlapChars, a.count, b.count)
        if maxK > 0 {
            for candidate in stride(from: maxK, through: 1, by: -1) {
                let left = String(a.suffix(candidate))
                let right = String(b.prefix(candidate))
                if left.lowercased() == right.lowercased() || squash(left) == squash(right) {
                    overlap = candidate
                    break
                }
            }
        }
        // leading 只算「開頭的空白」：2026-10-14（Q3-repair1 review-agy ①）這裡原本寫成
        // `tail.count - b.prefix(tail.count).count`，`b` 是整段 trim 過的，尾巴的空白也被算進來，
        // dropFirst 就多吃掉下一段的開頭字（「收一點。」→「收一點。高頻…」會變成「高頻」少了「收一點。」）。
        // 與 Android `ChunkedASR.kt` 的 `trimStart()` 同一套。
        let leading = tail.count - tail.drop(while: { $0.isWhitespace }).count
        var rest = overlap > 0 ? String(tail.dropFirst(leading + overlap)) : String(tail.dropFirst(leading))
        while let last = rest.last, last.isWhitespace { rest.removeLast() }
        guard !rest.isEmpty else { return head }
        guard !head.isEmpty else { return rest }
        // 3) 拉丁字母之間才補空白（Whisper 英文會回 " world"）；中文本來就沒有空白，不要補。
        if let left = head.last, let right = rest.first, needsSpace(left, right) {
            return head + " " + rest
        }
        return head + rest
    }

    /// 只有兩邊都是拉丁字母／數字才需要空白；中文、日文直接接。
    private static func needsSpace(_ left: Character, _ right: Character) -> Bool {
        func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        return latin(left) && latin(right)
    }

    /// 全部的段依序接起來。
    static func join(_ texts: [String]) -> String {
        texts.reduce(into: "") { acc, text in acc = join(previous: acc, next: text) }
    }

    /// 比對時把空白拿掉（英文 "world" / " world" 要視為同一段）。
    private static func squash(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    // MARK: - 走哪一條（純函式，兩邊同一組測試）

    /// 段數、限流、任一段失敗之後要走哪一條。
    enum Route: Equatable {
        /// 段數只有 1：跟舊做法一樣，沒有意義分。
        case whole
        /// 段數超過上限：整段一次送。
        case merged
        /// 遇到 429（Groq 免費額度每分鐘請求數）→ 立刻改回「講完整段送」，不能讓使用者等更久。
        case rateLimited
        /// 任一段失敗 → 整段用舊做法重送一次。
        case retryWhole
        /// 分段送出。
        case chunked
    }

    static func route(segmentCount: Int, rateLimited: Bool, anySegmentFailed: Bool,
                      maxChunks: Int = ChunkStream.maxChunks) -> Route {
        if segmentCount <= 1 { return .whole }
        if segmentCount > maxChunks { return .merged }
        if rateLimited { return .rateLimited }
        if anySegmentFailed { return .retryWhole }
        return .chunked
    }

    // MARK: - 傳送

    /// 一段辨識的結果；要分得出「被限流」（429），因為那要立刻改回舊做法。
    enum SegmentOutcome: Equatable {
        case ok(String)
        case rateLimited
        case failed
    }

    /// 送一段。`context`＝前一段的文字（Whisper prompt）。逾時、回 nil 都不算被限流。
    static func transcribeSegment(_ samples: [Float], language: String, hotwords: [String],
                                  provider: SmartCleanup.Provider, key: String, context: String?,
                                  transport: @escaping SmartCleanup.Transport = { try await URLSession.shared.data(for: $0) }) async -> SegmentOutcome {
        let seconds = Double(samples.count) / Double(ChunkStream.sampleRate)
        if seconds < 0.25 { return .failed }
        let budget = CleanupBudget(seconds: CloudASR.timeLimit(seconds: seconds))
        let audio = CloudASR.wav(CloudASR.trimSilence(samples))
        do {
            let outcome = try await budget.run { () -> Result<String, CloudASR.Outcome>? in
                try budget.check()
                let request = try CloudASR.makeRequest(provider: provider, key: key, wav: audio,
                                                      language: language, hotwords: hotwords, context: context)
                let data: Data
                let response: URLResponse
                do { (data, response) = try await transport(request) }
                catch { return .failure(.transport) }
                try budget.check()
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    return .failure(.http(http.statusCode))
                }
                do { return .success(try CloudASR.parse(data, provider: provider)) }
                catch { return .failure(.malformed) }
            }
            guard case .some(.success(let text)) = outcome else {
                // 429＝Groq 免費額度的每分鐘請求數上限；只有這一種要立刻改回整段送。
                if case .some(.failure(.http(429))) = outcome { return .rateLimited }
                return .failed
            }
            let cleaned = provider == .gemini ? CloudASR.stripCodeFence(text) : text
            guard let accepted = TranscriptGuard.clean(cleaned, language: language), !accepted.isEmpty else { return .failed }
            // 整段只有「謝謝大家收看」這類字幕結尾句＝停頓裡的底噪被補字，這段當空的接（join 會略過空字串）。
            return .ok(TranscriptGuard.dropOutroHallucination(accepted))
        } catch {
            return .failed
        }
    }

    /// 邊錄邊傳的最後一步：各段結果依序接起來。
    ///
    /// 任一段失敗、或被限流（429）→ 整段用舊做法重送一次（`whole`）；再失敗回 nil，
    /// 呼叫端照現行行為退回裝置端（Apple／系統 SpeechRecognizer）的結果。
    static func transcribeChunked(segments: [[Float]], whole: [Float], language: String, hotwords: [String],
                                  provider: SmartCleanup.Provider, key: String,
                                  transport: @escaping SmartCleanup.Transport = { try await URLSession.shared.data(for: $0) },
                                  log: CloudASR.Log = CloudASR.defaultLog) async -> String? {
        guard segments.count > 1 else {
            return await CloudASR.transcribe(whole, language: language, hotwords: hotwords,
                                             provider: provider, key: key, transport: transport, log: log)
        }
        var texts: [String] = []
        var rateLimited = false
        var anySegmentFailed = false
        // 依序送：每一段都帶前一段的文字當上下文（Whisper prompt），順序不能亂。
        for segment in segments {
            let context = ChunkedASR.contextPrompt(previous: texts.last ?? "")
            switch await transcribeSegment(segment, language: language, hotwords: hotwords,
                                           provider: provider, key: key, context: context, transport: transport) {
            case .ok(let text): texts.append(text)
            case .rateLimited: rateLimited = true
            case .failed: anySegmentFailed = true
            }
            if rateLimited || anySegmentFailed { break }
        }
        let decision = route(segmentCount: segments.count, rateLimited: rateLimited,
                             anySegmentFailed: anySegmentFailed)
        switch decision {
        case .chunked:
            let joined = join(texts)
            guard !joined.isEmpty else {
                return await CloudASR.transcribe(whole, language: language, hotwords: hotwords,
                                                 provider: provider, key: key, transport: transport, log: log)
            }
            return joined
        case .whole, .merged, .rateLimited, .retryWhole:
            // 任何一段不順就整段重送一次；再失敗回 nil → 呼叫端用裝置端結果。
            return await CloudASR.transcribe(whole, language: language, hotwords: hotwords,
                                             provider: provider, key: key, transport: transport, log: log)
        }
    }
}
/// 錄音中送出去的段：依序送、每段帶前一段的文字當上下文；講完時只送最後一段，再把各段結果接起來。
///
/// 任一段失敗或被限流（429）就停送，改由呼叫端走「整段一次送」的舊做法——不能讓使用者等更久。
actor LiveCloudASR {
    private let provider: SmartCleanup.Provider
    private let key: String
    private let language: String
    private let hotwords: [String]
    private let transport: SmartCleanup.Transport
    private var texts: [String] = []
    private var degraded = false
    private var chain: Task<Void, Never>?
    /// 還沒輪到的段（段號 → 音訊）。`Task` 不保證 FIFO，段號在音訊執行緒上先取，這裡照號排。
    private var pending: [Int: [Float]] = [:]
    private var nextSequence = 0

    init(provider: SmartCleanup.Provider, key: String, language: String, hotwords: [String],
         transport: @escaping SmartCleanup.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.provider = provider
        self.key = key
        self.language = language
        self.hotwords = hotwords
        self.transport = transport
    }

    /// 錄音中偵測到停頓就呼叫。`sequence` 由 `LiveChunkSubmitter` 在音訊執行緒上取（見該型別說明）。
    func submit(_ chunk: [Float], sequence: Int) {
        guard !degraded else { return }
        pending[sequence] = chunk
        drainPending()
    }

    /// 依段號把連續到的段落接上 `chain`；缺號就等下一個 `submit` 補齊（2026-10-14 Q3-repair1 review-agy ③）。
    private func drainPending() {
        while !degraded, let chunk = pending.removeValue(forKey: nextSequence) {
            nextSequence += 1
            let previous = chain
            chain = Task { [weak self] in
                _ = await previous?.value
                await self?.transcribe(chunk)
            }
        }
    }

    private func transcribe(_ chunk: [Float]) async {
        guard !degraded else { return }
        let context = ChunkedASR.contextPrompt(previous: texts.last ?? "")
        switch await ChunkedASR.transcribeSegment(chunk, language: language, hotwords: hotwords,
                                                  provider: provider, key: key, context: context,
                                                  transport: transport) {
        case .ok(let text): texts.append(text)
        case .rateLimited, .failed: degraded = true
        }
    }

    /// 已送完的段數（診斷／測試用）。
    var completedSegments: Int { texts.count }
    /// 有沒有因為失敗或被限流而退回舊做法。
    var fellBack: Bool { degraded }

    /// 講完：等前面都送完，送最後一段，接起來。
    /// `last`＝還沒講完的最後一段；`whole`＝整段錄音（任何退路都用它走舊做法）。
    func finish(last: [Float]?, whole: [Float], log: @escaping CloudASR.Log) async -> String? {
        await chain?.value
        let wholeFallback: () async -> String? = {
            await CloudASR.transcribe(whole, language: self.language, hotwords: self.hotwords,
                                      provider: self.provider, key: self.key,
                                      transport: self.transport, log: log)
        }
        guard !degraded else { return await wholeFallback() }
        guard !texts.isEmpty else { return await wholeFallback() }
        // 上限守門：段數超過就整段一次送（正常情況切段時已經卡住，這裡只是保險）。
        guard texts.count < ChunkStream.maxChunks else { return await wholeFallback() }
        guard let last, Double(last.count) / Double(ChunkStream.sampleRate) >= ChunkStream.minChunkSeconds else {
            return ChunkedASR.join(texts)
        }
        let context = ChunkedASR.contextPrompt(previous: texts.last ?? "")
        switch await ChunkedASR.transcribeSegment(last, language: language, hotwords: hotwords,
                                                  provider: provider, key: key, context: context,
                                                  transport: transport) {
        case .ok(let text): return ChunkedASR.join(texts + [text])
        case .rateLimited, .failed: return await wholeFallback()
        }
    }

    /// 使用者中途放棄 → 丟掉背景工作。
    func abandon() {
        degraded = true
        chain?.cancel()
        chain = nil
        pending.removeAll()
        texts.removeAll()
    }
}

/// 錄音中送段用的序號發號器（`LiveCloudASR.submit` 的段號來源）。
///
/// 2026-10-14（Q3-repair1 review-agy ③）：`KeyboardVoiceHost` 原本在音訊執行緒上寫
/// `Task { await live.submit(chunk) }`，`Task` 的排程不保證 FIFO —— 連續兩次停頓切出兩段時，
/// 後面那段可能先進 actor，兩段文字就倒序接起來。這裡在音訊執行緒上（本身是單一執行緒、順序固定）
/// 同步取號，actor 再照號排，順序就不會飄。
final class LiveChunkSubmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var issued: [Task<Void, Never>] = []
    private let live: LiveCloudASR

    init(live: LiveCloudASR) { self.live = live }

    /// 音訊執行緒上呼叫。只做加鎖＋取號＋丟 Task，不碰網路。
    func submit(_ chunk: [Float]) {
        lock.lock()
        let sequence = counter
        counter += 1
        let task = Task { await live.submit(chunk, sequence: sequence) }
        issued.append(task)
        lock.unlock()
    }

    /// 等所有已送出的段都進到 actor（測試與診斷用；錄音中不會呼叫）。
    func drain() async {
        for task in takeIssued() { await task.value }
    }

    /// NSLock 不能在 async 上下文呼叫，這裡把鎖包成同步函式（Swift 6 會直接編譯錯誤）。
    private func takeIssued() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let tasks = issued
        issued = []
        return tasks
    }

    /// 重新開始一次錄音時歸零（配新的 `LiveCloudASR` 才需要，這裡只是保險）。
    func reset() {
        lock.lock(); counter = 0; issued = []; lock.unlock()
    }
}
