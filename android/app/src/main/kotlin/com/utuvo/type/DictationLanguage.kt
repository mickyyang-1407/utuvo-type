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
        private const val VARIANT_PREFIX = "dictationVariant_"

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

        fun currentVariant(c: Context, language: DictationLanguage): LanguageVariant {
            val key = VARIANT_PREFIX + language.code
            val raw = prefs(c).getString(key, null)
            return language.resolveVariant(raw)
        }

        fun setVariant(c: Context, language: DictationLanguage, variant: LanguageVariant) {
            val key = VARIANT_PREFIX + language.code
            prefs(c).edit().putString(key, variant.id).apply()
        }

        private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    /** 該語言支援的變體清單與預設值。 */
    val variants: List<LanguageVariant>
        get() = when (this) {
            TRADITIONAL_CHINESE -> listOf(LanguageVariant.ZH_TW, LanguageVariant.ZH_HK, LanguageVariant.ZH_CN)
            SIMPLIFIED_CHINESE -> listOf(LanguageVariant.ZH_CN, LanguageVariant.ZH_TW, LanguageVariant.ZH_HK)
            ENGLISH -> listOf(LanguageVariant.EN_US, LanguageVariant.EN_GB)
            JAPANESE, KOREAN -> emptyList()
        }

    val defaultVariant: LanguageVariant
        get() = when (this) {
            TRADITIONAL_CHINESE -> LanguageVariant.ZH_TW
            SIMPLIFIED_CHINESE -> LanguageVariant.ZH_CN
            ENGLISH -> LanguageVariant.EN_US
            JAPANESE, KOREAN -> LanguageVariant.DEFAULT
        }

    fun resolveVariant(raw: String?): LanguageVariant {
        val list = variants
        if (list.isEmpty()) return defaultVariant
        return list.firstOrNull { it.id.equals(raw, ignoreCase = true) } ?: defaultVariant
    }
}

/**
 * 語言變體：影響整理提示詞與在地化拼字／用字，不換辨識模型。
 */
enum class LanguageVariant(
    val id: String,
    val labelRes: Int,
    val promptInstruction: String
) {
    DEFAULT("default", R.string.variant_default, ""),
    ZH_TW("zh_tw", R.string.variant_zh_tw, "繁體中文（台灣用字習慣與常用語，例「軟體」「程式」「透過」）"),
    ZH_HK("zh_hk", R.string.variant_zh_hk, "繁體中文（香港用字與常用語，例「的士」「雪櫃」「巴士」）"),
    ZH_CN("zh_cn", R.string.variant_zh_cn, "簡體中文（中國大陸用字與詞彙習慣）"),
    EN_US("en_us", R.string.variant_en_us, "American English (US spelling and vocabulary, e.g., 'color', 'organize', 'elevator')"),
    EN_GB("en_gb", R.string.variant_en_gb, "British English (UK spelling and vocabulary, e.g., 'colour', 'organise', 'lift')");

    /** 同 iOS `LanguageVariant.appliesTaiwanTraditionalFixer`：null＝沒選變體，交給呼叫端依語言判斷。 */
    val appliesTaiwanTraditionalFixer: Boolean?
        get() = when (this) {
            DEFAULT -> null
            ZH_TW -> true
            ZH_HK, ZH_CN, EN_US, EN_GB -> false   // 香港用字／簡體／英文：台灣繁體轉換會改掉使用者要的字
        }

    companion object {
        /** 同 iOS `LanguageVariant.traditionalFixerTarget`。 */
        fun traditionalFixerTarget(variant: LanguageVariant, language: String): Boolean =
            variant.appliesTaiwanTraditionalFixer ?: language.startsWith("zh-TW")
    }
}

