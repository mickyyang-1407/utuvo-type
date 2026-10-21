package com.utuvo.type

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 雲端辨識「邊錄邊傳」（對應 iOS `ios/App/ChunkedASR.swift`，2026-10-14）。
 *
 * Groq 只收整段檔案、不能真的串流，但它很快（實測講完後 0.51 秒中位／27 秒音檔）。
 * 所以錄音中偵測到停頓就把那一段先送去辨識、背景並行，講完時只送最後一段，再把各段結果依序接起來。
 *
 * 這裡只放純邏輯（切段、接段去重、上下文 prompt、走哪一條），不打網路；兩邊用同一組測試案例
 * （`ChunkedAsrChunkedTest.kt` ↔ `ios/iOSTests/ChunkedASRTests.swift`）。
 */
object ChunkedASR {

    /** 接段時最多往回比對幾個字（Whisper 兩段邊界最多重複這麼多）。 */
    const val MAX_OVERLAP_CHARS = 24

    /** 帶給下一段的上下文 prompt 長度上限（Whisper 的 prompt 欄位有長度限制）。 */
    const val CONTEXT_PROMPT_CHARS = 120

    // MARK: - 切段

    /** 已完成的一段：樣本索引，`end` 為 exclusive（等同 iOS `ChunkStream.Cut`）。 */
    data class Cut(val start: Int, val end: Int)

    /**
     * 錄音中累積樣本、偵測停頓、把已講完的段落交出去。
     *
     * 規則（與 iOS 相同）：
     * - 停頓 ≥ [minSilenceSeconds]（0.6 秒）且這一段已經講滿 [minSegmentSeconds]（3 秒）才切；
     * - 相鄰兩段音訊重疊 [overlapSeconds]（0.3 秒），接文字時才去得掉重複；
     * - 一次聽寫最多 [maxChunks]（6）段：Groq 免費額度有每分鐘請求數限制，超過就把尾巴併進最後一段。
     *
     * 只留「還沒切掉」的尾巴，記憶體不隨錄音長度成長。
     */
    class Stream @JvmOverloads constructor(
        private val sampleRate: Int = SAMPLE_RATE,
        private val maxChunks: Int = MAX_CHUNKS,
        private val minSilenceSeconds: Double = MIN_SILENCE_SECONDS,
        private val minSegmentSeconds: Double = MIN_SEGMENT_SECONDS,
        private val overlapSeconds: Double = OVERLAP_SECONDS,
        private val silenceThreshold: Float = SILENCE_THRESHOLD
    ) {
        private val buffer = ArrayList<Float>(SAMPLE_RATE * 4)
        private var base = 0            // buffer[0] 對應的絕對索引
        private var framePos = 0        // 尚未分析的樣本起點（buffer 內索引）
        private var silenceFrames = 0
        private var segmentStart = 0    // 目前這一段的絕對起點
        private var emitted = 0
        private var closed = false

        private val frameSamples = maxOf(1, (sampleRate * 0.02).toInt())
        private val silenceFramesNeeded = maxOf(1, Math.ceil(minSilenceSeconds / 0.02).toInt())
        private val minSegmentSamples = (minSegmentSeconds * sampleRate).toInt()
        private val overlapSamples = (overlapSeconds * sampleRate).toInt()

        @Synchronized
        fun push(samples: FloatArray): List<Cut> {
            if (closed || samples.isEmpty()) return emptyList()
            for (s in samples) buffer.add(s)
            val out = ArrayList<Cut>()
            while (framePos + frameSamples <= buffer.size) {
                var peak = 0f
                for (i in framePos until framePos + frameSamples) {
                    val v = abs(buffer[i]); if (v > peak) peak = v
                }
                framePos += frameSamples
                if (peak < silenceThreshold) {
                    silenceFrames++
                    continue
                }
                // 聲音回來了：剛才那段靜音夠長就切一刀，切在靜音中間。
                if (silenceFrames >= silenceFramesNeeded) makeCut()?.let { out.add(it) }
                silenceFrames = 0
            }
            return out
        }

        @Synchronized
        fun push(samples: FloatArray, from: Int, until: Int): List<Cut> =
            if (from >= until) emptyList() else push(samples.copyOfRange(from, until))

        /** 講完：把剩下的當最後一段（太短或已經送滿就不回）。 */
        @Synchronized
        fun finish(): Cut? {
            closed = true
            val start = segmentStart
            val end = base + buffer.size
            if (end <= start) return null
            if ((end - start).toDouble() / sampleRate < MIN_CHUNK_SECONDS) return null
            if (emitted >= maxChunks) return null
            emitted++
            return Cut(start, end)
        }

        /** 已送出的段數（給 log／測試看）。 */
        @get:Synchronized
        val emittedCount: Int get() = emitted

        private fun makeCut(): Cut? {
            val silenceSamples = silenceFrames * frameSamples
            // framePos 已經吃掉了這個「有聲音」的視窗，靜音要從它前面算回來。
            val silenceStart = base + framePos - frameSamples - silenceSamples
            val cutPoint = silenceStart + silenceSamples / 2
            if (cutPoint - segmentStart < minSegmentSamples) return null
            if (emitted >= maxChunks - 1) return null      // 最後一段留給 finish()
            val result = Cut(segmentStart, cutPoint)
            emitted++
            // 下一段從切點前 overlapSamples 開始：音訊重疊 0.3 秒，文字才去得掉重複。
            segmentStart = maxOf(0, cutPoint - overlapSamples)
            val keep = maxOf(0, segmentStart - base)
            if (keep > 0) {
                buffer.subList(0, keep).clear()
                base += keep
                framePos -= keep
            }
            return result
        }
    }

