package com.utuvo.type.core

import org.json.JSONArray
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 條列與分段的性質測試（2026-10-22 W2-6 修正）：與 Swift DeterministicStructurePropertyTests 讀同一份
 * structure-probes.json（兩份審查的探針＋44 句真人錄音辨識結果）。
 * - 條列／分段只能加編號、換行、標點，不能吃掉內容字（中文、英文字母、數字）。
 * - 整理兩次跟整理一次一樣。
 */
class StructurePropertyTest {
    private val n = Normalizer()

    private fun probes(): List<String> {
        val a = JSONArray(javaClass.getResource("/structure-probes.json")?.readText() ?: error("找不到 structure-probes.json"))
        return (0 until a.length()).map { a.getString(it) }
    }

    @Test fun listAndParagraphStagesKeepEveryContentCharacter() {
        val probes = probes()
        assertTrue(probes.size >= 250, "探針檔讀不到或被截短")
        val failures = probes.mapNotNull { input ->
            val before = n.normalize(input, stopBefore = "list").cleaned
            val after = n.normalize(input).cleaned
            StructureInvariant.firstDroppedContent(before, after)?.let { "「$input」\n  → 「$after」\n  $it" }
        }
        assertTrue(failures.isEmpty(), "${failures.size} 條吃字：\n" + failures.take(20).joinToString("\n"))
    }

    /** 第三輪政策（同 Swift，2026-10-22）：條列這一關不能只切行不編號——條列後面的文字裡不能多出「第N」開頭的行。 */
    @Test fun listStageNeverSplitsAnOrdinalWithoutNumberingIt() {
        val failures = probes().mapNotNull { input ->
            val before = n.normalize(input, stopBefore = "list").cleaned
            val listed = n.normalize(input, stopBefore = "paragraph").cleaned
            if (StructureInvariant.ordinalLineStarts(listed) > StructureInvariant.ordinalLineStarts(before)) "「$input」\n  → 「$listed」" else null
        }
        assertTrue(failures.isEmpty(), "${failures.size} 條只切行沒編號：\n" + failures.take(20).joinToString("\n"))
    }

    @Test fun normalizeIsIdempotentOnAllProbes() {
        val failures = probes().mapNotNull { input ->
            val once = n.normalize(input).cleaned
            val twice = n.normalize(once).cleaned
            if (twice != once) "「$input」\n  一次 「$once」\n  兩次 「$twice」" else null
        }
        assertTrue(failures.isEmpty(), "${failures.size} 條整理兩次結果不同：\n" + failures.take(20).joinToString("\n"))
    }

