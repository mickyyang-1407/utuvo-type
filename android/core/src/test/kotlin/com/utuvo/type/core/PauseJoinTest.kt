package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** 與 iOS `ChunkedASRTests.testPauseMark*` 同一組案例。 */
class PauseJoinTest {
    @Test fun longClauseAtPauseGetsComma() {
        assertEquals("，", PauseJoin.mark("今天天氣很好", "我們去公園"))
        assertEquals("，", PauseJoin.mark("我明天下午要去錄音室", "記得帶耳機"))
        // 前面已經有標點：只算最後一小句。
        assertEquals("，", PauseJoin.mark("好，那我們下午三點開會", "記得帶筆電"))
    }

    @Test fun neverAPeriod() {
        assertEquals("，", PauseJoin.mark("這個混音的低頻還要再收一點", "高頻要平衡一下"))
    }

    @Test fun shortClauseIsHesitation() {
        assertEquals("", PauseJoin.mark("今天天氣", "明天出門"))
        assertEquals("", PauseJoin.mark("我明天下午", "要去錄音室"))
        assertEquals("", PauseJoin.mark("好，今天很熱", "要喝水"))
    }

    @Test fun danglingEndingMeansMoreIsComing() {
        assertEquals("", PauseJoin.mark("我們下午要搭捷運到", "中正紀念堂"))
        assertEquals("", PauseJoin.mark("我覺得這是一個很好的", "機會"))
        assertEquals("", PauseJoin.mark("這個方案我覺得可能還要再", "想一下"))
    }

    /** 2026-11-02 審查：同一個數字講到一半停頓，不能拆成「三百，五十萬元」。 */
    @Test fun numberSplitAcrossPauseStaysWhole() {
        assertEquals("", PauseJoin.mark("這次預算總共三百", "五十萬元"))
        assertEquals("", PauseJoin.mark("這張專輯要付三百五十", "元"))
        assertEquals("", PauseJoin.mark("我們約明天下午三點", "半在錄音室"))
        // 數字講完、下一段是別的話：照常補。
        assertEquals("，", PauseJoin.mark("我們這次的預算是三百萬", "記得先跟老闆確認"))
        // 第二輪審查：「一點」＝一些、「公司」「一起」不是數字的後半。
        assertEquals("，", PauseJoin.mark("我今天會晚一點", "公司還有事情要處理"))
        assertEquals("，", PauseJoin.mark("這次預算是三百萬", "公司下週付款"))
        assertEquals("，", PauseJoin.mark("這次預算是三百萬", "一起去吃飯慶祝"))
        assertEquals("", PauseJoin.mark("這次預算總共三百萬", "一千元要另外算"))
    }

    @Test fun leadingParticleBelongsToPreviousClause() {
        assertEquals("", PauseJoin.mark("我已經把檔案寄給你", "了今天"))
        assertEquals("", PauseJoin.mark("那我們明天早上再討論", "吧"))
    }

    @Test fun punctuationOrLatinAtTheBoundary() {
        assertEquals("", PauseJoin.mark("今天天氣很好。", "我們去公園"))
        assertEquals("", PauseJoin.mark("今天天氣很好", "。我們去公園"))
        assertEquals("", PauseJoin.mark("我們今天要討論的是Atmos", "母帶"))
        assertEquals("", PauseJoin.mark("今天要把母帶交給客戶", "OK"))
        assertEquals("", PauseJoin.mark("send it to John", "tomorrow"))
        assertEquals("", PauseJoin.mark("", "今天天氣很好"))
        assertEquals("", PauseJoin.mark("今天天氣很好", ""))
    }

    @Test fun latinWordsCountAsOneEach() {
        assertEquals(3, PauseJoin.clauseLength("交 ADM 檔"))
        assertEquals(6, PauseJoin.clauseLength("今天天氣很好"))
        assertEquals("，", PauseJoin.mark("這次 Dolby Atmos 母帶做完了", "下週交"))
    }
}
