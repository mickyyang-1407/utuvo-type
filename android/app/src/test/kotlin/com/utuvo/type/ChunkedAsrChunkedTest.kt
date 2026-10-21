package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 雲端辨識「邊錄邊傳」的純邏輯（切段、接段去重、上限合併、429 退回）。
 * 逐條對應 iOS `ios/iOSTests/ChunkedASRTests.swift`；兩邊用同一組輸入與同一組期望值。
 * 全部用假 transport，不打真網路、不碰真 key。
 */
class ChunkedAsrChunkedTest {
    private val sr = 16_000
    private val groq = SmartCleanup.Provider.GROQ

    /** 講話（峰值 0.3）與靜音（0.0）交錯出來的假錄音。 */
    private fun script(vararg parts: Pair<Double, Boolean>): FloatArray {
        val out = ArrayList<Float>()
        for ((seconds, speech) in parts) {
            val n = (seconds * sr).toInt()
            val from = out.size
            for (i in 0 until n) out.add(if (i % 2 == 0) 0.3f else -0.3f)
            if (!speech) for (i in from until from + n) out[i] = 0f
        }
        return out.toFloatArray()
    }

    // MARK: - 切段（T1–T4）

    /** T1：兩次停頓切三段，相鄰兩段音訊重疊 0.3 秒。 */
    @Test
    fun planSplitsOnPausesWithOverlap() {
        val samples = script(4.0 to true, 0.8 to false, 4.0 to true, 0.8 to false, 2.0 to true)
        val cuts = ChunkedASR.plan(samples)
        assertEquals(3, cuts.size)
        assertEquals(ChunkedASR.Cut(0, 70_400), cuts[0])
        assertEquals(65_600, cuts[1].start)
        assertEquals(4_800, cuts[0].end - cuts[1].start)
        assertEquals(samples.size, cuts[2].end)
        assertEquals(0, cuts.first().start)
    }

    /** T2：停頓不到 0.6 秒不切。 */
    @Test
    fun shortPauseDoesNotSplit() {
        val samples = script(4.0 to true, 0.3 to false, 4.0 to true)
        assertEquals(1, ChunkedASR.plan(samples).size)
    }

    /** T3：這一段還沒講滿 3 秒不切（避免切出一堆碎片）。 */
    @Test
    fun shortSegmentDoesNotSplit() {
        val samples = script(2.0 to true, 0.8 to false, 4.0 to true)
        assertEquals(1, ChunkedASR.plan(samples).size)
    }

    /** T4：Groq 免費額度有每分鐘請求數限制，一次聽寫最多 6 段；超過就把尾巴併進最後一段。 */
    @Test
    fun chunkCountIsCappedAndTailMerged() {
        val parts = ArrayList<Pair<Double, Boolean>>()
        repeat(8) {
            parts.add(3.2 to true); parts.add(0.8 to false)
        }
        parts.add(1.0 to true)
        val samples = script(*parts.toTypedArray())
        val cuts = ChunkedASR.plan(samples)
        assertEquals(6, cuts.size)
        assertEquals(samples.size, cuts.last().end)
    }

    /** 錄音中逐塊丟進去，切出來的段跟一次規劃結果相同（串流與離線同一套規則）。 */
    @Test
    fun streamingMatchesBatchPlan() {
        val samples = script(4.0 to true, 0.8 to false, 4.0 to true, 0.8 to false, 2.0 to true)
        val stream = ChunkedASR.Stream()
        val cuts = ArrayList<ChunkedASR.Cut>()
        var index = 0
        while (index < samples.size) {
            val end = minOf(index + 1_600, samples.size)   // 每塊 100 ms
            cuts.addAll(stream.push(samples, index, end))
            index = end
        }
        stream.finish()?.let { cuts.add(it) }
        assertEquals(ChunkedASR.plan(samples), cuts)
    }

    /** 切出來的段要等於整段錄音（只有 0.3 秒的重疊），不能漏也不能重。 */
    @Test
    fun segmentsCoverWholeRecording() {
        val samples = script(4.0 to true, 0.8 to false, 4.0 to true, 0.8 to false, 2.0 to true)
        val cuts = ChunkedASR.plan(samples)
        for (i in 0 until cuts.size - 1) {
            assertTrue(cuts[i + 1].start > cuts[i].start)
            assertEquals(4_800, cuts[i].end - cuts[i + 1].start)
        }
        assertEquals(0, cuts.first().start)
        assertEquals(samples.size, cuts.last().end)
    }

