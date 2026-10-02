package com.utuvo.type

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.NormalizerOptions
import com.utuvo.type.core.PinyinEngine
import com.utuvo.type.core.TaiwanPhrases
import com.utuvo.type.core.ZhuyinEngine
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 在手機上逐條對 Swift 標準答案（core 的 GoldenTest 是在電腦 JVM 上跑）。
 * 為什麼要兩份：Android 的 java.util.regex、BreakIterator 底層是 ICU，跟電腦 JVM 不同——
 * 2026-09-19 就是 (?U) 旗標在電腦上合法、在 Android 上一編譯就閃退，電腦上的測試全綠。
 * 詞庫走 app 真正打包的 assets（mmap），跟鍵盤實際拿到的一樣。
 */
@RunWith(AndroidJUnit4::class)
class GoldenOnDeviceTest {
    private val test = InstrumentationRegistry.getInstrumentation().context
    private val app = InstrumentationRegistry.getInstrumentation().targetContext

    private fun golden(name: String) = JSONArray(test.assets.open(name).bufferedReader().readText())
    private fun JSONArray.strings() = (0 until length()).map { getString(it) }

    private fun report(kind: String, total: Int, diffs: List<String>) {
        assertTrue("$kind：標準答案是空的", total > 0)
        if (diffs.isNotEmpty()) fail("$kind：$total 條裡有 ${diffs.size} 條跟 Swift 不一致\n" + diffs.take(20).joinToString("\n"))
    }

    @Test
    fun normalizerMatchesSwift() {
        val cases = golden("normalizer.json")
        val dict = JSONObject(test.assets.open("normalizer-dictionary.json").bufferedReader().readText())
            .let { o -> o.keys().asSequence().associateWith { o.getString(it) } }
        val plain = Normalizer()
        val withDict = Normalizer(NormalizerOptions(dictionary = dict))
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val a = plain.normalize(input)
            if (TaiwanPhrases.apply(input) != c.getString("taiwan")) diffs += "taiwan 「$input」"
            if (a.cleaned != c.getString("cleaned")) diffs += "cleaned「$input」swift「${c.getString("cleaned")}」android「${a.cleaned}」"
            if (a.appliedSteps != c.getJSONArray("steps").strings()) diffs += "steps 「$input」"
            val b = withDict.normalize(input).cleaned
            if (b != c.getString("cleanedWithDictionary")) diffs += "dict 「$input」swift「${c.getString("cleanedWithDictionary")}」android「$b」"
        }
        report("文字整理", cases.length(), diffs)
    }

    /** 句尾語氣：規則用了 lookbehind（(?<!不)太…了）與 \\p{L}，手機上的 ICU 要跟 Swift 一字不差。 */
    @Test
    fun sentenceMoodMatchesSwift() {
        val cases = golden("sentence-mood.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val apply = com.utuvo.type.core.SentenceMood.apply(input)
            val finish = com.utuvo.type.core.SentenceMood.finish(input)
            if (apply != c.getString("apply")) diffs += "apply「$input」swift「${c.getString("apply")}」android「$apply」"
            if (finish != c.getString("finish")) diffs += "finish「$input」swift「${c.getString("finish")}」android「$finish」"
        }
        report("句尾語氣", cases.length(), diffs)
    }

    @Test
    fun zhuyinMatchesSwift() {
        val lexicon = Lexicons.zhuyin(app) ?: error("zhuyin.dat 開不起來")
        val cases = golden("zhuyin.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val e = ZhuyinEngine(lexicon)
            // 同 core 的 GoldenTest：<BS>＝倒退；0.2.5 起 Swift 匯出在讀 commitAll 前會再按一次空白（spaceAccepted）
            val keys = c.getString("keys")
            var k = 0
            while (k < keys.length) {
                when {
                    keys.startsWith("<BS>", k) -> { e.backspace(); k += 4 }
                    keys[k] == ' ' -> { e.space(); k += 1 }
                    else -> { e.type(keys[k]); k += 1 }
                }
            }
            val got = listOf(e.preedit, e.composing, e.conversion, e.candidates.take(12).map { it.text }.toString(),
                e.space().toString(), e.commitAll())
            val want = listOf(c.getString("preedit"), c.getString("composing"), c.getString("conversion"),
                c.getJSONArray("candidates").strings().toString(), c.getBoolean("spaceAccepted").toString(), c.getString("commitAll"))
            if (got != want) diffs += "「${c.getString("keys")}」swift $want android $got"
        }
        report("注音", cases.length(), diffs)
    }

    private fun pinyin(hant: Boolean, file: String) {
        val lexicon = (if (hant) Lexicons.pinyinHant(app) else Lexicons.pinyin(app)) ?: error("拼音詞庫開不起來")
        val cases = golden(file)
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val e = PinyinEngine(lexicon)
            for (ch in c.getString("keys")) e.type(ch)
            val cands = e.candidates.take(12).map { "${it.text}/${it.consumed}" }
            val want = c.getJSONArray("candidates").let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> "${o.getString("text")}/${o.getInt("consumed")}" } } }
            val got = listOf(e.preedit, e.bestSegmentation.toString(), cands.toString(), e.commitAll())
            val w = listOf(c.getString("preedit"), c.getJSONArray("segmentation").strings().toString(), want.toString(), c.getString("commitAll"))
            if (got != w) diffs += "「${c.getString("keys")}」swift $w android $got"
        }
        report(file, cases.length(), diffs)
    }

    @Test fun pinyinSimplifiedMatchesSwift() = pinyin(false, "pinyin.json")
    @Test fun pinyinTraditionalMatchesSwift() = pinyin(true, "pinyin-hant.json")
}
