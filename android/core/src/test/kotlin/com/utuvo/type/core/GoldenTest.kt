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

    /** 序數清單的封閉動詞表（2026-10-22 W2-6 第四輪）：跟 Swift Normalizer.ordinalListVerbs／ordinalListVerbNouns 逐字、同順序。 */
    @Test
    fun ordinalListVerbsMatchSwift() {
        val o = JSONObject(javaClass.getResource("/golden/ordinal-list-verbs.json")?.readText() ?: error("找不到 golden/ordinal-list-verbs.json"))
        val verbs = o.getJSONArray("verbs").strings()
        assertTrue(verbs.size >= 50, "動詞表是空的（匯出壞了？）")
        kotlin.test.assertEquals(verbs, Normalizer.ordinalListVerbs, "動詞表跟 Swift 不一樣")
        kotlin.test.assertEquals(o.getJSONArray("nouns").strings(), Normalizer.ordinalListVerbNouns, "名詞例外表跟 Swift 不一樣")
    }

    /** 數字正規化（FX-2 v2）：normalizeNumbers 本身（也跑在 LLM 輸出上）＋整條 normalize。 */
    @Test
    fun numbersMatchSwift() {
        val cases = golden("numbers.json")
        val plain = Normalizer()
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val n = Normalizer.normalizeNumbers(input)
            if (n != c.getString("numbers")) diffs += "numbers 「$input」\n   swift 「${c.getString("numbers")}」\n  kotlin 「$n」"
            val a = plain.normalize(input).cleaned
            if (a != c.getString("cleaned")) diffs += "cleaned 「$input」\n   swift 「${c.getString("cleaned")}」\n  kotlin 「$a」"
        }
        report("數字正規化", cases.length(), diffs)
    }

    /**
     * LLM 把關（FX-7）：本機版第一次貼上的字＋寬鬆把關的意思檢查（數值多出／換主人、對比翻轉、對調、人稱），
     * 句子是 fx-seven 審查回報＋fuzz 每 20 取 1＋單元測試的句對。同 Swift GoldenExportTests 的 fidelity.json。
     */
    @Test
    fun fidelityMatchesSwift() {
        val cases = golden("fidelity.json")
        val plain = Normalizer()
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val first = SentenceMood.finish(plain.normalize(input).cleaned)
            if (first != c.getString("first")) diffs += "first   「$input」\n   swift 「${c.getString("first")}」\n  kotlin 「$first」"
            if (!c.has("candidate")) continue
            val candidate = c.getString("candidate")
            val o = CleanupFidelity.spelledNumbers(Normalizer.normalizeNumbers(first))
            val n = CleanupFidelity.spelledNumbers(Normalizer.normalizeNumbers(candidate))
            val checks = listOf(
                CleanupFidelity.introducesNumberValues(o, n),
                CleanupFidelity.reordersNumberValues(o, n),
                CleanupFidelity.dropsNumberValues(o, n),
                CleanupFidelity.invertsContrast(o, n),
                CleanupFidelity.swapsAroundSharedMiddle(o, n),
                CleanupFidelity.keepsPerson(first, Normalizer.normalizeNumbers(candidate)),
            ).joinToString("") { if (it) "1" else "0" }
            if (checks != c.getString("checks")) diffs += "checks  「$input」→「$candidate」 swift ${c.getString("checks")} kotlin $checks"
        }
        report("LLM 把關", cases.length(), diffs)
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
    fun sentenceMoodMatchesSwift() {
        val cases = golden("sentence-mood.json")
        val diffs = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val apply = SentenceMood.apply(input)
            val finish = SentenceMood.finish(input)
            if (apply != c.getString("apply")) diffs += "apply「$input」 swift「${c.getString("apply")}」 kotlin「$apply」"
            if (finish != c.getString("finish")) diffs += "finish「$input」 swift「${c.getString("finish")}」 kotlin「$finish」"
        }
        val cont = golden("sentence-mood-continuation.json")
        for (i in 0 until cont.length()) {
            val c = cont.getJSONObject(i)
            val before = if (c.isNull("before")) null else c.getString("before")
            val previous = if (c.isNull("previous")) null else c.getString("previous")
            val got = SentenceMood.continuationPrefix(before, previous)
            if (got != c.getString("prefix")) diffs += "continuation「$before」「$previous」 swift「${c.getString("prefix")}」 kotlin「$got」"
        }
        report("句尾語氣", cases.length() + cont.length(), diffs)
    }

    /**
     * 接續聽寫（W2-7）：joinPrefix＋finishDroppedMark（＋finish）逐條對 Swift。交界上有 emoji、組合記號、各種空白，
     * 所以逐 code point 列差異（組合記號會讓兩邊印出來看起來一樣）。
     */
    @Test
    fun sentenceMoodJoinMatchesSwift() {
        val cases = golden("sentence-mood-join.json")
        val diffs = mutableListOf<String>()
        fun cps(s: String?) = s?.codePoints()?.toArray()?.joinToString(" ") { Integer.toHexString(it) } ?: "nil"
        fun JSONObject.optText(key: String) = if (isNull(key)) null else getString(key)
        var joins = 0
        var marks = 0
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            when (c.getString("fn")) {
                "joinPrefix" -> {
                    joins++
                    val before = c.optText("before")
                    val previous = c.optText("previous")
                    val next = c.getString("next")
                    val droppedMark = c.optText("droppedMark")
                    val got = SentenceMood.joinPrefix(before, previous, next, droppedMark)
                    if (got != c.getString("prefix")) {
                        diffs += "joinPrefix before[${cps(before)}] previous[${cps(previous)}] next[${cps(next)}] mark[${cps(droppedMark)}]\n" +
                            "   swift[${cps(c.getString("prefix"))}] kotlin[${cps(got)}]"
                    }
                }
                "finishDroppedMark" -> {
                    marks++
                    val text = c.getString("text")
                    val mark = SentenceMood.finishDroppedMark(text)
                    val finish = SentenceMood.finish(text)
                    if (mark != c.getString("mark")) diffs += "finishDroppedMark[${cps(text)}] swift[${cps(c.getString("mark"))}] kotlin[${cps(mark)}]"
                    if (finish != c.getString("finish")) diffs += "finish[${cps(text)}] swift[${cps(c.getString("finish"))}] kotlin[${cps(finish)}]"
                }
                else -> diffs += "不認得的 fn：${c.getString("fn")}"
            }
        }
        assertTrue(joins > 0 && marks > 0, "接續聽寫：joinPrefix $joins 條、finishDroppedMark $marks 條（兩種都要有）")
        report("接續聽寫", cases.length(), diffs)
    }

    /** 資料區塊定界符跳脫（審查 10-22）：逐 code point 比，不靠字串相等（組合記號會讓兩邊看起來一樣）。 */
    @Test
    fun dataDelimiterEscapeMatchesSwift() {
        val cases = golden("data-delimiters.json")
        val diffs = mutableListOf<String>()
        fun cps(s: String) = s.codePoints().toArray().joinToString(" ") { Integer.toHexString(it) }
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val input = c.getString("input")
            val got = VoiceModes.escapeDataDelimiters(input)
            val want = c.getString("escaped")
            if (cps(got) != cps(want)) diffs += "「${cps(input)}」\n   swift ${cps(want)}\n  kotlin ${cps(got)}"
        }
        report("定界符跳脫", cases.length(), diffs)
    }

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

    /** 英文專名修正（FX-5）：同一組詞、同樣的句子逐字對；english-words.txt 同一段逐字掃過，換掉的字（與換成什麼）要一模一樣。 */
    @Test
    fun latinNamesMatchSwift() {
        val sets = golden("latin-names.json")
        val english = File("../app/src/main/assets/english-words.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() }
        val diffs = mutableListOf<String>()
        var total = 0
        for (i in 0 until sets.length()) {
            val set = sets.getJSONObject(i)
            val name = set.getString("set")
            val terms = set.getJSONArray("terms").strings()
            val cases = set.getJSONArray("cases")
            for (j in 0 until cases.length()) {
                val c = cases.getJSONObject(j)
                val got = LatinNameFixer.fix(c.getString("input"), terms)
                total++
                if (got != c.getString("output")) diffs += "$name 「${c.getString("input")}」\n   swift 「${c.getString("output")}」\n  kotlin 「$got」"
                // 智慧整理的規則（W2-1 verifier）
                val cleanup = LatinNameFixer.fix(c.getString("input"), terms, LatinNameFixer.TextSource.CLEANUP)
                total++
                if (cleanup != c.getString("cleanupOutput")) {
                    diffs += "$name cleanup 「${c.getString("input")}」\n   swift 「${c.getString("cleanupOutput")}」\n  kotlin 「$cleanup」"
                }
            }
            val range = set.getJSONArray("sweepRange")
            val words = english.subList(range.getInt(0), range.getInt(1))
            for ((source, key) in listOf(LatinNameFixer.TextSource.SPEECH to "sweepChanges", LatinNameFixer.TextSource.CLEANUP to "cleanupSweepChanges")) {
                val out = LatinNameFixer.fix(words.joinToString("，"), terms, source).split("，")
                val got = words.indices.filter { words[it] != out[it] }.map { "${words[it]}→${out[it]}" }
                val swiftChanges = set.getJSONArray(key)
                val want = (0 until swiftChanges.length()).map { swiftChanges.getJSONArray(it).let { p -> "${p.getString(0)}→${p.getString(1)}" } }
                total += words.size
                if (got != want) diffs += "$name $key：swift ${want.size} 個、kotlin ${got.size} 個\n  只有 swift：${(want - got.toSet()).take(20)}\n  只有 kotlin：${(got - want.toSet()).take(20)}"
            }
        }
        report("英文專名", total, diffs)
    }

    /** 智慧整理後補套（W2-1 verifier）：同一份字典＋英文專名目標，套一次、套兩次都要跟 Swift 逐字一樣。 */
    @Test
    fun vocabularyApplyMatchesSwift() {
        val sets = golden("vocabulary-apply.json")
        val diffs = mutableListOf<String>()
        var total = 0
        for (i in 0 until sets.length()) {
            val set = sets.getJSONObject(i)
            val name = set.getString("set")
            val dictObject = set.getJSONObject("dictionary")
            val dictionary = dictObject.keys().asSequence().associateWith { dictObject.getString(it) }
            val terms = set.getJSONArray("latinTerms").strings()
            val cases = set.getJSONArray("cases")
            for (j in 0 until cases.length()) {
                val c = cases.getJSONObject(j)
                val once = Normalizer.applyVocabulary(c.getString("input"), dictionary, terms)
                val twice = Normalizer.applyVocabulary(once, dictionary, terms)
                total++
                if (once != c.getString("output") || twice != c.getString("twice")) {
                    diffs += "$name 「${c.getString("input")}」\n   swift 「${c.getString("output")}」「${c.getString("twice")}」\n  kotlin 「$once」「$twice」"
                }
            }
        }
        report("智慧整理後補套", total, diffs)
    }
}
