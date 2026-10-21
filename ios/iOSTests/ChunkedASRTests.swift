import XCTest
@testable import UTUVOTypeiOS

/// 雲端辨識「邊錄邊傳」的純邏輯（切段、接段去重、上限合併、429 退回）。
/// 逐條對應 Android `android/app/src/test/kotlin/com/utuvo/type/ChunkedAsrChunkedTest.kt`；
/// 兩邊用同一組輸入與同一組期望值，改一邊就要改另一邊。
final class ChunkedASRTests: XCTestCase {
    private let sr = 16_000

    /// 講話（峰值 0.3）與靜音（0.0）交錯出來的假錄音。
    private func script(_ parts: [(seconds: Double, speech: Bool)]) -> [Float] {
        var out: [Float] = []
        for part in parts {
            let n = Int(part.seconds * Double(sr))
            if part.speech {
                for i in 0..<n { out.append(i % 2 == 0 ? 0.3 : -0.3) }
            } else {
                out.append(contentsOf: [Float](repeating: 0, count: n))
            }
        }
        return out
    }

    private func seconds(_ count: Int) -> Double { Double(count) / Double(sr) }

    // MARK: - 切段（T1–T4）

    /// T1：兩次停頓切三段，相鄰兩段音訊重疊 0.3 秒。
    func testPlanSplitsOnPausesWithOverlap() {
        let samples = script([(4, true), (0.8, false), (4, true), (0.8, false), (2, true)])
        let cuts = ChunkStream.plan(samples)
        XCTAssertEqual(cuts.count, 3)
        XCTAssertEqual(cuts[0], ChunkStream.Cut(start: 0, end: 70_400), "切在靜音中間")
        XCTAssertEqual(cuts[1].start, 65_600, "下一段從切點前 0.3 秒開始")
        XCTAssertEqual(cuts[0].end - cuts[1].start, 4_800, "音訊重疊 0.3 秒")
        XCTAssertEqual(cuts[2].end, samples.count)
        // 整體覆蓋完整錄音，沒漏字。
        XCTAssertEqual(cuts.first?.start, 0)
        XCTAssertEqual(cuts.last?.end, samples.count)
    }

    /// T2：停頓不到 0.6 秒不切。
    func testShortPauseDoesNotSplit() {
        let samples = script([(4, true), (0.3, false), (4, true)])
        XCTAssertEqual(ChunkStream.plan(samples).count, 1)
    }

    /// T3：這一段還沒講滿 3 秒不切（避免切出一堆碎片）。
    func testShortSegmentDoesNotSplit() {
        let samples = script([(2, true), (0.8, false), (4, true)])
        XCTAssertEqual(ChunkStream.plan(samples).count, 1)
    }

    /// T4：Groq 免費額度有每分鐘請求數限制，一次聽寫最多 6 段；超過就把尾巴併進最後一段。
    func testChunkCountIsCappedAndTailMerged() {
        var parts: [(Double, Bool)] = []
        for _ in 0..<8 { parts.append((3.2, true)); parts.append((0.8, false)) }
        parts.append((1.0, true))
        let samples = script(parts)
        let cuts = ChunkStream.plan(samples)
        XCTAssertEqual(cuts.count, 6, "超過上限時合併成 6 段")
        XCTAssertEqual(cuts.last?.end, samples.count, "最後一段一路吃到錄音結尾")
        for cut in cuts { XCTAssertLessThanOrEqual(cut.end - cut.start, samples.count) }
    }

    /// 錄音中逐塊丟進去，切出來的段跟一次規劃結果相同（串流與離線同一套規則）。
    func testStreamingMatchesBatchPlan() {
        let samples = script([(4, true), (0.8, false), (4, true), (0.8, false), (2, true)])
        let stream = ChunkStream()
        var cuts: [ChunkStream.Cut] = []
        var index = 0
        while index < samples.count {
            let end = min(index + 1_600, samples.count)   // 每塊 100 ms
            cuts += stream.push(Array(samples[index..<end]))
            index = end
        }
        if let tail = stream.finish() { cuts.append(tail) }
        XCTAssertEqual(cuts, ChunkStream.plan(samples))
    }

