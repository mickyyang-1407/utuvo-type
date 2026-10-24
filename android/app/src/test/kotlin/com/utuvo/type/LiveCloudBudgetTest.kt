package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * capture-latency-v1（Android）：雲端重辨識從按停起算一個總時限（[CloudASR.timeLimit]，最多 6 秒），
 * 涵蓋「等前面幾段、送最後一段、整段退路」。修之前最差約 22 秒（等前段 10 秒＋最後一段 6 秒＋整段 6 秒）什麼都不貼，
 * 而且逾時／連不上之後會在同一條慢網路上整段重送。全部用假 transport，不打真網路、不碰真 key。
 */
class LiveCloudBudgetTest {
    private val sr = 16_000
    private val groq = SmartCleanup.Provider.GROQ

    private fun speech(seconds: Double): FloatArray =
        FloatArray((seconds * sr).toInt()) { i -> if (i % 2 == 0) 0.3f else -0.3f }

    /** 第 n 次請求怎麼回：照 [steps] 的順序，用完就一直用最後一個。 */
    private sealed interface Step {
        data class Ok(val text: String) : Step
        data class Status(val code: Int) : Step
        data class Sleep(val millis: Long) : Step
        object Unreachable : Step
    }

    private class Fake(private vararg val steps: Step) {
        val calls = AtomicInteger(0)
        fun send(): CloudASR.Response {
            val index = calls.getAndIncrement()
            return when (val step = steps[minOf(index, steps.size - 1)]) {
                is Step.Ok -> CloudASR.Response(200, "{\"text\":\"${step.text}\"}".toByteArray())
                is Step.Status -> CloudASR.Response(step.code, "{}".toByteArray())
                is Step.Sleep -> { Thread.sleep(step.millis); CloudASR.Response(200, "{\"text\":\"太晚了\"}".toByteArray()) }
                Step.Unreachable -> throw IOException("unreachable")
            }
        }
    }

    private fun live(fake: Fake) = LiveCloudASR(groq, "fake-key", "zh-TW", emptyList(), transport = { _, _ -> fake.send() })

    private fun budgetMs(wholeSeconds: Double) = (CloudASR.timeLimit(wholeSeconds) * 1000).toLong()

