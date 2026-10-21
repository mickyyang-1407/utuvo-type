package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 使用數據（每日計數、連續天數、熱圖、保留期限、舊資料 decode）的 JVM 測試。
 * 覆蓋工單要求的：跨日、跨時區日界、空資料、舊格式。
 */
class UsageStatsTest {

    // ── 字數 ──

    @Test
    fun `CJK 逐字算、其他語言按空白分詞`() {
        assertEquals(0, WordCount.count(""))
        assertEquals(0, WordCount.count("，。！？ \n"))
        assertEquals(4, WordCount.count("今天天氣"))
        assertEquals(3, WordCount.count("你好嗎"))
        assertEquals(2, WordCount.count("hello world"))
        assertEquals(2, WordCount.count("  hello  world  "))
        assertEquals(5, WordCount.count("hi 蘋果手機"))          // 1 詞 + 4 字
        assertEquals(2, WordCount.count("2026 年"))              // 數字算一個詞 + 1 字
        assertEquals(3, WordCount.count("ATMOs 現場"))           // 1 詞 + 2 字
        assertEquals(4, WordCount.count("ひらがな"))               // 假名逐字
        assertEquals(3, WordCount.count("한국어"))
    }

    // ── 本機日界 ──

    @Test
    fun `日界用本機時區算`() {
        val tz = java.util.TimeZone.getDefault()
        try {
            java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("Asia/Taipei"))
            val m = LocalDay.startMillis("2026-10-13") + 3 * 3600_000L
            assertEquals("2026-10-13", LocalDay.key(m))
            java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("America/Los_Angeles"))
            // 同一毫秒在台北是 13 日、在洛杉磯還是 12 日（差 15 小時）
            assertEquals("2026-10-12", LocalDay.key(m))
        } finally {
            java.util.TimeZone.setDefault(tz)
        }
    }

    @Test
    fun `加减天数跨月跨年`() {
        assertEquals("2026-10-12", LocalDay.shift("2026-10-13", -1))
        assertEquals("2026-11-01", LocalDay.shift("2026-10-31", 1))
        assertEquals("2027-01-01", LocalDay.shift("2026-12-31", 1))
        assertEquals("2026-12-31", LocalDay.shift("2027-01-01", -1))
        assertEquals(30, LocalDay.daysBetween("2026-10-01", "2026-10-31"))
        assertEquals(1, LocalDay.daysBetween("2026-12-31", "2027-01-01"))
    }

    // ── 每日計數合併 ──

    @Test
    fun `同一天再記一次是相加不是取代`() {
        val s = UsageStats().record("2026-10-13", 10, 5).record("2026-10-13", 3, 2, sessions = 1)
        assertEquals(13, s.days.getValue("2026-10-13").words)
        assertEquals(7, s.days.getValue("2026-10-13").seconds)
        assertEquals(2, s.days.getValue("2026-10-13").sessions)
        assertEquals(1, s.days.size)
    }

    @Test
    fun `空資料不會爆`() {
        val empty = UsageStats()
        val t = empty.totals("2026-10-13")
        assertEquals(0, t.words); assertEquals(0, t.activeDays); assertEquals(0, t.currentStreak)
        assertEquals(0.0, t.wordsPerMinute); assertEquals(0.0, t.minutesSaved)
        assertEquals(26, empty.heatmap("2026-10-13").size)
        assertTrue(empty.heatmap("2026-10-13").all { c -> c.all { it.level == 0 } })
    }

    // ── 省下時間／速度 ──

    @Test
    fun `省下時間下限 0、平均速度用有時長的那些日`() {
        // 打字 40 字／分：40 字要打 1 分鐘；講了 20 秒 → 省 40 秒
        assertEquals(40.0 / 60.0, UsageStats.minutesSaved(40, 20), 1e-9)
        // 講太久反而比打字慢 → 0，不會是負的
        assertEquals(0.0, UsageStats.minutesSaved(10, 600), 1e-9)
        val s = UsageStats()
            .record("2026-10-12", 100, 60)   // 100 字／1 分 → 100 wpm
            .record("2026-10-13", 999, 0)     // 沒時長：不進平均
        assertEquals(100.0, s.totals("2026-10-13").wordsPerMinute, 1e-9)
        assertEquals(1099, s.totals("2026-10-13").words)
    }

    // ── 連續天數 ──

    @Test
    fun `連續天數今天沒講不算斷`() {
        val s = UsageStats().record("2026-10-12", 5, 3).record("2026-10-11", 5, 3)
        assertEquals(2, s.streaks("2026-10-13").current)
        val withToday = s.record("2026-10-13", 5, 3)
        assertEquals(3, withToday.streaks("2026-10-13").current)
    }

    @Test
    fun `斷掉的連續會停、最長連續看全部資料`() {
        val s = UsageStats()
            .record("2026-10-13", 5, 3)
            .record("2026-10-12", 5, 3)
            .record("2026-10-11", 5, 3)
            .record("2026-10-05", 5, 3)
            .record("2026-10-06", 5, 3)
        val st = s.streaks("2026-10-13")
        assertEquals(3, st.current)
        assertEquals(3, st.longest)
    }

    // ── 熱圖 ──

    @Test
    fun `熱圖是 26 欄 7 列、最後一欄含今天`() {
        val s = UsageStats().record("2026-10-13", 100, 10).record("2026-10-12", 1, 1)
        val heat = s.heatmap("2026-10-13", 26)
        assertEquals(26, heat.size)
        assertTrue(heat.all { it.size == 7 })
        val lastWeek = heat.last()
        // 2026-10-13 修補：列＝星期日～六，今天（星期二）落在第 2 列；今天之後是未來。
        assertEquals("2026-10-13", lastWeek[2].day)
        assertEquals(2, LocalDay.weekday("2026-10-13"))
        assertTrue(lastWeek.drop(3).all { it.future })
        assertEquals(26 * 7, heat.sumOf { it.size })
        assertEquals(2, heat.flatten().count { it.level > 0 })
    }

    @Test
    fun `熱圖 5 階顏色`() {
        assertEquals(0, UsageStats.levelOf(0, 100))
        assertEquals(1, UsageStats.levelOf(1, 100))
        assertEquals(5 - 1, UsageStats.levelOf(100, 100))
        assertTrue(UsageStats.levelOf(50, 100) in 1..4)
        assertEquals(0, UsageStats.levelOf(5, 0))
    }

    // ── 舊格式 / 壞資料 ──

    @Test
    fun `decode 舊檔、壞檔、空檔都不會失敗`() {
        assertEquals(UsageStats(), UsageStats.decode(null))
        assertEquals(UsageStats(), UsageStats.decode(""))
        assertEquals(UsageStats(), UsageStats.decode("not json at all"))
        assertEquals(UsageStats(), UsageStats.decode("{\"format\":\"utuvo-type-usage\",\"version\":1}"))
        val old = UsageStats.decode("""{"days":[{"day":"2026-10-13","words":12}]}""")
        assertEquals(12, old.days.getValue("2026-10-13").words)
        assertEquals(0, old.days.getValue("2026-10-13").seconds)
        // 壞的那筆丟掉，好的照收
        val partial = UsageStats.decode("""{"days":[{"words":1},{"day":"2026-10-13","words":7,"seconds":3,"sessions":2}]}""")
        assertEquals(1, partial.days.size)
        assertEquals(7, partial.days.getValue("2026-10-13").words)
    }

    @Test
    fun `encode 再 decode 資料一致`() {
        val s = UsageStats().record("2026-10-13", 9, 4).record("2026-10-12", 1, 1)
        assertEquals(s.days, UsageStats.decode(UsageStats.encode(s)).days)
    }

    // ── 保留期限 ──

    @Test
    fun `保留期限篩選`() {
        val now = LocalDay.startMillis("2026-10-13") + 12 * 3600_000L
        fun ago(days: Int) = now - days * 24 * 3600_000L
        assertTrue(HistoryRetention.keeps(HistoryRetention.DAY, ago(0), now))
        assertEquals(false, HistoryRetention.keeps(HistoryRetention.DAY, ago(2), now))
        assertTrue(HistoryRetention.keeps(HistoryRetention.WEEK, ago(2), now))
        assertEquals(false, HistoryRetention.keeps(HistoryRetention.WEEK, ago(8), now))
        assertTrue(HistoryRetention.keeps(HistoryRetention.MONTH, ago(20), now))
        assertEquals(false, HistoryRetention.keeps(HistoryRetention.MONTH, ago(40), now))
        assertTrue(HistoryRetention.keeps(HistoryRetention.YEAR, ago(300), now))
        assertEquals(false, HistoryRetention.keeps(HistoryRetention.YEAR, ago(400), now))
        // 永遠＝全留、不保留＝全刪
        assertTrue(HistoryRetention.keeps(HistoryRetention.FOREVER, ago(4000), now))
        assertEquals(false, HistoryRetention.keeps(HistoryRetention.NONE, now, now))
    }

    @Test
    fun `過期筆數與 parse 預設`() {
        val now = LocalDay.startMillis("2026-10-13")
        val times = listOf(now, now - 2 * 24 * 3600_000L, now - 5 * 24 * 3600_000L)
        assertEquals(2, HistoryRetention.expiredCount(times, HistoryRetention.DAY, now))
        assertEquals(0, HistoryRetention.expiredCount(times, HistoryRetention.FOREVER, now))
        assertEquals(3, HistoryRetention.expiredCount(times, HistoryRetention.NONE, now))
        assertEquals(HistoryRetention.FOREVER, HistoryRetention.parse(null))
        assertEquals(HistoryRetention.DEFAULT, HistoryRetention.parse("garbage"))
        assertEquals(HistoryRetention.WEEK, HistoryRetention.parse("1w"))
    }
}