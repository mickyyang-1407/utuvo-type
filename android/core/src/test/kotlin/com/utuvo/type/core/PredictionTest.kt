package com.utuvo.type.core

import java.io.File
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 移植自 `Tests/UTUVOTypeCoreTests/PredictionTests.swift`：聯想詞（選字後建議下一段）與英文建議列。
 * 聯想詞走出貨的 ios/Keyboard/Resources/assoc-*.dat。macOS 系統拼字字典那段（AppKit）在這邊沒有對應來源，略過。
 */
class PredictionTest {
    private lateinit var hant: PhraseAssociations
    private lateinit var hans: PhraseAssociations

    @BeforeTest
    fun setUp() {
        val resources = File(System.getProperty("utuvo.resources") ?: error("缺 utuvo.resources"))
        hant = PhraseAssociations.open(File(resources, "assoc-hant.dat")) ?: error("assoc-hant.dat 開不起來")
        hans = PhraseAssociations.open(File(resources, "assoc-hans.dat")) ?: error("assoc-hans.dat 開不起來")
    }

    // ── 聯想詞 ──

    @Test
    fun traditionalAssociationsAfterNiHao() {
        assertTrue(hant.phraseCount > 50_000, "詞表應該有五萬筆以上，得到 ${hant.phraseCount}")
        val next = hant.continuations("你好", 8)
        assertEquals("嗎", next.first(), "你好 → 你好嗎（小麥注音聯想詞），得到 $next")
        assertTrue(next.contains("像"), "你好 的兩字前文用完後，用「好」補：好像，得到 $next")
        assertEquals(8, next.size)
        assertEquals(next.size, next.toSet().size, "不重複")
    }

    @Test
    fun associationsFollowScoreOrder() {
        // 小麥注音 data.txt：你們 −3.62 > 你的 > 你要…（依分數由高到低）
        assertEquals(listOf("們", "的", "要"), hant.continuationsOfPrefix("你").take(3))
        assertTrue(hant.continuations("", 5).isEmpty())
        assertTrue(hant.continuations("你好", 0).isEmpty())
        assertTrue(hant.continuations("🙂", 5).isEmpty(), "查不到的前文回空")
        assertTrue(hant.continuations("abc", 5).isEmpty())
    }

    @Test
    fun longContextUsesItsTail() {
        val next = hant.continuations("我們今天說你好", 3)
        assertEquals("嗎", next.first(), "只看結尾的「你好」，得到 $next")
    }

    @Test
    fun simplifiedAssociations() {
        assertEquals("啊", hans.continuations("你好", 5).first())
        val china = hans.continuations("中国", 5)
        assertTrue(china.contains("人"), "中国 → 中国人，得到 $china")
        assertTrue(hans.continuations("谢谢", 5).contains("大家"))
    }

    @Test
    fun malformedDataIsRejected() {
        fun reject(bytes: ByteArray) {
            val buf = java.nio.ByteBuffer.allocateDirect(bytes.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            buf.put(bytes); buf.flip()
            assertNull(PhraseAssociations.of(buf), "壞資料要被拒絕")
        }
        reject("nope".toByteArray())
        reject("UTAS".toByteArray() + ByteArray(16))                                  // 版本 0 不接受
        reject(header(1, 1_000, 20, 4_020))                                           // 索引超出檔案
        assertTrue(PhraseAssociations.of(java.nio.ByteBuffer.allocate(4)) == null, "太短的檔案")
    }

    /** 組出標頭：UTAS ＋ 版本 ＋ 詞數 ＋ 索引位移 ＋ 記錄位移。 */
    private fun header(version: Int, n: Int, idx: Int, rec: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write("UTAS".toByteArray())
        for (v in listOf(version, n, idx, rec)) {
            for (b in 0 until 4) out.write((v ushr (8 * b)) and 0xFF)
        }
        return out.toByteArray()
    }

    @Test
    fun associationLookupIsFast() {
        var worst = 0.0
        for (ch in "的一是不了人我在有他這中大來上國個到說們為子和你地出道也時年得就那要下以生會自著去之過家學對可她裡後小麼心多天而能好都然沒日於起還發成事只作當想看文無開手十用主行方又如前所本見經頭面公同三已老從動兩長") {
            val t = System.nanoTime()
            hant.continuations(ch.toString(), 20)
            worst = maxOf(worst, (System.nanoTime() - t) / 1e9)
        }
        assertTrue(worst < 0.050, "最常見的 100 個字，最慢一次 $worst ms（JVM 沒有 Swift 那麼緊）")
    }

    // ── 英文 ──

    @Test
    fun currentWord() {
        assertEquals("wor", EnglishSuggestions.currentWord("Hello wor"))
        assertEquals("kn", EnglishSuggestions.currentWord("I don't kn"))
        assertEquals("don't", EnglishSuggestions.currentWord("I don't"))
        assertEquals("", EnglishSuggestions.currentWord("end. "))
        assertEquals("", EnglishSuggestions.currentWord("abc,"))
        assertEquals("abc", EnglishSuggestions.currentWord("中文abc"))
        assertEquals("quo", EnglishSuggestions.currentWord("'quo"))
        assertEquals("", EnglishSuggestions.currentWord(null))
        assertEquals("", EnglishSuggestions.currentWord("abc123"))
    }

    @Test
    fun matchCase() {
        assertEquals("Hello", EnglishSuggestions.matchCase("hello", "Hel"))
        assertEquals("HELLO", EnglishSuggestions.matchCase("hello", "HEL"))
        assertEquals("hello", EnglishSuggestions.matchCase("hello", "hel"))
        assertEquals("iPhone", EnglishSuggestions.matchCase("iPhone", "iph"))
        assertEquals("Hello", EnglishSuggestions.matchCase("hello", "H"), "單一個大寫字母＝首字大寫，不是全大寫")
    }

    @Test
    fun mergeOrdersUserWordsThenSpelling() {
        val terms = listOf("Dolby Atmos", "Atmosphere", "McBopomofo", "中文詞")
        val s = EnglishSuggestions.merge("atm", true, listOf("atmosphere", "atm"), listOf("arm", "atom"), terms, 8)
        assertEquals(
            listOf("Atmos", "Atmosphere", "arm", "atom"), s,
            "使用者詞優先、保留原寫法；拼錯時 guesses 在前；去掉跟打的一樣的與重複的",
        )
        val ok = EnglishSuggestions.merge("Hel", false, listOf("hello", "help", "held"), listOf("gel"), emptyList(), 3)
        assertEquals(listOf("Hello", "Help", "Held"), ok, "拼對時補完在前、照打的大小寫、不超過上限")
        assertEquals(emptyList(), EnglishSuggestions.merge("", false, listOf("a"), emptyList(), emptyList()))
    }

    /** 使用者詞保留原本的寫法，不被 matchCase 改掉。 */
    @Test
    fun mergeKeepsUserTermsCase() {
        val s = EnglishSuggestions.merge(
            "iPh", false, listOf("iphone", "iphonex"), emptyList(), listOf("iPhone 15 Pro"), 8,
        )
        assertEquals(listOf("iPhone", "iphonex"), s, "使用者詞保留原寫法；打的首字沒有大寫就照建議原樣")
    }

    @org.junit.jupiter.api.Test fun matchCaseOnEmptySuggestionDoesNotCrash() {
        org.junit.jupiter.api.Assertions.assertEquals("", EnglishSuggestions.matchCase("", "Hel"))
        org.junit.jupiter.api.Assertions.assertEquals("", EnglishSuggestions.matchCase("", "HEL"))
    }
}
