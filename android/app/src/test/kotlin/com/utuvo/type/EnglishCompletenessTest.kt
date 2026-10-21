package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * D：英文資源完整性。
 *
 * `values/strings.xml` 的每一個 key 都要在 `values-en/strings.xml` 有對應條目。
 * Android 缺字串不會編譯失敗，只會在英文系統上默默顯示繁中原文（選了
 * 「介面語言：English」看到中英混雜），所以要在這裡擋。
 *
 * 順帶擋三件事：
 * - 英文檔多出 values/ 已經沒有的 key（改名後留下的殘影，翻譯永遠不會生效）。
 * - 同一個 key 的 format 參數在兩邊不一致（翻譯時掉了 `%1$s`，執行期直接 crash）。
 * - 英文字串是空的（翻譯者貼頭貼尾時最容易犯）。
 */
class EnglishCompletenessTest {

    private val base: File by lazy { findResDir() }
    private val source: File get() = File(base, "values/strings.xml")
    private val en: File get() = File(base, "values-en/strings.xml")

    /** 從 Gradle 的工作目錄（android/app 或 android）往上找，兩種都涵蓋。 */
    private fun findResDir(): File {
        val start = System.getProperty("user.dir") ?: "."
        var dir: File? = File(start).absoluteFile
        while (dir != null) {
            for (candidate in listOf(File(dir, "src/main/res"), File(dir, "app/src/main/res"))) {
                if (File(candidate, "values/strings.xml").isFile) return candidate
            }
            dir = dir.parentFile
        }
        error("找不到 res 目錄（從 $start 往上找 src/main/res 都沒有 values/strings.xml）")
    }

    /** key -> 去除 XML 實體、展開跳脫後的文字。 */
    private fun readStrings(file: File): Map<String, String> {
        val body = file.readText()
        val out = LinkedHashMap<String, String>()
        for (m in Regex("""<(string|string-array)\s+name="([^"]+)"\s*>(.*?)</\1>""", RegexOption.DOT_MATCHES_ALL)
            .findAll(body)) {
            out[m.groupValues[2]] = m.groupValues[3]
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&amp;", "&")   // 必須最後解，否則會把別的實體再解一次
        }
        for (m in Regex("""<plurals\s+name="([^"]+)">""").findAll(body)) {
            out[m.groupValues[1]] = ""
        }
        return out
    }

    private fun pluralNames(file: File): Set<String> =
        Regex("""<plurals\s+name="([^"]+)">""").findAll(file.readText())
            .map { it.groupValues[1] }.toSet()

    private val formatArgs = Regex("""%(?:\d+\$|[-#+ 0,(]*\d*(?:\.\d+)?)[a-zA-Z]""")

    /** (轉換符, 明確位置或 null) 的多重集合；兩邊相同才算對。 */
    private fun args(text: String): List<Pair<Char, Int?>> =
        formatArgs.findAll(text)
            .map {
                val tok = it.value
                val pos = Regex("""%(\d+)\$""").find(tok)
                (tok.last() to pos?.groupValues?.get(1)?.toIntOrNull())
            }
            .sortedBy { "${it.first}${it.second}" }
            .toList()

    @Test
    fun resFilesAreFound() {
        assertTrue("values/strings.xml 不存在：${source.absolutePath}", source.isFile)
        assertTrue("values-en/strings.xml 不存在：${en.absolutePath}", en.isFile)
    }

    @Test
    fun everyKeyInValuesHasAnEnglishEntry() {
        val src = readStrings(source).keys
        val enKeys = readStrings(en).keys
        val missing = src - enKeys
        assertTrue(
            "以下 ${missing.size} 個字串沒有英文翻譯，請補進 values-en/strings.xml：\n" +
                missing.joinToString("\n") { "  - $it" },
            missing.isEmpty()
        )
    }

    @Test
    fun englishHasNoKeysMissingFromValues() {
        val src = readStrings(source).keys
        val enKeys = readStrings(en).keys
        val orphans = enKeys - src
        assertTrue(
            "以下 ${orphans.size} 個英文字串在 values/strings.xml 已經不存在（改名殘影？）：\n" +
                orphans.joinToString("\n") { "  - $it" },
            orphans.isEmpty()
        )
    }

    @Test
    fun pluralsAreTranslatedToo() {
        val missing = pluralNames(source) - pluralNames(en)
        assertTrue(
            "以下 <plurals> 沒有英文翻譯：\n" + missing.joinToString("\n") { "  - $it" },
            missing.isEmpty()
        )
    }

    @Test
    fun formatArgumentsMatchTheSource() {
        val src = readStrings(source)
        val enStrings = readStrings(en)
        val broken = enStrings.keys.filter { it in src && args(src.getValue(it)) != args(enStrings.getValue(it)) }
        assertTrue(
            "以下字串的 format 參數跟正本不一致（執行期會 crash 或吃掉參數）：\n" +
                broken.joinToString("\n") { "  - $it\n      正本：${src[it]}\n      英文：${enStrings[it]}" },
            broken.isEmpty()
        )
    }

    @Test
    fun englishIsNotEmptyPerKey() {
        val empty = readStrings(en).filterValues { it.isBlank() }.keys -
            pluralNames(en)
        assertTrue("以下英文字串是空的：\n" + empty.joinToString("\n") { "  - $it" }, empty.isEmpty())
    }

    @Test
    fun bothFilesParseAndCountsAgree() {
        assertEquals(
            "英文字串數量應與正本相同（完整對齊）",
            readStrings(source).size,
            readStrings(en).size
        )
    }

    /**
     * 完整性檢查只證明「有翻」，不證明「翻的是英文」——有人把繁中原文貼進英文檔時，
     * 上面的 key 檢查一樣會綠（中文 demo 字串、語言原名是合法的，這裡只擋明顯殘留）。
     *
     * 白名單是刻意保留原文的 key：品牌名、語言／鍵盤層原名、繁中語音範例。
     */
    @Test
    fun englishHasNoChineseLeftBehind() {
        val keepAsIs = setOf(
            "app_name", "ime_name",
            "lang_ja_short", "lang_ko_short", "lang_zh_short",
            "dict_zh_hant_short", "dict_zh_hans_short", "dict_ja_short", "dict_ko_short",
            "kb_hant", "kb_hans", "layer_zhuyin", "layer_pinyin",
            "use_zhuyin", "use_pinyin",
            "hant_input_title", "hant_input_zhuyin", "hant_input_pinyin", "hant_input_explain",
            "guide_gesture_2", "guide_gesture_2_detail", "guide_gesture_3", "guide_gesture_3_detail",
            "option_zh_tw", "option_zh_cn",
            "smart_sample"
        )
        val han = Regex("[\\u4e00-\\u9fff\\u3400-\\u4dbf]")
        val offenders = readStrings(en)
            .filterKeys { it !in keepAsIs }
            .filterValues { han.containsMatchIn(it) }
            .keys
        assertTrue(
            "英文檔仍含中文（${offenders.size} 筆，確定是原文沒翻就加進 keepAsIs）：\n" +
                offenders.joinToString("\n") { "  - $it  → ${readStrings(en).getValue(it)}" },
            offenders.isEmpty()
        )
    }
}