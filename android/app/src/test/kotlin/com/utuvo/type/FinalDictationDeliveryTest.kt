package com.utuvo.type

import org.junit.Assert.*
import org.junit.Test

/** Exercises the actual coordinator invoked by UTUVOImeService.deliver. No Android
 * service, real preferences, history files, transports, audio or credentials. */
class FinalDictationDeliveryTest {
    private class Request {
        lateinit var complete: (String?) -> Unit
        var cancelled = 0
        var starts = 0
        fun run(done: (String?) -> Unit): () -> Unit { starts++; complete = done; return { cancelled++ } }
    }
    private class Fixture {
        val coordinator = FinalDictationDelivery()
        val primary = Request(); val local = Request()
        var valid = true
        val inserted = mutableListOf<String>()
        val history = mutableListOf<Pair<String, String>>()
        val retained = mutableListOf<String>()
        val events = mutableListOf<String>()
        fun start(localFallback: Boolean = true) = coordinator.start("原文",
            primary::run, if (localFallback) local::run else null, { valid },
            { inserted += it; history += "ASR 原稿" to it; true },
            { retained += it }, events::add)
    }
    @Test fun micStartPolicyPreservesPendingUtteranceUntilFinalInsertion() {
        val f = Fixture()
        assertTrue(f.coordinator.mayStartRecording())
        f.start()
        assertFalse(f.coordinator.mayStartRecording())
        f.primary.complete(null)
        assertFalse(f.coordinator.mayStartRecording())
        f.local.complete("第一句")
        assertEquals(listOf("第一句"), f.inserted)
        assertTrue(f.coordinator.mayStartRecording())
        f.start(); f.coordinator.cancel()
        assertTrue(f.coordinator.mayStartRecording())
    }
    @Test fun waitsThenInsertsOnceAndPreservesRawHistory() {
        val f = Fixture(); f.start()
        assertTrue(f.inserted.isEmpty()); assertTrue(f.history.isEmpty())
        f.primary.complete("最終文字")
        f.primary.complete("重複回呼")
        assertEquals(listOf("最終文字"), f.inserted)
        assertEquals(listOf("ASR 原稿" to "最終文字"), f.history)
        assertEquals("insertion-api-accepted", f.events.last())
    }
    @Test fun failedOrTimedOutCloudWaitsForIndependentLocalAttempt() {
        val f = Fixture(); f.start(); f.primary.complete(null)
        assertTrue(f.inserted.isEmpty())
        assertTrue(f.events.contains("local-fallback"))
        f.local.complete("本機結果"); f.primary.complete("過期雲端結果")
        assertEquals(listOf("本機結果"), f.inserted)
    }
    @Test fun totalFailureStillInsertsDeterministicOnce() {
        val f = Fixture(); f.start(); f.primary.complete(null); f.local.complete(null)
        assertEquals(listOf("原文"), f.inserted)
    }
    @Test fun cancelSuppressesPrimaryAndFallbackCallbacks() {
        val f = Fixture(); f.start(); f.coordinator.cancel(); f.primary.complete("舊句")
        assertTrue(f.inserted.isEmpty()); assertTrue(f.history.isEmpty())
        assertEquals(1, f.primary.cancelled)
        f.start(); f.primary.complete(null); f.coordinator.cancel(); f.local.complete("舊句")
        assertTrue(f.inserted.isEmpty()); assertEquals(1, f.local.cancelled)
    }
    @Test fun changedTargetRetainsResultWithoutInsertionOrDeliveredEvent() {
        val f = Fixture(); f.start(); f.valid = false; f.primary.complete("可複製結果")
        assertTrue(f.inserted.isEmpty()); assertEquals(listOf("可複製結果"), f.retained)
        assertFalse(f.events.contains("insertion-api-accepted"))
    }
    @Test fun newTurnAfterExplicitCancelDoesNotAcceptEarlierTurn() {
        val f = Fixture(); f.start(); val old = f.primary.complete
        f.coordinator.cancel()
        f.start(); old("舊句"); f.primary.complete("新句")
        assertEquals(listOf("新句"), f.inserted)
    }
    @Test fun duplicateStartWhileCloudPendingPreservesFirstUtteranceAndHistory() {
        val f = Fixture(); f.start(); val first = f.primary.complete
        f.start()
        assertEquals(1, f.primary.starts)
        assertEquals(0, f.primary.cancelled)
        assertTrue(f.events.contains("ignored-while-polishing"))
        first("第一句")
        first("重複ASR回呼")
        assertEquals(listOf("第一句"), f.inserted)
        assertEquals(listOf("ASR 原稿" to "第一句"), f.history)
    }
    @Test fun duplicateAsrDeliveryDuringLocalFallbackCannotCancelOriginalTurn() {
        val f = Fixture(); f.start(); f.primary.complete(null)
        val local = f.local.complete
        f.start()
        assertEquals(1, f.primary.starts)
        assertEquals(1, f.local.starts)
        assertEquals(0, f.local.cancelled)
        local("第一句本機結果")
        assertEquals(listOf("第一句本機結果"), f.inserted)
        assertEquals(listOf("ASR 原稿" to "第一句本機結果"), f.history)
        assertTrue(f.coordinator.mayStartRecording())
    }
    @Test fun synchronousFailureAndFallbackStillCompleteOnce() {
        val out = mutableListOf<String>()
        FinalDictationDelivery().start("原文", { done -> done(null); ({}) },
            { done -> done("本機"); ({}) }, { true }, { out += it; true }, {}, {})
        assertEquals(listOf("本機"), out)
    }
    @Test fun rejectedInsertionRetainsWithoutDuplicateAttempt() {
        var attempts = 0; val kept = mutableListOf<String>()
        val request = Request()
        FinalDictationDelivery().start("原文", request::run, null, { true },
            { attempts++; false }, kept::add, {})
        request.complete("結果"); request.complete("遲到")
        assertEquals(1, attempts); assertEquals(listOf("結果"), kept)
    }
}
