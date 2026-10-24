package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * FX-1 v2（2026-10-22）沒訊號的改口詞：Swift `SelfCorrectionPolicyTests` 逐條相同。
 * 第一次貼上＝SentenceMood.finish(Normalizer().normalize(raw).cleaned)；把關拿第一次貼上當原文、模型輸出先 normalizeNumbers。
 * C1 不對＋齊應勁稱外盤焦等頭味題口是描述詞；C2 沒停頓、沒連說的「不對／我是說／啊不對」只認值換值、新值後面最多 2 個中文字；
 * C3 小數是一整個值。有訊號的改口照 b8817d8。
 */
class SelfCorrectionPolicyTest {
    private val descriptive = listOf(
        "第3軌不對齊第4軌", "48K不對應96K", "左聲道跟右聲道不對稱", "這個感覺不對勁", "這個畫面不對焦",
        "價格不對等", "這個說法不對題", "這兩個人不對盤", "三點，不對應該是四點",
    )

    private val decimals = listOf(
        "取樣率44.1K不對48K" to "取樣率48K",
        "取樣率44.1K，不對，48K" to "取樣率48K",
        "音量調到1.5倍不對2倍" to "音量調到2倍",
        "版本1.2不對1.3" to "版本1.3",
        "音量調到1.5倍，不對，2倍" to "音量調到2倍",
    )

    private val keptAsSpoken = listOf(
        "買房補助不對買車的人發放", "住宿費不對住戶收取", "選舉結果不對選民公開", "回饋金不對回頭客發放",
        "搭車補助不對搭飛機的人發", "給他的檔案不對給他的同事公開", "去日本的補助不對去韓國的人發放",
        "用手機的人不對用電腦的人收費", "在台北的員工不對在台中的人發放", "使用者資料不對用戶公開",
        "現在的資料不對在場的人公開", "週六不對週日訪客發放停車證", "三號不對四號以後報名者退費",
        "今天不對明天出發旅客退票", "今天不對明天預約客人收訂金", "三樓不對四樓住戶發放鑰匙",
        "48K不對96K用戶推送更新", "台北辦公室的門禁卡不對台北辦公室訪客發放", "週三不對週四我也沒空",
        "今天不對明天我也不行", "48K不對96K我覺得也不行", "三點不對四點其實也不好", "三點不對四點卻可以",
        "今天不對明天倒是可以", "找他幫忙不對找她", "喝咖啡不對喝茶", "這個方向不對", "他說的不對", "這樣不對吧我覺得",
        "這個專案原始碼不對這個專案外包看就好", "我們公司資料不對我們公司客戶就好",
        "我住三樓不是四樓", "我要的是48K不是96K", "萬一不是三點呢", "開會時間是星期三不是星期四",
        "我們要的是第二版不是第三版",
        // 以前會改掉、現在照講的留著（政策接受的損失，不是缺陷）
        "我們約三點不對四點都可以", "打給王經理不對打給李經理", "小雅跟小波不對小雅跟小潘",
        "檔案用48K不對96K匯出的版本給我", "寄給王小明不對寄給李小華", "檔名叫做Final V3不對Final V4",
        // 時間「3:30」對齊規則會拆壞成「3:4:00」，沒訊號時不改
        "3:30不對4:00",
        // 「明天晚上」算一個值，但後面還有 4 個字
        "今天不對明天晚上我也不行",
    )

