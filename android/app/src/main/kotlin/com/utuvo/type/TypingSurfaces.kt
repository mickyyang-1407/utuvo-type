package com.utuvo.type

import android.content.Context

/**
 * 打字鍵盤增刪排序（對齊 Typeless 設定頁的 Keyboards；同 iOS `TypingSurfaces`）。語音永遠是第一個、不能拿掉。
 * 存完整順序（三種都在）＋關掉的那幾種，逗號分隔；沒設過＝現況 EN → 繁 → 简 全開。
 * 純邏輯部分（[normalizedOrder]、[next]、[nextTyping]、[sideOffsets]）不碰 Android，JVM 測得到。
 */
object TypingSurfaces {
    enum class Kind(val key: String) { EN("english"), HANT("hant"), HANS("hans") }

    private const val PREF = "keyboard"
    const val ORDER_KEY = "typingOrder"
    const val OFF_KEY = "typingOff"
    val DEFAULT_ORDER = listOf(Kind.EN, Kind.HANT, Kind.HANS)

    fun split(raw: String?): List<String> =
        (raw ?: "").split(',').map { it.trim() }.filter { it.isNotEmpty() }

    private fun kindOf(key: String) = Kind.values().firstOrNull { it.key == key }

    /** 不認得的丟掉、重複的只留第一個、漏掉的補在最後。 */
    fun normalizedOrder(raw: List<String>?): List<Kind> {
        val out = mutableListOf<Kind>()
        for (value in raw ?: emptyList()) kindOf(value)?.let { if (it !in out) out += it }
        for (kind in DEFAULT_ORDER) if (kind !in out) out += kind
        return out
    }

    fun enabled(order: List<Kind>, off: Set<Kind>) = order.filter { it !in off }

    fun order(c: Context) = normalizedOrder(split(prefs(c).getString(ORDER_KEY, null)))
    fun off(c: Context) = split(prefs(c).getString(OFF_KEY, null)).mapNotNull(::kindOf).toSet()
    fun enabled(c: Context) = enabled(order(c), off(c))

    fun save(c: Context, order: List<Kind>, off: Set<Kind>) {
        prefs(c).edit()
            .putString(ORDER_KEY, normalizedOrder(order.map { it.key }).joinToString(",") { it.key })
            .putString(OFF_KEY, DEFAULT_ORDER.filter { it in off }.joinToString(",") { it.key })
            .apply()
    }

    /** 左右滑：語音（null）→ 啟用的依序 → 回到語音。目前那個已被關掉就當作在語音；全關＝只剩語音。 */
    fun next(current: Kind?, enabled: List<Kind>, step: Int): Kind? {
        val ring: List<Kind?> = listOf<Kind?>(null) + enabled
        val index = current?.let { c -> ring.indexOf(c).takeIf { it >= 0 } } ?: 0
        val n = ring.size
        return ring[((index + step) % n + n) % n]
    }

    /** 打字面右上的版面鍵：只在啟用的打字鍵盤之間輪（只有一種就不動）。 */
    fun nextTyping(current: Kind, enabled: List<Kind>): Kind {
        val index = enabled.indexOf(current)
        if (index < 0 || enabled.size <= 1) return enabled.firstOrNull() ?: current
        return enabled[(index + 1) % enabled.size]
    }

    /** 語音面左側那排的垂直位置（以中間為 0）：啟用的照順序由上往下、整排置中。 */
    fun sideOffsets(count: Int, step: Int): List<Int> =
        (0 until count).map { ((it * 2 - (count - 1)) * step) / 2 }

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)
}
