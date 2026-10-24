package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * FX-2 v2（2026-10-22）：數字正規化不能發明或弄壞數值；有兩種讀法就整段照講的留著。
 * 與 Swift Tests/UTUVOTypeCoreTests/NumberSpanTests.swift 案例逐字相同；行為以 Swift 為準。
 */
class NumberSpanTest {
    private fun check(cases: List<Pair<String, String>>) =
        cases.forEach { (input, expected) -> assertEquals(expected, Normalizer.normalizeNumbers(input), input) }

    // N1 概數／單獨的位值字：整段照講的留著，不變 0、不縮成一個數
    private val n1VagueAndBareMagnitudesStayAsSpoken = listOf(
        "幾萬塊" to "幾萬塊",
        "一兩萬" to "一兩萬",
        "十幾萬" to "十幾萬",
        "上萬人" to "上萬人",
        "數萬元" to "數萬元",
        "一兩百 ms" to "一兩百 ms",
        "幾十 ms" to "幾十 ms",
        "三、四十 ms" to "三、四十 ms",
        "三四十 ms" to "三四十 ms",
        "一兩百塊" to "一兩百塊",
        "延遲大概一兩百 ms" to "延遲大概一兩百 ms",
        "兩三千塊" to "兩三千塊",
        "三四十個人" to "三四十個人",
        "幾百塊" to "幾百塊",
        "數千元" to "數千元",
        "上千塊" to "上千塊",
        "上百人" to "上百人",
        "十幾萬塊" to "十幾萬塊",
        "一百多萬塊" to "一百多萬塊",
        "萬元戶" to "萬元戶",
        "萬一他不來" to "萬一他不來",
        "3千幾百塊" to "3千幾百塊",
        "一兩 百 ms" to "一兩 百 ms",
        "三四 十 ms" to "三四 十 ms",
        "幾  十 ms" to "幾  十 ms",
        "幾　十 ms" to "幾　十 ms",
        "3 千 塊" to "3 千 塊",
        "5 百 塊" to "5 百 塊",
        "1.5 千 元" to "1.5 千 元",
        "3 百 Hz" to "3 百 Hz",
        "預算 3 千塊。" to "預算 3 千塊。",
        "三、四千塊" to "三、四千塊",
        "十一二萬" to "十一二萬",
    )

    // N1 反面：確定的數照轉（清單「第一、」不是概數）
    private val n1ExactAmountsStillConvert = listOf(
        "三千塊" to "3,000塊",
        "五萬" to "50,000",
        "十二萬" to "120,000",
        "一億" to "100,000,000",
        "十塊" to "10塊",
        "千元" to "1,000元",
        "第一、五千塊" to "第一、5,000塊",
        "加上三百塊" to "加上300塊",
        "三、四個人" to "三、四個人",
        "一千零五元" to "1,005元",
        "預算三千塊" to "預算3,000塊",
        "3千塊" to "3千塊",
        "1.5萬" to "15,000",
    )

    // N2 阿拉伯小數＋萬：讀成完整數值，空白照留，不會變「1.5 0 元」
    private val n2ArabicDecimalWithMagnitude = listOf(
        "1.5 萬 元" to "15,000 元",
        "1.5 萬 塊" to "15,000 塊",
        "1.5萬元" to "15,000元",
        "預算 1.5 萬 元" to "預算 15,000 元",
    )

    // N3 星期幾的數字不跟後面的數字黏在一起
    private val n3WeekdayNeverMergesWithFollowingNumber = listOf(
        "禮拜五三點半開會" to "禮拜五3:30開會",
        "禮拜五十點半開會" to "禮拜五10:30開會",
        "週五十一點半到" to "週五11:30到",
        "星期一三點開會" to "星期一3:00開會",
        "禮拜二十點半" to "禮拜二10:30",
        "星期三三點一萬塊" to "星期三三點10,000塊",
        "禮拜五三點一萬塊給你" to "禮拜五三點10,000塊給你",
        "週五三點一萬塊" to "週五三點10,000塊",
        "禮拜一一點一萬塊" to "禮拜一一點10,000塊",
        "禮拜五二點一萬" to "禮拜五二點10,000",
        "星期三十一點二分鐘" to "星期三十一點二分鐘",
        "禮拜五三四點半" to "禮拜五三四點半",
        "禮拜五十萬" to "禮拜五十萬",
        "禮拜五十個人" to "禮拜五十個人",
        "星期三十分鐘" to "星期三十分鐘",
        "週一二三有課" to "週一二三有課",
        "禮拜五三點三倍" to "禮拜五三點三倍",
        "這週三千塊的預算" to "這週3,000塊的預算",
        "禮拜五千塊" to "禮拜5,000塊",
        "禮拜五點半" to "禮拜5:30",
        "每週十一點半二萬就好" to "每週11:30二萬就好",
    )

