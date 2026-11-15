package com.utuvo.type

import android.content.Context

/**
 * 按停到辨識完成（貼出第一版文字）的時間，最近 20 筆（同 iOS `StopLatencyLog`）。
 * 每筆存「毫秒,1/0」（1＝按停當下就送雲端最後一段）；設定頁顯示中位數。正式版也記，只有數字、不含文字。
 * 純邏輯（[append]、[summarize]）不碰 Android，JVM 測得到。
 */
object StopLatencyLog {
    private const val PREF = "stopLatency"
    private const val KEY = "rows"
    const val KEEP = 20

    data class Summary(val medianMs: Int, val count: Int, val early: Int)

    fun append(rows: List<String>, ms: Long, early: Boolean): List<String> =
        (rows + "${ms.coerceIn(0L, Int.MAX_VALUE.toLong())},${if (early) 1 else 0}").takeLast(KEEP)

    fun summarize(rows: List<String>): Summary? {
        val parsed = rows.mapNotNull { row ->
            val parts = row.split(',')
            val ms = parts.getOrNull(0)?.toIntOrNull()
            if (parts.size != 2 || ms == null) null else ms to (parts[1] == "1")
        }
        if (parsed.isEmpty()) return null
        val sorted = parsed.map { it.first }.sorted()
        val mid = sorted.size / 2
        val median = if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2
        return Summary(median, parsed.size, parsed.count { it.second })
    }

    private fun rows(c: Context): List<String> =
        c.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString(KEY, null)
            ?.split(';')?.filter { it.isNotEmpty() } ?: emptyList()

    fun record(c: Context, ms: Long, early: Boolean) {
        c.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
            .putString(KEY, append(rows(c), ms, early).joinToString(";")).apply()
    }

    fun summary(c: Context): Summary? = summarize(rows(c))
}