    @Test fun invariantCheckerIsNotHollow() {
        assertNotNull(StructureInvariant.firstDroppedContent("我要買三樣東西，豬肉、雞肉、和牛", "我要買三樣東西：\n1. 豬肉\n2. 雞肉\n3. 牛"))
        assertNotNull(StructureInvariant.firstDroppedContent("這次要拍兩個，定點、跟拍", "這次要拍兩個：\n1. 定點\n2. 拍"))
        assertNotNull(StructureInvariant.firstDroppedContent("我想到兩個，戰爭、和平", "我想到兩個：\n1. 戰爭\n2. 平"))
        // 第三輪（同 Swift）：「N. 」只能代替符合條列規則的「第N」。修正前這幾條都算沒吃字（「1. 」被當成「第一」）。
        assertNotNull(StructureInvariant.firstDroppedContent("第一軌是 kick，第二是 snare，第三是 hihat", "1. 軌是 kick\n2. snare\n3. hihat"))
        assertNotNull(StructureInvariant.firstDroppedContent("我們錄了三遍，第一遍太快，第二是太慢，第三剛好", "我們錄了三遍：\n1. 遍太快\n2. 太慢\n3. 剛好"))
        assertNotNull(StructureInvariant.firstDroppedContent("第一小提琴太大聲，第二中提琴太小聲，第三大提琴剛好", "1. 小提琴太大聲\n2. 中提琴太小聲\n3. 大提琴剛好"))
        assertNotNull(StructureInvariant.firstDroppedContent("樂團裡第一吉他是阿明，第二貝斯是小華，第三鍵盤是阿強", "樂團裡：\n1. 吉他是阿明\n2. 貝斯是小華\n3. 鍵盤是阿強"))
        assertNotNull(StructureInvariant.firstDroppedContent("第一買牛奶，第二買麵包，第三寫報告", "1. 買牛奶\n2. 買麵包\n3. 寫報告"), "沒有清單引言")
        assertNotNull(StructureInvariant.firstDroppedContent("今天有兩件事，第一買牛奶第二回email第三寫報告", "今天有兩件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"), "數量對不上")
        // 第四輪（同 Swift）政策 (A)：「第二」緊接在「奶」後面不是子句開頭——沒有標點的連續序數串不能編號（第三輪這條是 Null）。
        assertNotNull(StructureInvariant.firstDroppedContent("今天有三件事第一買牛奶第二回email第三寫報告", "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"))
        assertNull(StructureInvariant.firstDroppedContent("今天有三件事，第一買牛奶，第二回email，第三寫報告", "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"))
        // 第四輪：排名／口號（第N 收在子句結尾）與「第N＋名詞」不能編號。修正前第一條算沒吃字（「速度」前面是「，」就放行）。
        assertNotNull(StructureInvariant.firstDroppedContent("安全第一，速度第二，大家小心開車", "安全：\n1. 速度\n2. 大家小心開車"))
        assertNotNull(StructureInvariant.firstDroppedContent("他拿了第一，我拿了第二，大家都很開心", "他拿了：\n1. 我拿了\n2. 大家都很開心"))
        assertNotNull(StructureInvariant.firstDroppedContent("今天有兩件事，第一小提琴重錄，第二小提琴補錄", "今天有兩件事：\n1. 小提琴重錄\n2. 小提琴補錄"))
        assertNotNull(StructureInvariant.firstDroppedContent("今天錄三樣，第一小提琴，第二中提琴，第三大提琴", "今天錄三樣：\n1. 小提琴\n2. 中提琴\n3. 大提琴"))
        assertNotNull(StructureInvariant.firstDroppedContent("以下第一小提琴重錄第二小提琴補錄", "以下：\n1. 小提琴重錄\n2. 小提琴補錄"))
        assertNotNull(StructureInvariant.firstDroppedContent("這週有兩件事，第一排錄音，第二排混音", "這週有兩件事：\n1. 排錄音\n2. 排混音"), "排＝量詞 (C)")
        assertNull(StructureInvariant.firstDroppedContent("以下兩點：第一確認檔案，第二上傳雲端", "以下兩點：\n1. 確認檔案\n2. 上傳雲端"))
        assertNull(StructureInvariant.firstDroppedContent("我說兩件事。第一是買菜，第二是煮飯", "我說兩件事。\n1. 買菜\n2. 煮飯"))
        assertNull(StructureInvariant.firstDroppedContent("第一，安全；第二，速度", "1. 安全\n2. 速度"))
        assertNull(StructureInvariant.firstDroppedContent("今天的工作清單是第一更新Pro Tools,第二匯出Stems,第三寫交付說明", "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明"))
        assertNull(StructureInvariant.firstDroppedContent("第一個是麥克風，第二點是耳機", "1. 麥克風\n2. 耳機"))
        assertNull(StructureInvariant.firstDroppedContent("第一是不是要先開會，第二是誰負責", "1. 是不是要先開會\n2. 誰負責"))
        assertEquals(2, StructureInvariant.ordinalLineStarts("我們要的是\n第二版不是\n第三版"))
        assertEquals(1, StructureInvariant.ordinalLineStarts("第一是A，第三是B"))
        assertNull(StructureInvariant.firstDroppedContent("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭", "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭"))
        assertNull(StructureInvariant.firstDroppedContent("第一是買菜；第二是煮飯", "1. 買菜\n2. 煮飯"))
        assertNull(StructureInvariant.firstDroppedContent("預算很緊，然後另外要再找人", "預算很緊。\n\n另外要再找人"))
        assertNull(StructureInvariant.firstDroppedContent("1. 買牛奶\n2. 回信", "1. 買牛奶\n2. 回信"))
    }
}

