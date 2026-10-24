package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * 接續聽寫（W2-7，2026-10-22）：Swift `SentenceMood.joinPrefix`／`finishDroppedMark` 的規則，一條一條驗
 * （同 Swift W2MacModesCoreTests.SentenceMoodJoinPrefixTests；逐字對 Swift 的在 GoldenTest.sentenceMoodJoinMatchesSwift）。
 */
class SentenceMoodJoinPrefixTest {

    /** 上一段（辨識原文 raw）finish 過貼上、記下拿掉的標點，游標沒動、這一段緊接著講。 */
    private fun join(raw: String, next: String, before: String = SentenceMood.finish(raw)): String =
        SentenceMood.joinPrefix(before, SentenceMood.finish(raw), next, SentenceMood.finishDroppedMark(raw))

    // ── 規則一：永遠不補「。」（或任何句末標點） ──

    @Test
    fun `講到一半停住的兩段接成一句不插句號`() {
        assertEquals("", join("我要", "一杯咖啡"))
        assertEquals("", join("我的老闆", "明天要來"))
        assertEquals("", join("我想要", "一杯咖啡"))
        assertEquals("", join("因為下雨", "所以取消"))
        assertEquals("", join("如果明天下雨的话", "我们就改到室内"), "簡體同一條")
    }

    @Test
    fun `辨識收的句號被拿掉了也不補回去`() {
        assertEquals("。", SentenceMood.finishDroppedMark("我要。"))
        assertEquals("", join("我要。", "一杯咖啡"))
        assertEquals("", join("我到了。", "就在門口"))
        assertEquals("", SentenceMood.joinPrefix("他到家的時候", "他到家的時候", "記得打給我", "。"))
        for ((raw, next) in listOf("我要。" to "一杯咖啡", "好" to "我們走", "太好了！" to "我們走", "你在哪？" to "我到了")) {
            assertFalse(join(raw, next).contains("。"), "$raw＋$next：永遠不補句號")
        }
    }

    // ── 規則二：中文接中文什麼都不插；上一段自己的？！照留 ──

    @Test
    fun `中文接中文什麼都不插`() {
        assertEquals("", SentenceMood.joinPrefix("前面的字我到了", "我到了", "你在哪"))
        assertEquals("", join("我到了", "你在哪裡"))
        assertEquals("", join("你在哪？", "我到了"))
        assertEquals("", join("我到了", "OK 我們走"), "中文接英文")
        assertEquals("", join("Sounds good", "我們走"), "英文接中文")
        assertEquals("", join("價格是100", "元"), "數字接中文")
        assertEquals("", join("I am here.", "我在門口"), "英文句點接中文")
    }

    // ── 規則三：英數字（或 .!?,;:）接英數字補一個空白 ──

    @Test
    fun `英數字接英數字補一個空白`() {
        assertEquals(" ", join("I want", "a coffee"))
        assertEquals(" ", join("I am here.", "Where"))
        assertEquals(" ", join("room 42", "3 people"))
        assertEquals(" ", join("Pro Tools", "2024"))
        assertEquals(" ", SentenceMood.joinPrefix("Note: I'm here", "I'm here", "Where are you?"))
        for (tail in listOf(".", "!", "?", ",", ";", ":")) {
            assertEquals(" ", SentenceMood.joinPrefix("ok$tail", "ok$tail", "next"), "上一段尾是「$tail」")
        }
        assertEquals("", SentenceMood.joinPrefix("value)", "value)", "next"), "「)」不在清單裡")
        assertEquals("", SentenceMood.joinPrefix("x", "x", "_y"), "底線不是英數字")
        assertEquals("", SentenceMood.joinPrefix("Ａ", "Ａ", "b"), "全形字母不是 ASCII")
        assertEquals("", SentenceMood.joinPrefix("I'm here", "I'm here", ""), "這一段是空的")
    }

    // ── 規則四：上一段被 finish 拿掉的「，」「、」原樣補回 ──

    @Test
    fun `上一段拿掉的逗號頓號補回去`() {
        assertEquals("，", SentenceMood.finishDroppedMark("如果明天下雨的話，"))
        assertEquals("，", join("如果明天下雨的話，", "我們就改到室內"))
        assertEquals("、", join("蘋果、", "香蕉"))
        assertEquals("，", join("取樣率用96k，", "48k也可以"), "「，」優先於英數字的空白")
        assertEquals("、", SentenceMood.finishDroppedMark("轉寄給小雅跟小潘、 "))
        assertEquals("", join("轉寄給小雅跟小潘、 ", "還有小王"), "finish 留下結尾空白：游標前是空白，不補")
        assertEquals("", SentenceMood.joinPrefix("我到了", "我到了", "你", "；"), "只認「，」「、」")
        assertEquals("", SentenceMood.finishDroppedMark("Hello world,"), "英文逗號 finish 不拿")
        assertEquals(" ", join("Hello world,", "again"))
    }

