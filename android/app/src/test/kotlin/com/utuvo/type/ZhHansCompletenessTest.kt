package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * B4：簡體中文資源完整性。
 *
 * `values/strings.xml` 的每一個 key 都要在 `values-zh-rCN/strings.xml` 有對應條目。
 * Android 缺字串不會編譯失敗，只會在簡中系統上默默顯示英文，所以要在這裡擋。
 *
 * 順帶擋兩件事：
 * - 簡中檔多出 values/ 已經沒有的 key（改名後留下的殘影，翻譯永遠不會生效）。
 * - 同一個 key 的 format 參數在兩邊不一致（翻譯時掉了 `%1$s`，執行期直接 crash）。
 */
class ZhHansCompletenessTest {

    private val base: File by lazy { findResDir() }
    private val source: File get() = File(base, "values/strings.xml")
    private val zhHans: File get() = File(base, "values-zh-rCN/strings.xml")

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
        assertTrue("values-zh-rCN/strings.xml 不存在：${zhHans.absolutePath}", zhHans.isFile)
    }

    @Test
    fun everyKeyInValuesHasAZhHansEntry() {
        val en = readStrings(source).keys
        val zh = readStrings(zhHans).keys
        val missing = en - zh
        assertTrue(
            "以下 ${missing.size} 個字串沒有簡體中文翻譯，請補進 values-zh-rCN/strings.xml：\n" +
                missing.joinToString("\n") { "  - $it" },
            missing.isEmpty()
        )
    }

    @Test
    fun zhHansHasNoKeysMissingFromValues() {
        val en = readStrings(source).keys
        val zh = readStrings(zhHans).keys
        val orphans = zh - en
        assertTrue(
            "以下 ${orphans.size} 個簡中字串在 values/strings.xml 已經不存在（改名殘影？）：\n" +
                orphans.joinToString("\n") { "  - $it" },
            orphans.isEmpty()
        )
    }

    @Test
    fun pluralsAreTranslatedToo() {
        val missing = pluralNames(source) - pluralNames(zhHans)
        assertTrue(
            "以下 <plurals> 沒有簡體中文翻譯：\n" + missing.joinToString("\n") { "  - $it" },
            missing.isEmpty()
        )
    }

    @Test
    fun formatArgumentsMatchTheSource() {
        val en = readStrings(source)
        val zh = readStrings(zhHans)
        val broken = zh.keys.filter { it in en && args(en.getValue(it)) != args(zh.getValue(it)) }
        assertTrue(
            "以下字串的 format 參數跟原文不一致（執行期會 crash 或吃掉參數）：\n" +
                broken.joinToString("\n") { "  - $it\n      正本：${en[it]}\n      簡中：${zh[it]}" },
            broken.isEmpty()
        )
    }

    @Test
    fun zhHansIsNotEmptyPerKey() {
        val empty = readStrings(zhHans).filterValues { it.isBlank() }.keys -
            pluralNames(zhHans)
        assertTrue("以下簡中字串是空的：\n" + empty.joinToString("\n") { "  - $it" }, empty.isEmpty())
    }

    @Test
    fun bothFilesParseAndCountsAgree() {
        assertEquals(
            "簡中字串數量應與正本相同（完整對齊）",
            readStrings(source).size,
            readStrings(zhHans).size
        )
    }

    /**
     * 完整性檢查只證明「有翻」，不證明「翻的是簡體」——有人把繁中原文貼進簡中檔時，
     * 上面的 key 檢查一樣會綠。這裡擋常見的繁體字。
     *
     * 清單是從 `values/strings.xml`（繁中正本）裡實際出現過、且 OpenCC t2s 會改寫的字
     * 自動算出來的：涵蓋這個 app 會用到的詞彙，但**不是**全部繁體字，罕用字仍可能漏網。
     * 產生方式：對正本每個漢字跑 `opencc -c t2s.txt`，取 `convert(c) != c` 者。
     */
    @Test
    fun noTraditionalCharactersLeakIntoZhHans() {
        val traditional = (
            "並併來個們備傳優儲內兩別刪則動務勢匯參問啟單國圖報場學實寫專尋對層帳庫強彙後從態慣憲應戶換擇敗數時暫會業構樂標樣機檔檢欄權歷氣決沒測準濟灣為無狀現產畫當盤確禮稅稱筆節簡紀約細結絡給統綁經網線編總續聲聽脈腦與薦藥處號術補裝裡製複見覺觸訂計訊記設許詞試話認語誤說請講證識譯變讓財費貼資質贅車軟較載輕輯輸轉這連進運過選還邊郵醫錄錯鍊鍵鑰長閉開間關際隨險離雲電靜韓響頁項順須預領題額類顯風餘饋馬驗體麥麼點"
            ).map { it.toString() }.toSet()
        val offenders = readStrings(zhHans)
            .mapNotNull { (key, text) ->
                val hit = text.filter { it.toString() in traditional }.toSet()
                if (hit.isEmpty()) null else "  - $key  含繁體字「${hit.joinToString("")}」：$text"
            }
        assertTrue(
            "簡中檔出現繁體字（${offenders.size} 筆）：\n" + offenders.joinToString("\n"),
            offenders.isEmpty()
        )
    }
}
