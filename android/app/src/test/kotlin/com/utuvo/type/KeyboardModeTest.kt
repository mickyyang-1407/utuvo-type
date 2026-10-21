package com.utuvo.type

import com.utuvo.type.core.VoiceMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 使用者選的鍵盤語音模式優先於「有選取＝說出要怎麼改」。
 *
 * 審查抓到的問題：只要有選取，[KeyboardMode.decide] 就判成 [KeyboardMode.Edit]，
 * 使用者明明切到「幫我寫」或「問問題」，講完話卻送去改寫選取。
 */
class KeyboardModeTest {

    @Test
    fun `聽寫模式有選取就是說出要怎麼改`() {
        val m = KeyboardMode.decide("他說晚點回覆。", null, VoiceMode.DICTATE)
        assertTrue(m is KeyboardMode.Edit)
    }

    @Test
    fun `問問題模式有選取不被改寫搶走`() {
        assertEquals(KeyboardMode.Dictate, KeyboardMode.decide("他說晚點回覆。", null, VoiceMode.ASK_ANYTHING))
    }

    @Test
    fun `幫我寫模式有選取不被改寫搶走`() {
        assertEquals(KeyboardMode.Dictate, KeyboardMode.decide("他說晚點回覆。", null, VoiceMode.HELP_WRITE))
    }

    @Test
    fun `改寫模式有選取就是在改那一段`() {
        // 已經有選取就直接改那一段，不要再問「這一段／全部文字」
        assertTrue(KeyboardMode.decide("他說晚點回覆。", null, VoiceMode.SPEAK_TO_EDIT) is KeyboardMode.Edit)
    }

    @Test
    fun `改寫模式沒有選取時交給範圍選擇那一條路`() {
        assertEquals(KeyboardMode.Dictate, KeyboardMode.decide(null, null, VoiceMode.SPEAK_TO_EDIT))
        assertEquals(KeyboardMode.Dictate, KeyboardMode.decide("   ", null, VoiceMode.SPEAK_TO_EDIT))
    }

    @Test
    fun `空白選取不算選取`() {
        assertEquals(KeyboardMode.Dictate, KeyboardMode.decide("   ", null, VoiceMode.DICTATE))
    }

    @Test
    fun `沒有選取的舊簽章維持原行為`() {
        assertEquals(KeyboardMode.Dictate, KeyboardMode.decide(null, null))
        assertTrue(KeyboardMode.decide("選到的字", null) is KeyboardMode.Edit)
    }
}