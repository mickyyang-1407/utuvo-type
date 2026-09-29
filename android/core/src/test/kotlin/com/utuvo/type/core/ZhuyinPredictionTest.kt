package com.utuvo.type.core

import java.io.File
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 移植自 `Tests/UTUVOTypeCoreTests/ZhuyinPredictionTests.swift`：注音「邊打邊出候選」——
 * 沒收尾的音節、簡拼（只打聲母）、不打聲調、倒退與還原。用出貨的 ios/Keyboard/Resources/zhuyin.dat。
 */
class ZhuyinPredictionTest {
    private lateinit var lexicon: ZhuyinLexicon

    @BeforeTest
    fun setUp() {
        val resources = File(System.getProperty("utuvo.resources") ?: error("缺 utuvo.resources"))
        lexicon = ZhuyinLexicon.open(File(resources, "zhuyin.dat")) ?: error("zhuyin.dat 開不起來")
    }

    private fun engine() = ZhuyinEngine(lexicon)

    /** 依序打字；空白字元＝空白鍵。 */
    private fun ZhuyinEngine.typeAll(keys: String) {
        for (ch in keys) if (ch == ' ') space() else type(ch)
    }

    private fun ZhuyinEngine.texts(limit: Int = 8) = candidates(limit).map { it.text }

    @Test
    fun singleInitialAlreadyHasCandidates() {
        val e = engine()
        e.type('ㄋ')
        assertEquals("ㄋ", e.composing)
        val t = e.texts()
        assertTrue(t.contains("你"), "只打 ㄋ 就要有「你」，得到 $t")
        assertTrue(e.candidates(8).all { it.readingCount == 1 })
    }

    @Test
    fun toneLessSyllableRanksExactFirst() {
        val e = engine().apply { typeAll("ㄕ") }
        assertEquals("是", e.texts().first(), "ㄕ（不分聲調）第一個應該是「是」，得到 ${e.texts()}")
        val f = engine().apply { typeAll("ㄋㄧ") }
        assertEquals("你", f.texts().first(), "ㄋㄧ → 你（ㄋㄧˇ 只差聲調，不扣分），得到 ${f.texts()}")
    }

    @Test
    fun initialsOnlyAbbreviation() {
        val e = engine().apply { typeAll("ㄋㄏ") }
        assertEquals(listOf("ㄋ"), e.readings, "第二個聲母擠開第一個音節")
        assertEquals("ㄏ", e.composing)
        // 排序完全照小麥注音的詞頻：ㄋㄏ 開頭的兩字詞裡 女孩（−4.15）、年後…比 你好（−5.09）常見，
        // 所以 你好 不會是第一個，但要在鍵盤候選列（20 格）裡。
        val c = e.candidates(20)
        assertTrue(c.contains(ZhuyinCandidate("你好", 2)), "ㄋㄏ → 要有 你好，得到 ${c.map { it.text }}")
        assertTrue(c.take(2).all { it.readingCount == 2 }, "兩字詞排在前面")
        assertTrue(c.any { it.readingCount == 1 && it.text == "你" }, "單字候選也要在（多字詞不能把單字擠光）")
        assertTrue(e.candidates(8).any { it.readingCount == 1 }, "只顯示 8 格時也留位置給單字")
        assertEquals(e.candidates(1).firstOrNull()?.text, e.conversion, "整句送出＝最佳的兩字詞")
        assertEquals("ㄋㄏ", e.preedit, "輸入框顯示打了什麼")
    }

    @Test
    fun longerAbbreviations() {
        val cases = listOf(
            "ㄊㄅ" to "台北", "ㄉㄋ" to "電腦", "ㄓㄏㄇㄍ" to "中華民國", "ㄐㄊ" to "今天",
        )
        for ((keys, expected) in cases) {
            val t = engine().apply { typeAll(keys) }.texts(10)
            assertTrue(
                t.contains(expected) || t.contains(expected.replace("台", "臺")),
                "$keys 應該有 $expected，得到 $t",
            )
        }
    }

    @Test
    fun toneLessSyllablesConvert() {
        val e = engine().apply { typeAll("ㄋㄧㄏㄠ") }
        assertEquals(listOf("ㄋㄧ"), e.readings)
        assertEquals("ㄏㄠ", e.composing)
        assertEquals(ZhuyinCandidate("你好", 2), e.candidates(8).first())
        assertEquals("你好", e.conversion)
        assertTrue(e.hasUncompletedSyllables)
        assertFalse(e.space(), "有沒收尾的音節時空白不當一聲（交給呼叫端整句送出）")
        assertEquals("你好", e.commitAll())
        assertTrue(e.isEmpty)
    }

    @Test
    fun mixedToneAndToneLess() {
        val e = engine().apply { typeAll("ㄐㄧㄣ ㄊㄧㄢ ㄏㄠˇ") }
        assertEquals("今天好", e.conversion)
        val f = engine().apply { typeAll("ㄐㄊ") }          // 今天 的簡拼
        assertTrue(f.texts(10).contains("今天"), "ㄐㄊ 應該有 今天，得到 ${f.texts(10)}")
    }

