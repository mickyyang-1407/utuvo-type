package com.utuvo.type

import com.utuvo.type.CloudFallback.Notice
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * delivery-learning-v3（Android）＋capture-latency-v1 ③：雲端重辨識沒成功、改貼裝置端文字時要提示，
 * 而且分得出「網路慢」與「服務失敗」。修之前完全靜默。
 */
class CloudFallbackNoticeTest {

    @Test
    fun networkFailuresSaySlowNetwork() {
        assertEquals(Notice.SLOW_NETWORK, CloudFallback.notice("timeout", null, "裝置端文字"))
        assertEquals(Notice.SLOW_NETWORK, CloudFallback.notice("transport", null, "裝置端文字"))
    }

    @Test
    fun serviceFailuresSayFailed() {
        for (outcome in listOf("http:401", "http:429", "http:500", "malformed", "empty", "loop", "error")) {
            assertEquals(outcome, Notice.FAILED, CloudFallback.notice(outcome, null, "裝置端文字"))
        }
    }

    @Test
    fun noNoticeWhenCloudSucceededOrNothingWasDelivered() {
        assertEquals(Notice.NONE, CloudFallback.notice("ok", "雲端文字", "裝置端文字"))
        // 雲端回來的只是被濾掉的結尾句：雲端沒失敗，不提示。
        assertEquals(Notice.NONE, CloudFallback.notice("ok", "謝謝大家收看", "裝置端文字"))
        // 沒有裝置端文字＝沒有東西被改貼（那條路自己會講「沒有聽到聲音」）。
        assertEquals(Notice.NONE, CloudFallback.notice("timeout", null, ""))
        // 根本沒送出請求（太短、沒有 key）。
        assertEquals(Notice.NONE, CloudFallback.notice(null, null, "裝置端文字"))
    }

    @Test
    fun outcomeTapKeepsLastOutcomeAndForwards() {
        val forwarded = ArrayList<String>()
        val tap = CloudASR.OutcomeTap(CloudASR.Log { _, _, _, outcome, _, _ -> forwarded.add(outcome) })
        tap.record(0, 1, "groq", "http:500", 1.0, 0)
        tap.record(0, 1, "groq", "timeout", 1.0, 0)
        assertEquals("timeout", tap.last)
        assertEquals(listOf("http:500", "timeout"), forwarded)
    }
}