    const val SAMPLE_RATE = 16_000
    const val MAX_CHUNKS = 6
    const val MIN_SILENCE_SECONDS = 0.6
    const val MIN_SEGMENT_SECONDS = 3.0
    const val OVERLAP_SECONDS = 0.3

    /** 低於這個值算靜音（20 ms 視窗的峰值）。實麥克風底噪約 0.005～0.02，講話時峰值遠高於此。 */
    const val SILENCE_THRESHOLD = 0.012f

    /**
     * 尾巴短到這個長度就不值得打網路（＝ [CloudASR] 段路徑的 0.25 秒下限，兩端同一組值）。
     *
     * 2026-10-14（Q3-repair1 review-agy ①）：這裡原本是 0.6 秒，於是「好。」「謝謝」這種很短的
     * 結尾整段被丟掉（[Stream.finish] 回 null，連帶 [LiveCloudASR.finish] 也不送），使用者講的
     * 最後一句不見。既然 [transcribeSegment] 本來就擋 < 0.25 秒，這裡再高一階只是白白吃掉字。
     */
    const val MIN_CHUNK_SECONDS = 0.25

    private fun abs(v: Float) = if (v < 0f) -v else v

    /** 一次規劃（純函式版本）：整段樣本 → 段範圍。錄音中用 `push`／`finish`，測試與離線分析用這個。 */
    @JvmStatic
    @JvmOverloads
    fun plan(samples: FloatArray, sampleRate: Int = SAMPLE_RATE, maxChunks: Int = MAX_CHUNKS,
             minSilenceSeconds: Double = MIN_SILENCE_SECONDS, minSegmentSeconds: Double = MIN_SEGMENT_SECONDS,
             overlapSeconds: Double = OVERLAP_SECONDS, silenceThreshold: Float = SILENCE_THRESHOLD): List<Cut> {
        val stream = Stream(sampleRate, maxChunks, minSilenceSeconds, minSegmentSeconds, overlapSeconds, silenceThreshold)
        val cuts = ArrayList(stream.push(samples))
        stream.finish()?.let { cuts.add(it) }
        return cuts
    }

    /** 段範圍 → 音訊樣本。 */
    @JvmStatic
    fun slice(samples: FloatArray, cut: Cut): FloatArray {
        val lower = maxOf(0, minOf(cut.start, samples.size))
        val upper = maxOf(lower, minOf(cut.end, samples.size))
        return samples.copyOfRange(lower, upper)
    }

    // MARK: - 接段

    private val boundaryPunctuation = setOf(
        "，", "、", "。", "！", "？", "；", "：", "…", "．",
        ",", ".", "!", "?", ";", ":"
    )

    private fun isPunctuation(c: Char) = boundaryPunctuation.contains(c.toString())

    private fun isLatin(c: Char) = c.code < 128 && (c.isLetter() || c.isDigit())

    /** 比對時把空白拿掉（英文 "world" / " world" 要視為同一段）。 */
    private fun squash(s: String) = s.filter { !it.isWhitespace() }

    /**
     * 前段結果當下一段的上下文（Whisper prompt）：取尾巴，避免斷句處用字不一致。
     */
    @JvmStatic
    @JvmOverloads
    fun contextPrompt(previous: String, maxChars: Int = CONTEXT_PROMPT_CHARS): String {
        val trimmed = previous.trim()
        return if (trimmed.length <= maxChars) trimmed else trimmed.takeLast(maxChars)
    }