    // N4 省略「一」的千／百：千六＝1,600，不是 1,006
    private val n4AbbreviatedThousands = listOf(
        "千六塊" to "1,600塊",
        "千七 dB" to "1700 dB",
        "三點千六塊" to "三點1,600塊",
        "百五塊" to "150塊",
        "一千六塊" to "1,600塊",
    )

    // N5 共用位值的範圍：整段照講的留著，不讀成一半
    private val n5SharedMagnitudeRangesAreNotHalfRead = listOf(
        "一千到兩千萬" to "一千到兩千萬",
        "三千到五千萬元" to "三千到五千萬元",
        "月薪大概三到五萬" to "月薪大概三到五萬",
        "預算三十到五十萬" to "預算三十到五十萬",
        "股價一到五萬就賣" to "股價一到五萬就賣",
        "價格一到三萬我就買" to "價格一到三萬我就買",
        "一到三萬就通知我" to "一到三萬就通知我",
        "從一到五萬" to "從一到五萬",
        "排名從1到2萬名" to "排名從1到2萬名",
        "一到三千" to "一到三千",
        "兩到三百塊" to "兩到三百塊",
        "一到兩百 ms" to "一到兩百 ms",
        "三到四十 ms" to "三到四十 ms",
        "五到十萬" to "五到十萬",
        "月薪 3 到 5 萬" to "月薪 3 到 5 萬",
        "1.5到2萬" to "1.5到2萬",
        "3～5 萬" to "3～5 萬",
        "等他一到兩百就停" to "等他一到兩百就停",
        "從一到兩百" to "從一到兩百",
        "編號一到五百" to "編號一到五百",
        "一到五百號" to "一到五百號",
    )

    // N5 反面：起點比終點係數大＝各自是完整的數，照舊轉
    private val n5RangesWithoutSharedMagnitudeStillConvert = listOf(
        "預算五千到一萬塊" to "預算5,000到10,000塊",
        "兩千到三萬塊" to "2,000到30,000塊",
        "五萬到十萬" to "50,000到100,000",
        "三十到四十個人" to "三十到40個人",
        "10,000到2萬" to "10,000到20,000",
    )

    // 不可退步：鐘點＋金額
    private val clockPlusAmountKeepsBaseReading = listOf(
        "今晚八點一萬塊" to "今晚八點10,000塊",
        "深夜十一點一萬塊" to "深夜十一點10,000塊",
        "午夜十二點一萬塊" to "午夜十二點10,000塊",
        "這週末三點一萬塊給你" to "這週末三點10,000塊給你",
        "前天三點一萬塊" to "前天三點10,000塊",
        "清晨五點一萬塊" to "清晨五點10,000塊",
        "明早八點一萬塊" to "明早八點10,000塊",
        "三點一萬塊給你" to "三點10,000塊給你",
        "十點一萬塊" to "十點10,000塊",
        "明天三點一萬塊給你" to "明天三點10,000塊給你",
        "今天三點一萬塊交給你" to "今天三點10,000塊交給你",
        "下午三點一萬塊交給你" to "下午三點10,000塊交給你",
        "下午三點五十" to "下午三點五十",
        "下午一點五十到" to "下午一點五十到",
        "三點半開會" to "3:30開會",
        "下午三點開會" to "下午3:00開會",
        "明天三點兩萬塊給你" to "明天三點20,000塊給你",
    )

