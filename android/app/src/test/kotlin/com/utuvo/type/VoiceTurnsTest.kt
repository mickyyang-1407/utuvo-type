package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * mobile-keyboard-1：✕ 只作廢「這一次」語音。錄音中、按停之後等結果／整理中都能按；
 * 沒在錄也沒在整理時沒有 ✕。上一段還在背景跑的結果不受影響（不能用 inputGeneration 一起丟）。
 */
class VoiceTurnsTest {

    @Test
    fun `錄音中與按停之後都能取消`() {
        val turns = VoiceTurns()
        assertFalse("還沒開始：沒有 ✕", turns.cancellable)
        val id = turns.start()
        assertEquals(VoiceTurns.Phase.RECORDING, turns.phase)
        assertTrue("錄音中：✕ 在", turns.cancellable)
        turns.stopped()
        assertEquals(VoiceTurns.Phase.PROCESSING, turns.phase)
        assertTrue("按停之後等結果／整理中：✕ 還在", turns.cancellable)
        assertTrue(turns.isLive(id))
    }

    @Test
    fun `取消錄音中的這一次：結果作廢、✕ 收起`() {
        val turns = VoiceTurns()
        val id = turns.start()
        assertEquals(id, turns.cancel())
        assertFalse("取消之後晚到的結果不能貼", turns.isLive(id))
        assertFalse(turns.cancellable)
        assertEquals(VoiceTurns.Phase.IDLE, turns.phase)
    }

    @Test
    fun `取消整理中的這一次`() {
        val turns = VoiceTurns()
        val id = turns.start()
        turns.stopped()
        assertEquals(id, turns.cancel())
        assertFalse(turns.isLive(id))
    }

    @Test
    fun `結果已經貼出之後沒有東西可以取消`() {
        val turns = VoiceTurns()
        val id = turns.start()
        turns.stopped()
        turns.finish(id)
        assertFalse(turns.cancellable)
        assertNull("沒在錄也沒在整理：✕ 不作廢任何東西", turns.cancel())
        assertTrue("已經貼出的那一次不會事後被標成作廢", turns.isLive(id))
    }

    @Test
    fun `取消新的一次不影響上一次還在背景的結果`() {
        val turns = VoiceTurns()
        val first = turns.start()
        turns.stopped()               // 上一次還在等雲端
        val second = turns.start()    // 使用者又開始講
        assertEquals(second, turns.cancel())
        assertTrue("上一次的結果照常貼", turns.isLive(first))
        assertFalse(turns.isLive(second))
    }

    @Test
    fun `舊的那一次結束不會把現在這一次的 ✕ 收掉`() {
        val turns = VoiceTurns()
        val first = turns.start()
        turns.stopped()
        turns.start()
        turns.finish(first)
        assertTrue(turns.cancellable)
        assertEquals(VoiceTurns.Phase.RECORDING, turns.phase)
    }

    @Test
    fun `沒在錄音時按停不會讓 ✕ 跑出來`() {
        val turns = VoiceTurns()
        turns.stopped()
        assertFalse(turns.cancellable)
        val id = turns.start()
        turns.finish(id)
        turns.stopped()
        assertFalse(turns.cancellable)
    }

    @Test
    fun `每一次都是新的身分`() {
        val turns = VoiceTurns()
        val a = turns.start(); turns.cancel()
        val b = turns.start()
        assertTrue(a != b)
        assertTrue("新的一次不會繼承上一次的取消", turns.isLive(b))
    }

    @Test
    fun `最近取消的幾次都還記得`() {
        val turns = VoiceTurns()
        val ids = (1..16).map { turns.start().also { turns.cancel() } }
        ids.forEach { assertFalse(turns.isLive(it)) }
    }
}