/** 同 Swift `StructureInvariant`：前一關的內容字要依序出現在結果裡（例外見 Swift 版說明）；「N. 」只能代替符合條列規則的「第N」。 */
internal object StructureInvariant {
    fun firstDroppedContent(before: String, after: String): String? {
        unqualifiedNumbering(before, after)?.let { return it }
        var b = numberedMarkersAsOrdinals(before)
        b = Regex("(第[一二三四五六七八九十]{1,3})[ \\t]*[個點項步件就]?是(?!否|不是)").replace(b, "$1")
        b = Regex("、[ \\t]*(?:還有|以及)").replace(b, "、")
        val openers = (Normalizer.paragraphOpeners + Normalizer.paragraphClosers + Normalizer.paragraphWeakOpeners)
            .joinToString("|") { Regex.escape(it) }
        b = Regex("(^|[，,。！？!?；;\\s])(?:然後|那)(?=$openers)").replace(b, "$1")
        val want = content(b)
        val have = content(numberedMarkersAsOrdinals(after))
        var j = 0
        for ((i, cp) in want.withIndex()) {
            while (j < have.size && have[j] != cp) j++
            if (j == have.size) {
                val around = want.subList(maxOf(0, i - 6), minOf(want.size, i + 6)).joinToString("") { String(Character.toChars(it)) }
                return "第 $i 個內容字「${String(Character.toChars(cp))}」不見了（前後文「$around」）"
            }
            j++
        }
        return null
    }

    private fun content(s: String): List<Int> = s.codePoints().toArray().filter { Character.isLetterOrDigit(it) }

    // 「N. 」只能代替符合條列規則的「第N」（同 Swift，2026-10-22 第三輪＋第四輪 A／B／C；照規格另外寫一份，不呼叫 Normalizer）

    private val measureWords = listOf("小節", "聲道", "回合") + "軌台遍支個次首張件項點步章節段位名天週年輪場集拍層樓號種款顆則筆趟口套組隻條把本部版的頁列排關".map { it.toString() }
    /** 第四輪政策 (B) 的動作動詞：票面列的字＋「重開／重新」＋同一批字的簡體（同 Swift StructureInvariant.actionVerbs）。 */
    private val actionVerbs = listOf("買", "回", "寫", "交", "做", "改", "加", "刪", "寄", "送", "帶", "排", "繳", "洗", "煮", "倒", "拿", "找", "問",
        "練", "讀", "修", "開", "關", "去", "準備", "更新", "匯出", "匯入", "確認", "檢查", "整理", "收", "錄", "補錄",
        "重錄", "重做", "上傳", "下載", "安裝", "測試", "聯絡", "通知", "預約", "處理", "安排", "提醒", "規劃", "設定",
        "備份", "重開", "重新",
        "买", "写", "删", "带", "缴", "问", "练", "读", "开", "关", "录", "准备", "汇出", "汇入", "确认", "检查", "补录",
        "重录", "重开", "上传", "下载", "安装", "测试", "联络", "预约", "处理", "规划", "备份")
    private const val countIntro = "(?<![第0-9一二三四五六七八九十兩百])(?:([兩二三四五六七八九十]|10|[2-9])(?:件事情|件事|樣東西|樣|項|個步驟|個重點)|([兩二三四五六七八九十])點)"
    private val counts = mapOf("兩" to 2, "二" to 2, "三" to 3, "四" to 4, "五" to 5, "六" to 6, "七" to 7, "八" to 8, "九" to 9, "十" to 10, "10" to 10,
        "2" to 2, "3" to 3, "4" to 4, "5" to 5, "6" to 6, "7" to 7, "8" to 8, "9" to 9)
    private const val ordinalCue = "第[一二三四五六七八九十]{1,3}"

    /** 同 Swift unqualifiedNumbering：結果裡每一行「K. 內容」，內容在整理前的文字裡前面要是分隔或符合條列規則的「第K」。 */
    fun unqualifiedNumbering(before: String, after: String): String? {
        for (line in after.split("\n")) {
            val m = Regex("^[ \\t]*[0-9]{1,2}\\. ").find(line) ?: continue
            val k = m.value.filter { it.isDigit() }.toIntOrNull() ?: continue
            val key = line.substring(m.range.last + 1).codePoints().toArray().filter { Character.isLetterOrDigit(it) }.take(2)
            if (key.isEmpty()) continue
            var pattern = Regex.escape(String(Character.toChars(key[0])))
            if (key.size > 1) pattern += "[^\\p{L}\\p{N}]*" + Regex.escape(String(Character.toChars(key[1])))
            val allowed = Regex(pattern).findAll(before).any { hit ->
                numberingAllowed(before.substring(0, hit.range.first), before.substring(hit.range.first), k)
            }
            if (!allowed) return "「$line」：整理前這一項前面不是符合條列規則的「第${chinese(k)}」或分隔，不能換成編號"
        }
        return null
    }

