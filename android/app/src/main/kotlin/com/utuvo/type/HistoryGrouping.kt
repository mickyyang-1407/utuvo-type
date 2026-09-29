package com.utuvo.type

import java.text.Normalizer
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * 歷史頁的純邏輯（移植 iOS `ios/Shared/HistoryGrouping.swift`）：搜尋過濾、依日分組、日期標題。
 * 沒有 Android 依賴，所以 JVM 單元測試（`HistoryGroupingTest`）直接跑同一份。
 *
 * 介面文字一律繁體中文（app 的語系），日期標題格式與 iOS 一致：
 * 今天／昨天／`9月14日 週一`／跨年才補年份的 `2025年12月31日 週三`。
 */
object HistoryGrouping {

    /** 歷史頁的一筆紀錄（與 `HistoryStore.Record` 同形；不綁 Android 型別，保持可測）。 */
    data class Item(val time: Long, val raw: String, val cleaned: String)

    /** 歷史頁的一個「日」區段。 */
    data class Section(val day: LocalDate, val title: String, val records: List<Item>)

    /** 星標（iOS 有、Android 目前資料層還沒有星標欄位，先留著介面開關不接）。 */
    private val WEEKDAYS = arrayOf("週一", "週二", "週三", "週四", "週五", "週六", "週日")

    /**
     * 搜尋：不分大小寫、不分全半形／重音；空白切成多個詞，每個詞都要命中（raw 或 cleaned）。
     * 空白查詢＝沒在搜，全部留著。
     */
    fun filter(records: List<Item>, query: String, starredOnly: Boolean = false): List<Item> {
        val terms = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.map { fold(it) }
        return records.filter { record ->
            if (starredOnly) return@filter false          // Android 還沒有星標，starredOnly 一律不命中
            if (terms.isEmpty()) return@filter true
            val haystack = listOf(fold(record.cleaned), fold(record.raw))
            terms.all { term -> haystack.any { it.contains(term) } }
        }
    }

    /**
     * 依日分組，最新的一天在前；同一天內最新的在前。
     * `now` 與 `zone` 決定「今天」是誰（測試固定 Asia/Taipei 與一個已知的 now）。
     */
    fun sections(
        records: List<Item>,
        now: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<Section> {
        val today = dayOf(now, zone)
        return records.groupBy { dayOf(it.time, zone) }
            .map { (day, items) -> Section(day, dayTitle(day, today), items.sortedByDescending { it.time }) }
            .sortedByDescending { it.day }
    }

    /** 今天／昨天／同年「9月14日 週一」／跨年「2025年12月31日 週三」。 */
    fun dayTitle(day: LocalDate, today: LocalDate): String {
        if (day == today) return "今天"
        if (day == today.minus(1, ChronoUnit.DAYS)) return "昨天"
        val weekday = WEEKDAYS[(day.dayOfWeek.value - 1).coerceIn(0, 6)]
        val year = if (day.year == today.year) "" else "${day.year}年"
        return "$year${day.monthValue}月${day.dayOfMonth}日 $weekday"
    }

    /** 毫秒時間落在哪一天（使用者所在的時區，不是 UTC）。 */
    fun dayOf(time: Long, zone: ZoneId): LocalDate =
        Instant.ofEpochMilli(time).atZone(zone).toLocalDate()

    /**
     * 搜尋比對用的正規化：轉小寫、全形英數摺成半形、去掉重音符號。
     * （`ＡＢＣ` 要能被 `abc` 搜到、`é` 要能被 `e` 搜到——同 iOS 的 widthInsensitive／diacriticInsensitive。）
     */
    fun fold(s: String): String {
        val halfWidth = StringBuilder(s.length)
        for (ch in s) {
            val c = ch.code
            // 全形 ASCII 區 U+FF01–U+FF5E 對應半形 0x21–0x7E；全形空白 U+3000 當一般空白。
            halfWidth.append(if (c in 0xFF01..0xFF5E) (c - 0xFEE0).toChar() else ch)
        }
        val decomposed = Normalizer.normalize(halfWidth, Normalizer.Form.NFD)
        return buildString {
            for (ch in decomposed) {
                val type = Character.getType(ch)
                if (type != Character.NON_SPACING_MARK.toInt() && type != Character.COMBINING_SPACING_MARK.toInt()) {
                    append(ch.lowercaseChar())
                }
            }
        }
    }
}
