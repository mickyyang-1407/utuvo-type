package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * 2026-10-22 Typeless 對打（cleanup-format／cleanup-semantics）：數字、單位、金額、標點、電話的 deterministic 規則。
 * 與 Swift Tests/UTUVOTypeCoreTests/FormatRulesTests.swift 案例逐字相同；行為以 Swift 為準。
 */
class FormatRulesTest {
    private fun numbers(cases: List<Pair<String, String>>) =
        cases.forEach { (input, expected) -> assertEquals(expected, Normalizer.normalizeNumbers(input), input) }

    private fun numbersUnchanged(inputs: List<String>) =
        inputs.forEach { assertEquals(it, Normalizer.normalizeNumbers(it), it) }

    // cleanup-format-1(a)：阿拉伯數字＋萬／億 → 完整數值

    @Test fun arabicWanYiBecomesFullValue() = numbers(listOf(
        "30萬" to "300,000",
        "10萬5" to "105,000",
        "1.5萬" to "15,000",
        "10萬5000" to "105,000",
        "30 萬" to "300,000",
        "3萬2千" to "32,000",
        "30萬元" to "300,000元",
        "10萬5 塊" to "105,000 塊",
        "3億" to "300,000,000",
        "2億5" to "250,000,000",
        "3億5000萬" to "350,000,000",
        "預算是30萬，第二期先付10萬5" to "預算是300,000，第二期先付105,000",
    ))

    @Test fun arabicWanYiLeavesOtherShapesAlone() {
        numbersUnchanged(listOf(
            "三樓", "3:30", "1. 播放器", "千萬不要", "3萬五千", "存了3萬一直沒用", "3億5000", "3億2千萬",
            "1,000萬", "10萬5.5", "1.55555萬", "10萬5,000", "30萬 2026年",
        ))
        val spaced = Normalizer.normalizeNumbers("先付 10 萬 5000 塊")
        assertFalse(spaced.contains("100,000") || spaced.contains("105,000,000"), spaced)
    }

    @Test fun arabicWanYiAgreesWithChineseNumerals() {
        assertEquals(Normalizer.normalizeNumbers("三十萬"), Normalizer.normalizeNumbers("30 萬"))
        assertEquals(Normalizer.normalizeNumbers("一點五萬"), Normalizer.normalizeNumbers("1.5萬"))
        assertEquals(Normalizer.normalizeNumbers("一點五萬"), Normalizer.normalizeNumbers(Normalizer.normalizeNumbers("一點五萬")))
    }

    // cleanup-format-2：中文數字＋技術單位、負數

    @Test fun chineseNumeralsBeforeTechnicalUnits() = numbers(listOf(
        "九十六 kHz" to "96 kHz",
        "九十六kHz" to "96kHz",
        "二十四 bit" to "24 bit",
        "負十四 LUFS" to "-14 LUFS",
        "九十六K" to "96K",
        "四十八點一 kHz" to "48.1 kHz",
        "負一 dBTP" to "-1 dBTP",
        "三百二十 kbps" to "320 kbps",
        "AIFC，二十四bit，離散的九十六kHz" to "AIFC，24bit，離散的96kHz",
        "響度對齊到負十四 LUFS" to "響度對齊到-14 LUFS",
    ))

    @Test fun technicalUnitRuleLeavesWordsAlone() = numbersUnchanged(listOf(
        "三樓", "一小時", "三件事", "第二個部分", "九十六", "K 歌", "唯一 K", "統一 dB", "之一 ms",
        "九十六\nK", "負責九十六", "十五 Kelvin",
    ))

    // cleanup-format-6：金額與 塊／元 之間有空白

    @Test fun moneyWithSpaceBeforeUnitGetsSeparator() = numbers(listOf(
        "1250 塊" to "1,250 塊",
        "1250塊" to "1,250塊",
        "12000 元" to "12,000 元",
        "總共是1250 塊" to "總共是1,250 塊",
        "1250 元" to "1,250 元",
    ))

    @Test fun moneyRuleDoesNotCrossLinesOrTouchOtherNumbers() =
        numbersUnchanged(listOf("2026 年", "第 1250 號", "3 塊錢", "1250\n塊", "清單 1250\n元件"))