    /** ①最後一段卡住 10 秒（傳輸層不守逾時）→ 總時限 +0.3 秒內回 null，整段退路一次都沒打。 */
    @Test
    fun stuckFinalSegmentReturnsNullWithinBudgetWithoutWholeResend() {
        val fake = Fake(Step.Ok("前面那段"), Step.Sleep(10_000))
        val asr = live(fake)
        asr.submit(speech(4.0))
        waitFor { fake.calls.get() >= 1 }
        val whole = speech(5.0)
        val stoppedAt = System.nanoTime()
        val text = asr.finish(speech(1.0), whole, stoppedAtNanos = stoppedAt)
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - stoppedAt)
        assertNull(text)
        assertTrue("總時限 ${budgetMs(5.0)}ms，實際 ${elapsedMs}ms", elapsedMs <= budgetMs(5.0) + 300)
        Thread.sleep(300)   // 放棄之後背景也不准再打整段
        assertEquals("只送了前段＋最後一段，整段退路沒有被呼叫", 2, fake.calls.get())
    }

    /** ②最後一段立刻回 500（服務錯誤，不是網路）→ 在總時限內整段重送一次，結果正確。 */
    @Test
    fun serverErrorOnFinalSegmentStillRetriesWholeOnce() {
        val fake = Fake(Step.Ok("前面那段"), Step.Status(500), Step.Ok("整段重送"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        val tap = CloudASR.OutcomeTap()
        val text = asr.finish(speech(1.0), speech(5.0), log = tap)
        assertEquals("整段重送", text)
        assertEquals(3, fake.calls.get())
        assertEquals("ok", tap.last)
    }

    /** ③最後一段 429（剛剛才送的）→ 同一把 key 馬上整段重送大概還是 429：不重送，回 null。 */
    @Test
    fun rateLimitedFinalSegmentDoesNotResendWhole() {
        val fake = Fake(Step.Ok("前面那段"), Step.Status(429), Step.Ok("不該被送"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        val tap = CloudASR.OutcomeTap()
        assertNull(asr.finish(speech(1.0), speech(5.0), log = tap))
        assertEquals(2, fake.calls.get())
        assertEquals("http:429", tap.last)
    }

    /** 最後一段連不上 → 不在同一條網路上整段重送，記成網路問題（鍵盤據此提示「網路較慢」）。 */
    @Test
    fun unreachableFinalSegmentFallsBackWithoutResend() {
        val fake = Fake(Step.Ok("前面那段"), Step.Unreachable, Step.Ok("不該被送"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        val tap = CloudASR.OutcomeTap()
        assertNull(asr.finish(speech(1.0), speech(5.0), log = tap))
        assertEquals(2, fake.calls.get())
        assertEquals("transport", tap.last)
        assertEquals(CloudFallback.Notice.SLOW_NETWORK, CloudFallback.notice(tap.last, null, "裝置端文字"))
    }

    /** 錄音中某段連不上（降級原因是網路）→ 按停後也不整段重送，直接退回裝置端。 */
    @Test
    fun networkDegradedDuringRecordingSkipsWholeResend() {
        val fake = Fake(Step.Unreachable, Step.Ok("不該被送"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        waitFor { asr.fellBack }
        assertNull(asr.finish(speech(1.0), speech(5.0)))
        assertEquals(1, fake.calls.get())
    }

    /** 前面還有一段卡在網路上，總時限到了 → 回 null（接不出完整文字），不再送最後一段也不整段重送。 */
    @Test
    fun inFlightSegmentPastDeadlineGivesUp() {
        val fake = Fake(Step.Sleep(10_000), Step.Ok("不該被送"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        waitFor { fake.calls.get() >= 1 }
        val stoppedAt = System.nanoTime()
        val tap = CloudASR.OutcomeTap()
        assertNull(asr.finish(speech(1.0), speech(5.0), log = tap, stoppedAtNanos = stoppedAt))
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - stoppedAt)
        assertTrue("實際 ${elapsedMs}ms", elapsedMs <= budgetMs(5.0) + 300)
        assertEquals(1, fake.calls.get())
        assertEquals("timeout", tap.last)
    }

    /** 總時限從按停算：系統辨識器很晚才回、時間已經用完 → 不打網路，直接回 null。 */
    @Test
    fun budgetAlreadySpentMakesNoRequest() {
        val fake = Fake(Step.Ok("不該被送"))
        val asr = live(fake)
        val whole = speech(5.0)
        val stoppedAt = System.nanoTime() - TimeUnit.MILLISECONDS.toNanos(budgetMs(5.0) + 1_000)
        val tap = CloudASR.OutcomeTap()
        assertNull(asr.finish(null, whole, log = tap, stoppedAtNanos = stoppedAt))
        assertEquals(0, fake.calls.get())
        assertEquals("timeout", tap.last)
    }

    /** 不能改的：網路正常時照樣在總時限內拿到雲端文字。 */
    @Test
    fun healthyNetworkStillUsesCloudText() {
        val fake = Fake(Step.Ok("第一段"), Step.Ok("第二段"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        assertEquals("第一段第二段", asr.finish(speech(1.0), speech(5.0)))
        assertEquals(2, fake.calls.get())
    }

    /** 不能改的：沒有裝置端文字可退（stoppedAtNanos = null，只能靠雲端救）時照舊——連不上也整段重送一次。 */
    @Test
    fun rescueWithoutDeviceTextKeepsOldRetry() {
        val fake = Fake(Step.Ok("前面那段"), Step.Unreachable, Step.Ok("整段重送"))
        val asr = live(fake)
        asr.submit(speech(4.0))
        assertEquals("整段重送", asr.finish(speech(1.0), speech(5.0), stoppedAtNanos = null))
        assertEquals(3, fake.calls.get())
    }

    /** 整段一次送（沒分段）也守同一個總時限：時間用完不打網路、記 timeout。 */
    @Test
    fun wholePathRespectsRemainingBudget() {
        val calls = AtomicInteger(0)
        val tap = CloudASR.OutcomeTap()
        val result = CloudASR.transcribe(speech(5.0), "zh-TW", emptyList(), groq, "fake-key",
            transport = { _, _ -> calls.incrementAndGet(); CloudASR.Response(200, "{\"text\":\"不該被送\"}".toByteArray()) },
            log = tap, maxBudgetMs = 0)
        assertNull(result)
        assertEquals(0, calls.get())
        assertEquals("timeout", tap.last)
        // 剩下的時間 = 總時限 − 按停到現在。
        val stoppedAt = System.nanoTime() - TimeUnit.MILLISECONDS.toNanos(1_000)
        val left = CloudASR.remainingBudgetMs(stoppedAt, 5.0)
        assertTrue("剩 $left ms", left in (budgetMs(5.0) - 1_100)..(budgetMs(5.0) - 990))
    }

    private fun waitFor(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(5)
    }
}
