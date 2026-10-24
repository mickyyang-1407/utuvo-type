package com.utuvo.type.core

import org.json.JSONArray
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * FX-5（同 Swift LatinCommonWordTests）：英文專名修正不准把常用英文字換成別的詞。
 * 修之前 english-words.txt 前兩萬個字：舊 Mac 16 詞改到 100 個、整包 ai 295 個（phone→iPhone、shop→Zhipu、
 * stock→SDK、types→Typeless、commits→commit）、三包全開 351 個。
 * 內建包的詞在 app 模組，core 測試從 Swift 匯出的 golden/latin-names.json 拿同一組詞。
 */
class LatinCommonWordTest {
    private val sets: Map<String, List<String>> by lazy {
        val arr = JSONArray(javaClass.getResource("/golden/latin-names.json")?.readText() ?: error("找不到 golden/latin-names.json"))
        (0 until arr.length()).associate { i ->
            val o = arr.getJSONObject(i)
            val t = o.getJSONArray("terms")
            o.getString("set") to (0 until t.length()).map { t.getString(it) }
        }
    }
    private fun set(name: String) = sets[name] ?: error("golden 裡沒有 $name")

    private val englishWords: List<String> by lazy {
        val file = File("../app/src/main/assets/english-words.txt")
        assertTrue(file.exists(), "找不到 ${file.absolutePath}")
        file.readLines().map { it.trim() }.filter { it.isNotEmpty() }
    }

    @Test fun ticketSentencesStayAsSpoken() {
        for (sentence in listOf(
            "I'm glad the cloud sync works",
            "我的 phone 拿去 shop 修了，這些 types 的 stock 都還在",
            "commits are pushed",
            "apply the claim to the common gold",
        )) {
            assertEquals(sentence, LatinNameFixer.fix(sentence, set("aiPack")), "整包 ai")
            assertEquals(sentence, LatinNameFixer.fix(sentence, set("aiTwAudio")), "三包全開")
            assertEquals(sentence, LatinNameFixer.fix(sentence, set("oldMac16")), "舊 Mac 16 詞")
        }
    }

    @Test fun longerCommonWordsBeyondTheFirst20kAreAlsoLeftAlone() {
        for (word in listOf("nineteen", "metering", "partials", "timeless", "Christmas", "telegraph", "commute", "whispers",
            "goggles", "discreet", "emission", "confession", "fostering", "wanderer", "innuendo")) {
            assertEquals("我說 $word 了", LatinNameFixer.fix("我說 $word 了", set("aiTwAudio")), word)
        }
    }

    @Test fun commonWordIsNotSplitIntoTerms() {
        assertEquals("Christmas", LatinNameFixer.fix("Christmas", set("aiTwAudio")))
        assertEquals("confession", LatinNameFixer.fix("confession", set("aiPack")))
        assertEquals("Apple NVIDIA", LatinNameFixer.fix("AppleNVidia", set("aiPack")))
    }

    @Test fun caseOnlyFixOfTheSameCommonWordStillApplies() {
        assertTrue(LatinNameFixer.isCommonEnglishWord("radar"))
        assertEquals("打開 RADAR", LatinNameFixer.fix("打開 radar", listOf("RADAR")))
        assertEquals("打開 RADAR", LatinNameFixer.fix("打開 rader", listOf("RADAR")))
        assertEquals("打開 reader", LatinNameFixer.fix("打開 reader", listOf("RADAR")))
        assertEquals("我的 iPhone", LatinNameFixer.fix("我的 iphone", set("aiPack")))
        assertEquals("ChatGPT 跟 OpenAI", LatinNameFixer.fix("chatgpt 跟 openai", set("aiPack")))
    }

    @Test fun commonWordCheckIsSingleTokenOnly() {
        assertTrue(LatinNameFixer.isCommonEnglishWord("Cloud"))
        assertTrue(LatinNameFixer.isCommonEnglishWord("co-op"))
        assertFalse(LatinNameFixer.isCommonEnglishWord("cloud code"), "多字詞不在此限")
        assertFalse(LatinNameFixer.isCommonEnglishWord("Protus"))
        assertFalse(LatinNameFixer.isCommonEnglishWord("Gemeni"))
    }

    @Test fun phrasesAndNonWordsKeepWorking() {
        val on = set("personal+aiTwAudio")
        assertEquals("更新 Pro Tools", LatinNameFixer.fix("更新 Protus", on))
        assertEquals("我用 Dolby Atmos 混", LatinNameFixer.fix("我用 Dolbe Edmos 混", on))
        assertEquals("我在 DAMI music 上班", LatinNameFixer.fix("我在 Darmy Music 上班", on))
        assertEquals("用 UTUVO Type 打字", LatinNameFixer.fix("用 Utuvo Type 打字", on))
        assertEquals("這首要做 Spatial Audio 版本", LatinNameFixer.fix("這首要做 Special Audio 版本", on))
        assertEquals("我在測試 Gemini 的東西", LatinNameFixer.fix("我在測試 Gemeni 的東西", on))
        assertEquals("問一下 ChatGPT", LatinNameFixer.fix("問一下 chat gpt", on))
        assertEquals("Claude Code", LatinNameFixer.fix("Cloud coat", on), "兩個常用字分開聽到＝多字詞，照比對")
        // 音訊包關著：Special Audio 不動。
        assertEquals("這首要做 Special Audio 版本", LatinNameFixer.fix("這首要做 Special Audio 版本", set("aiPack")))
    }