    private val resolved = listOf(
        "三點，不對，四點出發" to "4:00出發",
        "三點不對不對四點出發" to "4:00出發",
        "三樓，不是，四樓" to "四樓",
        "小雅跟小波不對不對小雅跟小潘" to "小雅跟小潘",
        "三點不對不對四點以後再說" to "4點以後再說",
        "48K不對不對96K匯出的版本給我" to "96K匯出的版本給我",
        "版本V3不對不對V4更新" to "版本V4更新",
        "我們約三點不對不對四點都可以" to "我們約四點都可以",
        "檔名叫做Final V3,啊不對是Final V4" to "檔名叫做Final V4",
        "幫我轉寄給小雅跟小柏﹑不是,是小雅跟小潘﹑" to "幫我轉寄給小雅跟小潘",
        "取樣利用48k﹐不對不對是96k﹐" to "取樣利用96k",
        "打給王經理，不對，打給李經理" to "打給李經理",
        "三點開會，不對，四點開會" to "4:00開會",
        "三點不對四點出發" to "4:00出發",
        "48K不對96K" to "96K",
        "今天不對明天出發" to "明天出發",
        "預算1200不對12000" to "預算12000",
        "版本V3不對V4更新" to "版本V4更新",
        "三點不對四點" to "四點",
        "三點啊不對四點" to "四點",
        "三點我是說四點" to "四點",
        "三點不對四點不對五點" to "五點",
        // 星期／相對日＋時段算一個值（合併 FX-3 時發現：「下午見」不該算三個字的後文）。同 Swift。
        "我們約禮拜三不對禮拜五下午見" to "我們約禮拜五下午見",
        "今天不對明天晚上好了" to "明天晚上好了",
    )

    private val strictRejects = listOf(
        "第3軌不對齊第4軌" to "第4軌。",
        "48K不對應96K" to "96K。",
        "買房補助不對買車的人發放" to "買車的人發放。",
        "給他的檔案不對給他的同事公開" to "給他的同事公開。",
        "週六不對週日訪客發放停車證" to "週日訪客發放停車證。",
        "三樓不對四樓住戶發放鑰匙" to "四樓住戶發放鑰匙。",
        "週三不對週四我也沒空" to "週四我也沒空。",
        "喝咖啡不對喝茶" to "喝茶。",
        "打給王經理不對打給李經理" to "打給李經理。",
    )

    private val accepted = listOf(
        "三點，不對，四點出發" to "4點出發。",
        "檔名叫做Final V3,啊不對是Final V4" to "檔名叫做 Final V4。",
    )

    private fun firstPaste(raw: String) = SentenceMood.finish(Normalizer().normalize(raw).cleaned)

    /** 只比字：標點、空白、換行不算（條列格式化會把句子拆行）。 */
    private fun squash(text: String) = text.replace(Regex("[\\s，。、,.!?！？：:；;]"), "")

    @Test
    fun descriptiveNotRightIsNeverAMarker() {
        for (raw in descriptive) assertEquals(raw, firstPaste(raw), raw)
    }

    @Test
    fun decimalsAreReplacedWhole() {
        for ((raw, expected) in decimals) assertEquals(expected, firstPaste(raw), raw)
    }

    @Test
    fun unsignalledNonValueMarkersStayAsSpoken() {
        for (raw in keptAsSpoken) assertEquals(squash(raw), squash(firstPaste(raw)), raw)
    }

    @Test
    fun signalledAndValueForValueCorrectionsKeepTheirResult() {
        for ((raw, expected) in resolved) assertEquals(expected, firstPaste(raw), raw)
    }

    @Test
    fun strictGateRejectsResolvedRestatements() {
        for ((raw, candidate) in strictRejects) {
            assertFalse(CleanupFidelity.preservesContent(firstPaste(raw), Normalizer.normalizeNumbers(candidate)), "$raw → $candidate")
        }
    }

    /** Android 只有嚴格把關（寬鬆 passesRelaxed 只在 Swift），這裡只比嚴格那關。 */
    @Test
    fun gateStillAcceptsSignalledCorrections() {
        for ((raw, candidate) in accepted) {
            val original = firstPaste(raw)
            val cleaned = Normalizer.normalizeNumbers(candidate)
            assertTrue(CleanupFidelity.preservesContent(original, cleaned), "$raw → $candidate：${CleanupFidelity.rejectionReason(original, cleaned)}")
        }
    }

    /** 連說記號只在 repeat → self-correction 兩關之間存在，不會留在輸出裡。 */
    @Test
    fun doubledFlagNeverLeaks() {
        for (raw in listOf("喝咖啡不對不對喝茶", "我是說我是說", "不是不是", "這樣不對不對吧")) {
            assertFalse(Normalizer().normalize(raw).cleaned.contains(Normalizer.DOUBLED_FLAG), raw)
        }
        assertEquals("喝咖啡不對喝茶", Normalizer().normalize("喝咖啡不對不對喝茶").cleaned)
    }
}