    // MARK: - 接段去重（T5–T8）

    /** T5：相鄰段音訊重疊，文字也重疊 → 只留一份。 */
    @Test
    fun joinRemovesRepeatedText() {
        assertEquals("今天天氣很好我們去公園",
            ChunkedASR.join("今天天氣很好", "天氣很好我們去公園"))
    }

    /** T6：標點不重複（上一段已經有句號，下一段開頭的句號丟掉）。 */
    @Test
    fun joinDoesNotDuplicatePunctuation() {
        assertEquals("第一段。第二段", ChunkedASR.join("第一段。", "。第二段"))
        assertEquals("第一段，第二段", ChunkedASR.join("第一段，", "第二段"))
    }

    /** T7：對不上就一個字都不能吃。 */
    @Test
    fun joinNeverEatsCharacters() {
        assertEquals("今天天氣明天出門", ChunkedASR.join("今天天氣", "明天出門"))
        assertEquals("abc xyz", ChunkedASR.join("abc", "xyz"))   // 拉丁字母之間補空白是刻意的，不算吃字
    }

    /** T8：英文段之間要有空白，空白差異也算重疊。 */
    @Test
    fun joinHandlesEnglishSpacing() {
        assertEquals("hello world again", ChunkedASR.join("hello world", "world again"))
        assertEquals("hello world again", ChunkedASR.join("hello world", "again"))
    }

    /** 全部段依序接起來。 */
    @Test
    fun joinAllSegments() {
        assertEquals("今天天氣很好我們去公園門口有櫻花",
            ChunkedASR.join(listOf("今天天氣很好", "天氣很好我們去公園", "公園門口有櫻花")))
    }

    /** 前段結果當下一段的上下文 prompt：只帶尾巴，長度有上限。 */
    @Test
    fun contextPromptKeepsTailWithinLimit() {
        assertEquals("天氣很好", ChunkedASR.contextPrompt("天氣很好"))
        val long = "字".repeat(400)
        val prompt = ChunkedASR.contextPrompt(long)
        assertEquals(120, prompt.length)
        assertTrue(long.endsWith(prompt))
    }

    /**
     * Q3-repair1 ①：前段結尾帶空白／句號時，既不重複也不吃字。
     *
     * 逐條對應 iOS `testJoinTrailingWhitespaceDoesNotEatNextSegment`。iOS 原本把**結尾**空白算進
     * `leading`（`tail.count - b.count`），`dropFirst` 就多吃掉下一段的開頭；這邊本來就對，
     * 這個測試是兩端共用的契約：誰改壞了兩邊都紅。
     */
    @Test
    fun joinTrailingWhitespaceDoesNotEatNextSegment() {
        assertEquals("那我們記得收一點。", ChunkedASR.join("那我們記得收一點", "記得收一點。   "))
        assertEquals("那我們記得收一點。高頻要平衡一下", ChunkedASR.join("那我們記得收一點", " 記得收一點。高頻要平衡一下"))
        assertEquals("今天天氣很好我們去公園", ChunkedASR.join("今天天氣很好", "天氣很好我們去公園  "))
        assertEquals("第一段。第二段", ChunkedASR.join("第一段。", "。第二段  "))
    }

    // MARK: - 走哪一條（T9）

    /** T9：段數、限流、任一段失敗之後的處置（純函式）。 */
    @Test
    fun routeDecisions() {
        assertEquals(ChunkedASR.Route.WHOLE,
            ChunkedASR.route(1, rateLimited = false, anySegmentFailed = false))
        assertEquals(ChunkedASR.Route.MERGED,
            ChunkedASR.route(9, rateLimited = false, anySegmentFailed = false))
        assertEquals(ChunkedASR.Route.RATE_LIMITED,
            ChunkedASR.route(4, rateLimited = true, anySegmentFailed = false))
        assertEquals(ChunkedASR.Route.RETRY_WHOLE,
            ChunkedASR.route(4, rateLimited = false, anySegmentFailed = true))
        assertEquals(ChunkedASR.Route.CHUNKED,
            ChunkedASR.route(4, rateLimited = false, anySegmentFailed = false))
        assertEquals(ChunkedASR.Route.RATE_LIMITED,
            ChunkedASR.route(4, rateLimited = true, anySegmentFailed = true))
    }

