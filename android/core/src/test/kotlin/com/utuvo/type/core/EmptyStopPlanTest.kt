package com.utuvo.type.core

import com.utuvo.type.core.EmptyStopPlan.Action
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * mobile-keyboard-v2：系統辨識回空結果時的收尾。
 * 以前不分情況一律丟掉雲端錄音、提示回到待機（使用者按停後講的話整段不見、沒有回饋）。
 */
class EmptyStopPlanTest {

    @Test
    fun `按停而且有雲端錄音就送雲端救`() {
        assertEquals(Action.RESCUE, EmptyStopPlan.decide(stopRequested = true, hasCloudSamples = true, translating = false))
    }

    @Test
    fun `60 秒自動收尾不把一分鐘的靜音送上雲端`() {
        assertEquals(Action.DROP, EmptyStopPlan.decide(stopRequested = false, hasCloudSamples = true, translating = false))
    }

    @Test
    fun `翻譯中不送雲端重辨識`() {
        assertEquals(Action.DROP, EmptyStopPlan.decide(stopRequested = true, hasCloudSamples = true, translating = true))
    }

    @Test
    fun `沒有雲端錄音就沒有東西可救`() {
        assertEquals(Action.DROP, EmptyStopPlan.decide(stopRequested = true, hasCloudSamples = false, translating = false))
        assertEquals(Action.DROP, EmptyStopPlan.decide(stopRequested = false, hasCloudSamples = false, translating = false))
        assertEquals(Action.DROP, EmptyStopPlan.decide(stopRequested = false, hasCloudSamples = false, translating = true))
    }
}
