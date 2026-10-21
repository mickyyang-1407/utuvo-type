package com.utuvo.type.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * 聽寫歷史的檔案格式（純邏輯，不碰 Android；放 core 才能在電腦上測舊資料相容）。
 *
 * 相容性：舊檔只有 `time` / `raw` / `cleaned`，**沒有 duration** —— 讀不出時長不是錯誤，
 * 那一筆就當「不知道多長」（[Record.durationSec] = 0），整份歷史照樣讀得出來。
 */
object HistoryCodec {
    const val MAX = 500

    data class Record(val time: Long, val raw: String, val cleaned: String, val durationSec: Int = 0) {
        /** 上限 100 小時：負數、零、亂寫的字串都當「未知」，不讓整份檔案讀不出來。 */
        fun normalized() = copy(durationSec = if (durationSec in 1..MAX_SECONDS) durationSec else 0)
    }

    const val MAX_SECONDS = 100 * 3600

    fun decode(text: String?): List<Record> {
        if (text.isNullOrBlank()) return emptyList()
        return runCatching {
            val a = JSONArray(text)
            (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val time = o.optLong("time", Long.MIN_VALUE)
                if (time == Long.MIN_VALUE) return@mapNotNull null
                Record(
                    time,
                    o.optString("raw"),
                    o.optString("cleaned"),
                    o.optInt("duration", 0),
                ).normalized()
            }
        }.getOrDefault(emptyList())
    }

    fun encode(records: List<Record>): String {
        val a = JSONArray()
        for (r in records) {
            a.put(JSONObject().put("time", r.time).put("raw", r.raw).put("cleaned", r.cleaned)
                .apply { if (r.durationSec > 0) put("duration", r.durationSec) })
        }
        return a.toString()
    }
}