    // cleanup-format-v1：英文字／數字後面的半形 , ; ! ? 在中文裡轉全形

    @Test fun halfWidthPunctuationAfterLatinInsideChinese() = listOf(
        "Utuvo Type,在手機" to "Utuvo Type，在手機",
        "2比1,不要" to "2比1，不要",
        "重開一個Session?" to "重開一個Session？",
        "Tim,大家好" to "Tim，大家好",
        "OK!我們走" to "OK！我們走",
        "用 Pro Tools ; 不要用 Logic" to "用 Pro Tools；不要用 Logic",
        "Utuvo Type, 在手機" to "Utuvo Type，在手機",
        "響度對齊到 -14 LUFS,\n第二個問題" to "響度對齊到 -14 LUFS，\n第二個問題",
        "你有用 Atmos 嗎 OK?" to "你有用 Atmos 嗎 OK？",
    ).forEach { (input, expected) -> assertEquals(expected, Normalizer.normalizePunctuation(input), input) }

    @Test fun halfWidthPunctuationLeftAloneOutsideChinese() = listOf(
        "1,250塊", "v0.2.1", "3:30", "2:1", "Hello, world", "Are you OK?", "Hello, world\n你好",
        "版本 v0.2.1 已上線", "時間 3:30 見", "比例 2:1 就好", "Hi,\n你好",
    ).forEach { assertEquals(it, Normalizer.normalizePunctuation(it), it) }

    // cleanup-format-v2：台灣電話號碼

    @Test fun taiwanPhoneNumbersAreFormatted() = numbers(listOf(
        "0912345678" to "0912-345-678",
        "零九一二三四五六七八" to "0912-345-678",
        "0912-345678" to "0912-345-678",
        "0912 345 678" to "0912-345-678",
        "0223333333" to "02-2333-3333",
        "02-23333333" to "02-2333-3333",
        "我的電話是0912345678，市話0223333333" to "我的電話是0912-345-678，市話02-2333-3333",
    ))

    @Test fun otherDigitRunsAreNotPhoneNumbers() =
        numbersUnchanged(listOf("09123456789", "20260913", "1,250", "3:30", "0312345678", "A0912345678", "3.0912345678"))

    @Test fun strictGateAcceptsFormattedPhone() {
        assertNull(CleanupFidelity.rejectionReason("我的電話是0912345678", "我的電話是 0912-345-678"))
        assertNull(CleanupFidelity.rejectionReason("我的電話是零九一二三四五六七八", "我的電話是 0912-345-678"))
        assertNull(CleanupFidelity.rejectionReason("電話0912-345678", "電話 0912-345-678"))
        assertNull(CleanupFidelity.rejectionReason("市話02-23333333", "市話 02-2333-3333"))
        assertNotNull(CleanupFidelity.rejectionReason("我的電話是0912345678", "我的電話是 0912-345-679"))
    }

    // cleanup-semantics-2：改口裡的 萬／億 數字

    @Test fun correctionWithWanKeepsSingleAmount() {
        assertEquals("金額是一萬兩千塊。", Normalizer.applySelfCorrection("金額是一萬二，不對，是一萬兩千塊。"))
        assertEquals("金額是12,000塊。", Normalizer().normalize("金額是一萬二，不對，是一萬兩千塊。").cleaned)
        assertEquals("金額是15,000", Normalizer().normalize("金額是一萬二，不對，一萬五").cleaned)
        assertEquals("四億", Normalizer.applySelfCorrection("三億，不對，四億"))
        assertEquals("一億五", Normalizer.applySelfCorrection("一億二，不對，一億五"))
    }

    @Test fun correctionWithoutWanUnchanged() {
        assertEquals("一千五", Normalizer.applySelfCorrection("一千二，不對，一千五"))
        assertEquals("三十五萬", Normalizer.applySelfCorrection("三十萬，不對，三十五萬"))
        assertEquals("三萬", Normalizer.applySelfCorrection("兩萬，不對，三萬"))
        assertEquals("金額是12000塊。", Normalizer.applySelfCorrection("金額是12000,不對,是12000塊。"))
        assertEquals("我覺得一萬塊不對", Normalizer.applySelfCorrection("我覺得一萬塊不對"))
    }
}
