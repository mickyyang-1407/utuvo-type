package com.utuvo.type

import android.content.Context

/**
 * 「繁」鍵盤用注音還是拼音（同 iOS `SettingsScreen` 的「『繁』鍵盤輸入法」）。
 * 鍵盤服務（`UTUVOImeService`）與主 app 設定頁共用這一個 key，不要各自存一份。
 */
object HantInput {
    private const val PREF = "keyboard"
    private const val KEY = "hantUsesPinyin"

    fun usesPinyin(c: Context) = prefs(c).getBoolean(KEY, false)
    fun setUsesPinyin(c: Context, value: Boolean) = prefs(c).edit().putBoolean(KEY, value).apply()

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)
}
