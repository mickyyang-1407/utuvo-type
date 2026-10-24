package com.utuvo.type

import com.utuvo.type.core.HistoryCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * app-shell-1 PART B：保留期限選「永遠」其實最多留 [HistoryCodec.MAX] 筆，畫面上要講出來（三個語言都要）。
 * mobile-keyboard-1／2：✕ 與「不用按住」的字串三個語言都有、繁中用台灣用語。
 */
class KeyboardUxStringsTest {

    private val res: File by lazy {
        val start = System.getProperty("user.dir") ?: "."
        var dir: File? = File(start).absoluteFile
        while (dir != null) {
            for (candidate in listOf(File(dir, "src/main/res"), File(dir, "app/src/main/res"))) {
                if (File(candidate, "values/strings.xml").isFile) return@lazy candidate
            }
            dir = dir.parentFile
        }
        error("找不到 res 目錄（從 $start 往上找）")
    }

    private fun string(locale: String, name: String): String {
        val body = File(res, "$locale/strings.xml").readText()
        val m = Regex("""<string\s+name="${Regex.escape(name)}"\s*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL).find(body)
            ?: error("$locale/strings.xml 沒有 $name")
        return m.groupValues[1]
    }

    private val locales = listOf("values", "values-en", "values-zh-rCN")

    @Test
    fun `「永遠」講明最多留幾筆，跟真正的上限一致`() {
        for (locale in locales) {
            val label = string(locale, "history_retention_forever")
            assertTrue("$locale 的「永遠」要寫出上限 ${HistoryCodec.MAX}：$label", label.contains(HistoryCodec.MAX.toString()))
        }
    }

    @Test
    fun `其他期限的字不受影響`() {
        assertEquals("1 週", string("values", "history_retention_week"))
        assertEquals("不保留", string("values", "history_retention_none"))
        assertFalse(string("values", "history_retention_year").contains(HistoryCodec.MAX.toString()))
    }

    @Test
    fun `取消與不用按住的提示三個語言都有`() {
        for (locale in locales) {
            for (name in listOf("key_cancel_voice", "hint_voice_cancelled", "hint_hold_tip", "undo_insert_desc")) {
                assertTrue("$locale/$name 是空的", string(locale, name).isNotBlank())
            }
            assertTrue("$locale/hint_translate_release 要帶語言參數", string(locale, "hint_translate_release").contains("%1\$s"))
        }
    }

    @Test
    fun `新字串的繁中用台灣用語`() {
        val banned = listOf("手把手", "視頻", "默認", "信息", "粘貼", "撤銷")
        for (name in listOf("key_cancel_voice", "hint_voice_cancelled", "hint_hold_tip", "undo_insert_desc",
            "hint_translate_release", "history_retention_forever")) {
            val text = string("values", name)
            banned.forEach { assertFalse("values/$name 用了「$it」：$text", text.contains(it)) }
        }
    }
}
