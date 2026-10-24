package com.utuvo.type.core

import org.json.JSONArray
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * FX-6（2026-10-23）：改口後的鐘點換掉整個舊時間；幾種數字講法不能轉一半。
 * 與 Swift Tests/UTUVOTypeCoreTests/ClockCorrectionNumberTests.swift 案例逐字相同；行為以 Swift 為準。
 * 第一次貼上＝SentenceMood.finish(Normalizer().normalize(raw).cleaned)。
 */
class ClockCorrectionNumberTest {
    // T1 舊值是「N點＋分鐘」、新值只有整點 → 舊的分鐘一起換掉，寫成整點「H:00」（以前留著舊分鐘：4:30、4:15）。
    private val t1CorrectedClockReplacesTheWholeOldTime = listOf(
        "我們約三點半，不對，四點" to "我們約4:00",
        "三點半不對四點" to "4:00",
        "明天三點十五分，不對，四點" to "明天4:00",
        "我們約兩點半，不是，三點" to "我們約3:00",
        "下午兩點半，不對，三點" to "下午3:00",
        "三點半開會，不對，四點" to "4:00開會",
        "三點半，不對，四點開會" to "4:00開會",
        "三點一刻，不對，四點" to "4:00",
        "兩點四十，不對，三點" to "3:00",
        "3點半，不對，4點" to "4:00",
        "三點半，我是說四點" to "4:00",
        "時間不是三點半是四點" to "時間4:00",
    )

    // T1 反面：新值自己有分鐘、或舊值沒有分鐘 → 照舊。
    private val t1NewMinutesOrNoOldMinutesUnchanged = listOf(
        "我們約三點，不對，四點半" to "我們約4:30",
        "三點半，不對，四點半" to "4:30",
        "三點半不對四點半" to "4:30",
        "三點，不對，四點" to "四點",
        "我們約三點，不對，四點" to "我們約四點",
        "會議三點半，不對，四點十五分開始" to "會議3:30，不對，4:15開始",
    )

    // T1：讀不出舊的鐘點＝整句照講的留著。FX-8 D1 改了第一條的期待值（同 Swift）：「禮拜五三點半」的鐘點是「三點半」，
    // 改口照 T1 換成「禮拜五4:00」；真的讀不出來的鐘點（三十點半）照舊留著原話。
    private val t1UnreadableHourStaysAsSpoken = listOf(
        "禮拜五三點半，不對，四點" to "禮拜五4:00",
        "禮拜五三十點半，不對，四點" to "禮拜五三十點半，不對，四點",
    )

    // T2 阿拉伯鐘點 H:MM 是一整個值（以前在「:」拆開：3:4:00、10:10:45）。
    private val t2ArabicClockIsOneValue = listOf(
        "3:30，不對，4:00" to "4:00",
        "10:15，不對，10:45" to "10:45",
        "我們約3:30，不對，4:00開會" to "我們約4:00開會",
        "16:9，不對，4:3" to "16:9，不對，4:3",
        "3:30不對4:00" to "3:30不對4:00",
    )

    // T3 normalizeNumbers 冪等：鐘點的數字不會被讀進後面的中文數字。
    private val t3ClockDigitsNeverJoinTheNextNumber = listOf(
        "每週十一點半二萬就好" to "每週11:30二萬就好",
        "每週11:30二萬就好" to "每週11:30二萬就好",
        "11:32萬" to "11:32萬",
        "十一點半二十個人" to "11:30二十個人",
        "3:30一分鐘" to "3:30一分鐘",
        "1:30八 ms" to "1:30八 ms",
        "5:30五元" to "5:30五元",
        "2:30五倍" to "2:30五倍",
        "3:30一起去" to "3:30一起去",
        "3:30三到五個人" to "3:30三到五個人",
        "3:30一到就走" to "3:30一到就走",
        // 辨識器拆開的「四十二」照舊接回（後面就收尾或接時間字）。
        "7.40二" to "7.42",
        "7:40二到" to "7:42到",
        "7:40二，" to "7:42，",
    )

    // T4 小數＋千不轉一半；萬照舊交給小數規則；小數點後面不念「兩」。
    private val t4DecimalThousandNeverHalfConverted = listOf(
        "一點五千元" to "一點五千元",
        "這台冷氣一點五千瓦" to "這台冷氣一點五千瓦",
        "三點五千米" to "三點五千米",
        "大概一點五千塊左右" to "大概一點五千塊左右",
        "一點五千萬" to "一點五千萬",
        "差一點五千塊" to "差一點五千塊",
        "一點五千 Hz" to "一點五千 Hz",
        "還差一點五萬就達標" to "還差15,000就達標",
        "這一點一萬塊不算什麼" to "這一點10,000塊不算什麼",
        "一點五萬" to "15,000",
        "三點兩千塊" to "三點2,000塊",
        "下午三點兩千塊交給你" to "下午三點2,000塊交給你",
        "三點千六塊" to "三點1,600塊",
        "五千塊" to "5,000塊",
    )

    // T5 概數的百分比照講的留著；確定的百分比照轉。
    private val t5VaguePercentagesStayVague = listOf(
        "大概百分之十幾" to "大概百分之十幾",
        "百分之二十幾的人" to "百分之二十幾的人",
        "百分之十來" to "百分之十來",
        "百分之五十多" to "百分之五十多",
        "百分之十餘" to "百分之十餘",
        "百分之十" to "10%",
        "百分之五十的人" to "50%的人",
        "百分之三點五" to "3.5%",
    )

