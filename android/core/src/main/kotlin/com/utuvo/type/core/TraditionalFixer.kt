package com.utuvo.type.core

import java.io.File
import java.io.InputStream

/**
 * 修正新辨識引擎（Android 系統語音）的繁中：它的繁體是逐字硬轉的（2026-09-19 實測 25 句 21 句錯：
 * 回家→迴家、頭髮→頭發、干擾→幹擾、颱風→臺風、系統→係統、周圍→週圍、皇后→皇後、游泳→遊泳…）。
 *
 * 做法＝OpenCC（Apache-2.0）同一條路：先轉回簡體（t2s，多對一、不會錯），再**按詞**轉台灣繁體（s2tw）。
 * 同一組 25 句轉完只剩辨識本身聽錯的；48 段正確原文轉一圈只剩台灣正式寫法差異，那幾個改回日常寫法
 * （臺→台、瞭解→了解、儘量→盡量、絃→弦）。字典與 iOS 共用同一份 `ios/Shared/Resources/OpenCC`（不複製）。
 *
 * 字典來源由呼叫端提供（App 端＝assets，測試＝檔案系統）；讀不到就原樣回傳。
 */
object TraditionalFixer {
    /** 字典在 assets／資源資料夾裡的子目錄名。 */
    const val DICT_DIR = "OpenCC"

    /** 字典檔來源：`name` 是不含副檔名的名稱（`STPhrases`…），回傳 null 表示沒有這份字典。 */
    fun interface DictSource {
        fun open(name: String): InputStream?
    }

    private class Dict(val map: Map<String, String>, val maxLength: Int)

    private class Chain(val t2s: List<List<Dict>>, val s2tw: List<List<Dict>>)

    private val lock = Any()

    @Volatile
    private var source: DictSource? = null

    @Volatile
    private var loaded: Chain? = null

    @Volatile
    private var loadFailed = false

    /** 日常寫法（OpenCC s2tw 給的是台灣正式用字）。 */
    val everyday: List<Pair<String, String>> = listOf("瞭解" to "了解", "儘量" to "盡量", "臺" to "台", "絃" to "弦")

    /** 從 assets 讀（App 端：路徑 `OpenCC/<name>.txt`）。 */
    fun assetsSource(open: (String) -> InputStream?) = DictSource { name -> open("$DICT_DIR/$name.txt") }

    /** 從檔案系統讀（測試與離線驗證）。 */
    fun directorySource(dir: File) = DictSource { name -> File(dir, "$name.txt").takeIf { it.isFile }?.inputStream() }

    /** 換字典來源；已載入的字典會作廢，下次呼叫時重讀。 */
    fun configure(s: DictSource?) = synchronized(lock) {
        source = s
        loaded = null
        loadFailed = false
    }

    /** 轉換；字典讀不到就原樣回傳。 */
    fun fix(text: String): String {
        if (text.none { it.code in 0x4E00..0x9FFF }) return text
        val chain = chain() ?: return text
        var out = convert(convert(text, chain.t2s), chain.s2tw)
        for ((formal, daily) in everyday) out = out.replace(formal, daily)
        return out
    }

    /** 片段逐一修（停頓補標點要用片段）：整串一起轉（才有上下文），字數沒變就照原本長度切回去；變了就原樣。 */
    fun fixTokens(texts: List<String>, extra: (String) -> String = { it }): List<String> {
        val joined = texts.joinToString("")
        val fixed = extra(fix(joined))
        if (fixed.length != joined.length) return texts
        var i = 0
        return texts.map { text ->
            val n = text.length
            val piece = fixed.substring(i, i + n)
            i += n
            piece
        }
    }

    // MARK: - OpenCC 最長匹配

    private fun convert(text: String, chain: List<List<Dict>>): String {
        var current = text
        for (group in chain) {
            val maxLength = group.maxOf { it.maxLength }
            val out = StringBuilder(current.length)
            var i = 0
            while (i < current.length) {
                var matched = false
                var length = minOf(maxLength, current.length - i)
                while (length >= 1 && !matched) {
                    val key = current.substring(i, i + length)
                    for (dict in group) {
                        val value = dict.map[key]
                        if (value != null) {
                            out.append(value)
                            i += length
                            matched = true
                            break
                        }
                    }
                    length--
                }
                if (!matched) {
                    out.append(current[i])
                    i++
                }
            }
            current = out.toString()
        }
        return current
    }

    private fun chain(): Chain? {
        loaded?.let { return it }
        if (loadFailed) return null
        synchronized(lock) {
            loaded?.let { return it }
            if (loadFailed) return null
            val s = source ?: return null
            fun read(name: String): Dict? {
                val text = s.open(name)?.use { it.readBytes().toString(Charsets.UTF_8) } ?: return null
                val map = HashMap<String, String>()
                var maxLength = 1
                for (line in text.split("\n")) {
                    val tab = line.indexOf('\t')
                    if (tab <= 0) continue
                    val key = line.substring(0, tab)
                    map[key] = line.substring(tab + 1)
                    maxLength = maxOf(maxLength, key.length)
                }
                return if (map.isEmpty()) null else Dict(map, maxLength)
            }
            val tsp = read("TSPhrases"); val tsc = read("TSCharacters")
            val stp = read("STPhrases"); val stc = read("STCharacters"); val twv = read("TWVariants")
            if (tsp == null || tsc == null || stp == null || stc == null || twv == null) {
                loadFailed = true
                return null
            }
            val result = Chain(t2s = listOf(listOf(tsp, tsc)), s2tw = listOf(listOf(stp, stc), listOf(twv)))
            loaded = result
            return result
        }
    }
}
