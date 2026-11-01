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
