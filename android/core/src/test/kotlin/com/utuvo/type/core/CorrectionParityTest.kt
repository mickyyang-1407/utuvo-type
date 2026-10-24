package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

class CorrectionParityTest {
    // Keep these input/output pairs byte-for-byte aligned with Swift's CorrectionParityTests.
    private val corrections = listOf(
        "我們約3點開會,不對,4點,地點在3樓" to "我們約4點開會,地點在3樓",
        "取樣率用48K,不對,是96K。" to "取樣率用96K。",
        "檔名叫做Final V3,啊不對,是Final V4。" to "檔名叫做Final V4。",
        "金額是12000,不對,是12000塊。" to "金額是12000塊。",
        "幫我轉寄給小雅跟小博,不是,是小雅跟小潘。" to "幫我轉寄給小雅跟小潘。",
        "這次上課的教室改成四樓" to "這次上課的教室改成四樓",
        "請參考第3章,不對,是第4章。" to "請參考第4章。",
        "版本為final_v3,不對,是final_v4。" to "版本為final_v4。",
        "會議排在星期三,不對,星期四。" to "會議排在星期四。",
        "會議排在禮拜三,不對,禮拜四。" to "會議排在禮拜四。",
        "約星期三，不對，下個星期四" to "約下個星期四",
        "約3點開會,不對,4點\r\n在3樓" to "約4點開會\r\n在3樓",
        "我是剛上去，喔不對，剛出門要搭937。" to "我是剛出門要搭937。",
        "會議原訂3點,不對,就是4點。" to "會議原訂4點。",
        "明天三點半開會不是三點是四點" to "明天三點半開會四點",
        "明天不是週一，是週二開會" to "明天週二開會",
        "今天開會,不對,明天早上開會。" to "明天早上開會。",
        "我們約3點開會在家,不對,4點在公司。" to "我們約3點開會在家,不對,4點在公司。",
        "我不是生氣，是累了" to "我是累了",
        "這不是我的，是他的" to "這是他的",
    )

    // Ordinary uses and near-matches must survive deterministic correction unchanged.
    private val counterexamples = listOf(
        "我覺得不對" to "我覺得不對",
        "這不是我的" to "這不是我的",
        "這不是我的，是不是你的" to "這不是我的，是不是你的",
        "他去台南玩，不對，南投下雨。" to "他去台南玩，不對，南投下雨。",
        "是不是要改成四點" to "是不是要改成四點",
        "應該是明天吧" to "應該是明天吧",
        "不對稱" to "不對稱",
        "不是嗎？" to "不是嗎？",
        "不是星期四而是星期三" to "不是星期四而是星期三",
        "教室改成四樓" to "教室改成四樓",
        "我想問是不是要改成四點" to "我想問是不是要改成四點",
        "我覺得這件事不對勁" to "我覺得這件事不對勁",
        "這不是我說的" to "這不是我說的",
        "是不是應該是明天" to "是不是應該是明天",
        "應該是可以" to "應該是可以",
        "他說的不是嗎？" to "他說的不是嗎？",
        "這個不對稱設計很有趣" to "這個不對稱設計很有趣",
        "我不是說你錯" to "我不是說你錯",
        "剛才那樣不對勁" to "剛才那樣不對勁",
        "你是不是要改成四點" to "你是不是要改成四點",
        "明天應該是星期三" to "明天應該是星期三",
        "不是這樣嗎" to "不是這樣嗎",
        "改成中文版本" to "改成中文版本",
    )

    @Test
    fun correctionCases() {
        corrections.forEach { (input, expected) ->
            assertEquals(expected, Normalizer.applySelfCorrection(input), input)
        }
    }

    @Test
    fun normalizerPreservesNotIsCorrectionThroughRepeatStage() {
        val input = "幫我轉寄給小雅跟小博,不是,是小雅跟小潘。"
        assertEquals("幫我轉寄給小雅跟小潘。", Normalizer().normalize(input).cleaned)
    }

    @Test
    fun ordinaryPhrasesRemainUntouched() {
        counterexamples.forEach { (input, expected) ->
            assertEquals(expected, Normalizer.applySelfCorrection(input), input)
        }
    }
}