    // MARK: - 分段送出（T10–T13）

    private class Fake(texts: List<String> = emptyList(), val status: List<Int> = emptyList()) {
        val prompts = ArrayList<String>()
        val audioBytes = ArrayList<Int>()
        var index = 0
        private val texts = texts

        fun handle(request: CloudASR.Request): CloudASR.Response {
            val code = if (status.isEmpty()) 200 else status[minOf(index, status.size - 1)]
            val payload = if (texts.isEmpty()) "" else texts[minOf(index, texts.size - 1)]
            prompts.add(prompt(request))
            audioBytes.add(audioLength(request))
            index++
            return CloudASR.Response(code, "{\"text\":\"$payload\"}".toByteArray())
        }
    }

    private fun segments(): List<FloatArray> {
        val samples = script(4.0 to true, 0.8 to false, 4.0 to true, 0.8 to false, 2.0 to true)
        return ChunkedASR.plan(samples).map { ChunkedASR.slice(samples, it) }
    }

    private fun flatten(segments: List<FloatArray>): FloatArray {
        val total = segments.sumOf { it.size }
        val out = FloatArray(total)
        var at = 0
        for (s in segments) { s.copyInto(out, at); at += s.size }
        return out
    }

    /** T10：三段都成功 → 接起來，而且每一段都帶著前一段的文字。 */
    @Test
    fun chunkedSuccessJoinsAndCarriesContext() {
        val fake = Fake(listOf("今天天氣很好", "天氣很好我們去公園", "公園門口有櫻花"))
        val segs = segments()
        val text = ChunkedASR.transcribeChunked(segs, flatten(segs), "zh-TW", listOf("UTUVO"), groq, "fake-key",
            transport = { req, _ -> fake.handle(req) }, log = CloudASR.NO_LOG)
        assertEquals("今天天氣很好我們去公園門口有櫻花", text)
        assertEquals(3, fake.prompts.size)
        assertTrue("每一段都帶同一份熱詞", fake.prompts[0].contains("UTUVO"))
        assertTrue("第二段帶第一段的結果", fake.prompts[1].contains("今天天氣很好"))
        assertTrue(fake.prompts[2].contains("我們去公園"))
        assertTrue(fake.audioBytes.all { it < 1_000_000 })
    }

    /** T11：任一段失敗 → 整段用舊做法重送一次。 */
    @Test
    fun chunkedFailureFallsBackToWholeRecording() {
        val segs = segments()
        val fake = Fake(listOf("第一段", "", "整段重送"), listOf(200, 500, 200, 200))
        val text = ChunkedASR.transcribeChunked(segs, flatten(segs), "zh-TW", emptyList(), groq, "fake-key",
            transport = { req, _ -> fake.handle(req) }, log = CloudASR.NO_LOG)
        assertEquals("整段重送", text)
        assertEquals(3, fake.index)
        assertTrue(fake.audioBytes.last() > fake.audioBytes[0])
    }

    /** T12：429（Groq 每分鐘請求數上限）→ 立刻改回整段一次送，不能讓使用者等更久。 */
    @Test
    fun chunkedRateLimitedFallsBackToWhole() {
        val segs = segments()
        val fake = Fake(listOf("第一段", "整段重送"), listOf(429, 200))
        val text = ChunkedASR.transcribeChunked(segs, flatten(segs), "zh-TW", emptyList(), groq, "fake-key",
            transport = { req, _ -> fake.handle(req) }, log = CloudASR.NO_LOG)
        assertEquals("整段重送", text)
        assertEquals(2, fake.index)
    }

    /** T13：段數只有一段時走舊做法，不做無謂的分段。 */
    @Test
    fun singleSegmentUsesWholePath() {
        val fake = Fake(listOf("整段"))
        val one = listOf(script(4.0 to true, 0.8 to false, 4.0 to true))
        val text = ChunkedASR.transcribeChunked(one, flatten(one), "zh-TW", emptyList(), groq, "fake-key",
            transport = { req, _ -> fake.handle(req) }, log = CloudASR.NO_LOG)
        assertEquals("整段", text)
        assertEquals(1, fake.index)
    }