    // 不可退步：「一點」＝一些；這／那一點；一點五萬＝15,000
    // FX-6 T4（2026-10-23，同 Swift）改了前六條的期望值：「一點一千／一點五千／一點三千」也可以讀成 1,100／1,500／1,300，
    // 兩種讀法＝整段照講的留著（以前寫成「差一點1,000塊」）。
    private val comparativeYiDianKeepsBaseReading = listOf(
        "差一點一千塊" to "差一點一千塊",
        "少一點一千塊" to "少一點一千塊",
        "便宜一點一千塊" to "便宜一點一千塊",
        "貴一點一千塊" to "貴一點一千塊",
        "再便宜一點五千塊就好" to "再便宜一點五千塊就好",
        "便宜一點三千" to "便宜一點三千",
        "再便宜一點五塊就好" to "再便宜一點5塊就好",
        "多一點五塊" to "多一點5塊",
        "貴一點五元" to "貴一點5元",
        "再便宜一點一萬塊就好" to "再便宜一點10,000塊就好",
        "再便宜一點三萬塊就賣你" to "再便宜一點30,000塊就賣你",
        "差一點一萬塊就買了" to "差一點10,000塊就買了",
        "多給一點一萬塊吧" to "多給一點10,000塊吧",
        "有一點一萬塊的差距" to "有一點10,000塊的差距",
        "早一點一萬元也可以" to "早一點10,000元也可以",
        "這一點一萬塊不算什麼" to "這一點10,000塊不算什麼",
        "那一點一萬塊也要" to "那一點10,000塊也要",
        "第一點一萬塊的訂金" to "第一點10,000塊的訂金",
        "一點五萬" to "15,000",
        "還差一點五萬就達標" to "還差15,000就達標",
    )

    // FX-11 E1／E2：小數＋萬／億後面接 塊／元 等單位＝一整個值，跟沒有單位時一樣（以前「一點50,000塊」「兩點50,000塊」）
    private val fx11DecimalWanYiBeforeUnitReadsWhole = listOf(
        "一點五萬塊" to "15,000塊",
        "兩點五萬元" to "25,000元",
        "預算一點五萬塊" to "預算15,000塊",
        "三點五萬塊錢" to "35,000塊錢",
        "我花了兩點五萬塊買的" to "我花了25,000塊買的",
        "這台三點二萬元" to "這台32,000元",
        "這台只有一點零五萬元" to "這台只有10,500元",
        "金額一點零五萬元。不是四點" to "金額10,500元。不是四點",
        "這台只有一點零五萬元。不是四點" to "這台只有10,500元。不是四點",
        "一點零五萬塊。不是四點" to "10,500塊。不是四點",
        "一點〇五萬塊。不是四點" to "10,500塊。不是四點",
        "兩點零五億元。不是四點" to "205,000,000元。不是四點",
        "兩點〇五億元。不是四點" to "205,000,000元。不是四點",
        "這台只有一點零五億元。不是四點" to "這台只有105,000,000元。不是四點",
        "金額一點五萬元。不是四點" to "金額15,000元。不是四點",
        "預算一點五萬元。不是四點" to "預算15,000元。不是四點",
        "價格一點五萬元。不是四點" to "價格15,000元。不是四點",
        "金額是一點五萬元。不是四點" to "金額是15,000元。不是四點",
        "預算為兩點五億元。不是四點" to "預算為250,000,000元。不是四點",
        "價格為三點五萬塊啊，不對，四點" to "價格為35,000塊啊，不對，四點",
        "一點五萬元。船班不是四點" to "15,000元。船班不是四點",
        "這台有一點零五萬元" to "這台有10,500元",
        "這台還有一點零五萬元" to "這台還有10,500元",
        "只有一點五萬塊" to "只有15,000塊",
        "還有一點五萬塊" to "還有15,000塊",
        "金額一點零五萬元。開會不是四點" to "金額10,500元。開會不是四點",
        "金額一點零五萬元！開會不是四點" to "金額10,500元！開會不是四點",
        "金額一點零五萬元？開會不是四點" to "金額10,500元？開會不是四點",
        "金額一點零五萬元\n開會不是四點" to "金額10,500元\n開會不是四點",
        "金額一點零五萬元，開會不是四點" to "金額10,500元，開會不是四點",
        "金額一點零五萬元，開會時間應該是四點" to "金額10,500元，開會時間應該是四點",
        "金額兩點零五萬元，開會不是四點" to "金額20,500元，開會不是四點",
        "金額一點零五萬元；開會不是四點" to "金額10,500元；開會不是四點",
        "金額一點零五萬元。會議不是四點" to "金額10,500元。會議不是四點",
        "金額一點零五萬元。其實開會不是四點" to "金額10,500元。其實開會不是四點",
        "金額一點零五萬元。啊開會不是四點" to "金額10,500元。啊開會不是四點",
        "金額一點零五萬元啊，開會不是四點" to "金額10,500元啊，開會不是四點",
        "金額一點零五萬元，其實開會不是四點" to "金額10,500元，其實開會不是四點",
        "金額一點零五萬元。他不是四點" to "金額10,500元。他不是四點",
        "金額一點零五萬元。她不是四點" to "金額10,500元。她不是四點",
        "金額一點零五萬元；我不是四點" to "金額10,500元；我不是四點",
        "金額一點零五萬元\n會議不是四點" to "金額10,500元\n會議不是四點",
        "一點二萬塊的那台" to "12,000塊的那台",
        "一點五億元" to "150,000,000元",
        "十點五萬元" to "105,000元",
        "一點五萬塊美金" to "15,000塊美金",
        "一點五萬塊左右" to "15,000塊左右",
        "大概一點五萬塊" to "大概15,000塊",
        "一點五萬塊的預算" to "15,000塊的預算",
        "零點五萬塊" to "5,000塊",
        "兩點零五萬塊" to "20,500塊",
        "報價是三點八萬元整" to "報價是38,000元整",
        "總共一點二億元" to "總共120,000,000元",
        "差不多一點二萬塊" to "差不多12,000塊",
        "一點五萬 塊" to "15,000 塊",
        "一點五萬塊，不對，兩萬" to "15,000塊，不對，20,000",
        "明天三點五萬塊要準備好" to "明天35,000塊要準備好",
    )

