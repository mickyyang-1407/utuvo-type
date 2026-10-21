package com.utuvo.type.core

import java.util.Calendar
import java.util.Locale
import org.json.JSONObject

/**
 * 使用數據（Typeless 手機版的 Home insights）：每天只存數字——字數、說話秒數、聽寫次數。
 * **不存任何文字**（隱私），不受歷史 500 筆上限影響，使用者刪歷史也不會動到這份。
 *
 * 這裡全部是純邏輯（不碰 Android API），所以電腦上就能測。
 * 「天」以本機時區的日界算（`dayKey`），跟使用者看到的一模一樣。
 */
object WordCount {
    /** 中日韓逐字算一個字，其他語言按空白切詞（同 Mac 版／iOS UsageInsights）。 */
    fun count(text: String): Int {
        var cjk = 0
        var words = 0
        var inWord = false
        for (ch in text) {
            if (isCJK(ch)) {
                cjk += 1
                inWord = false
            } else if (ch.isLetterOrDigit()) {
                if (!inWord) { words += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return cjk + words
    }

    fun isCJK(ch: Char): Boolean {
        val v = ch.code
        return v in 0x3400..0x9FFF || v in 0xF900..0xFAFF || v in 0x3040..0x30FF || v in 0xAC00..0xD7AF
    }
}

/** 本機時區的日界：同一毫秒在台北是 10/13、在倫敦可能是 10/12，連續天數要跟這個走。 */
object LocalDay {
    /** `yyyy-MM-dd`（本機時區）。 */
    fun key(millis: Long): String {
        val c = Calendar.getInstance()
        c.timeInMillis = millis
        return String.format(Locale.US, "%04d-%02d-%02d",
            c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
    }

    /** 這個 key 的當天 00:00 在本機時區的毫秒。key 格式壞掉就回 0。 */
    fun startMillis(key: String): Long {
        val p = key.split("-")
        if (p.size != 3) return 0L
        val (y, m, d) = p.map { it.toIntOrNull() ?: return 0L }
        val c = Calendar.getInstance()
        c.clear()
        c.set(y, m - 1, d, 0, 0, 0)
        c.set(Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }

    /** key 加減天數（跨月、跨年、跨 DST 都走日曆，不用 86400000 加法）。 */
    fun shift(key: String, days: Int): String {
        val start = startMillis(key)
        if (start == 0L) return key
        val c = Calendar.getInstance()
        c.timeInMillis = start
        c.add(Calendar.DAY_OF_MONTH, days)
        return key(c.timeInMillis)
    }

    /** 星期幾：0＝星期日 … 6＝星期六（本機時區）。key 壞掉回 0。 */
    fun weekday(key: String): Int {
        val start = startMillis(key)
        if (start == 0L) return 0
        val c = Calendar.getInstance().apply { timeInMillis = start }
        return c.get(Calendar.DAY_OF_WEEK) - 1
    }

    fun daysBetween(from: String, to: String): Int? {
        val a = startMillis(from); val b = startMillis(to)
        if (a == 0L || b == 0L) return null
        val ca = Calendar.getInstance().apply { timeInMillis = a }
        val cb = Calendar.getInstance().apply { timeInMillis = b }
        // 用「午夜」的時間差換算整天，不要直接除 86400000（DST 那天會差一小時）。
        return Math.round((b - a) / 86_400_000.0).toInt()
    }
}

/** 一天的計數。沒有文字，只有數字。 */
data class DailyCount(val day: String, val words: Int = 0, val seconds: Int = 0, val sessions: Int = 0)

/** 一天的用量小計。 */
data class UsageTotals(
    val words: Int = 0,
    val seconds: Int = 0,
    val sessions: Int = 0,
    val activeDays: Int = 0,
    val currentStreak: Int = 0,
    val longestStreak: Int = 0,
    /** 省下的分鐘：打字 40 wpm − 實際說話時間，逐日取下限 0 再加（每天少講不該被別天的量補回來）。 */
    val minutesSaved: Double = 0.0,
    /** 平均說話速度（字／分）。沒時長的日不算，所以是「有時長的那些日」的加權平均。 */
    val wordsPerMinute: Double = 0.0,
)

data class Streaks(val current: Int, val longest: Int)

/** 活動熱圖一格。[future]＝這一天還沒到（今天之後），畫的時候不要畫顏色。 */
data class HeatCell(val day: String, val words: Int, val level: Int, val future: Boolean = false)

/**
 * 每日計數本體：日期 → 計數。單一寫入點、原子寫檔在 app 層（`UsageStore`），
 * 這裡只負責合併與統計。
 */
data class UsageStats(val days: Map<String, DailyCount> = emptyMap()) {

    /** 同一天再記一次就往上加（合併，不是取代）。 */
    fun record(day: String, words: Int, seconds: Int, sessions: Int = 1): UsageStats {
        val cur = days[day] ?: DailyCount(day)
        return copy(days = days + (day to DailyCount(
            day, cur.words + words.coerceAtLeast(0), cur.seconds + seconds.coerceAtLeast(0),
            cur.sessions + sessions.coerceAtLeast(0))))
    }

    fun totals(today: String): UsageTotals {
        var words = 0; var seconds = 0; var sessions = 0; var active = 0; var saved = 0.0; var wpmWords = 0; var wpmSeconds = 0
        for (d in days.values) {
            words += d.words; seconds += d.seconds; sessions += d.sessions
            if (d.sessions > 0 || d.words > 0) active++
            saved += minutesSaved(d.words, d.seconds)
            if (d.seconds > 0) { wpmWords += d.words; wpmSeconds += d.seconds }
        }
        val streak = streaks(today)
        return UsageTotals(
            words = words, seconds = seconds, sessions = sessions, activeDays = active,
            currentStreak = streak.current, longestStreak = streak.longest,
            minutesSaved = saved,
            wordsPerMinute = if (wpmSeconds > 0) wpmWords * 60.0 / wpmSeconds else 0.0,
        )
    }

    /**
     * 連續天數。今天還沒講不算斷（從昨天往回算）；往回遇到空缺就停。
     */
    fun streaks(today: String): Streaks {
        var current = 0
        var cursor = if (days[today]?.let { it.sessions > 0 || it.words > 0 } == true) today else LocalDay.shift(today, -1)
        while (days[cursor]?.let { it.sessions > 0 || it.words > 0 } == true) {
            current++
            cursor = LocalDay.shift(cursor, -1)
        }
        val sorted = days.filterValues { it.sessions > 0 || it.words > 0 }.keys.sorted()
        var longest = 0; var run = 0; var prev: String? = null
        for (d in sorted) {
            val contiguous = prev != null && LocalDay.daysBetween(prev, d) == 1
            run = if (contiguous) run + 1 else 1
            if (run > longest) longest = run
            prev = d
        }
        return Streaks(current, longest)
    }

    /**
     * 熱圖：最近 [weeks] 週，欄＝週、列＝星期日～六（本機時區），5 階顏色（0 沒活動、1～4 由多到少）。
     *
     * 2026-10-13 修補：以前從 `today - (weeks*7-1)` 天直接排 7 個一組，列跟星期完全對不上
     * （今天不一定落在星期二那列）。現在整張的起點一定是星期日、最後一欄一定含今天，
     * 今天之後的格子標 [HeatCell.future]。
     */
    fun heatmap(today: String, weeks: Int = 26): List<List<HeatCell>> {
        val w = weeks.coerceAtLeast(1)
        // 最後一欄＝含 today 的那一週 → 該欄的星期日往回推 w-1 週就是第一欄的星期日。
        val sunday = LocalDay.shift(today, -LocalDay.weekday(today))
        val firstDay = LocalDay.shift(sunday, -(w - 1) * 7)
        val all = (0 until w * 7).map { LocalDay.shift(firstDay, it) }
        val max = all.maxOfOrNull { days[it]?.words ?: 0 } ?: 0
        return (0 until w).map { col ->
            (0 until 7).map { row ->
                val day = all[col * 7 + row]
                val words = days[day]?.words ?: 0
                val future = LocalDay.daysBetween(today, day)?.let { it > 0 } ?: false
                HeatCell(day, words, levelOf(words, max), future)
            }
        }
    }

    /** 只保留 [days] 內的日期（含），其餘丟掉。 */
    fun pruned(keepDays: Set<String>): UsageStats =
        copy(days = days.filterKeys { it in keepDays })

    companion object {
        const val FORMAT = "utuvo-type-usage"
        const val VERSION = 1
        /** 打字速度基準（同 Mac 版）：40 字／分。 */
        const val TYPING_WPM = 40.0

        /** 省下的分數，下限 0。 */
        fun minutesSaved(words: Int, seconds: Int): Double =
            (words / TYPING_WPM - seconds / 60.0).coerceAtLeast(0.0)

        /** 5 階：0＝沒活動；1～4 依這段期間的最大值等分。 */
        fun levelOf(words: Int, max: Int): Int {
            if (words <= 0 || max <= 0) return 0
            return 1 + (((words - 1).toLong() * 4 / max).toInt()).coerceAtMost(3)
        }

        fun encode(stats: UsageStats): String {
            val o = JSONObject()
            o.put("format", FORMAT); o.put("version", VERSION)
            val arr = org.json.JSONArray()
            for (d in stats.days.values.sortedBy { it.day }) {
                arr.put(JSONObject().put("day", d.day).put("words", d.words)
                    .put("seconds", d.seconds).put("sessions", d.sessions))
            }
            o.put("days", arr)
            return o.toString()
        }

        /** 舊／壞的檔案讀不出來就當沒資料（不准讓使用數據整個打不開）。 */
        fun decode(text: String?): UsageStats {
            if (text.isNullOrBlank()) return UsageStats()
            return runCatching {
                val o = JSONObject(text)
                val arr = o.optJSONArray("days") ?: return@runCatching UsageStats()
                val out = LinkedHashMap<String, DailyCount>()
                for (i in 0 until arr.length()) {
                    val e = arr.optJSONObject(i) ?: continue
                    val day = e.optString("day")
                    if (day.isEmpty()) continue
                    out[day] = DailyCount(day,
                        e.optInt("words", 0).coerceAtLeast(0),
                        e.optInt("seconds", 0).coerceAtLeast(0),
                        e.optInt("sessions", 0).coerceAtLeast(0))
                }
                UsageStats(out)
            }.getOrDefault(UsageStats())
        }
    }
}

/** 歷史保留期限（只砍歷史紀錄，**不動每日計數**）。 */
enum class HistoryRetention(val id: String) {
    DAY("24h"), WEEK("1w"), MONTH("1m"), YEAR("1y"), FOREVER("forever"), NONE("none");

    companion object {
        val DEFAULT = FOREVER
        fun parse(id: String?) = entries.firstOrNull { it.id == id } ?: DEFAULT

        /** 從 [nowMillis] 往前的門檻（毫秒）；FOREVER／NONE 回 null（＝沒有時間門檻）。 */
        fun cutoffMillis(retention: HistoryRetention, nowMillis: Long): Long? = when (retention) {
            DAY -> nowMillis - 24L * 3600 * 1000
            WEEK -> nowMillis - 7L * 24 * 3600 * 1000
            MONTH -> nowMillis - 30L * 24 * 3600 * 1000
            YEAR -> nowMillis - 365L * 24 * 3600 * 1000
            FOREVER, NONE -> null
        }

        /** 這筆紀錄（[recordTime]）留不留。NONE＝一律不留。 */
        fun keeps(retention: HistoryRetention, recordTime: Long, nowMillis: Long): Boolean = when (retention) {
            NONE -> false
            else -> cutoffMillis(retention, nowMillis)?.let { recordTime >= it } ?: true
        }

        /** 會被砍掉幾筆（給確認對話框講清楚）。 */
        fun expiredCount(times: List<Long>, retention: HistoryRetention, nowMillis: Long): Int =
            times.count { !keeps(retention, it, nowMillis) }
    }
}