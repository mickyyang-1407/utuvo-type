package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * 歷史頁分日／搜尋（對齊 Typeless 歷史）——案例搬自 iOS `ios/iOSTests/HistoryGroupingTests.swift`。
 * 純邏輯：不需要 Android 設定，跑在 JVM。
 */
class HistoryGroupingTest {
    private val zone = ZoneId.of("Asia/Taipei")

    /** 2026-09-17 12:00 台北。 */
    private val now: Long =
        LocalDateTime.of(2026, 9, 17, 12, 0).atZone(zone).toInstant().toEpochMilli()

    private fun millis(date: LocalDate, hour: Int): Long =
        date.atTime(hour, 0).atZone(zone).toInstant().toEpochMilli()

    private fun record(
        text: String,
        daysAgo: Int = 0,
        hour: Int = 10,
        raw: String? = null,
        today: LocalDate = LocalDate.of(2026, 9, 17),
    ) = HistoryGrouping.Item(
        time = millis(today.minusDays(daysAgo.toLong()), hour),
        raw = raw ?: text,
        cleaned = text,
    )

    // MARK: - 分日

    @Test
    fun sectionsGroupByDayNewestFirst() {
        val records = listOf(
            record("三天前", daysAgo = 3),
            record("今天早", daysAgo = 0, hour = 8),
            record("昨天", daysAgo = 1),
            record("今天晚", daysAgo = 0, hour = 20),
        )
        val sections = HistoryGrouping.sections(records, now, zone)
        assertEquals(listOf("今天", "昨天", "9月14日 週一"), sections.map { it.title })
        assertEquals(listOf("今天晚", "今天早"), sections[0].records.map { it.cleaned })
    }

    @Test
    fun dayTitleIncludesYearOnlyWhenDifferentYear() {
        val today = LocalDate.of(2026, 9, 17)
        assertEquals("2025年12月31日 週三", HistoryGrouping.dayTitle(LocalDate.of(2025, 12, 31), today))
        assertEquals("1月5日 週一", HistoryGrouping.dayTitle(LocalDate.of(2026, 1, 5), today))
    }

    /** 午夜前後兩筆要落在不同日。 */
    @Test
    fun midnightBoundary() {
        val lateYesterday = record("昨晚", daysAgo = 1, hour = 23)
        val earlyToday = record("今早", daysAgo = 0, hour = 0)
        val sections = HistoryGrouping.sections(listOf(lateYesterday, earlyToday), now, zone)
        assertEquals(2, sections.size)
        assertEquals("今天", sections[0].title)
        assertEquals("昨天", sections[1].title)
    }

    @Test
    fun emptyInputGivesNoSections() {
        assertTrue(HistoryGrouping.sections(emptyList(), now, zone).isEmpty())
    }

    /** 分日用使用者時區，不是 UTC：台北凌晨 0 點之前算前一天。 */
    @Test
    fun dayBoundaryFollowsDeviceZone() {
        val taipeiMidnight = millis(LocalDate.of(2026, 9, 17), 0)
        assertEquals(LocalDate.of(2026, 9, 17), HistoryGrouping.dayOf(taipeiMidnight, zone))
        assertEquals(LocalDate.of(2026, 9, 16), HistoryGrouping.dayOf(taipeiMidnight, ZoneOffset.UTC))
    }

    // MARK: - 搜尋

    @Test
    fun emptyQueryKeepsEverything() {
        val records = listOf(record("甲"), record("乙", daysAgo = 1))
        assertEquals(2, HistoryGrouping.filter(records, "").size)
        assertEquals(2, HistoryGrouping.filter(records, "   ").size)
    }

    @Test
    fun queryMatchesCleanedOrRawCaseInsensitive() {
        val records = listOf(
            record("Meeting at three"),
            record("清理後沒有這個字", raw = "嗯 原始有 Keyword 在這"),
            record("完全不相干"),
        )
        assertEquals(
            listOf("Meeting at three"),
            HistoryGrouping.filter(records, "MEETING").map { it.cleaned },
        )
        assertEquals(
            "raw 也要搜得到",
            listOf("清理後沒有這個字"),
            HistoryGrouping.filter(records, "keyword").map { it.cleaned },
        )
    }

    @Test
    fun multipleTermsMustAllMatch() {
        val records = listOf(
            record("明天下午三點開會"),
            record("明天早上"),
            record("下午三點"),
        )
        assertEquals(
            listOf("明天下午三點開會"),
            HistoryGrouping.filter(records, "明天 三點").map { it.cleaned },
        )
    }

    @Test
    fun fullWidthAndHalfWidthMatch() {
        val records = listOf(record("ＡＢＣ 全形"))
        assertEquals(1, HistoryGrouping.filter(records, "abc").size)
    }

    @Test
    fun diacriticsAreIgnored() {
        val records = listOf(record("café"))
        assertEquals(1, HistoryGrouping.filter(records, "cafe").size)
    }

    /** Android 的歷史資料層還沒有星標欄位，starredOnly 目前一律不命中（不假裝有這張卡）。 */
    @Test
    fun starredOnlyFindsNothingUntilRecordsCarryStars() {
        val records = listOf(record("星"), record("無", daysAgo = 1))
        assertTrue(HistoryGrouping.filter(records, "", starredOnly = true).isEmpty())
    }

    /** 搜尋結果也要能分日（搜尋框輸入後畫面結構不變）。 */
    @Test
    fun filterThenSections() {
        val records = listOf(
            record("今天開會", daysAgo = 0),
            record("昨天的會", daysAgo = 1),
        )
        val hit = HistoryGrouping.sections(HistoryGrouping.filter(records, "會"), now, zone)
        assertEquals(listOf("今天", "昨天"), hit.map { it.title })
    }
}
