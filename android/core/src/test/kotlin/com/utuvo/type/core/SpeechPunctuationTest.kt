package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

class SpeechPunctuationTest {
    @Test fun restoresQuestionAndClearClauseBoundary() {
        assertEquals("你明天要一起去嗎？", SpeechPunctuation.restore("你明天要一起去嗎", SpeechPunctuation.Field.CHAT))
        assertEquals("你今天晚上要吃什麼？", SpeechPunctuation.restore("你今天晚上要吃什麼", SpeechPunctuation.Field.CHAT))
        assertEquals("我想知道你要吃什麼。", SpeechPunctuation.restore("我想知道你要吃什麼", SpeechPunctuation.Field.DOCUMENT))
        assertEquals("我明天會到，但是可能晚一點。", SpeechPunctuation.restore("我明天會到但是可能晚一點", SpeechPunctuation.Field.DOCUMENT))
    }

    @Test fun respectsExistingPunctuationAndFieldStyle() {
        assertEquals("我明天會到，但是可能晚一點。", SpeechPunctuation.restore("我明天會到，但是可能晚一點。", SpeechPunctuation.Field.DOCUMENT))
        assertEquals("晚點再說", SpeechPunctuation.restore("晚點再說", SpeechPunctuation.Field.CHAT))
        assertEquals("明天開會。", SpeechPunctuation.restore("明天開會", SpeechPunctuation.Field.DOCUMENT))
        assertEquals("明天開會", SpeechPunctuation.restore("明天開會", SpeechPunctuation.Field.SEARCH))
        assertEquals("API key", SpeechPunctuation.restore("API key", SpeechPunctuation.Field.DOCUMENT))
    }
}
