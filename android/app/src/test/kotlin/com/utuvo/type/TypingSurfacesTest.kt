package com.utuvo.type

import com.utuvo.type.TypingSurfaces.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 打字鍵盤增刪排序（同 iOS `TypingSurfacesTests`）。 */
class TypingSurfacesTest {
    @Test fun orderSurvivesJunkDuplicatesAndMissingKinds() {
        assertEquals(listOf(Kind.HANS, Kind.HANT, Kind.EN), TypingSurfaces.normalizedOrder(listOf("hans", "bogus", "hans", "hant")))
        assertEquals(listOf(Kind.EN, Kind.HANT, Kind.HANS), TypingSurfaces.normalizedOrder(null))
        assertEquals(listOf("hant", "hans"), TypingSurfaces.split(" hant, ,hans "))
        assertEquals(listOf(Kind.HANT, Kind.HANS), TypingSurfaces.enabled(listOf(Kind.HANT, Kind.EN, Kind.HANS), setOf(Kind.EN)))
    }

    @Test fun swipeCyclesVoiceThenEnabledOnly() {
        val onlyZhuyin = listOf(Kind.HANT)
        assertEquals(Kind.HANT, TypingSurfaces.next(null, onlyZhuyin, 1))
        assertNull(TypingSurfaces.next(Kind.HANT, onlyZhuyin, 1))
        assertEquals(Kind.HANT, TypingSurfaces.next(null, onlyZhuyin, -1))
        val two = listOf(Kind.HANS, Kind.EN)
        assertEquals(Kind.HANS, TypingSurfaces.next(null, two, 1))
        assertEquals(Kind.EN, TypingSurfaces.next(Kind.HANS, two, 1))
        assertNull(TypingSurfaces.next(Kind.EN, two, 1))
        assertEquals(Kind.EN, TypingSurfaces.next(null, two, -1))
        assertEquals(Kind.HANS, TypingSurfaces.next(Kind.HANT, two, 1))   // 目前那個剛被關掉：當作在語音
        assertNull(TypingSurfaces.next(null, emptyList(), 1))            // 全關：只剩語音
    }

    @Test fun layoutKeyAndSideOffsets() {
        assertEquals(Kind.HANT, TypingSurfaces.nextTyping(Kind.HANT, listOf(Kind.HANT)))
        assertEquals(Kind.EN, TypingSurfaces.nextTyping(Kind.HANS, listOf(Kind.EN, Kind.HANS)))
        assertEquals(listOf(-50, 0, 50), TypingSurfaces.sideOffsets(3, 50))
        assertEquals(listOf(-25, 25), TypingSurfaces.sideOffsets(2, 50))
        assertEquals(listOf(0), TypingSurfaces.sideOffsets(1, 50))
    }
}