    /**
     * 兩段文字接起來：相鄰段音訊重疊 0.3 秒，這裡在文字層面把重複去掉；
     * 標點不重複（上一段已經有句號，下一段開頭的句號丟掉），而且不吃字（一定要真的對得上才砍）。
     */
    @JvmStatic
    fun join(previous: String, next: String): String {
        val head = previous
        var tail = next
        if (tail.isEmpty()) return head
        // 1) 邊界標點不重複。
        if (head.isNotEmpty() && tail.isNotEmpty() && isPunctuation(head.last()) && isPunctuation(tail.first())) {
            tail = tail.substring(1)
        }
        if (tail.isEmpty()) return head
        val a = head.trim()
        val b = tail.trim()
        // 2) 最長重疊：前段結尾 == 後段開頭（比對時忽略空白與大小寫，英文才接得起來）。
        var overlap = 0
        val maxK = minOf(MAX_OVERLAP_CHARS, a.length, b.length)
        if (maxK > 0) {
            for (candidate in maxK downTo 1) {
                val left = a.takeLast(candidate)
                val right = b.take(candidate)
                if (left.lowercase() == right.lowercase() || squash(left) == squash(right)) {
                    overlap = candidate
                    break
                }
            }
        }
        // leading 只算開頭空白（trimStart），兩端同一套（iOS ChunkedASR.swift 同名註解）。
        val leading = tail.length - tail.trimStart().length
        var rest = if (overlap > 0) tail.substring(leading + overlap) else tail.substring(leading)
        rest = rest.trimEnd()
        if (rest.isEmpty()) return head
        if (head.isEmpty()) return rest
        // 3) 拉丁字母之間才補空白（Whisper 英文會回 " world"）；中文本來就沒有空白，不要補。
        if (isLatin(head.last()) && isLatin(rest.first())) return "$head $rest"
        return head + rest
    }

    /** 全部的段依序接起來。 */
    @JvmStatic
    fun join(texts: List<String>): String = texts.fold("") { acc, text -> join(acc, text) }

    // MARK: - 走哪一條（純函式，兩邊同一組測試）

    /** 段數、限流、任一段失敗之後要走哪一條。 */
    enum class Route { WHOLE, MERGED, RATE_LIMITED, RETRY_WHOLE, CHUNKED }

    @JvmStatic
    @JvmOverloads
    fun route(segmentCount: Int, rateLimited: Boolean, anySegmentFailed: Boolean,
              maxChunks: Int = MAX_CHUNKS): Route = when {
        segmentCount <= 1 -> Route.WHOLE
        segmentCount > maxChunks -> Route.MERGED
        rateLimited -> Route.RATE_LIMITED
        anySegmentFailed -> Route.RETRY_WHOLE
        else -> Route.CHUNKED
    }

    // MARK: - 傳送

    /** 一段辨識的結果；要分得出「被限流」（429），因為那要立刻改回舊做法。 */
    enum class SegmentOutcome { OK, RATE_LIMITED, FAILED }

    /** 一段辨識的結果＋文字。 */
    data class SegmentResult(val outcome: SegmentOutcome, val text: String = "")

    /**
     * 邊錄邊傳的最後一步：各段結果依序接起來。
     *
     * 任一段失敗、或被限流（429）→ 整段用舊做法重送一次（`whole`）；再失敗回 null，
     * 呼叫端照現行行為退回裝置端（系統 SpeechRecognizer）的結果。
     */
    @JvmStatic
    fun transcribeChunked(segments: List<FloatArray>, whole: FloatArray, language: String,
                          hotwords: List<String>, provider: SmartCleanup.Provider, key: String,
                          transport: CloudASR.Transport = CloudASR.HttpTransport,
                          log: CloudASR.Log = CloudASR.NO_LOG,
                          guard: CloudASR.Guard = CloudASR.Guard(CloudASR::trimGuard)): String? {
        if (segments.size <= 1) {
            return CloudASR.transcribe(whole, language, hotwords, provider, key, transport, log, guard)
        }
        val texts = ArrayList<String>()
        var rateLimited = false
        var anySegmentFailed = false
        // 依序送：每一段都帶前一段的文字當上下文（Whisper prompt），順序不能亂。
        for (segment in segments) {
            val context = contextPrompt(texts.lastOrNull() ?: "")
            val result = transcribeSegment(segment, language, hotwords, provider, key, context, transport, guard)
            when (result.outcome) {
                SegmentOutcome.OK -> texts.add(result.text)
                SegmentOutcome.RATE_LIMITED -> rateLimited = true
                SegmentOutcome.FAILED -> anySegmentFailed = true
            }
            if (rateLimited || anySegmentFailed) break
        }
        return when (route(segments.size, rateLimited, anySegmentFailed)) {
            Route.CHUNKED -> {
                val joined = join(texts)
                if (joined.isEmpty()) {
                    CloudASR.transcribe(whole, language, hotwords, provider, key, transport, log, guard)
                } else joined
            }
            // 任何一段不順就整段重送一次；再失敗回 null → 呼叫端用裝置端結果。
            else -> CloudASR.transcribe(whole, language, hotwords, provider, key, transport, log, guard)
        }
    }

