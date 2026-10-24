package com.utuvo.type

import com.utuvo.type.core.EditScope
import com.utuvo.type.core.VoiceMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executor

/**
 * mobile-keyboard-1 × capture-latency-1（verify r2 medium）：一次語音的 ✕ 或收尾只動那一次自己的。
 *
 * 照 UTUVOImeService 的呼叫順序重播（stopListening → startEarlyCloudFinish → onResults → deliverWithCloud
 * → 又按光球 startListening/startCloudRecording → ✕ cancelVoiceTurn），用真的 [VoiceTurns]、[TurnCloudJobs]、
 * [EarlyCloudFinish]。背景執行緒換成手動執行器：雲端什麼時候「回來」由測試決定，不靠 sleep，每次結果一樣。
 */
class CrossTurnCancelTest {

    /** 手動執行器：[runAll] 之前背景那一份都還在「跑」（雲端還沒回來）。 */
    private class ManualExecutor : Executor {
        private val queue = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { queue.addLast(command) }
        fun runAll() { while (queue.isNotEmpty()) queue.removeFirst().run() }
    }

    private val helpWrite = TurnSnapshot(KeyboardMode.Dictate, VoiceMode.HELP_WRITE)

    /**
     * 第 1 次按停、雲端還在跑時開始第 2 次並按 ✕。回傳第 1 次那一份、兩次的 id。
     * [cloud]＝第 1 次的雲端（按停時開跑那一份）回來的文字。
     */
    private class CrossTurn(val turns: VoiceTurns, val jobs: TurnCloudJobs<EarlyCloudFinish>,
                            val executor: ManualExecutor, val early: EarlyCloudFinish, val first: Int, val second: Int)

    private fun cancelSecondWhileFirstWaits(first: TurnSnapshot, second: TurnSnapshot, cloud: () -> String?): CrossTurn {
        val turns = VoiceTurns()
        val jobs = TurnCloudJobs<EarlyCloudFinish> { it.cancel() }
        val executor = ManualExecutor()
        // 第 1 次：startListening → stopListening（按停）→ startEarlyCloudFinish：雲端最後一段開跑。
        val t1 = turns.start(first)
        turns.stopped(t1)
        turns.freezeSeconds(t1, 7)
        val early = EarlyCloudFinish(executor, cloud)
        jobs.begin(t1, early)
        // 系統結果到了 → deliverWithCloud：拿走這一次的那一份、交給 cloudWorker 等。
        val claimed = jobs.claim(t1)
        assertSame(early, claimed)
        jobs.running(t1, claimed)
        // 雲端還在跑（listening 已經是 false），使用者又按光球：第 2 次開始 → startCloudRecording → stopLiveCloud。
        val t2 = turns.start(second)
        jobs.dropPending()
        // 第 2 次按 ✕ → cancelVoiceTurn。
        val cancelled = turns.cancel()
        assertEquals("✕ 作廢的是第 2 次", t2, cancelled)
        jobs.cancelTurn(cancelled!!)
        return CrossTurn(turns, jobs, executor, early, t1, t2)
    }

    @Test
    fun `取消第 2 次不中斷第 1 次還在等的雲端，照第 1 次的走向（幫我寫）交付`() {
        val run = cancelSecondWhileFirstWaits(helpWrite, helpWrite) { "幫我寫一封請假信" }
        assertFalse("第 1 次的雲端不能被第 2 次的 ✕ 中斷", run.early.isCancelled)
        run.executor.runAll()   // 雲端回來
        var rescues = 0
        assertEquals("幫我寫一封請假信", run.early.await("") { rescues++; "整段重送" })
        assertEquals(0, rescues)
        run.jobs.done(run.early)
        // keyboard.post：第 1 次還活著，交付照它開始時的走向——不是 ✕ 歸零之後的聽寫（不然指示會被原樣貼出去）。
        assertTrue(run.turns.isLive(run.first))
        val route = run.turns.snapshot(run.first)!!
        assertEquals(VoiceMode.HELP_WRITE, route.voiceMode)
        assertFalse("幫我寫不是一般聽寫", route.dictating)
        assertEquals("秒數是第 1 次自己的，不被第 2 次的開始或 ✕ 歸零", 7, run.turns.seconds(run.first))
        assertNull("被取消的第 2 次沒有秒數", run.turns.seconds(run.second))
    }

    @Test
    fun `取消第 2 次：第 1 次系統沒聽到、雲端時限內放棄時照樣整段重送救回來`() {
        val dictate = TurnSnapshot(KeyboardMode.Dictate, VoiceMode.DICTATE)
        val run = cancelSecondWhileFirstWaits(dictate, dictate) { null }
        run.executor.runAll()
        var rescues = 0
        assertEquals("明天下午三點開會", run.early.await("") { rescues++; "明天下午三點開會" })
        assertEquals("唯一的結果不能因為第 2 次的 ✕ 丟掉", 1, rescues)
    }

    @Test
    fun `取消第 2 次：第 1 次手上有系統文字時照樣貼雲端文字`() {
        val dictate = TurnSnapshot(KeyboardMode.Dictate, VoiceMode.DICTATE)
        val run = cancelSecondWhileFirstWaits(dictate, dictate) { "明天下午三點開會" }
        run.executor.runAll()
        assertEquals("明天下午三點開會", run.early.await("明天下午3點開會") { "整段重送" })
        assertTrue(run.turns.snapshot(run.first)!!.dictating)
    }

