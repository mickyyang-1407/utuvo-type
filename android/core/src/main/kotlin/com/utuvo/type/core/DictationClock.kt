package com.utuvo.type.core

/**
 * 一次聽寫的秒數：**停止聽寫的那一刻**就算好，交付（含雲端重辨識、翻譯）不再碰時鐘。
 *
 * 2026-10-13 修補：`finishSession` 先把開始時間歸零，`noteDictation` 才去算秒數，
 * 於是每次都回 0（講一分鐘也記 0 秒 → WPM、省下時間、總聽寫時間全錯）。
 * 純函式，放 core 才能在電腦上測。
 */
object DictationClock {
    /** 從開始到現在幾秒。沒在錄（[startedAt] ≤ 0）或時鐘倒退 → 0。 */
    fun elapsedSeconds(startedAt: Long, now: Long): Int {
        if (startedAt <= 0L || now <= startedAt) return 0
        return ((now - startedAt) / 1000L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    /**
     * 停止聽寫：把這次的秒數算出來存著，之後的交付都用這個值。
     * 講過就算過——不到一秒也記 1 秒，避免又變回 0。
     */
    fun freeze(startedAt: Long, now: Long): Int {
        if (startedAt <= 0L) return 0
        val seconds = elapsedSeconds(startedAt, now)
        return if (seconds > 0) seconds else 1
    }
}