    /**
     * 送一段。[context]＝前一段的文字（Whisper prompt）。逾時、回 null 都不算被限流。
     */
    @JvmStatic
    fun transcribeSegment(segment: FloatArray, language: String, hotwords: List<String>,
                          provider: SmartCleanup.Provider, key: String, context: String?,
                          transport: CloudASR.Transport = CloudASR.HttpTransport,
                          guard: CloudASR.Guard = CloudASR.Guard(CloudASR::trimGuard)): SegmentResult {
        val seconds = segment.size / 16_000.0
        if (seconds < 0.25) return SegmentResult(SegmentOutcome.FAILED)
        if (key.isEmpty()) return SegmentResult(SegmentOutcome.FAILED)
        val budgetMs = (CloudASR.timeLimit(seconds) * 1000).toLong().coerceAtLeast(1)
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(budgetMs)
        val audio = CloudASR.wav(CloudASR.trimSilence(segment))
        val response: CloudASR.Response
        try {
            response = transport.send(
                CloudASR.makeRequest(provider, key, audio, language, hotwords, context = context),
                remainingMs(deadlineNanos))
        } catch (e: Exception) {
            return SegmentResult(SegmentOutcome.FAILED)
        }
        if (response.code != 200) {
            val outcome = if (response.code == 429) SegmentOutcome.RATE_LIMITED else SegmentOutcome.FAILED
            return SegmentResult(outcome)
        }
        val text = try { CloudASR.parse(response.body, provider) } catch (e: Exception) {
            return SegmentResult(SegmentOutcome.FAILED)
        }
        val cleaned = if (provider == SmartCleanup.Provider.GEMINI) CloudASR.stripCodeFence(text) else text
        val accepted = runCatching { guard.accept(cleaned, language, seconds) }.getOrNull()
        if (accepted.isNullOrEmpty()) return SegmentResult(SegmentOutcome.FAILED)
        if (CloudASR.looksLooping(accepted, seconds)) return SegmentResult(SegmentOutcome.FAILED)
        // 整段只有「謝謝大家收看」這類結尾句＝停頓裡的底噪被補字，當空段接。
        return SegmentResult(SegmentOutcome.OK, CloudASR.dropOutroHallucination(accepted))
    }

    private fun remainingMs(deadlineNanos: Long) =
        TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime()).coerceAtLeast(1)
}
/**
 * 錄音中送出去的段：依序送、每段帶前一段的文字當上下文；講完時只送最後一段，再把各段結果接起來。
 *
 * 任一段失敗或被限流（429）就停送，改由呼叫端走「整段一次送」的舊做法——不能讓使用者等更久。
 * 對應 iOS `ios/App/ChunkedASR.swift` 的 `LiveCloudASR` actor。
 */
