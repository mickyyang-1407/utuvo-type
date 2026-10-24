package com.utuvo.type.core

/** 辨識提示詞要送哪一種字形（fx-hints，2026-10-22）。Swift core `HintScript` 同一份。 */
enum class HintScript {
    /** 照原樣送（非中文聽寫）。 */
    AS_IS,
    /** 台灣繁體：只有簡體寫的個人詞才轉；已經是繁體、或兩邊通用的詞原樣送。 */
    TRADITIONAL,
    /** 簡體：有繁體專用字的詞轉簡體（內建包是台灣繁體，簡體輸出時不該把辨識器往繁體拉）。 */
    SIMPLIFIED,
}

/**
 * 一個詞是簡體還是繁體寫的（辨識提示詞用；Swift core `HanScript` 同一條規則、同一份字表）。
 *
 * 以前提示詞整串跑 ICU Hans-Hant，但它對已經是繁體的字不是冪等的：兩邊通用的字（杰 干 岩 庄 范 于 后）
 * 會被改成別的字——周杰倫→周傑倫、干擾→乾擾、奇岩站→奇巖站、于美人→於美人、后里→後里，提示詞反而把辨識器
 * 帶去錯的人名、地名。現在只看詞裡有沒有「只在簡體出現的字」（码 请 伦）與「只在繁體出現的字」（倫 擾 頭）：
 * 字表在 [HanScriptData]（OpenCC 產生，見 scripts/build-han-script.py）。
 */
object HanScript {
    internal val simplifiedOnly: Set<Char> = HanScriptData.SIMPLIFIED_ONLY.filterNot { it.isWhitespace() }.toSet()
    internal val traditionalOnly: Set<Char> = HanScriptData.TRADITIONAL_ONLY.filterNot { it.isWhitespace() }.toSet()

    /** 有沒有只在簡體出現的字（邀请码 的 请 码）。 */
    fun hasSimplifiedOnly(term: String): Boolean = term.any { it in simplifiedOnly }

    /** 有沒有只在繁體出現的字（周杰倫 的 倫、頭前庄站 的 頭）。 */
    fun hasTraditionalOnly(term: String): Boolean = term.any { it in traditionalOnly }

    /**
     * 簡體寫的詞：有簡體專用字、而且沒有繁體專用字（邀请码、周杰伦）。
     * 繁體（周杰倫、干擾）、兩邊通用（奇岩站、于美人、后里）、繁簡混寫的都不算——那些照使用者打的送。
     */
    fun isSimplified(term: String): Boolean = hasSimplifiedOnly(term) && !hasTraditionalOnly(term)

    /**
     * 個人字典的詞：TRADITIONAL 只轉簡體寫的詞（[toTraditional] 要按詞轉，Mac／Android 傳 OpenCC [TraditionalFixer]）；
     * SIMPLIFIED 只轉有繁體專用字的詞。
     */
    fun personalHint(term: String, script: HintScript,
                     toTraditional: (String) -> String, toSimplified: (String) -> String): String = when (script) {
        HintScript.AS_IS -> term
        HintScript.TRADITIONAL -> if (isSimplified(term)) toTraditional(term) else term
        HintScript.SIMPLIFIED -> if (hasTraditionalOnly(term)) toSimplified(term) else term
    }

    /** 內建包與 catalog 種子（台灣繁體精選）：繁體不動；簡體輸出時有繁體專用字的才轉簡體。 */
    fun curatedHint(term: String, script: HintScript, toSimplified: (String) -> String): String =
        if (script == HintScript.SIMPLIFIED && hasTraditionalOnly(term)) toSimplified(term) else term
}

/**
 * 辨識提示詞的排序與字形（Swift core `BuiltInVocabulary.asrHints(personal:packTerms:…)` 同一條）：
 * 個人字典 → 產品名 → 內建包（音訊 → AI → 其他，呼叫端排好）→ catalog 種子；包內的 [EXCLUSIONS] 不送；
 * 字形照 [HanScript.personalHint]／[HanScript.curatedHint] 轉完再去重，取前 [limit] 個。
 */
object AsrHints {
    /** 不送進辨識提示詞的包內詞：使用者說「Type」，模型會被「Typeless」拉過去（pn05）。個人字典裡的照送。 */
    val EXCLUSIONS: Set<String> = setOf("Typeless")

    fun hints(personal: List<String>, productNames: List<String>, packTerms: List<String>,
              script: HintScript, limit: Int,
              toTraditional: (String) -> String, toSimplified: (String) -> String,
              excluding: Set<String> = EXCLUSIONS): List<String> {
        if (limit <= 0) return emptyList()
        val out = LinkedHashSet<String>()
        fun add(term: String): Boolean {
            if (term.isNotEmpty()) out.add(term)
            return out.size >= limit
        }
        for (raw in personal) if (add(HanScript.personalHint(raw, script, toTraditional, toSimplified))) return out.toList()
        for (raw in productNames) if (add(raw)) return out.toList()
        for (raw in packTerms) {
            if (raw in excluding) continue
            if (add(HanScript.curatedHint(raw, script, toSimplified))) return out.toList()
        }
        return out.toList()
    }
}