    // FX-11 不可退步：沒有單位、千／百、小數點後只有「一」、時段／星期／第、比較的「一點」（E3）、改口講整點＝照舊
    private val fx11DecimalWanYiKeepsBaseReading = listOf(
        "一點五萬" to "15,000",
        "兩點零五萬" to "20,500",
        "一點五億" to "150,000,000",
        "一點五萬美金" to "15,000美金",
        "一點五萬多塊" to "15,000多塊",
        "一點五千塊" to "一點五千塊",
        "兩點五千元" to "兩點五千元",
        "一點五百塊" to "一點五百塊",
        "這一點一萬塊不算什麼" to "這一點10,000塊不算什麼",
        "三點一萬塊，不對，四點" to "三點10,000塊，不對，四點",
        "三點五萬塊，不對，四點" to "三點50,000塊，不對，四點",
        "討論金額後三點五萬塊。不是四點" to "討論金額後三點50,000塊。不是四點",
        "價格再便宜一點五萬塊" to "價格再便宜一點50,000塊",
        "金額一點一萬塊，不對，四點" to "金額一點10,000塊，不對，四點",
        "三點五萬塊。不對，四點" to "三點50,000塊。不對，四點",
        "三點五萬塊啊，不對，四點" to "三點50,000塊啊，不對，四點",
        "三點五萬塊 其實不是四點" to "三點50,000塊 其實不是四點",
        "三點五萬塊！不對，四點" to "三點50,000塊！不對，四點",
        "三點五萬塊？不是四點" to "三點50,000塊？不是四點",
        "三點五萬塊；不對，四點" to "三點50,000塊；不對，四點",
        "三點五萬塊\n不對，四點" to "三點50,000塊\n不對，四點",
        "三點五萬塊呀，不對，四點" to "三點50,000塊呀，不對，四點",
        "三點五萬塊喔，不對，四點" to "三點50,000塊喔，不對，四點",
        "三點五萬塊吧，不對，四點" to "三點50,000塊吧，不對，四點",
        "三點五萬塊。其實不是四點" to "三點50,000塊。其實不是四點",
        "三點五萬塊啊，其實不是四點" to "三點50,000塊啊，其實不是四點",
        "三點五萬塊，其实不是四點" to "三點50,000塊，其实不是四點",
        "三點五萬塊。不對啊，四點" to "三點50,000塊。不對啊，四點",
        "有一點一萬塊的差距" to "有一點10,000塊的差距",
        "三點五萬塊，不是四點" to "三點50,000塊，不是四點",
        "三點五萬塊不對四點" to "三點50,000塊不對四點",
        "三點五萬塊，我是說四點" to "三點50,000塊，我是說四點",
        "三點五萬塊，應該是四點" to "三點50,000塊，應該是四點",
        "三點五萬塊，不對，4:00" to "三點50,000塊，不對，4:00",
        "三點五萬 塊，不對，四點" to "三點50,000 塊，不對，四點",
        "三點五萬圓，不對，四點" to "三點50,000圓，不對，四點",
        "三點五萬 dollars，不對，四點" to "三點50,000 dollars，不對，四點",
        "三點五萬塊錢，不對，四點" to "三點50,000塊錢，不對，四點",
        "三點，五萬塊帶來" to "三點，50,000塊帶來",
        "我三點要付五萬塊" to "我三點要付50,000塊",
        "下午三點五萬塊的貨到" to "下午三點50,000塊的貨到",
        "禮拜三點五萬塊" to "禮拜三點50,000塊",
        "第一點五萬塊" to "第一點50,000塊",
        "還差一點五萬塊" to "還差一點50,000塊",
        "再便宜一點五萬塊就好" to "再便宜一點50,000塊就好",
        "多一點五萬塊" to "多一點50,000塊",
        "這一點五萬塊" to "這一點50,000塊",
        "那一點二萬元" to "那一點20,000元",
        "一兩點二萬塊" to "一兩點20,000塊",
        "三四點三萬元" to "三四點30,000元",
    )

