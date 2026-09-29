package com.utuvo.type

import android.content.Context

/**
 * 聽寫語言（對齊 iOS `ios/Shared/DictationLanguage.swift`）。
 *
 * 鍵盤右上徽章點開選一次，這裡就記住，`SpeechRequest` 立刻照這個語言送給辨識器。
 * 徽章上的短名（「繁中」「简中」「EN」「日本語」「한국어」）跟 iOS 一樣**不隨介面語言在地化**：
 * 它講的是「要聽哪一種文字」，不是介面語言，兩種介面都一樣。
 *
 * [resolve]／[speechLanguage] 是純函式、不碰 Android，測試直接驗。
 */
enum class DictationLanguage(val code: String, val labelRes: Int, val shortRes: Int, val english: String) {
    TRADITIONAL_CHINESE("zh-TW", R.string.dict_zh_hant, R.string.dict_zh_hant_short, "Traditional Chinese"),
    SIMPLIFIED_CHINESE("zh-CN", R.string.dict_zh_hans, R.string.dict_zh_hans_short, "Simplified Chinese"),
    ENGLISH("en-US", R.string.dict_en, R.string.dict_en_short, "English (US)"),
    JAPANESE("ja-JP", R.string.dict_ja, R.string.dict_ja_short, "Japanese"),
    KOREAN("ko-KR", R.string.dict_ko, R.string.dict_ko_short, "Korean");

    companion object {
        /** 與鍵盤服務共用同一份 prefs（跟 [HantInput] 一樣，不要各自存一份）。 */
        const val PREFS = "keyboard"
        private const val KEY = "dictationLanguage"

        val all: List<DictationLanguage> = values().toList()

        /** 不認得的代碼（含舊值、null）一律回繁中——鍵盤不能沒有語言。 */
        fun resolve(raw: String?): DictationLanguage =
            all.firstOrNull { it.code.equals(raw, ignoreCase = true) } ?: TRADITIONAL_CHINESE

        /** 送給 `RecognizerIntent.EXTRA_LANGUAGE` 的代碼。 */
        fun speechLanguage(raw: String?): String = resolve(raw).code

        fun current(c: Context): DictationLanguage = resolve(prefs(c).getString(KEY, null))

        fun set(c: Context, language: DictationLanguage) {
            prefs(c).edit().putString(KEY, language.code).apply()
        }

        private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }
}