    private fun numberingAllowed(rawHead: String, item: String, k: Int): Boolean {
        val head = rawHead.trimEnd(' ', '\t')
        val spaced = head.length < rawHead.length
        if (Regex("(?:^|\\n)[ \\t]*$k\\.$").containsMatchIn(head)) return true
        val ordinal = "第" + chinese(k)
        // 「第N」＋分隔或「是」類＝明確的序號 (B)：要是第 K，而且在子句開頭 (A)。
        Regex("(第[一二三四五六七八九十]{1,3})[ \\t]*(?:[、，,：:]|[個點項步件就]?是)$").find(head)?.let { hit ->
            return hit.groupValues[1] == ordinal && atClauseStart(head.substring(0, hit.range.first))
        }
        if (Regex("[、，,：:](?:[ \\t]*(?:還有|以及))?$").containsMatchIn(head)) return true
        if (!head.endsWith(ordinal) || !atClauseStart(head.dropLast(ordinal.length))) return false  // (A)
        if (measureWords.any { item.startsWith(it) }) return false  // (C)
        if (spaced || item.startsWith("是否") || item.startsWith("是不是")) return true
        // (B)：直接接內容＝這一項要用政策的動作動詞開頭。
        if (actionVerbs.none { item.startsWith(it) }) return false
        // (B)：引言＝這句第一個「第N」前面，那裡沒有字就看前一句；最後一個子句講的數量要等於這句「第N」的個數。
        val parts = head.split(Regex("[。！？!?\\n]"))
        val sentence = parts.last() + item.takeWhile { it !in "。！？!?\n" }
        val cues = Regex(ordinalCue).findAll(sentence).count()
        val firstCue = Regex(ordinalCue).find(sentence) ?: return false
        var intro = sentence.substring(0, firstCue.range.first)
        if (intro.codePoints().noneMatch { Character.isLetterOrDigit(it) }) intro = parts.dropLast(1).lastOrNull() ?: ""
        intro = intro.trim { it in " \t\n，,、：:；;。！？!?" }
        val cut = intro.indexOfLast { it in "，,、；;：:" }
        if (cut >= 0) intro = intro.substring(cut + 1)
        val hit = Regex(countIntro).findAll(intro).lastOrNull()
        if (hit != null) return (hit.groups[1]?.value ?: hit.groups[2]?.value)?.let { counts[it] } == cues
        return listOf("以下", "如下", "清單").any { intro.contains(it) }
    }

    /** (A) 「第N」前面（pre）是子句開頭：開頭、分隔、句尾（可接引號括號）或清單引言本身（同 Swift atClauseStart）。 */
    private fun atClauseStart(pre: String): Boolean {
        if (pre.isEmpty() || pre.last() in " \t\n\r，,、：:；;。！？!?") return true
        if (Regex("[。！？!?][」』”\"）)]+$").containsMatchIn(pre)) return true
        return Regex("(?:清單是|清單|以下|如下|$countIntro)$").containsMatchIn(pre)
    }

    /** 「第N」開頭的行數（條列這一關不能只切行不編號）。 */
    fun ordinalLineStarts(s: String): Int = s.split("\n").count { Regex("^[ \\t]*$ordinalCue").containsMatchIn(it) }

    private fun numberedMarkersAsOrdinals(s: String): String =
        Regex("(?m)^[ \\t]*([0-9]{1,2})\\. ").replace(s) { "第" + chinese(it.groupValues[1].toInt()) }

    private fun chinese(n: Int): String {
        val d = listOf("零", "一", "二", "三", "四", "五", "六", "七", "八", "九")
        if (n < 10) return d[n]
        val tens = n / 10
        val ones = n % 10
        return (if (tens == 1) "" else d[tens]) + "十" + (if (ones == 0) "" else d[ones])
    }
}
