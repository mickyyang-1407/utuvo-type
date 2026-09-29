package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 預設服務遷移與整理健康狀態（對齊 iOS `SmartCleanup.resolvedDefaultProvider` 與 `SmartLog.summary/reason`）。
 * 純邏輯：provider 解析只吃字串，彙總只吃紀錄，都不碰 Android 設定。
 */
class SmartCleanupLogTest {
    private fun entry(outcome: String, provider: String = "groq", at: String = "2026-09-29T00:00:00Z") =
        SmartLog.Entry(at, 1200, provider, outcome, 10, 9)

    // MARK: - 預設服務

    @Test
    fun newUsersGetTheRecommendedProvider() {
        assertEquals(SmartCleanup.Provider.GROQ, SmartProviders.recommended)
        assertEquals(SmartCleanup.Provider.GROQ, SmartProviders.resolve(null, hasGeminiKey = false))
    }

    @Test
    fun oldGeminiUsersKeepGemini() {
        assertEquals(SmartCleanup.Provider.GEMINI, SmartProviders.resolve(null, hasGeminiKey = true))
    }

    @Test
    fun reinstalledWithBothKeysPrefersRecommended() {
        assertEquals(
            SmartCleanup.Provider.GROQ,
            SmartProviders.resolve(null, hasGeminiKey = true, hasGroqKey = true)
        )
    }

    @Test
    fun aStoredChoiceIsNeverOverridden() {
        SmartCleanup.Provider.entries.forEach { p ->
            assertEquals(p, SmartProviders.resolve(p.id, hasGeminiKey = true, hasGroqKey = true))
        }
    }

    @Test
    fun unknownStoredValueFallsBackToTheMigration() {
        assertEquals(SmartCleanup.Provider.GEMINI, SmartProviders.resolve("retired", hasGeminiKey = true))
        assertEquals(SmartCleanup.Provider.GROQ, SmartProviders.resolve(null, hasGeminiKey = false))
    }

    // MARK: - 彙總

    @Test
    fun countsSuccessesAndFailures() {
        val summary = SmartLog.summary(listOf(entry("ok"), entry("ok"), entry("timeout"), entry("rejected")))
        assertEquals(2, summary.ok)
        assertEquals(2, summary.failed)
    }

    @Test
    fun lastFailureIsTheLastFailingEntryNotTheLastEntry() {
        val summary = SmartLog.summary(
            listOf(
                entry("http(429)", at = "2026-09-29T01:00:00Z"),
                entry("ok", at = "2026-09-29T02:00:00Z"),
                entry("http(401)", provider = "gemini", at = "2026-09-29T03:00:00Z")
            )
        )
        assertEquals(1, summary.ok)
        assertEquals(2, summary.failed)
        assertEquals("gemini", summary.lastFailureProvider)
        assertEquals("2026-09-29T03:00:00Z", summary.lastFailureAt)
        assertEquals("http(401)", summary.lastFailureOutcome)
        assertEquals(R.string.smart_reason_auth, summary.lastFailure)
    }

    @Test
    fun noFailureMeansNoLastFailure() {
        val summary = SmartLog.summary(listOf(entry("ok"), entry("ok")))
        assertNull(summary.lastFailureProvider)
        assertNull(summary.lastFailureOutcome)
    }

    @Test
    fun emptyLogIsAllZero() {
        val summary = SmartLog.summary(emptyList())
        assertEquals(0, summary.ok)
        assertEquals(0, summary.failed)
        assertNull(summary.lastFailure)
    }

    // MARK: - 失敗原因

    @Test
    fun mapsOutcomesToReasons() {
        val cases = mapOf(
            "http(429)" to R.string.smart_reason_quota,
            "http(401)" to R.string.smart_reason_auth,
            "http(403)" to R.string.smart_reason_auth,
            "http(503)" to R.string.smart_reason_busy,
            "http(400)" to R.string.smart_reason_http,
            "timeout" to R.string.smart_reason_timeout,
            "rejected" to R.string.smart_reason_rejected,
            "notConfigured" to R.string.smart_reason_not_configured,
            "java.net.UnknownHostException" to R.string.smart_reason_network,
            "something-else" to R.string.smart_reason_other,
        )
        for ((outcome, expected) in cases) {
            assertEquals("outcome=$outcome", expected, SmartLog.reasonRes(outcome))
        }
    }

    @Test
    fun knownProvidersHaveNamesAndUnknownOnesDoNot() {
        assertEquals(R.string.smart_provider_groq, SmartLog.providerNameRes("groq"))
        assertEquals(R.string.smart_provider_gemini, SmartLog.providerNameRes("gemini"))
        assertEquals(R.string.smart_provider_dashscope, SmartLog.providerNameRes("dashscope"))
        assertEquals(R.string.smart_provider_custom, SmartLog.providerNameRes("custom"))
        assertNull(SmartLog.providerNameRes("retired-service"))
    }
}
