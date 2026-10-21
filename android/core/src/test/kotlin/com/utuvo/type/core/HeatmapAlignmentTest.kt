package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 熱圖的星期對齊（2026-10-13 修補項 2）：列＝星期日～六、最後一欄＝含今天的那一週，
 * 今天之後的格子標 `future`。用固定日期驗證，今天＝2026-10-13（星期二）→ 落在第 2 列（index 2）。
 */
class HeatmapAlignmentTest {
    private val today = "2026-10-13"      // 星期二
    private val stats = UsageStats(
        mapOf(today to DailyCount(today, words = 30, seconds = 90, sessions = 2))
    )

    @Test
    fun `今天落在星期二那一列`() {
        assertEquals(2, LocalDay.weekday(today))
        val cells = stats.heatmap(today, weeks = 4)
        val last = cells.last()
        assertEquals(today, last[2].day)
        assertTrue(last[2].level > 0)
        assertTrue(!last[2].future)
    }

    @Test
    fun `最後一欄含今天 今天之後標成未來`() {
        val cells = stats.heatmap(today, weeks = 4)
        val last = cells.last()
        // 今天之後（週三～六）沒到過 → future
        for (row in 3..6) assertTrue(last[row].future, "row $row 應該是未來")
        for (row in 0..2) assertTrue(!last[row].future, "row $row 不應該是未來")
    }

    @Test
    fun `每一欄都從星期日開始 第一欄也是星期日`() {
        val cells = stats.heatmap(today, weeks = 4)
        assertEquals(4, cells.size)
        for ((ci, col) in cells.withIndex()) {
            assertEquals(7, col.size)
            for ((ri, cell) in col.withIndex()) assertEquals(ri, LocalDay.weekday(cell.day), "欄 $ci 列 $ri")
        }
        // 第一欄＝最早那週的星期日
        assertEquals(0, LocalDay.weekday(cells.first()[0].day))
    }

    @Test
    fun `最後一欄的星期日是今天往前數的星期日`() {
        val cells = stats.heatmap(today, weeks = 4)
        val lastSunday = cells.last()[0].day
        assertEquals(LocalDay.shift(today, -2), lastSunday)   // 週二往前兩天
        // 整張往左推回去：每一欄都是七天、欄與欄之間連續
        val flat = cells.flatten()
        for (i in 1 until flat.size) assertEquals(LocalDay.shift(flat[i - 1].day, 1), flat[i].day)
    }

    @Test
    fun `星期日的格子也不是未來`() {
        val sunday = "2026-10-11"     // 同一週的星期日
        val cells = UsageStats(mapOf(sunday to DailyCount(sunday, words = 5))).heatmap(sunday, weeks = 2)
        val last = cells.last()
        assertEquals(sunday, last[0].day)
        assertTrue(!last[0].future)
        assertTrue(last[1].future)
    }
}