    /** 同 Swift testLogicProMishearingsAreFixedOnTheSpeechPath：Largec Pro／Large C Pro → Logic Pro，只限辨識稿。 */
    @Test fun logicProMishearingsAreFixedOnTheSpeechPath() {
        val on = set("personal+aiTwAudio")
        assertEquals("我用 Logic Pro 混", LatinNameFixer.fix("我用 Largec Pro 混", on))
        assertEquals("我用 Logic Pro 混", LatinNameFixer.fix("我用 Large C Pro 混", on))
        assertEquals("Logic Pro會出的音檔", LatinNameFixer.fix("Largec Pro會出的音檔", on))
        for (kept in listOf("我用 Logic Pro 混", "這是 lark Pro 版", "這是 large Pro 版", "我用 Mac Pro 混", "這組 power tools 很好用")) {
            assertEquals(kept, LatinNameFixer.fix(kept, on))
        }
        // 錨點規則放寬到距離 2 時，一般片語裡骨架不同的字不能被拉走（同 Swift）。
        for (kept in listOf("logins Pro", "Louis Pro", "Lagos Pro", "David music", "alpine music", "Paris Tools", "Utah Type",
            "Tahoe Peak", "mini Bites")) {
            assertEquals("我說 $kept 這個", LatinNameFixer.fix("我說 $kept 這個", on))
        }
        assertEquals("我用 Largec Pro 混", LatinNameFixer.fix("我用 Largec Pro 混", on, LatinNameFixer.TextSource.CLEANUP), "只限辨識稿")
        assertEquals("我用 Largec Pro 混", LatinNameFixer.fix("我用 Largec Pro 混", set("aiPack")), "音訊包關著")
    }

    @Test fun explicitPersonalDictionaryEntryStillApplies() {
        val sentence = "I'm glad the cloud sync works"
        val withEntry = Normalizer(NormalizerOptions(dictionary = mapOf("cloud" to "Claude"), latinTerms = set("aiPack")))
        assertEquals("I'm glad the Claude sync works", withEntry.normalize(sentence).cleaned)
        assertEquals("I'm glad the Claude sync works", withEntry.applyVocabulary(sentence))
        assertEquals(sentence, Normalizer(NormalizerOptions(latinTerms = set("aiPack"))).normalize(sentence).cleaned)
        val glados = Normalizer(NormalizerOptions(dictionary = mapOf("glad" to "GLaDOS"), latinTerms = set("aiPack")))
        assertEquals("I'm GLaDOS the cloud sync works", glados.normalize(sentence).cleaned)
    }

    /** 整個 35 級（前 49,877 行，工單量的前兩萬行在裡面）逐字掃過：每一組詞都只准有「只差大小寫」的修正。 */
    @Test fun noCommonWordIsRewrittenToAnotherTermInAnyTermSet() {
        val common = englishWords.subList(0, CommonEnglishWords.RANK_CUTOFF)
        for ((name, terms) in sets) {
            val out = LatinNameFixer.fix(common.joinToString("，"), terms).split("，")
            assertEquals(common.size, out.size)
            val changed = common.indices.filter { common[it] != out[it] && LatinNameFixer.plain(common[it]) != LatinNameFixer.plain(out[it]) }
            assertEquals(0, changed.size, "$name：" + changed.take(20).joinToString("、") { "${common[it]}→${out[it]}" })
        }
    }

    /** 常用字表跟來源詞表一致，而且跟 Swift 那份逐段相同（同 Swift testWordListMatchesSourceAndKotlinCopy）。 */
    @Test fun wordListMatchesSourceAndSwiftCopy() {
        val words = englishWords
        val starts = (1 until words.size).filter { words[it].length < words[it - 1].length }
        assertEquals(4, starts.size, "english-words.txt 應該是 10/20/35/40/50 五級")
        assertEquals(starts[2], CommonEnglishWords.RANK_CUTOFF, "取到 35 級的最後一行")
        val letters = Regex("^[A-Za-z]+$")
        val expected = words.subList(0, starts[2]).filter { letters.matches(it) }.map { it.lowercase() }.toSet()
        assertEquals(expected, CommonEnglishWords.words, "跟 english-words.txt 不一致：重跑 scripts/build-common-english-words.py")
        assertEquals(expected.size, CommonEnglishWords.COUNT)

        val swift = File("../../Sources/UTUVOTypeCore/CommonEnglishWords.swift")
        assertTrue(swift.exists(), "找不到 ${swift.absolutePath}")
        val text = swift.readText()
        val body = text.substring(text.indexOf("static let chunks: [String] = ["))
        val swiftChunks = body.split("\"\"\"").filterIndexed { i, _ -> i % 2 == 1 }.map { it.split(Regex("\\s+")).filter(String::isNotEmpty) }
        assertEquals(CommonEnglishWords.CHUNKS.map { it.split(Regex("\\s+")).filter(String::isNotEmpty) }, swiftChunks,
            "Swift CommonEnglishWords.swift 跟 Kotlin 不同：重跑 scripts/build-common-english-words.py")
        assertTrue(text.contains("static let rankCutoff = ${CommonEnglishWords.RANK_CUTOFF}"))
        assertTrue(text.contains("static let count = ${CommonEnglishWords.COUNT}"))
    }
}
