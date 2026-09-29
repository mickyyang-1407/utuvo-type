package com.utuvo.type.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 內附英文詞表：合成詞表驗規則，出貨詞表驗真的打得出常見字。 */
class EnglishLexiconTest {
    private val tiny = EnglishLexicon(listOf("the", "to", "tomorrow", "Tom", "tomato", "tumor", "I", "don't", "THE"))

    @Test
    fun completionsFollowRankAndSkipTheWordItself() {
        assertEquals(listOf("tomorrow", "tomato"), tiny.completions("tom", 8))
        assertEquals(listOf("tomorrow"), tiny.completions("Tom", 1))
        assertEquals(listOf("don't"), tiny.completions("don", 8))
        assertEquals(emptyList(), tiny.completions("x", 8))
        assertEquals(emptyList(), tiny.completions("", 8))
    }

    @Test
    fun duplicatesKeepFirstSpelling() {
        assertEquals(8, tiny.size)
        assertTrue(tiny.contains("The"))
        assertTrue(tiny.contains("tom"))
    }

    @Test
    fun guessesAreOneEditAwayAndRanked() {
        // tomor：插 r → tomorr? 不在；換 o→u 得 tumor；刪 r 得 tomo? 不在。
        assertEquals(listOf("tumor"), tiny.guesses("tumer", 8))
        assertEquals(listOf("the"), tiny.guesses("teh", 8))           // 對調
        assertEquals(listOf("to", "Tom"), tiny.guesses("tox", 8))     // 刪 x 得 to；換 x→m 得 tom
        assertEquals(listOf("don't"), tiny.guesses("dont", 8))        // 插撇號
        assertEquals(emptyList(), tiny.guesses("the", 8))             // 拼對的沒有建議
    }

    @Test
    fun shippedWordListGivesEverydayWords() {
        val file = File("../app/src/main/assets/english-words.txt")
        assertTrue(file.exists(), "找不到 ${file.absolutePath}")
        val lex = EnglishLexicon(file.readLines())
        assertTrue(lex.size > 50_000, "詞表太小：${lex.size}")
        assertTrue("tomorrow" in lex.completions("tomor", 8))
        assertEquals("the", lex.guesses("teh", 8).first())
        assertTrue("hello" in lex.completions("hel", 8))
        assertTrue(lex.contains("Monday"))
        assertFalse(lex.contains("tomor"))
        // 補完是在打字熱路徑上跑的：一個字母的前綴（最多命中）也要夠快。
        val start = System.nanoTime()
        repeat(100) { lex.completions("s", 8); lex.guesses("recieve", 8) }
        val perCallMs = (System.nanoTime() - start) / 1e6 / 200
        assertTrue(perCallMs < 5, "每次查詢 ${"%.2f".format(perCallMs)} ms 太慢")
    }
}
