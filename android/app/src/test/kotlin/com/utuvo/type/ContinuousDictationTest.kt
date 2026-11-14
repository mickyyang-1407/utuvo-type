package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
        // 「我明天下午」只有 5 個字＝遲疑，不補；接上「要去錄音室」夠長了，停頓補「，」（2026-11-01 PauseJoin）。
        assertEquals("我明天下午要去錄音室，對母帶。", s.finish())
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
        assertEquals("我明天下午要去錄音室，記得帶耳機", s.segmentText(""))
        for (p in listOf("I will go to the", "I'll go to the studio")) s.partial(p)
        assertEquals("I'll go to the studio", s.segmentText(""))
        // 開頭掉一個字的改寫（更短、開頭不同）：舊版整句已涵蓋，不重複。
        for (p in listOf("我明天下午要去錄音室", "明天下午要去錄音室")) s.partial(p)
        assertEquals("我明天下午要去錄音室", s.segmentText(""))
        // 下一句只比前一句短一點點（沒短到一半）也要收起前一句，不能丟。
        for (p in listOf("今天的混音先做到這裡", "明天再來對母帶")) s.partial(p)
        assertEquals("今天的混音先做到這裡，明天再來對母帶", s.segmentText(""))
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

    /** 長句講很多段（2026-11-01 回報：七、八十字以上整段沒有標點）：停頓處補逗號，不補句號、遲疑不補。 */
    @Test fun longDictationKeepsPauseCommas() {
        val s = session()
        for (seg in listOf("今天下午我們先把這首歌的混音做完", "低頻的部分還要再", "收一點", "然後明天早上", "再跟客戶確認母帶的版本"))
            s.onSegment(seg)
        s.requestStop()
        assertEquals("今天下午我們先把這首歌的混音做完，低頻的部分還要再收一點，然後明天早上，再跟客戶確認母帶的版本",
            s.finish())
    }

    @Test fun chineseSegmentsJoinWithPauseRule() {
        assertEquals("今天天氣很好，我們去公園", ContinuousDictation.join(listOf("今天天氣很好", "我們去公園")))
        assertEquals("今天天氣明天出門", ContinuousDictation.join(listOf("今天天氣", "明天出門")))
        assertEquals("我們下午要搭捷運到中正紀念堂", ContinuousDictation.join(listOf("我們下午要搭捷運到", "中正紀念堂")))
    }

    /** 2026-11-01 Pixel 回報（結構照原句、文字改寫）：辨識器每次重開／換句都把前一句後半段再聽一次、還改幾個字 → 同一段話出現三次。 */
    private val A = "我想先把母帶放到Google Drive或者甚至是一個網站嗎就是除了這個每週的錄音以外我想要做一個頁面嗎"
    private val B = "就是除了這個每週的錄音以外我想要做一個可以讓學生看的頁面嗎"
    private val C = "就是除了這個每週的錄音以外我想要做一個可以讓學生看的每週回顧的頁面或是怎麼做一個完整的一個混音課程的整理你覺得這樣子"
    private val D = "完整的一個混音課程的整理你覺得這樣子要怎麼開始？"
    // 段落邊界是停頓：main 的停頓逗號規則（PauseJoin，2026-11-01）會在「網站嗎」後面補「，」。
    private val ABCD = "我想先把母帶放到Google Drive或者甚至是一個網站嗎，" +
        "就是除了這個每週的錄音以外我想要做一個可以讓學生看的每週回顧的頁面或是怎麼做一個完整的一個混音課程的整理你覺得這樣子要怎麼開始？"

    @Test fun reheardTailAcrossSegmentsIsNotRepeated() {
        val s = session()
        for (seg in listOf(A, B, C)) assertEquals(ContinuousDictation.Next.RESTART, s.onSegment(seg))
        s.requestStop()
        s.onSegment(D)
        assertEquals(ABCD, s.finish())
    }

    @Test fun reheardTailWithinOneRunIsNotRepeated() {
        val s = session()
        // 同一次辨識裡即時結果跳到較短、開頭不同的句子（＝換句），但其實是重聽前一句後半段。
        for (p in listOf(A.take(20), A, B, C.take(30), C, D.take(5), D)) s.partial(p)
        assertEquals(ABCD, s.preview(D))
        assertEquals(ABCD, s.segmentText(""))
    }

    @Test fun overlapMergeLeavesRealRepeatsAlone() {
        // 短的重複是真的講了兩次：不能吃掉。
        assertEquals("好好", ContinuousDictation.join(listOf("好", "好")))
        assertEquals("對對對，對對對", ContinuousDictation.join(listOf("對對對，", "對對對")))
        // 沒重疊照常接。
        assertEquals("我明天下午要去錄音室，對母帶", ContinuousDictation.join(listOf("我明天下午", "要去錄音室", "對母帶")))
        // 英文只認整字對齊："hearsal" 不是 "rehearsal" 的重聽。
        assertEquals("the rehearsal tomorrow hearsal notes", ContinuousDictation.join(listOf("the rehearsal tomorrow", "hearsal notes")))
        // 英文重聽：從重疊處接、用較新的版本。
        assertEquals("send the mix to John tomorrow morning please",
            ContinuousDictation.join(listOf("send the mix to John tomorrow", "to John tomorrow morning please")))
        // Pixel 歷史裡另一種形狀：同一句越聽越長、每一版都被接上（「A／A＋幾個字／A＋更多」）。
        assertEquals("我的意思是這個插件有很多種用法所以不用擔心",
            ContinuousDictation.join(listOf("我的意思是這個", "我的意思是這個插件有很多", "我的意思是這個插件有很多種用法", "我的意思是這個插件有很多種用法所以不用擔心")))
        // 開頭剛好 6 字的重聽也要接上。
        assertEquals("那因為我還有五套不同的軟體", ContinuousDictation.join(listOf("那因為我還有", "那因為我還有五套不同的軟體")))
        // 新段整句已經在前文結尾：跳過。
        assertEquals("今天天氣很好我們去公園散步", ContinuousDictation.join(listOf("今天天氣很好我們去公園散步", "我們去公園散步")))
    }

    /** 停頓逗號（PauseJoin）＋重聽合併同時發生：重聽的那一段跨過我們剛補的「，」也要認得出來，不能整段再接一次。 */
    @Test fun reheardTailSpanningAnInsertedPauseCommaIsNotRepeated() {
        val joined = ContinuousDictation.join(listOf("我想先把母帶放到雲端或者做一個網站嗎", "就是除了每週的錄音以外", "網站嗎就是除了每週的錄音以外我還想做一個頁面"))
        assertEquals(1, Regex("每週的錄音以外").findAll(joined).count())
        assertTrue(joined, joined.endsWith("我還想做一個頁面"))
    }
}

