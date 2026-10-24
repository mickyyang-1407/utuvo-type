package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * modes-2：語音翻譯翻的是哪一份。有開智慧整理＋有雲端 key → 先整理再翻；
 * 整理失敗／沒通過把關（回 null）就翻原本那份；沒 key 或只有手機上的模型 → 跟以前一樣直接翻。
 */
class TranslateSourceTest {

    private val deterministic = "三點，不對，四點開會"
    private val cleaned = "四點開會"

    private fun run(cleanFirst: Boolean, cleanResult: String?): Pair<List<String>, Int> {
        val translated = mutableListOf<String>()
        var cleanCalls = 0
        TranslateSource.run(cleanFirst, deterministic,
            clean = { done -> cleanCalls++; done(cleanResult) },
            translate = { translated += it })
        return translated to cleanCalls
    }

    @Test
    fun `開了智慧整理又有雲端 key 才先整理`() {
        assertTrue(TranslateSource.cleansFirst(cleanupEnabled = true, onDeviceOnly = false))
        assertFalse("沒開智慧整理：照舊", TranslateSource.cleansFirst(cleanupEnabled = false, onDeviceOnly = false))
        assertFalse("只有手機上的模型（沒有 key）：一句 8–60 秒，不拖住翻譯",
            TranslateSource.cleansFirst(cleanupEnabled = true, onDeviceOnly = true))
        assertFalse(TranslateSource.cleansFirst(cleanupEnabled = false, onDeviceOnly = true))
    }

    @Test
    fun `先整理時翻的是整理好的那份`() {
        val (translated, cleanCalls) = run(cleanFirst = true, cleanResult = cleaned)
        assertEquals(1, cleanCalls)
        assertEquals(listOf(cleaned), translated)
    }

    @Test
    fun `整理失敗或沒通過把關就翻原本那份`() {
        assertEquals(listOf(deterministic), run(cleanFirst = true, cleanResult = null).first)
        assertEquals(listOf(deterministic), run(cleanFirst = true, cleanResult = "  \n").first)
    }

    @Test
    fun `不先整理時跟以前一樣直接翻、也不打整理`() {
        val (translated, cleanCalls) = run(cleanFirst = false, cleanResult = cleaned)
        assertEquals(0, cleanCalls)
        assertEquals(listOf(deterministic), translated)
    }

    @Test
    fun `整理回呼被叫兩次也只翻一次`() {
        val translated = mutableListOf<String>()
        TranslateSource.run(true, deterministic,
            clean = { done -> done(cleaned); done(null) },
            translate = { translated += it })
        assertEquals(listOf(cleaned), translated)
    }

    @Test
    fun `整理還沒回來就不翻`() {
        val translated = mutableListOf<String>()
        var pending: ((String?) -> Unit)? = null
        TranslateSource.run(true, deterministic,
            clean = { done -> pending = done },
            translate = { translated += it })
        assertTrue(translated.isEmpty())
        pending!!.invoke(cleaned)
        assertEquals(listOf(cleaned), translated)
    }

    @Test
    fun `整理好的那份去頭尾空白`() {
        assertEquals(cleaned, TranslateSource.pick(deterministic, "  $cleaned\n"))
        assertEquals(deterministic, TranslateSource.pick(deterministic, null))
        assertEquals(deterministic, TranslateSource.pick(deterministic, ""))
    }
}
