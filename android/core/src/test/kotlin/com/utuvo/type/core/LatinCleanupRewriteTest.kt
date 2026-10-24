package com.utuvo.type.core

import org.json.JSONArray
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * W2-1 verifier（2026-10-22，同 Swift LatinCleanupRewriteTests）：智慧整理通過把關後補套「英文專名＋個人字典」
 * （[Normalizer.applyVocabulary]）不能把整理寫對的文字改壞，也要冪等：開頭是數字的詞疊字（3Coins→33Coins）、
 * 個人單字詞拉走正確英文（cloud→iCloud、codec→Codex、Mickey→Micky、Tone Master→Tonmeister）、
 * protocols→Pro Tools、一般名詞小寫與複數被改（vibe coding→Vibe Coding、UTUVO Types→UTUVO Type）。
 * 字典與詞表（內建包在 app 模組）從 Swift 匯出的 golden/vocabulary-apply.json 拿同一組。
 */
class LatinCleanupRewriteTest {
    private class Setup(val dictionary: Map<String, String>, val latinTerms: List<String>, val speechTerms: List<String>)

    private val sets: Map<String, Setup> by lazy {
        val arr = JSONArray(javaClass.getResource("/golden/vocabulary-apply.json")?.readText() ?: error("找不到 golden/vocabulary-apply.json"))
        (0 until arr.length()).associate { i ->
            val o = arr.getJSONObject(i)
            o.getString("set") to Setup(o.getJSONObject("dictionary").toStringMap(), o.getJSONArray("latinTerms").strings(),
                o.getJSONArray("speechTerms").strings())
        }
    }
    private val real get() = sets["real-like"] ?: error("golden 裡沒有 real-like")

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }
    private fun JSONObject.toStringMap(): Map<String, String> = keys().asSequence().associateWith { getString(it) }

    private fun apply(text: String, setup: Setup = real) = Normalizer.applyVocabulary(text, setup.dictionary, setup.latinTerms)

    @Test fun misspelledUserTermsAreStillFixed() {
        for ((input, expected) in listOf(
            "這次的 Dolby Atmos 混音是在 Pro Tools 上面做的，然後送到 Darmy Music 的教室去示範。" to
                "這次的 Dolby Atmos 混音是在 Pro Tools 上面做的，然後送到 DAMI music 的教室去示範。",
            "我最近在研究 ToneMaster 的認證課程，北藝大的那門課用的是 Apple 的 Spatial Audio 工具。" to
                "我最近在研究 Tonmeister 的認證課程，北藝大的那門課用的是 Apple 的 Spatial Audio 工具。",
            "Type 那個 app 在 Mac 上叫做 Utuvo Type，在手機上面也叫做 Utuvo Type，被搞混了。" to
                "Type 那個 app 在 Mac 上叫做 UTUVO Type，在手機上面也叫做 UTUVO Type，被搞混了。",
            "DAMI Music 的 logo 要改。" to "DAMI music 的 logo 要改。",
            "我在 Darmy Music 用 Utuvo Type 寫歌詞。" to "我在 DAMI music 用 UTUVO Type 寫歌詞。",
            "更新 Protus 之後再匯出 stems。" to "更新 Pro Tools 之後再匯出 stems。",
        )) {
            assertEquals(expected, apply(input))
            assertEquals(expected, apply(expected), "再套一次不變")
        }
    }

    @Test fun digitLeadingTermsDoNotStack() {
        for (text in listOf("我在 3Coins 買了收納盒。", "密碼都存在 1Password 裡。", "我在 7-Eleven 買咖啡。", "這個 password 太短。")) {
            assertEquals(text, apply(text))
            assertEquals(text, apply(apply(apply(text))), "套三次也不疊")
            assertEquals(text, LatinNameFixer.fix(text, real.speechTerms), "第一次貼上")
        }
        for (source in LatinNameFixer.TextSource.values()) {
            assertEquals("我在測 Qwen3 的模型", LatinNameFixer.fix("我在測 Qwen3 的模型", listOf("Qwen3"), source))
            assertEquals("我在測 Qwen 的模型", LatinNameFixer.fix("我在測 Qwen 的模型", listOf("Qwen3"), source), "不憑空補版本號")
        }
    }

    @Test fun personalSingleWordTermsDoNotPullCorrectEnglish() {
        for (text in listOf("請把檔案上傳到 cloud，我等一下用 phone 看。", "I'm glad the cloud sync works.", "這個 codec 不支援 Atmos。",
            "AAC 跟 ALAC 這兩種 codecs 都可以。", "我女兒的同學叫 Daisy。", "我覺得這個問題很 perplexing。",
            "Fender 的 Tone Master 是一台吉他音箱。", "I'm glad it works.", "Our product is called UTUVO Type.",
            "Mickey Mouse 的配樂是誰做的？", "Martin 跟 Morten 是兩個人。")) {
            assertEquals(text, apply(text))
        }
        val rules = sets["rules-ai-tw"] ?: error("golden 裡沒有 rules-ai-tw")
        for (text in listOf("I'm glad it works.", "Our product is called UTUVO Type.", "Mickey Mouse 的配樂是誰做的？",
            "Martin 跟 Morten 是兩個人。", "Fender 的 Tone Master 是一台吉他音箱。")) {
            assertEquals(text, apply(text, rules))
        }
    }

    @Test fun speechPathStillFixesMishearings() {
        assertEquals("我是 Tonmeister", LatinNameFixer.fix("我是 Tone Master", listOf("Tonmeister")))
        assertEquals("用 Codex 寫", LatinNameFixer.fix("用 Coldex 寫", listOf("Codex")))
        assertEquals("研究 Tonmeister", LatinNameFixer.fix("研究 ToneMaster", listOf("Tonmeister"), LatinNameFixer.TextSource.CLEANUP))
        assertEquals("用 Coldex 寫", LatinNameFixer.fix("用 Coldex 寫", listOf("Codex"), LatinNameFixer.TextSource.CLEANUP))
    }

    @Test fun explicitDictionaryRuleBeatsFuzzyMatch() {
        val dict = mapOf("Jemini" to "Gemini 2.5", "cloud" to "Claude")
        val ai = listOf("Gemini", "Google Gemini", "ChatGPT", "Claude", "iCloud")
        assertEquals("我在用 Gemini 2.5 跟 Claude", Normalizer.applyVocabulary("我在用 Jemini 跟 cloud", dict, ai))
        val speech = Normalizer(NormalizerOptions(dictionary = dict, latinTerms = ai)).normalize("我在用 Jemini 跟 cloud").cleaned
        assertTrue(speech.contains("Gemini 2.5 跟 Claude"), speech)
        assertEquals("我在 DAMI music", Normalizer.applyVocabulary("我在 Darmy Music", mapOf("Darmy Music" to ""), listOf("DAMI music")))
        assertEquals(setOf("Jemini"), Normalizer.dictionaryRuleKeys(mapOf("Jemini" to "Gemini 2.5", "Atmos" to "", "iCloud" to "iCloud")))
    }

    /** 同 Swift testCommonTwoWordPhrasesAreNotPulledToTerms：game music→DAMI music、live coding→Vibe Coding 不換。 */
    @Test fun commonTwoWordPhrasesAreNotPulledToTerms() {
        for (text in listOf("我喜歡 game music。", "這是 team music。", "same music 也可以。", "today music 排行。", "dumb music",
            "live coding 很好玩。", "selective Type 的設定", "claims Bites", "請輸入 access code", "這個 is code 嗎",
            "這段 quality code 很乾淨", "這個我 could code 出來")) {
            assertEquals(text, apply(text))
            assertEquals(text, LatinNameFixer.fix(text, real.speechTerms), "第一次貼上")
        }
        assertEquals("Claude Code", LatinNameFixer.fix("Cloud coat", real.speechTerms))
        assertEquals("我是 Tonmeister", LatinNameFixer.fix("我是 Tone Master", real.speechTerms), "字數不同、同首字母的照修")
        assertEquals("這首要做 Spatial Audio 版本", LatinNameFixer.fix("這首要做 Special Audio 版本", real.speechTerms))
        assertEquals("這首要做 Spatial Audio 版本", apply("這首要做 Special Audio 版本"))
        assertEquals("我在 DAMI music 上課", apply("我在 Darmy Music 上課"))
    }

    @Test fun protocolsIsNotPulledToProTools() {
        assertEquals("這兩個 protocols 不相容。", apply("這兩個 protocols 不相容。"))
        assertEquals("這兩個 protocols 不相容。", LatinNameFixer.fix("這兩個 protocols 不相容。", real.speechTerms))
    }

    @Test fun lowercaseCommonNounsAndPluralsAreKept() {
        for (text in listOf("他是 vibe coding 的愛好者。", "這版的 true peak 要控制在 -1 dBTP", "這個 spatial audio 混音有點太寬。",
            "UTUVO Types 這個名字不好。", "mix bites 是一個系列。")) {
            assertEquals(text, apply(text))
        }
        assertEquals("UTUVO Types 這個名字不好", LatinNameFixer.fix("UTUVO Types 這個名字不好", real.speechTerms))
        assertEquals("這些 GPTs 都很好用", LatinNameFixer.fix("這些 GPTs 都很好用", listOf("GPT")))
        assertEquals("用 UTUVO Type 打字", apply("用 utuvo type 打字"))
        assertEquals("在 DAMI music 上課", apply("在 Dami Music 上課"))
    }

    /** 一樣長的兩個 key 重疊（a-b-c）：長的先、一樣長照字串排（Swift 同一個順序，修之前 Swift 跟著 Dictionary 順序走）。 */
    @Test fun dictionaryKeysOfEqualLengthApplyInAFixedOrder() {
        assertEquals("xx A-c yy", Normalizer.applyDictionary("xx a-b-c yy", linkedMapOf("b-c" to "B", "a-b" to "A")))
        assertEquals("xx A-c yy", Normalizer.applyDictionary("xx a-b-c yy", linkedMapOf("a-b" to "A", "b-c" to "B")))
    }
}