    // FX-11 E4：「第N」的數字不併進鐘點（以前「第13:00開會」）；「第二十點」照舊是 20 點
    private val fx11OrdinalDigitStaysWithDi = listOf(
        "第一三點開會" to "第一3:00開會",
        "第二四點出發" to "第二4:00出發",
        "第三五點半集合" to "第三5:30集合",
        "第一，三點開會" to "第一，3:00開會",
        "第一是三點開會" to "第一是3:00開會",
        "第二十點開會" to "第20:00開會",
    )

    @Test fun n1VagueAndBareMagnitudesStayAsSpoken() = check(n1VagueAndBareMagnitudesStayAsSpoken)
    @Test fun n1ExactAmountsStillConvert() = check(n1ExactAmountsStillConvert)
    @Test fun n2ArabicDecimalWithMagnitude() = check(n2ArabicDecimalWithMagnitude)
    @Test fun n3WeekdayNeverMergesWithFollowingNumber() = check(n3WeekdayNeverMergesWithFollowingNumber)
    @Test fun n4AbbreviatedThousands() = check(n4AbbreviatedThousands)
    @Test fun n5SharedMagnitudeRangesAreNotHalfRead() = check(n5SharedMagnitudeRangesAreNotHalfRead)
    @Test fun n5RangesWithoutSharedMagnitudeStillConvert() = check(n5RangesWithoutSharedMagnitudeStillConvert)
    @Test fun clockPlusAmountKeepsBaseReading() = check(clockPlusAmountKeepsBaseReading)
    @Test fun comparativeYiDianKeepsBaseReading() = check(comparativeYiDianKeepsBaseReading)
    @Test fun fx11DecimalWanYiBeforeUnitReadsWhole() = check(fx11DecimalWanYiBeforeUnitReadsWhole)
    @Test fun fx11DecimalWanYiKeepsBaseReading() = check(fx11DecimalWanYiKeepsBaseReading)
    @Test fun fx11OrdinalDigitStaysWithDi() = check(fx11OrdinalDigitStaysWithDi)

    /** 閘門兩邊都跑 normalizeNumbers：已經正規化過的文字再跑一次不能再變。 */
    @Test fun normalizingTwiceChangesNothing() {
        // 「每週十一點半二萬就好」的例外已拿掉：FX-6 T3 修好 decimalTimes 把「11:30二萬」讀成「11:32萬」（同 Swift）。
        (n1VagueAndBareMagnitudesStayAsSpoken + n1ExactAmountsStillConvert + n2ArabicDecimalWithMagnitude + n3WeekdayNeverMergesWithFollowingNumber + n4AbbreviatedThousands + n5SharedMagnitudeRangesAreNotHalfRead + n5RangesWithoutSharedMagnitudeStillConvert + clockPlusAmountKeepsBaseReading + comparativeYiDianKeepsBaseReading +
            fx11DecimalWanYiBeforeUnitReadsWhole + fx11DecimalWanYiKeepsBaseReading + fx11OrdinalDigitStaysWithDi).forEach { (input, _) ->
            val once = Normalizer.normalizeNumbers(input)
            assertEquals(once, Normalizer.normalizeNumbers(once), input)
        }
    }
}