    @Test
    fun selectingAbbreviatedCandidateClearsComposer() {
        val e = engine().apply { typeAll("ㄋㄏ") }
        val nihao = e.candidates(20).first { it.text == "你好" }
        assertEquals("你好", e.select(nihao))
        assertTrue(e.isEmpty, "選了涵蓋正在組的音節的候選，整個緩衝區清空")

        e.typeAll("ㄋㄏ")
        val ni = e.candidates(20).first { it.readingCount == 1 && it.text == "你" }
        assertEquals("你", e.select(ni))
        assertEquals(emptyList(), e.readings)
        assertEquals("ㄏ", e.composing, "剩下的沒收尾音節回到正在組")
        assertTrue(e.texts().contains("好"))
    }

    @Test
    fun backspaceReopensUncompletedSyllable() {
        val e = engine().apply { typeAll("ㄋㄏ") }
        assertTrue(e.backspace())
        assertEquals(emptyList(), e.readings)
        assertEquals("ㄋ", e.composing, "刪掉 ㄏ 之後回到正在組 ㄋ")
        assertTrue(e.type('ㄧ'), "可以接著組成 ㄋㄧ")
        assertTrue(e.type('ˇ'))
        assertEquals(listOf("ㄋㄧˇ"), e.readings)

        val f = engine().apply { typeAll("ㄋㄏㄠˇ") }
        assertEquals(listOf("ㄋ", "ㄏㄠˇ"), f.readings)
        assertTrue(f.backspace(), "刪整個 ㄏㄠˇ")
        assertEquals(emptyList(), f.readings)
        assertEquals("ㄋ", f.composing)
    }

    @Test
    fun onlyConflictingSymbolsStartANewSyllable() {
        val e = engine().apply { typeAll("ㄓㄨㄥ") }            // 聲母→介音→韻母：同一個音節
        assertEquals(emptyList(), e.readings)
        assertEquals("ㄓㄨㄥ", e.composing)
        e.type('ㄨ')                   // 介音槽後面已經有韻母 → 新音節
        assertEquals(listOf("ㄓㄨㄥ"), e.readings)
        assertEquals("ㄨ", e.composing)
    }

    @Test
    fun completeToneInputBehavesAsBefore() {
        val e = engine().apply { typeAll("ㄊㄞˊㄅㄟˇㄕˋ") }
        assertFalse(e.hasUncompletedSyllables)
        assertEquals(ZhuyinCandidate("台北市", 3), e.candidates.first())
        assertEquals(e.preedit, e.conversion)
    }

    @Test
    fun unknownComposerFallsBackToSymbols() {
        val e = engine().apply { typeAll("ㄅㄩ") }              // 沒有任何音節是 ㄅㄩ…
        assertEquals("ㄅㄩ", e.conversion, "組不出音節時原樣送出，不吞字")
    }

    @Test
    fun stateRestoreRoundTrips() {
        val e = engine().apply { typeAll("ㄋㄧˇㄏㄓ") }
        val state = e.state
        val preedit = e.preedit
        val candidates = e.candidates(8)
        val conversion = e.conversion
        e.commitAll()
        assertTrue(e.isEmpty)
        e.restore(state)
        assertEquals(preedit, e.preedit)
        assertEquals(conversion, e.conversion)
        assertEquals(candidates, e.candidates(8))
        assertEquals("ㄓ", e.composing)
    }

    @Test
    fun spaceOnBareInitialDefersToCaller() {
        val e = engine()
        e.type('ㄋ')
        assertFalse(e.space(), "只有聲母 ㄋ：一聲只對到注音符號本身，不收成它")
        assertEquals("ㄋ", e.composing)
        assertFalse(e.conversion.contains("ㄋ"), "送出的是最佳猜測，不是符號：${e.conversion}")
        val f = engine()
        f.type('ㄙ')
        assertTrue(f.space(), "ㄙ 一聲是真的字（思），照舊收尾")
        assertEquals(listOf("ㄙ"), f.readings)
    }

    /** 最壞情況之一：一路只打聲母（每個位置都是幾十個音節）。 */
    @Test
    fun manyInitialsStayFast() {
        val e = engine()
        var worst = 0.0
        for (ch in "ㄨㄇㄐㄊㄗㄊㄅㄕㄉㄉㄋㄍㄙㄎㄏㄊㄌㄒㄐㄏ") {
            val t = System.nanoTime()
            e.type(ch)
            e.preedit
            e.conversion
            e.candidates(8)
            worst = maxOf(worst, (System.nanoTime() - t) / 1e9)
        }
        assertEquals(19, e.readings.size)
        assertTrue(worst < 0.200, "只打聲母 20 個，最慢一鍵 ${worst * 1000} ms（JVM 沒有 Swift 那麼緊）")
    }

    /** 選完字之後可以接聯想詞（Swift PredictionTests.testZhuyinCommitThenAssociate）。 */
    @Test
    fun commitThenAssociate() {
        val resources = File(System.getProperty("utuvo.resources") ?: error("缺 utuvo.resources"))
        val assoc = PhraseAssociations.open(File(resources, "assoc-hant.dat")) ?: error("assoc-hant.dat 開不起來")
        assertTrue(assoc.phraseCount > 0)
        val e = engine().apply { typeAll("ㄋㄧˇㄏㄠˇ") }
        val picked = e.select(e.candidates(8).first())
        assertEquals("你好", picked)
        assertTrue(e.isEmpty)
        assertEquals("嗎", assoc.continuations(picked, 8).first())
    }
}