    /// 切出來的段加起來要等於整段錄音（只有 0.3 秒的重疊），不能漏也不能重。
    func testSegmentsCoverWholeRecording() {
        let samples = script([(4, true), (0.8, false), (4, true), (0.8, false), (2, true)])
        let cuts = ChunkStream.plan(samples)
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            XCTAssertGreaterThan(b.start, a.start)
            XCTAssertEqual(a.end - b.start, 4_800, "每段起點重疊前一段結尾 0.3 秒")
        }
    }

    // MARK: - 接段去重（T5–T8）

    /// T5：相鄰段音訊重疊，文字也重疊 → 只留一份。
    func testJoinRemovesRepeatedText() {
        XCTAssertEqual(ChunkedASR.join(previous: "今天天氣很好", next: "天氣很好我們去公園"),
                       "今天天氣很好我們去公園")
    }

    /// T6：標點不重複（上一段已經有句號，下一段開頭的句號丟掉）。
    func testJoinDoesNotDuplicatePunctuation() {
        XCTAssertEqual(ChunkedASR.join(previous: "第一段。", next: "。第二段"), "第一段。第二段")
        XCTAssertEqual(ChunkedASR.join(previous: "第一段，", next: "第二段"), "第一段，第二段")
    }

    /// T7：對不上就一個字都不能吃。
    func testJoinNeverEatsCharacters() {
        XCTAssertEqual(ChunkedASR.join(previous: "今天天氣", next: "明天出門"), "今天天氣明天出門")
        XCTAssertEqual(ChunkedASR.join(previous: "abc", next: "xyz"), "abc xyz", "拉丁字母之間補空白是刻意的")
    }

    /// T8：英文段之間要有空白，空白差異也算重疊。
    func testJoinHandlesEnglishSpacing() {
        XCTAssertEqual(ChunkedASR.join(previous: "hello world", next: "world again"), "hello world again")
        XCTAssertEqual(ChunkedASR.join(previous: "hello world", next: "again"), "hello world again")
    }

    /// 全部段依序接起來。
    func testJoinAllSegments() {
        let texts = ["今天天氣很好", "天氣很好我們去公園", "公園門口有櫻花"]
        XCTAssertEqual(ChunkedASR.join(texts), "今天天氣很好我們去公園門口有櫻花")
    }

    /// Q3-repair1 ①：前段結尾帶空白／句號時，既不重複也不吃字。
    ///
    /// 修之前 `leading` 把**結尾**空白也算進去（`tail.count - b.count`），`dropFirst` 就多吃掉
    /// 下一段的開頭 —— 「收一點。」＋「收一點。高頻…」會變成「收一點。高頻…」少了開頭那幾個字。
    func testJoinTrailingWhitespaceDoesNotEatNextSegment() {
        // 修之前的 bug：next 有結尾空白時，leading 多算 3 個字 → 「高頻」變成「要平衡一下」這種吃掉開頭的結果。
        XCTAssertEqual(ChunkedASR.join(previous: "那我們記得收一點", next: "記得收一點。   "),
                       "那我們記得收一點。",
                       "next 只有重疊與結尾空白：不該多出也不該少字")
        XCTAssertEqual(ChunkedASR.join(previous: "那我們記得收一點", next: " 記得收一點。高頻要平衡一下"),
                       "那我們記得收一點。高頻要平衡一下",
                       "next 開頭有空白也不能吃字")
        XCTAssertEqual(ChunkedASR.join(previous: "今天天氣很好", next: "天氣很好我們去公園  "),
                       "今天天氣很好我們去公園",
                       "英文／中文都一樣：結尾空白只是被 trim，不影響去重")
        XCTAssertEqual(ChunkedASR.join(previous: "第一段。", next: "。第二段  "), "第一段。第二段")
    }

    /// 前段結果當下一段的上下文 prompt：只帶尾巴，長度有上限。
    func testContextPromptKeepsTailWithinLimit() {
        XCTAssertEqual(ChunkedASR.contextPrompt(previous: "天氣很好"), "天氣很好")
        let long = String(repeating: "字", count: 400)
        let prompt = ChunkedASR.contextPrompt(previous: long)
        XCTAssertEqual(prompt.count, 120)
        XCTAssertTrue(long.hasSuffix(prompt))
    }

    // MARK: - 走哪一條（T9）

    /// T9：段數、限流、任一段失敗之後的處置（純函式）。
    func testRouteDecisions() {
        XCTAssertEqual(ChunkedASR.route(segmentCount: 1, rateLimited: false, anySegmentFailed: false), .whole)
        XCTAssertEqual(ChunkedASR.route(segmentCount: 9, rateLimited: false, anySegmentFailed: false), .merged)
        XCTAssertEqual(ChunkedASR.route(segmentCount: 4, rateLimited: true, anySegmentFailed: false), .rateLimited)
        XCTAssertEqual(ChunkedASR.route(segmentCount: 4, rateLimited: false, anySegmentFailed: true), .retryWhole)
        XCTAssertEqual(ChunkedASR.route(segmentCount: 4, rateLimited: false, anySegmentFailed: false), .chunked)
        // 限流優先於失敗：429 要立刻改舊做法。
        XCTAssertEqual(ChunkedASR.route(segmentCount: 4, rateLimited: true, anySegmentFailed: true), .rateLimited)
    }

    // MARK: - 分段送出（T10–T13）

    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts_: [String] = []
        private var audioBytes_: [Int] = []
        private var index_ = 0
        let status: [Int]
        let texts: [String]

        init(texts: [String] = [], status: [Int] = []) {
            self.texts = texts
            self.status = status
        }

        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts_ }
        var audioBytes: [Int] { lock.lock(); defer { lock.unlock() }; return audioBytes_ }
        var index: Int { lock.lock(); defer { lock.unlock() }; return index_ }

        func record(_ request: URLRequest) -> (code: Int, text: String) {
            lock.lock(); defer { lock.unlock() }
            let code = status.isEmpty ? 200 : status[min(index_, status.count - 1)]
            let text = texts.isEmpty ? "" : texts[min(index_, texts.count - 1)]
            prompts_.append(ChunkedASRTests.prompt(of: request))
            audioBytes_.append(ChunkedASRTests.audioLength(of: request))
            index_ += 1
            return (code, text)
        }
    }

    private let noLog: CloudASR.Log = { _, _, _, _, _, _ in }

    /// 從 multipart body 抓出 prompt 欄位（body 裡有 WAV 位元組，不能整段轉字串）。
    private static func prompt(of request: URLRequest) -> String {
        guard let body = request.httpBody else { return "" }
        return String(decoding: multipartField("prompt", in: body), as: UTF8.self)
    }

    /// audio/wav 那一段的位元組數（整段送 vs 分段送的大小比較用）。
    private static func audioLength(of request: URLRequest) -> Int {
        guard let body = request.httpBody,
              let marker = body.range(of: Data("Content-Type: audio/wav\r\n\r\n".utf8)) else { return -1 }
        return body.distance(from: marker.upperBound, to: body.endIndex)
    }

    private static func multipartField(_ name: String, in body: Data) -> Data {
        guard let header = body.range(of: Data("name=\"\(name)\"\r\n\r\n".utf8)) else { return Data() }
        let rest = body[header.upperBound...]
        guard let end = rest.range(of: Data("\r\n--".utf8)) else { return Data() }
        return Data(rest[..<end.lowerBound])
    }

    private func responder(_ fake: Fake) -> SmartCleanup.Transport {
        { request in
            let (code, payload) = fake.record(request)
            let data = Data("{\"text\":\"\(payload)\"}".utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: code,
                                          httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    private let provider = SmartCleanup.Provider.groq

    private func segments() -> [[Float]] {
        let samples = script([(4, true), (0.8, false), (4, true), (0.8, false), (2, true)])
        return ChunkStream.plan(samples).map { ChunkStream.slice(samples, $0) }
    }

    /// T10：三段都成功 → 接起來，而且每一段都帶著前一段的文字。
    func testChunkedSuccessJoinsAndCarriesContext() async {
        let fake = Fake(texts: ["今天天氣很好", "天氣很好我們去公園", "公園門口有櫻花"])
        let segs = segments()
        let text = await ChunkedASR.transcribeChunked(segments: segs, whole: segs.flatMap { $0 },
                                                      language: "zh-TW", hotwords: ["UTUVO"],
                                                      provider: provider, key: "fake-key",
                                                      transport: responder(fake), log: noLog)
        XCTAssertEqual(text, "今天天氣很好我們去公園門口有櫻花")
        XCTAssertEqual(fake.prompts.count, 3, "一段一個請求，沒有重送整段")
        XCTAssertTrue(fake.prompts[0].contains("UTUVO"), "每一段都帶同一份熱詞")
        XCTAssertTrue(fake.prompts[1].contains("今天天氣很好"), "第二段帶第一段的結果")
        XCTAssertTrue(fake.prompts[2].contains("我們去公園"))
        XCTAssertTrue(fake.audioBytes.allSatisfy { $0 < 1_000_000 }, "每段都比整段小")
    }

    /// T11：任一段失敗 → 整段用舊做法重送一次。
    func testChunkedFailureFallsBackToWholeRecording() async {
        let segs = segments()
        let fake = Fake(texts: ["第一段", "", "整段重送"], status: [200, 500, 200, 200])
        let text = await ChunkedASR.transcribeChunked(segments: segs, whole: segs.flatMap { $0 },
                                                      language: "zh-TW", hotwords: [],
                                                      provider: provider, key: "fake-key",
                                                      transport: responder(fake), log: noLog)
        XCTAssertEqual(text, "整段重送", "失敗之後改用整段送")
        XCTAssertEqual(fake.index, 3, "1、2 段送出，第 2 段 500 → 馬上整段重送")
        XCTAssertGreaterThan(fake.audioBytes.last ?? 0, fake.audioBytes[0], "最後一次是整段")
    }

    /// T12：429（Groq 每分鐘請求數上限）→ 立刻改回整段一次送，不能讓使用者等更久。
    func testChunkedRateLimitedFallsBackToWhole() async {
        let segs = segments()
        let fake = Fake(texts: ["第一段", "整段重送"], status: [429, 200])
        let text = await ChunkedASR.transcribeChunked(segments: segs, whole: segs.flatMap { $0 },
                                                      language: "zh-TW", hotwords: [],
                                                      provider: provider, key: "fake-key",
                                                      transport: responder(fake), log: noLog)
        XCTAssertEqual(text, "整段重送")
        XCTAssertEqual(fake.index, 2, "第一段被限流 → 馬上整段重送，後面的段不再送")
    }

    /// T13：段數只有一段時走舊做法，不做無謂的分段。
    func testSingleSegmentUsesWholePath() async {
        let fake = Fake(texts: ["整段"])
        let one = [script([(4, true), (0.8, false), (4, true)])]
        let text = await ChunkedASR.transcribeChunked(segments: one, whole: one.flatMap { $0 },
                                                      language: "zh-TW", hotwords: [],
                                                      provider: provider, key: "fake-key",
                                                      transport: responder(fake), log: noLog)
        XCTAssertEqual(text, "整段")
        XCTAssertEqual(fake.index, 1)
    }

    // MARK: - LiveCloudASR（Q3-repair1 ②③④）

    /// 一段 0.4 秒的「好。」——低於舊的 0.6 秒門檻。
    private func shortTail() -> [Float] { script([(0.4, true)]) }

    private func fourSeconds() -> [Float] { script([(4, true)]) }

    /// Q3-repair1 ②：很短的結尾（「好。」「謝謝」）一定要送出去，不能整段丟掉。
    func testLiveCloudSendsShortFinalSegment() async {
        let fake = Fake(texts: ["前面那段", "好。"])
        let live = LiveCloudASR(provider: provider, key: "fake-key", language: "zh-TW",
                                hotwords: [], transport: responder(fake))
        await live.submit(fourSeconds(), sequence: 0)
        let text = await live.finish(last: shortTail(), whole: fourSeconds(), log: noLog)
        XCTAssertEqual(text, "前面那段好。", "0.4 秒的結尾要送，不因為短就被丟")
        XCTAssertEqual(fake.index, 2, "前面一段＋結尾一段，共兩次請求")
    }

    /// Q3-repair1 ②的另一半：只有 0.4 秒的結尾也要切出來（門檻從 0.6 降到 0.25）。
    func testShortTailIsCutFromStream() {
        let samples = script([(0.4, true)])
        let cuts = ChunkStream.plan(samples)
        XCTAssertEqual(cuts.count, 1, "0.4 秒的結尾要被切出來當最後一段")
        XCTAssertEqual(seconds(ChunkStream.slice(samples, cuts[0]).count), 0.4, accuracy: 0.05)
    }

    /// Q3-repair1 ③：段落不能倒序 —— 故意讓後段（序號 1）先到 actor，結果仍要依序接起來。
    func testLiveCloudKeepsSegmentOrderWhenLaterArrivesFirst() async {
        let fake = Fake(texts: ["第一段", "第二段", "第三段"])
        let live = LiveCloudASR(provider: provider, key: "fake-key", language: "zh-TW",
                                hotwords: [], transport: responder(fake))
        // 反序提交：2、1、0。actor 必須等到 0 來了才開始送，否則文字會倒著接。
        await live.submit(fourSeconds(), sequence: 2)
        await live.submit(fourSeconds(), sequence: 1)
        await live.submit(fourSeconds(), sequence: 0)
        let text = await live.finish(last: nil, whole: fourSeconds(), log: noLog)
        XCTAssertEqual(text, "第一段第二段第三段", "段號 2 先到也不能排在前面")
        XCTAssertEqual(fake.prompts.count, 3)
        XCTAssertTrue(fake.prompts[1].contains("第一段"), "第二段帶的是第一段的文字當上下文")
        XCTAssertTrue(fake.prompts[2].contains("第二段"), "第三段帶的是第二段的文字")
    }

    /// Q3-repair1 ④：任一段被限流（429）就降級，**排隊中還沒送的段全部取消**，直接走整段。
    func testLiveCloudStopsSendingAfterRateLimited() async {
        let fake = Fake(texts: ["第一段", "整段重送"], status: [429, 200])
        let live = LiveCloudASR(provider: provider, key: "fake-key", language: "zh-TW",
                                hotwords: [], transport: responder(fake))
        await live.submit(fourSeconds(), sequence: 0)   // 429 → 降級
        await live.submit(fourSeconds(), sequence: 1)   // 這段已經排隊了，不該再送
        await live.submit(fourSeconds(), sequence: 2)
        let fellBack = await live.fellBack
        XCTAssertTrue(fellBack, "429 之後要降級")
        let text = await live.finish(last: nil, whole: fourSeconds(), log: noLog)
        XCTAssertEqual(text, "整段重送")
        XCTAssertEqual(fake.index, 2, "只有第一段（429）＋整段重送；後面兩段沒送出來")
    }

    /// Q3-repair1 ③：發號器在音訊執行緒上同步取號，段號一定是 0、1、2…（不管 Task 怎麼排）。
    func testLiveChunkSubmitterAssignsSequentialNumbersInOrder() async {
        let fake = Fake(texts: ["甲", "乙"])
        let live = LiveCloudASR(provider: provider, key: "fake-key", language: "zh-TW",
                                hotwords: [], transport: responder(fake))
        let submitter = LiveChunkSubmitter(live: live)
        // 連續送，模擬錄音執行緒上接連兩次停頓。
        for _ in 0..<2 { submitter.submit(fourSeconds()) }
        await submitter.drain()
        let text = await live.finish(last: nil, whole: fourSeconds(), log: noLog)
        XCTAssertEqual(text, "甲乙", "發號器保證依序送出")
        XCTAssertEqual(fake.prompts.count, 2)
    }
}