    // ── 規則五：讀不到游標前、游標前是空白、游標移走：什麼都不插 ──

    @Test
    fun `游標前不是上一段的結尾就什麼都不插`() {
        assertEquals("", SentenceMood.joinPrefix(null, "蘋果", "香蕉", "、"), "讀不到游標前")
        assertEquals("", SentenceMood.joinPrefix("", "我到了", "你在哪"))
        assertEquals("", SentenceMood.joinPrefix("蘋果 ", "蘋果", "香蕉", "、"), "游標前是空白")
        assertEquals("", SentenceMood.joinPrefix("I'm here ", "I'm here", "Where"))
        assertEquals("", SentenceMood.joinPrefix("我到了\n", "我到了", "你在哪"))
        assertEquals("", SentenceMood.joinPrefix("ok\u3000", "ok", "next"), "全形空白")
        assertEquals("", SentenceMood.joinPrefix("ok\u00A0", "ok", "next"), "不換行空白")
        assertEquals("", SentenceMood.joinPrefix("別的", "蘋果", "香蕉", "、"), "游標移走了")
        assertEquals("", SentenceMood.joinPrefix("到了", "我到了", "你", "，"), "游標前比上一段短")
        assertEquals("", SentenceMood.joinPrefix("我到了", null, "你在哪"))
        assertEquals("", SentenceMood.joinPrefix("我到了", "", "你在哪"))
    }

    // ── 交界上的字照 Swift 的 Character（字形叢集） ──

    @Test
    fun `交界上的emoji組合記號跟Swift一樣按整個字看`() {
        // 空白後面黏組合記號：Swift 是一個字、算空白 → 不補（Kotlin 的 Char.isWhitespace 會看成不是空白）。
        assertEquals("", SentenceMood.joinPrefix("我到了 \u0301", "我到了 \u0301", "你", "，"))
        // 標準等價算同一個字（「é」＝「e＋組合尖音符」）。
        assertEquals("，", SentenceMood.joinPrefix("咖啡caf\u00E9", "咖啡cafe\u0301", "好", "，"))
        // 從字中間切開的不算上一段的結尾：「e＋記號」不以「記號」結尾、ZWJ 家庭不以「👧」結尾、膚色不單獨算。
        assertEquals("", SentenceMood.joinPrefix("xe\u0301", "\u0301", "好", "，"))
        assertEquals("", SentenceMood.joinPrefix("家👨\u200D👩\u200D👧", "👧", "ok", "，"))
        assertEquals("", SentenceMood.joinPrefix("great👍🏽", "🏽", "ok", "，"))
        assertEquals("，", SentenceMood.joinPrefix("great👍🏽", "👍🏽", "ok", "，"))
        assertEquals("", SentenceMood.joinPrefix("a\r\nb", "\nb", "c", "，"), "\\r\\n 是一個字")
        // ASCII 字母後面黏記號就不是 ASCII 英數字；emoji、罕用字（非 BMP）也不是。
        assertEquals("", SentenceMood.joinPrefix("ok", "ok", "a\u0301b"))
        assertEquals("", SentenceMood.joinPrefix("A.\u0301", "A.\u0301", "b"))
        assertEquals("", SentenceMood.joinPrefix("OK 👍", "OK 👍", "thanks"))
        assertEquals("", SentenceMood.joinPrefix("x", "x", "𠮷"))
        assertEquals("、", SentenceMood.joinPrefix("吃𠮷", "𠮷", "好", "、"))
        // 零寬空白、U+001C 不是 Swift 的空白。
        assertEquals("，", SentenceMood.joinPrefix("ok\u200B", "ok\u200B", "next", "，"))
        assertEquals("，", SentenceMood.joinPrefix("ok\u001C", "ok\u001C", "x", "，"))
    }

    @Test
    fun `finishDroppedMark回報的正好是finish拿掉的那一個`() {
        assertEquals("，", SentenceMood.finishDroppedMark("好， \u0301"))
        assertEquals("好 \u0301", SentenceMood.finish("好， \u0301"))
        assertEquals("，", SentenceMood.finishDroppedMark("好，\r\n"), "\\r\\n 是一個字，不算換行")
        assertEquals("", SentenceMood.finishDroppedMark("好，\u0301"), "「，＋記號」不是「，」")
        assertEquals("", SentenceMood.finishDroppedMark("好，\u001C"))
        assertEquals("，", SentenceMood.finishDroppedMark("①，"), "①算數字")
        assertEquals("，", SentenceMood.finishDroppedMark("Ⅻ，"))
        assertEquals("", SentenceMood.finishDroppedMark("🙂，"), "只有 emoji 不算有字")
        assertEquals("，", SentenceMood.finishDroppedMark("𠮷，"))
        assertEquals("", SentenceMood.finishDroppedMark("第一段。\n第二段。"), "分段長文不拿")
        assertEquals("", SentenceMood.finishDroppedMark("你明天會來嗎。"), "apply 先改成問號，finish 就不拿東西")
    }
}
