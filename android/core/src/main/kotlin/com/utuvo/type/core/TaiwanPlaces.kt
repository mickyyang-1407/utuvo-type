package com.utuvo.type.core

/**
 * 台灣常用地名（2026-09-19 Micky 實測「圓山站」→「元山站」）。兩個用途：
 * 1. 交給辨識器當提示詞（AnalysisContext），一開始就比較容易聽對；
 * 2. 聽錯了還能救：後面接「站」、或前面是「捷運」，而且每個字讀音都一樣（去聲調拼音）才換成正確站名。
 *    不接站／捷運的「原山」不動——一般詞不猜。
 *
 * 讀音比對需要繁體拼音詞庫（`pinyin-hant.dat`，App 端由呼叫端注入；測試直接開檔）。
 * 沒有詞庫時只比對完全相同的字（等同於不做讀音救援），不猜。
 */
object TaiwanPlaces {
    /** 台北捷運站名（不含「站」）。 */
    val taipeiMRT: List<String> = listOf(
        // 淡水信義線
        "淡水", "紅樹林", "竹圍", "關渡", "忠義", "復興崗", "北投", "新北投", "奇岩", "唭哩岸", "石牌", "明德", "芝山", "士林",
        "劍潭", "圓山", "民權西路", "雙連", "中山", "台北車站", "台大醫院", "中正紀念堂", "東門", "大安森林公園", "大安",
        "信義安和", "台北101", "世貿", "象山",
        // 松山新店線
        "松山", "南京三民", "台北小巨蛋", "南京復興", "松江南京", "北門", "西門", "小南門", "古亭", "台電大樓", "公館",
        "萬隆", "景美", "大坪林", "七張", "新店區公所", "新店", "小碧潭",
        // 板南線
        "頂埔", "永寧", "土城", "海山", "亞東醫院", "府中", "板橋", "新埔", "江子翠", "龍山寺", "善導寺", "忠孝新生",
        "忠孝復興", "忠孝敦化", "國父紀念館", "市政府", "永春", "後山埤", "昆陽", "南港", "南港展覽館",
        // 中和新蘆線
        "南勢角", "景安", "永安市場", "頂溪", "行天宮", "中山國小", "民權西路", "大橋頭", "台北橋", "菜寮", "三重",
        "先嗇宮", "頭前庄", "新莊", "輔大", "丹鳳", "迴龍", "三重國小", "三和國中", "徐匯中學", "三民高中", "蘆洲",
        // 文湖線
        "動物園", "木柵", "萬芳社區", "萬芳醫院", "辛亥", "麟光", "六張犁", "科技大樓", "中山國中", "松山機場", "大直",
        "劍南路", "西湖", "港墘", "文德", "內湖", "大湖公園", "葫洲", "東湖", "南港軟體園區",
        // 環狀線
        "十四張", "秀朗橋", "景平", "中和", "橋和", "中原", "板新", "新埔民生", "幸福", "新北產業園區",
    )

    /** 給辨識器的提示詞（站名＋「站」），去重。 */
    val contextualStrings: List<String> = taipeiMRT.distinct().map { it + "站" }

    private val byLength: Map<Int, List<String>> = taipeiMRT.distinct().groupBy { it.length }

    @Volatile
    var lexicon: PinyinLexicon? = null

    private val lock = Any()
    private val pinyinCache = HashMap<Char, String>()

    /** 台灣口音寬鬆比對（只用在站名這種專名）：前後鼻音（in/ing、en/eng）、捲舌（zh/z、ch/c、sh/s）不分。 */
    fun looseSound(c: Char): String {
        var p = pinyin(c) ?: return ""
        for ((a, b) in listOf("zh" to "z", "ch" to "c", "sh" to "s")) if (p.startsWith(a)) p = b + p.substring(a.length)
        for ((a, b) in listOf("ing" to "in", "eng" to "en")) if (p.endsWith(a)) p = p.dropLast(a.length) + b
        return p
    }

    fun soundsAlike(a: Char, b: Char): Boolean =
        a == b || (isCJK(a) && isCJK(b) && pinyin(a) != null && looseSound(a) == looseSound(b))

    /** 把讀音相同的錯字站名換成正確站名（只在後面接「站」或前面是「捷運」時）。 */
    fun fixStations(text: String): String {
        if (!text.contains("站") && !text.contains("捷運")) return text
        val chars = text.toCharArray()
        var i = 0
        while (i < chars.size) {
            var replaced = false
            for (length in (2..6).reversed()) {
                if (i + length > chars.size) continue
                val names = byLength[length] ?: continue
                val after = if (i + length < chars.size) chars[i + length] else null
                val before2 = if (i >= 2) String(chars, i - 2, 2) else ""
                if (after != '站' && before2 != "捷運") continue
                val candidate = String(chars, i, length)
                if (names.contains(candidate)) {
                    i += length
                    replaced = true
                    break
                }
                val match = names.firstOrNull { name ->
                    name.indices.all { name[it] == candidate[it] || soundsAlike(candidate[it], name[it]) }
                }
                if (match != null) {
                    match.toCharArray().copyInto(chars, i)
                    i += length
                    replaced = true
                    break
                }
            }
            if (!replaced) i++
        }
        return String(chars)
    }

    fun isCJK(c: Char) = c.code in 0x3400..0x9FFF || c.code in 0xF900..0xFAFF

    /** 單字拼音（無聲調）；查不到回 null。詞庫沒有時回 null。 */
    private fun pinyin(c: Char): String? = synchronized(lock) {
        pinyinCache[c]?.let { return it }
        val lex = lexicon ?: return null
        var found: String? = null
        for (s in lex.syllables.all) {
            val hit = lex.lookup(listOf(s)).firstOrNull { it.text.contains(c) }
            if (hit != null) {
                found = s
                break
            }
        }
        if (found != null) pinyinCache[c] = found
        found
    }
}
