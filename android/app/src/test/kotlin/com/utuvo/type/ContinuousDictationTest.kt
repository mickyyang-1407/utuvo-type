package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Test

class ContinuousDictationTest {
    private var clock = 0L
    private fun session() = ContinuousDictation(maxSilenceMillis = 60_000, now = { clock })

    @Test fun pauseDoesNotEndTheDictation() {
        val s = session()
        // 講一句、停頓（系統送出這一段）→ 還沒按停：要繼續聽，不是結束。
        assertEquals(ContinuousDictation.Next.RESTART, s.onSegment("我明天下午"))
        clock += 2_000
        assertEquals(ContinuousDictation.Next.RESTART, s.onSilence())   // 停頓那段沒聽到字
        assertEquals(ContinuousDictation.Next.RESTART, s.onSegment("要去錄音室"))
        s.requestStop()
        assertEquals(ContinuousDictation.Next.FINISH, s.onSegment("對母帶。"))
        assertEquals("我明天下午要去錄音室對母帶。", s.finish())
    }

    @Test fun stopWithLastSegmentInFinish() {
        val s = session()
        s.onSegment("第一段，")
        s.requestStop()
        assertEquals("第一段，第二段。", s.finish("第二段。"))
    }

    @Test fun previewShowsEarlierSegmentsPlusPartial() {
        val s = session()
        s.onSegment("今天天氣很好，")
        assertEquals("今天天氣很好，我們去", s.preview("我們去"))
        assertEquals("今天天氣很好，", s.preview())
    }

    @Test fun latinSegmentsGetASpace() {
        assertEquals("send it to John tomorrow", ContinuousDictation.join(listOf("send it to John", "tomorrow")))
        assertEquals("Atmos母帶", ContinuousDictation.join(listOf("Atmos", "母帶")))
        assertEquals("混音OK", ContinuousDictation.join(listOf("混音", "OK")))
        assertEquals("Hi. How", ContinuousDictation.join(listOf("Hi.", "How")))
        assertEquals("好。下一句", ContinuousDictation.join(listOf("好。", "下一句")))
    }

    @Test fun longSilenceFinishesOnItsOwn() {
        val s = session()
        s.onSegment("剛剛講完")
        clock += 59_000
        assertEquals(ContinuousDictation.Next.RESTART, s.onSilence())
        clock += 2_000
        assertEquals(ContinuousDictation.Next.FINISH, s.onSilence())
        assertEquals("剛剛講完", s.finish())
    }

    /** 模擬器實錄的順序：停頓後即時結果歸零、最終結果空白 → 兩句都要留下（以前只剩第二句）。 */
    @Test fun partialResetAfterPauseKeepsTheEarlierSentence() {
        val s = session()
        for (p in listOf("", "I", "I will go to the studio", "I will go to the studio tomorrow afternoon", "", "", " remember", " remember to bring the headphones"))
            s.partial(p)
        assertEquals("I will go to the studio tomorrow afternoon remember to bring the headphones", s.preview(" remember to bring the headphones"))
        val seg = s.segmentText("")
        assertEquals("I will go to the studio tomorrow afternoon remember to bring the headphones", seg)
        s.requestStop()
        s.onSegment(seg)
        assertEquals(seg, s.finish())
    }

    /** 最終結果本身已經是完整兩句：不能再接一次（不重複）。 */
    @Test fun fullFinalResultIsNotDoubled() {
        val s = session()
        for (p in listOf("我明天下午", "我明天下午要去錄音室", "", "記得帶耳機")) s.partial(p)
        assertEquals("我明天下午要去錄音室記得帶耳機", s.segmentText("我明天下午要去錄音室記得帶耳機"))
        // 最終結果只有後半句：補上前半句。
        for (p in listOf("今天", "今天很熱", "", "要喝水")) s.partial(p)
        assertEquals("今天很熱要喝水", s.segmentText("要喝水"))
    }

    /** 沒有送空的即時結果、直接跳到下一句：一樣要收起前一句。即時改字（開頭相同）不算換句。 */
    @Test fun jumpToShorterNextSentenceWithoutEmptyPartial() {
        val s = session()
        for (p in listOf("我明天下午", "我明天下午要去錄音室", "記得", "記得帶耳機")) s.partial(p)
        assertEquals("我明天下午要去錄音室記得帶耳機", s.segmentText(""))
        for (p in listOf("I will go to the", "I'll go to the studio")) s.partial(p)
        assertEquals("I'll go to the studio", s.segmentText(""))
    }

    /** 最終結果把前一句改了字：不能再把舊的前句接一次（重複貼上）。 */
    @Test fun finalWithCorrectedEarlierSentenceIsNotDoubled() {
        val s = session()
        for (p in listOf("我要去錄音事", "", "記得帶耳機")) s.partial(p)
        assertEquals("我要去錄音室記得帶耳機", s.segmentText("我要去錄音室記得帶耳機"))
    }

    @Test fun nothingSaidAndStopped() {
        val s = session()
        s.requestStop()
        assertEquals(ContinuousDictation.Next.FINISH, s.onSilence())
        assertEquals("", s.finish())
    }
}
