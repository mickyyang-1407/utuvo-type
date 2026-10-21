package com.utuvo.type

import android.content.Context
import com.utuvo.type.core.LocalDay
import com.utuvo.type.core.UsageStats
import com.utuvo.type.core.WordCount
import java.io.File

/**
 * 使用數據（每日計數）：**單一寫入點**，鍵盤服務與主 app 不論同 process 或不同 process 都走這裡。
 *
 * ・只存數字（字數／秒數／次數），不存任何文字
 * ・不受歷史 500 筆上限影響；使用者刪歷史或清空歷史都不會動到這份
 * ・寫檔用 tmp＋rename 原子替換，避免兩個 process 同時寫壞 JSON
 */
object UsageStore {
    private const val FILE = "usage.json"

    private fun file(c: Context) = File(c.filesDir, FILE)

    /**
     * 讀改寫整段共用同一把鎖（同 [HistoryStore] 的做法，2026-10-13 修補）：
     * 每個方法各標 `@Synchronized` 鎖不到「A 的 load ＋ B 的 save」這種交錯。
     */
    private val lock = Any()

    fun load(c: Context): UsageStats = synchronized(lock) { loadLocked(c) }

    private fun loadLocked(c: Context): UsageStats = UsageStats.decode(runCatching { file(c).readText() }.getOrNull())

    /** 今天（以傳入的時間算，跑分與測試可以指定）。 */
    fun today(now: Long = System.currentTimeMillis()): String = LocalDay.key(now)

    /**
     * 記一次聽寫。這是**唯一**的寫入口：App 內與鍵盤內都呼叫這裡。
     *
     * @param text 逐字稿或整理後文字（只拿去算字數，不會存下來）
     * @param seconds 錄音秒數；未知（0 或負）就當沒有時長，不影響字數與次數
     */
    fun record(c: Context, text: String, seconds: Int, now: Long = System.currentTimeMillis()) = synchronized(lock) {
        val words = WordCount.count(text)
        val stats = loadLocked(c).record(today(now), words, seconds.coerceAtLeast(0), sessions = 1)
        writeLocked(c, stats)
    }

    /** 測試／資料補登用：直接加一筆每日計數。 */
    fun recordDay(c: Context, day: String, words: Int, seconds: Int, sessions: Int = 1) = synchronized(lock) {
        writeLocked(c, loadLocked(c).record(day, words, seconds, sessions))
    }

    fun save(c: Context, stats: UsageStats) = synchronized(lock) { writeLocked(c, stats) }

    private fun writeLocked(c: Context, stats: UsageStats) {
        val json = UsageStats.encode(stats)
        // tmp 檔名帶 thread id：有漏網的並行寫也不會搶同一個 tmp。
        val tmp = File(c.filesDir, "$FILE.${Thread.currentThread().id}.tmp")
        tmp.writeText(json)
        if (!tmp.renameTo(file(c))) {
            // rename 在少數檔案系統上會跨檔案系統失敗：退回覆蓋寫（還是同一個目錄，風險低很多）。
            file(c).writeText(json)
            tmp.delete()
        }
    }
}