    // MARK: - LiveCloudASR（Q3-repair1 ②③④）

    /** 一段 0.4 秒的「好。」——低於舊的 0.6 秒門檻。 */
    private fun shortTail() = script(0.4 to true)

    private fun fourSeconds() = script(4.0 to true)

    /** Q3-repair1 ②：很短的結尾（「好。」「謝謝」）一定要送出去，不能整段丟掉。 */
    @Test
    fun liveCloudSendsShortFinalSegment() {
        val fake = Fake(listOf("前面那段", "好。"))
        val live = LiveCloudASR(groq, "fake-key", "zh-TW", emptyList(),
            transport = { req, _ -> fake.handle(req) })
        live.submit(fourSeconds())
        val text = live.finish(shortTail(), fourSeconds())
        assertEquals("前面那段好。", text)
        assertEquals(2, fake.index)
    }

    /** Q3-repair1 ②的另一半：只有 0.4 秒的結尾也要切出來（Stream.finish 也要放行，門檻從 0.6 降到 0.25）。 */
    @Test
    fun shortTailIsCutFromStream() {
        val samples = script(0.4 to true)
        val cuts = ChunkedASR.plan(samples)
        assertEquals(1, cuts.size)
        val tailSeconds = ChunkedASR.slice(samples, cuts[0]).size / 16_000.0
        assertTrue("結尾應該約 0.4 秒，實際 $tailSeconds", Math.abs(tailSeconds - 0.4) < 0.05)
    }

    /** Q3-repair1 ③：連續送三段，結果仍依序接起來（順序不能亂）。 */
    @Test
    fun liveCloudKeepsSegmentOrder() {
        val fake = Fake(listOf("第一段", "第二段", "第三段"))
        val live = LiveCloudASR(groq, "fake-key", "zh-TW", emptyList(),
            transport = { req, _ -> fake.handle(req) })
        repeat(3) { live.submit(fourSeconds()) }
        val text = live.finish(null, fourSeconds())
        assertEquals("第一段第二段第三段", text)
        assertEquals(3, fake.index)
    }

    /**
     * Q3-repair1 ④：任一段被限流（429）就降級，**排隊中還沒送的段全部取消**，直接走整段。
     *
     * 修之前 worker 的任務開頭沒有再檢查 `degraded`，後面兩段照樣打網路；
     * `finish()` 還會用 `worker.submit{}.get(10, SECONDS)` 空等到滿才重送整段。
     */
    @Test
    fun liveCloudStopsSendingAfterRateLimited() {
        val fake = Fake(listOf("第一段", "整段重送"), listOf(429, 200))
        val live = LiveCloudASR(groq, "fake-key", "zh-TW", emptyList(),
            transport = { req, _ -> fake.handle(req) })
        repeat(3) { live.submit(fourSeconds()) }
        val started = System.nanoTime()
        val text = live.finish(null, fourSeconds())
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("429 之後要降級", live.fellBack)
        assertEquals("整段重送", text)
        assertEquals(2, fake.index)
        assertTrue("降級後要立刻走整段，不該空等 10 秒（實際 ${elapsedMs}ms）", elapsedMs < 3_000)
    }
}

/** 從 multipart body 抓出 prompt 欄位（body 裡有 WAV 位元組，不能整段轉字串）。 */
private fun prompt(request: CloudASR.Request): String {
    val marker = "name=\"prompt\"\r\n\r\n".toByteArray(Charsets.UTF_8)
    val start = indexOf(request.body, marker)
    if (start < 0) return ""
    val from = start + marker.size
    val end = indexOf(request.body, "\r\n--".toByteArray(Charsets.UTF_8), from)
    if (end < 0) return ""
    return String(request.body, from, end - from, Charsets.UTF_8)
}

/** audio/wav 那一段的位元組數（整段送 vs 分段送的大小比較用）。 */
private fun audioLength(request: CloudASR.Request): Int {
    val marker = "Content-Type: audio/wav\r\n\r\n".toByteArray(Charsets.UTF_8)
    val start = indexOf(request.body, marker)
    return if (start < 0) -1 else request.body.size - start - marker.size
}

private fun indexOf(haystack: ByteArray, needle: ByteArray, from: Int = 0): Int {
    outer@ for (i in from..haystack.size - needle.size) {
        for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
        return i
    }
    return -1
}
