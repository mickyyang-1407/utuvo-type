package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmartCleanupFidelityTest {
    @Test
    fun rejectsMeaningChangesAndAllowsFormattingCleanup() {
        assertFalse(SmartCleanup.accepts("然後送到清風教室去示範", "之後送往清風教室進行示範"))
        assertFalse(SmartCleanup.accepts("教室改成四樓，另外教材我會帶過去", "教室四樓，教材我會帶過去"))
        assertFalse(SmartCleanup.accepts("明天先確認大家收到資料再開會", "明天開會前，先確認大家是否都已收到資料。"))
        assertTrue(SmartCleanup.accepts("明天先確認大家收到資料再開會", "明天先確認大家收到資料，再開會。"))
        assertTrue(SmartCleanup.accepts("我想明天，不對，後天寄", "我想後天寄。"))
    }

    @Test
    fun acceptsOptionalFillerRemovalWithoutDroppingMeaningfulConnectors() {
        val source = "嗯,我覺得那個,就是,這個 low-end 還可以再收一點。"
        assertTrue(SmartCleanup.accepts(source, source))
        assertTrue(SmartCleanup.accepts(source, "我覺得這個 low-end 還可以再收一點。"))
        assertFalse(SmartCleanup.accepts("做完然後寄給他", "做完寄給他"))
    }

    @Test
    fun promptCandidateV2ProbeOutputsPassTheFullAndroidGate() {
        val cases = listOf(
            "嗯,我覺得那個,就是,這個low-end還可以再收一點。" to "我覺得這個 low-end 還可以再收一點。",
            "然後然後,呃,高頻好像有點毛,你再聽一下。" to "高頻好像有點毛，你再聽一下。",
            "嗯嗯,然後就是說,我這邊沒有收到你的檔案。" to "我這邊沒有收到你的檔案。",
            "我們約3點開會,不對,4點,地點在3樓" to "我們約4點開會，地點在3樓。",
            "黨名叫做Final V3,啊不對,是Final V4。" to "黨名叫做Final V4。",
            "幫我轉寄給小雅跟小博,不是,是小雅跟小潘。" to "幫我轉寄給小雅跟小潘。",
            "接下來有三件事,第一是把Low-End收乾淨,第二是把Delay收短,第三是重做母帶" to
                "接下來有三件事：\n1. 把 Low-End 收乾淨\n2. 把 Delay 收短\n3. 重做母帶",
            "今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明" to
                "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明",
            "那個Compressor的Ratio我建議設成2比1,不要讓它Pump。" to "Compressor的Ratio我建議設成2比1，不要讓它Pump。",
            "王老師好,這次上課的教室改成四樓,另外教材我會帶過去。" to
                "王老師好，這次上課的教室改成四樓，另外教材我會帶過去。"
        )

        cases.forEachIndexed { index, (source, output) ->
            assertTrue("Probe case ${index + 1} was rejected", SmartCleanup.accepts(source, output))
        }
    }

    @Test
    fun q2OverEditsRemainRejectedByTheFullAndroidGate() {
        assertFalse(SmartCleanup.accepts("是不是該把主唱推到前面一點？", "該把主唱推到前面一點嗎？"))
        assertFalse(SmartCleanup.accepts("上面做的", "上做"))
        assertFalse(SmartCleanup.accepts("地點在3樓", "地點在三樓"))
        assertFalse(SmartCleanup.accepts("教室改成四樓", "教室四樓"))
        listOf("另外", "對了", "總之").forEach { transition ->
            assertFalse(SmartCleanup.accepts(
                "清單：先確認檔案，${transition}備份資料",
                "清單：\n1. 先確認檔案\n2. 備份資料"
            ))
        }
    }

    @Test
    fun q2ListProbeCasesPassTheFullAndroidGate() {
        val s17 = "今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明"
        assertTrue(SmartCleanup.accepts(
            s17,
            "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ))
        assertTrue(SmartCleanup.accepts(
            s17,
            "今天的工作清單：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ))
        assertTrue(SmartCleanup.accepts(
            "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。",
            "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭"
        ))
    }

    @Test
    fun timeoutUsesFourSecondsForShortTextAndCapsAtTen() {
        assertEquals(4_000L, SmartCleanup.timeoutMsFor("短".repeat(16)))
        assertEquals(10_000L, SmartCleanup.timeoutMsFor("長".repeat(56)))
        assertEquals(10_000L, SmartCleanup.timeoutMsFor("長".repeat(100)))
    }
}