    @Test
    fun `第 2 次是翻譯、第 1 次是改寫：各走各的`() {
        val target = Translation.all.first()
        val edit = TurnSnapshot(KeyboardMode.Dictate, VoiceMode.SPEAK_TO_EDIT, scope = EditScope.PARAGRAPH)
        val run = cancelSecondWhileFirstWaits(edit, TurnSnapshot(KeyboardMode.Translate(target), VoiceMode.SPEAK_TO_EDIT)) { "改得正式一點" }
        val first = run.turns.snapshot(run.first)!!
        assertNull("第 1 次不是翻譯", first.translateTarget)
        assertEquals("第 1 次的改寫範圍還在（✕ 清掉的是現在的 pendingScope）", EditScope.PARAGRAPH, first.scope)
        assertEquals(target, run.turns.snapshot(run.second)!!.translateTarget)
    }

    @Test
    fun `同一次按 ✕ 照樣中斷它自己的雲端：不救援、不貼`() {
        val turns = VoiceTurns()
        val jobs = TurnCloudJobs<EarlyCloudFinish> { it.cancel() }
        val executor = ManualExecutor()
        val t1 = turns.start(helpWrite)
        turns.stopped(t1)
        val early = EarlyCloudFinish(executor) { "晚到的雲端" }
        jobs.begin(t1, early)
        jobs.running(t1, jobs.claim(t1))
        assertEquals(t1, turns.cancel())
        jobs.cancelTurn(t1)
        assertTrue(early.isCancelled)
        executor.runAll()
        var rescues = 0
        assertNull(early.await("") { rescues++; "x" })
        assertEquals(0, rescues)
        assertFalse(turns.isLive(t1))
    }

    @Test
    fun `按停之後、系統結果還沒到就按 ✕：還沒人拿的那一份收掉`() {
        val turns = VoiceTurns()
        val jobs = TurnCloudJobs<EarlyCloudFinish> { it.cancel() }
        val t1 = turns.start(helpWrite)
        turns.stopped(t1)
        val early = EarlyCloudFinish(ManualExecutor()) { "x" }
        jobs.begin(t1, early)
        jobs.cancelTurn(turns.cancel()!!)
        assertTrue(early.isCancelled)
        assertFalse(jobs.hasPending)
    }

    @Test
    fun `系統結果拿到的是別次的那一份：收掉、不拿（別把別次的錄音結果貼進這一次）`() {
        val jobs = TurnCloudJobs<EarlyCloudFinish> { it.cancel() }
        val early = EarlyCloudFinish(ManualExecutor()) { "x" }
        jobs.begin(1, early)
        assertNull(jobs.claim(2))
        assertTrue(early.isCancelled)
        assertFalse(jobs.hasPending)
    }

    @Test
    fun `取消別次的 id 什麼都不收`() {
        val jobs = TurnCloudJobs<EarlyCloudFinish> { it.cancel() }
        val pending = EarlyCloudFinish(ManualExecutor()) { "x" }
        jobs.begin(3, pending)
        jobs.cancelTurn(2)
        assertFalse(pending.isCancelled)
        assertTrue(jobs.hasPending)
        jobs.cancelAll()   // 服務收掉：全部
        assertTrue(pending.isCancelled)
    }

    @Test
    fun `舊辨識器晚到的回呼不處理，也不會把新的一次改成整理中`() {
        val turns = VoiceTurns()
        val first = turns.start()
        turns.stopped(first)
        val second = turns.start()
        assertFalse("第 1 次的辨識器晚到的結果不併進第 2 次的 session", turns.accepts(first))
        assertTrue(turns.accepts(second))
        turns.stopped(first)   // 第 1 次晚到的收尾
        assertEquals("第 2 次還在錄音", VoiceTurns.Phase.RECORDING, turns.phase)
        turns.stopped(second)
        assertEquals(VoiceTurns.Phase.PROCESSING, turns.phase)
        turns.cancel()
        assertFalse("被取消的那一次的回呼照舊擋掉", turns.accepts(second))
        assertTrue("第 1 次本身沒被取消（雲端結果照貼）", turns.isLive(first))
    }

    @Test
    fun `每一次的走向只留最近幾次`() {
        val turns = VoiceTurns()
        val first = turns.start(helpWrite)
        turns.freezeSeconds(first, 5)
        repeat(16) { turns.start(TurnSnapshot(KeyboardMode.Dictate, VoiceMode.DICTATE)) }
        assertNull("太舊的不留（記憶體有上限）", turns.snapshot(first))
        assertNull(turns.seconds(first))
        assertEquals(VoiceMode.DICTATE, turns.snapshot(turns.current)!!.voiceMode)
        turns.freezeSeconds(first, 9)
        assertNull("太舊的不再記", turns.seconds(first))
        turns.freezeSeconds(turns.current, 0)
        assertNull("0 秒不記（交付時退回服務的計時）", turns.seconds(turns.current))
    }
}