class LiveCloudASR(
    private val provider: SmartCleanup.Provider,
    private val key: String,
    private val language: String,
    private val hotwords: List<String>,
    private val guard: CloudASR.Guard = CloudASR.Guard(CloudASR::trimGuard),
    private val transport: CloudASR.Transport = CloudASR.HttpTransport
) {
    private val lock = Any()
    private val texts = ArrayList<String>()
    private var degraded = false

    /** 已排進 worker、還沒跑完的段數。降級要靠它把佇列裡剩下的段作廢（2026-10-14 Q3-repair1 review-agy ④）。 */
    private val inFlight = java.util.concurrent.atomic.AtomicInteger(0)

    /** 依序送（單一執行緒）：下一段要帶前一段的文字當上下文，順序不能亂。 */
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "live-cloud-asr").apply { isDaemon = true }
    }

    /**
     * 錄音中偵測到停頓就呼叫（錄音執行緒 → 立刻丟進工作執行緒，不在錄音執行緒上等網路）。
     *
     * 降級（429／失敗）之後，佇列裡已排入但還沒跑的段一律作廢不再送：`degraded` 在鎖內檢查，
     * worker 的任務開頭也再檢查一次 —— 只有開頭那次是不夠的，段是在排隊當下就已經排進去了。
     */
    fun submit(chunk: FloatArray) {
        synchronized(lock) { if (degraded) return }
        inFlight.incrementAndGet()
        try {
            worker.execute {
                try {
                    // 已經降級：這段直接丟掉，不要再打網路。
                    if (synchronized(lock) { degraded }) return@execute
                    val context = synchronized(lock) { ChunkedASR.contextPrompt(texts.lastOrNull() ?: "") }
                    val result = ChunkedASR.transcribeSegment(chunk, language, hotwords, provider, key, context, transport, guard)
                    synchronized(lock) {
                        when (result.outcome) {
                            ChunkedASR.SegmentOutcome.OK -> texts.add(result.text)
                            // 任一段不順 → 整段重送（舊做法）
                            ChunkedASR.SegmentOutcome.RATE_LIMITED, ChunkedASR.SegmentOutcome.FAILED -> degraded = true
                        }
                    }
                } finally {
                    inFlight.decrementAndGet()
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            inFlight.decrementAndGet()   // abandon() 之後再送：不當成錯誤
        }
    }

    /** 已送完的段數（診斷／測試用）。 */
    val completedSegments: Int get() = synchronized(lock) { texts.size }

    /** 有沒有因為失敗或被限流而退回舊做法。 */
    val fellBack: Boolean get() = synchronized(lock) { degraded }

    /**
     * 講完：等前面都送完，送最後一段，接起來。
     * `last`＝還沒講完的最後一段；`whole`＝整段錄音（任何退路都用它走舊做法）。
     * 阻塞：呼叫端本來就在背景執行緒上等雲端。
     */
    fun finish(last: FloatArray?, whole: FloatArray, log: CloudASR.Log = CloudASR.NO_LOG,
              guard: CloudASR.Guard = this.guard): String? {
        // 2026-10-14（Q3-repair1 review-agy ④）：原本用 `worker.submit{}.get(10, SECONDS)` 空等佇列排乾，
        // 一旦降級就白白等滿 10 秒才重送整段。改成：降級就立刻走整段；沒降級才等前面幾段跑完
        // （有上限，仍是保險不是保證 —— 正常情況每一段都有 CloudASR.timeLimit 兜底）。
        if (!synchronized(lock) { degraded }) awaitQueued(10_000)
        fun wholeFallback(): String? =
            CloudASR.transcribe(whole, language, hotwords, provider, key, transport, log, guard)

        if (synchronized(lock) { degraded }) { worker.shutdownNow(); return wholeFallback() }
        // 收工：這次的分段工作階段結束，執行緒不要留著空等（下面每個 return 之前都不再各自 shutdown）。
        worker.shutdown()
        val done = synchronized(lock) { ArrayList(texts) }
        if (done.isEmpty()) return wholeFallback()
        // 上限守門：段數超過就整段一次送（正常情況切段時已經卡住，這裡只是保險）。
        if (done.size >= ChunkedASR.MAX_CHUNKS) return wholeFallback()
        if (last == null || last.size / 16_000.0 < ChunkedASR.MIN_CHUNK_SECONDS) return ChunkedASR.join(done)
        val context = ChunkedASR.contextPrompt(done.last())
        val result = ChunkedASR.transcribeSegment(last, language, hotwords, provider, key, context, transport, guard)
        return when (result.outcome) {
            ChunkedASR.SegmentOutcome.OK -> ChunkedASR.join(done + result.text)
            ChunkedASR.SegmentOutcome.RATE_LIMITED, ChunkedASR.SegmentOutcome.FAILED -> wholeFallback()
        }
    }

    /**
     * 等 worker 裡排隊的段跑完，最多 [timeoutMs]。
     *
     * 用 `inFlight` 計數而不是塞一個空任務去排隊：降級時排隊中的段會立刻作廢回來（[submit] 開頭的檢查），
     * 這裡的迴圈下一圈就看出 `degraded` 而直接返回，不會白等到逾時。逾時只在真的卡住時才會碰到 ——
     * 而每一段本身都有 `CloudASR.timeLimit` 兜底，所以這只是保險。
     */
    private fun awaitQueued(timeoutMs: Long) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (inFlight.get() > 0) {
            if (synchronized(lock) { degraded }) return
            val remain = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            if (remain <= 0) return
            Thread.sleep(minOf(remain, 50))
        }
    }

    /** 使用者中途放棄 → 丟掉背景工作。 */
    fun abandon() {
        synchronized(lock) { degraded = true; texts.clear() }
        worker.shutdownNow()
    }
}
