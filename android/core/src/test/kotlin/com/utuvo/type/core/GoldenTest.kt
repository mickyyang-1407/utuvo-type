package com.utuvo.type.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Kotlin 移植逐條對 Swift 標準答案（Tests/UTUVOTypeCoreTests/GoldenExportTests.swift 匯出）。
 * 重匯：`UTUVO_GOLDEN_OUT=$PWD/android/core/src/test/resources/golden swift test --filter GoldenExportTests`
 *
 * 不一致時把全部差異一次列出（不是第一條就停），好看出是哪一類規則沒對上。
 */
class GoldenTest {
    private val resources = File(System.getProperty("utuvo.resources") ?: error("缺 utuvo.resources"))

    private fun golden(name: String): JSONArray =
        JSONArray(javaClass.getResource("/golden/$name")?.readText() ?: error("找不到 golden/$name"))

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }

    private fun report(kind: String, total: Int, diffs: List<String>) {
        assertTrue(total > 0, "$kind：標準答案是空的（匯出壞了？）")
        if (diffs.isNotEmpty()) fail("$kind：$total 條裡有 ${diffs.size} 條跟 Swift 不一致\n" + diffs.take(40).joinToString("\n"))
    }

    @Test
    fun normalizerMatchesSwift() {
        val cases = golden("normalizer.json")
        val dict = JSONObject(javaClass.getResource("/golden/normalizer-dictionary.json")!!.readText())
            .let { o -> o.keySet().associateWith { o.getString(it) } }
        val plain = Normalizer()
        val withDict = Normalizer(NormalizerOptions(dictionary = dict))
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val a = plain.normalize(input)
            val tw = TaiwanPhrases.apply(input)
            if (tw != c.getString("taiwan")) diffs += "taiwan  「$input」\n   swift 「${c.getString("taiwan")}」\n  kotlin 「$tw」"
            if (a.cleaned != c.getString("cleaned")) diffs += "cleaned 「$input」\n   swift 「${c.getString("cleaned")}」\n  kotlin 「${a.cleaned}」"
            if (a.appliedSteps != c.getJSONArray("steps").strings()) diffs += "steps   「$input」 swift ${c.getJSONArray("steps")} kotlin ${a.appliedSteps}"
            val b = withDict.normalize(input).cleaned
            if (b != c.getString("cleanedWithDictionary")) diffs += "dict    「$input」\n   swift 「${c.getString("cleanedWithDictionary")}」\n  kotlin 「$b」"
        }
        report("文字整理", cases.length(), diffs)
    }

    private fun JSONArray.candidates() = (0 until length()).map {
        val o = getJSONObject(it)
        "${o.getString("text")}/${o.getInt("readingCount")}"
    }

    private fun List<ZhuyinCandidate>.candidates() = map { "${it.text}/${it.readingCount}" }

    /** 標準答案的 `keys` 裡 `<BS>` 代表倒退（不是鍵盤上有的鍵，只是讓案例能重播）。 */
    private fun replay(e: ZhuyinEngine, keys: String) {
        var i = 0
        while (i < keys.length) {
            when {
                keys.startsWith("<BS>", i) -> { e.backspace(); i += 4 }
                keys[i] == ' ' -> { e.space(); i += 1 }
                else -> { e.type(keys[i]); i += 1 }
            }
        }
    }

    @Test
    fun zhuyinMatchesSwift() {
        val lexicon = ZhuyinLexicon.open(File(resources, "zhuyin.dat")) ?: error("zhuyin.dat 開不起來")
        val cases = golden("zhuyin.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val keys = c.getString("keys")
            val e = ZhuyinEngine(lexicon)
            replay(e, keys)
            val got = listOf(
                e.readings.toString(), e.composing, e.preedit, e.conversion,
                e.candidates.take(12).map { it.text }.toString(),
                e.candidates(8).candidates(), e.candidates(20).candidates(),
                e.hasUncompletedSyllables.toString(), e.space().toString(), e.commitAll(),
            )
            val want = listOf(
                c.getJSONArray("readings").strings().toString(), c.getString("composing"), c.getString("preedit"),
                c.getString("conversion"), c.getJSONArray("candidates").strings().toString(),
                c.getJSONArray("candidates8").candidates(), c.getJSONArray("candidates20").candidates(),
                c.getBoolean("hasUncompletedSyllables").toString(), c.getBoolean("spaceAccepted").toString(),
                c.getString("commitAll"),
            )
            for (d in 0 until got.size) {
                if (got[d] != want[d]) diffs += "「$keys」欄位 $d\n   swift ${want[d]}\n  kotlin ${got[d]}"
            }
        }
        report("注音", cases.length(), diffs)
    }

    private fun pinyinCase(dat: String, file: String) {
        val lexicon = PinyinLexicon.open(File(resources, dat)) ?: error("$dat 開不起來")
        val cases = golden(file)
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val keys = c.getString("keys")
            val e = PinyinEngine(lexicon)
            for (ch in keys) e.type(ch)
            val cands = e.candidates.take(12).map { "${it.text}/${it.consumed}" }
            val cands8 = e.candidates(8).map { "${it.text}/${it.consumed}" }
            val wantCands = c.getJSONArray("candidates").let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> "${o.getString("text")}/${o.getInt("consumed")}" } } }
            val wantCands8 = c.getJSONArray("candidates8").let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> "${o.getString("text")}/${o.getInt("consumed")}" } } }
            val got = listOf(e.preedit, e.bestSegmentation.toString(), cands.toString(), cands8.toString(), e.commitAll())
            val want = listOf(c.getString("preedit"), c.getJSONArray("segmentation").strings().toString(), wantCands.toString(), wantCands8.toString(), c.getString("commitAll"))
            if (got != want) diffs += "「$keys」\n   swift $want\n  kotlin $got"
        }
        report(file, cases.length(), diffs)
    }

    @Test
    fun pinyinSimplifiedMatchesSwift() = pinyinCase("pinyin.dat", "pinyin.json")

    @Test
    fun pinyinTraditionalMatchesSwift() = pinyinCase("pinyin-hant.dat", "pinyin-hant.json")

    private fun associationCase(dat: String, file: String) {
        val assoc = PhraseAssociations.open(File(resources, dat)) ?: error("$dat 開不起來")
        val cases = golden(file)
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val ctx = c.getString("context")
            val got = listOf(assoc.continuations(ctx, 8).toString(), assoc.continuations(ctx, 0).toString())
            val want = listOf(c.getJSONArray("continuations8").strings().toString(), c.getJSONArray("continuations0").strings().toString())
            if (got != want) diffs += "「$ctx」\n   swift $want\n  kotlin $got"
        }
        report("聯想詞 $dat", cases.length(), diffs)
    }

    @Test
    fun associationsTraditionalMatchSwift() = associationCase("assoc-hant.dat", "associations-hant.json")

    @Test
    fun associationsSimplifiedMatchSwift() = associationCase("assoc-hans.dat", "associations-hans.json")

    @Test
    fun englishCurrentWordMatchesSwift() {
        val cases = golden("english-current-word.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val before = if (c.isNull("before")) null else c.getString("before")
            val got = EnglishSuggestions.currentWord(before)
            if (got != c.getString("word")) diffs += "「${before ?: "nil"}」 swift「${c.getString("word")}」 kotlin「$got」"
        }
        report("英文 currentWord", cases.length(), diffs)
    }

    @Test
    fun englishMatchCaseMatchesSwift() {
        val cases = golden("english-match-case.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val got = EnglishSuggestions.matchCase(c.getString("suggestion"), c.getString("typed"))
            if (got != c.getString("matched")) diffs += "「${c.getString("typed")}」 swift「${c.getString("matched")}」 kotlin「$got」"
        }
        report("英文 matchCase", cases.length(), diffs)
    }

    @Test
    fun englishMergeMatchesSwift() {
        val cases = golden("english-merge.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val got = EnglishSuggestions.merge(
                word = c.getString("word"),
                isMisspelled = c.getBoolean("isMisspelled"),
                completions = c.getJSONArray("completions").strings(),
                guesses = c.getJSONArray("guesses").strings(),
                userTerms = c.getJSONArray("terms").strings(),
                limit = c.getInt("limit"),
            )
            if (got != c.getJSONArray("merged").strings()) {
                diffs += "「${c.getString("word")}」\n   swift ${c.getJSONArray("merged")}\n  kotlin $got"
            }
        }
        report("英文 merge", cases.length(), diffs)
    }
}
