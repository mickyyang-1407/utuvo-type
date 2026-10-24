package com.utuvo.type

import java.util.concurrent.Executor
import java.util.concurrent.FutureTask

/**
 * 雲端重辨識的最後一段**按停當下就開跑**（capture-latency-1，Android 半邊）。純邏輯，JVM 測得到。
 *
 * 以前要等系統辨識器交回最終結果（onResults）才送最後一段：雲端的時間跟系統定稿的時間是**相加**。
 * 按停的那一刻音訊已經齊了（錄音已經停、最後一段已經取出），所以這時就丟上背景跑；
 * 系統結果到了只是拿來當退路與「謝謝收看」幻覺字的對照，等的是兩者中**比較慢**的那一個。
 *
 * [work] 用按停時間起算的總時限跑（跟以前「手上有系統文字」時同一個時限）。它放棄（回 null）時：
 *  - 系統有文字 → 回 null，呼叫端貼系統文字（跟以前一樣）；
 *  - 系統什麼都沒聽到（只能靠雲端救）→ 用 [await] 的 rescue 再送一次、不設總時限——不能為了快把唯一的結果也丟掉。
 */
internal class EarlyCloudFinish(executor: Executor, work: () -> String?) {
    private val task = FutureTask(work)

    init {
        executor.execute(task)
    }

    /** 不要了（換輸入框、取消、新的錄音開始）：中斷背景那一份，之後 [await] 一律回 null。 */
    fun cancel() {
        task.cancel(true)
    }

    val isCancelled: Boolean get() = task.isCancelled

    /**
     * 在背景執行緒上等結果（阻塞）。[raw]＝系統辨識器的文字。
     * 取消了就回 null、也不救援。
     */
    fun await(raw: String, rescue: () -> String?): String? {
        val text = try {
            task.get()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()   // 服務在收（shutdownNow）：不要再救援打網路
            return null
        } catch (_: Exception) {
            null   // 取消、背景那一份自己丟例外：當成雲端沒結果
        }
        if (text != null) return text
        if (task.isCancelled) return null
        return if (raw.isEmpty()) rescue() else null
    }
}

/**
 * 按停就開跑的雲端最後一段記著是**哪一次**語音的（mobile-keyboard-1 × capture-latency-1）。純邏輯，JVM 測得到。
 *
 *  - pending：按停時開跑、系統辨識器的結果還沒到（還沒被 deliverWithCloud 拿走）。
 *  - running：已經交給 cloudWorker 在等（同一時間只有一份，服務的 cloudAsrRunning 擋著）。
 *
 * ✕ 只收掉被取消的那一次的（[cancelTurn]）：上一次已經在等的那一份照常跑完、照常貼，
 * 系統什麼都沒聽到時的整段救援也照跑——以前 ✕ 一律收掉手上那一份，取消第 2 次會把第 1 次的雲端結果弄丟。
 */
internal class TurnCloudJobs<J : Any>(private val cancelJob: (J) -> Unit) {
    private var pending: Pair<Int, J>? = null
    private var running: Pair<Int, J>? = null

    val hasPending: Boolean get() = pending != null

    /** 按停：[turn] 這一次的那一份開跑。還留著別的（不該發生）就先收掉。 */
    fun begin(turn: Int, job: J) {
        pending?.let { cancelJob(it.second) }
        pending = turn to job
    }

    /** 系統結果到了：拿走 [turn] 這一次的那一份。留著的是別次的 → 收掉、不拿（別把別次的錄音結果貼進這一次）。 */
    fun claim(turn: Int): J? {
        val p = pending ?: return null
        pending = null
        if (p.first == turn) return p.second
        cancelJob(p.second)
        return null
    }

    /** 拿走的那一份交給 cloudWorker 在等（null＝這一次沒有按停就開跑的那一份）。 */
    fun running(turn: Int, job: J?) {
        running = job?.let { turn to it }
    }

    /** cloudWorker 等完了（不論結果）：同一份才清掉。 */
    fun done(job: J?) {
        if (job != null && running?.second === job) running = null
    }

    /** 新的一次開始、丟掉錄音：還沒人拿的那一份收掉（它的錄音已經不在了）。 */
    fun dropPending() {
        pending?.let { cancelJob(it.second) }
        pending = null
    }

    /** ✕ 取消 [turn]：只收那一次自己的，別次的一份都不碰。 */
    fun cancelTurn(turn: Int) {
        pending?.takeIf { it.first == turn }?.let { cancelJob(it.second); pending = null }
        running?.takeIf { it.first == turn }?.let { cancelJob(it.second); running = null }
    }

    /** 服務收掉：全部。 */
    fun cancelAll() {
        dropPending()
        running?.let { cancelJob(it.second) }
        running = null
    }
}