    // FX-12 C1：序數的一～九留在第後，改口只替換鐘點。
    private val fx12C1OrdinalClockCorrection = listOf(
        "第一三點開會，不對，十點" to "第一10:00開會",
        "第二三點開會，不對，十一點" to "第二11:00開會",
        "第五四點出發，不對不對，十點" to "第五10:00出發",
        "第九兩點到，我是說，十點" to "第九10:00到",
        "第一三點開會，不對，四點" to "第一4:00開會",
        "第二四點出發，不對，五點" to "第二5:00出發",
        "第一三點半開會，不對，四點" to "第一4:00開會",
        "第三五點集合，我是說六點" to "第三六點集合",
        "第一九點集合，不對，十點" to "第一十點集合",
        "第一三點，不對，四點開會" to "第一4:00開會",
    )

    // FX-12 C2：每週的十位小數數量整段替換，不留下假星期幾。
    private val fx12C2WeeklyDecimalQuantityCorrection = listOf(
        "每週三十點五小時，不對，四十點五小時" to "每週四十點五小時",
        "每週三十點五個小時，不對，四十點五個小時" to "每週四十點五個小時",
        "每週三十點五公里，不對，四十點五公里" to "每週四十點五公里",
        "每週三十點五公斤，不對，四十點五公斤" to "每週四十點五公斤",
        "每週三十點五分鐘，不對，四十點五分鐘" to "每週四十點五分鐘",
    )

    // FX-12 反面：星期鐘點、正常序數、名次／次數與普通鐘點逐字保留base讀法。
    private val fx12GuardReadings = listOf(
        "週三十點開會，不對，十一點" to "週三11:00開會",
        "每週三十點開會，不對，十一點" to "每週三11:00開會",
        "第一，三點開會，不對，四點" to "第一，4:00開會",
        "第一是三點開會，不對，四點" to "第一是4:00開會",
        "第十三點開會，不對，十四點" to "第14:00開會",
        "第二十點集合，不對，二十一點" to "第二十一點集合",
        "第一名三點領獎，不對，四點" to "第一名四點領獎",
        "第一次三點開會，不對，四點" to "第一次4:00開會",
        "禮拜五三點半，不對，四點" to "禮拜五4:00",
        "三點開會，不對，四點" to "4:00開會",
        "三點半，不對，四點" to "4:00",
    )

    private fun firstPaste(raw: String) = SentenceMood.finish(Normalizer().normalize(raw).cleaned)

    private fun checkFirstPaste(cases: List<Pair<String, String>>) =
        cases.forEach { (raw, expected) -> assertEquals(expected, firstPaste(raw), raw) }

    private fun checkNumbers(cases: List<Pair<String, String>>) =
        cases.forEach { (raw, expected) -> assertEquals(expected, Normalizer.normalizeNumbers(raw), raw) }

    @Test fun fx12GuardReadings() = checkFirstPaste(fx12GuardReadings)
    @Test fun fx12C1OrdinalClockCorrection() = checkFirstPaste(fx12C1OrdinalClockCorrection)
    @Test fun fx12C2WeeklyDecimalQuantityCorrection() = checkFirstPaste(fx12C2WeeklyDecimalQuantityCorrection)

    @Test fun t1CorrectedClockReplacesTheWholeOldTime() = checkFirstPaste(t1CorrectedClockReplacesTheWholeOldTime)
    @Test fun t1NewMinutesOrNoOldMinutesUnchanged() = checkFirstPaste(t1NewMinutesOrNoOldMinutesUnchanged)
    @Test fun t1UnreadableHourStaysAsSpoken() = checkFirstPaste(t1UnreadableHourStaysAsSpoken)
    @Test fun t2ArabicClockIsOneValue() = checkFirstPaste(t2ArabicClockIsOneValue)
    @Test fun t3ClockDigitsNeverJoinTheNextNumber() = checkNumbers(t3ClockDigitsNeverJoinTheNextNumber)
    @Test fun t4DecimalThousandNeverHalfConverted() = checkNumbers(t4DecimalThousandNeverHalfConverted)
    @Test fun t5VaguePercentagesStayVague() = checkNumbers(t5VaguePercentagesStayVague)

    /** T4／T5 在整條第一次貼上也一樣。 */
    @Test fun t4AndT5HoldOnTheFirstPaste() = checkFirstPaste(listOf(
        "一點五千元" to "一點五千元", "這台冷氣一點五千瓦" to "這台冷氣一點五千瓦", "三點五千米" to "三點五千米",
        "百分之二十幾的人" to "百分之二十幾的人", "大概百分之十幾" to "大概百分之十幾", "百分之十來" to "百分之十來",
    ))

    /** T3 性質：normalizeNumbers 對整份數字標準答案語料（golden/numbers.json 的全部輸入，同 Swift）冪等。 */
    @Test fun normalizeNumbersIsIdempotentOverTheGoldenNumberCorpus() {
        val cases = JSONArray(javaClass.getResource("/golden/numbers.json")?.readText() ?: error("找不到 golden/numbers.json"))
        assertTrue(cases.length() > 9000, "語料讀不到（匯出壞了？）")
        val failures = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val input = cases.getJSONObject(i).getString("input")
            val once = Normalizer.normalizeNumbers(input)
            val twice = Normalizer.normalizeNumbers(once)
            if (twice != once) failures += "「$input」→「$once」→「$twice」"
        }
        assertTrue(failures.isEmpty(), "${failures.size} 條再整理一次會變：\n" + failures.take(30).joinToString("\n"))
    }
}
