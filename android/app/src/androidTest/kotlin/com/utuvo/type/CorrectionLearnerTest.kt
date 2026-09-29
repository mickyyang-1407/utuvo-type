package com.utuvo.type

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/** 同 iOS CorrectionLearnerTests（同音判斷用手機上的 ICU Han-Latin，所以在裝置上跑）。 */
@RunWith(AndroidJUnit4::class)
class CorrectionLearnerTest {
    private fun run(dictated: String, deleteFromEnd: Int, vararg typed: String, clock: () -> Long = { 0L }): Pair<String, String>? {
        val l = CorrectionLearner(clock)
        l.dictationInserted(dictated)
        val doc = StringBuilder(dictated)
        repeat(deleteFromEnd) { l.willDelete(doc.last()); doc.setLength(doc.length - 1) }
        var learned: Pair<String, String>? = null
        for (t in typed) l.didType(t)?.let { learned = it }
        return learned
    }

    @Test fun learnsHomophoneFix() = assertEquals("除值" to "儲值", run("悠悠卡自動除值", 2, "儲值"))
    @Test fun learnsTypedInPieces() = assertEquals("及時" to "即時", run("他不是及時", 2, "即", "時"))
    @Test fun notChangeOfMind() = assertNull(run("我們明天開會", 4, "後天開會"))
    @Test fun notSingleCharacter() = assertNull(run("我明天在", 1, "再"))
    @Test fun notDifferentLength() = assertNull(run("悠悠卡自動除值", 2, "儲值了"))
    @Test fun notPronounSwap() = assertNull(run("我跟他說", 2, "她說"))
    @Test fun expires() {
        var t = 0L
        val l = CorrectionLearner { t }
        l.dictationInserted("自動除值")
        t = CorrectionLearner.WINDOW_MS + 1
        l.willDelete('值'); l.willDelete('除')
        assertNull(l.didType("儲值"))
    }
}
