package com.utuvo.type.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** 同 Swift DictionarySyncTests；fixture 是 Swift 端也讀的同一份檔。 */
class DictionarySyncTest {
    @Test fun lastWriterWinsBothDirections() {
        var mac = DictionarySync().set("cloud code", "Claude Code", 10.0).set("jamin", "Gemini", 10.0)
        val phone = DictionarySync().set("cloud code", "Claude Code 2", 20.0).set("除值", "儲值", 5.0)
        mac = mac.remove("jamin", 30.0)
        val a = mac.merged(phone); val b = phone.merged(mac)
        assertEquals(a, b)
        assertEquals(mapOf("cloud code" to "Claude Code 2", "除值" to "儲值"), a.live)
    }

    @Test fun deletionTravelsButLaterReAddWins() {
        var a = DictionarySync().set("x", "X", 1.0)
        val b = a.remove("x", 2.0)
        assertEquals(emptyMap(), a.merged(b).live)
        a = a.set("x", "X!", 3.0)
        assertEquals(mapOf("x" to "X!"), a.merged(b).live)
    }

    @Test fun tieIsDeterministic() {
        val a = DictionarySync().set("k", "A", 5.0); val b = DictionarySync().set("k", "B", 5.0)
        assertEquals(a.merged(b), b.merged(a))
        val c = DictionarySync().set("k", "A", 5.0).remove("k", 5.0)
        assertEquals(mapOf("k" to "A"), a.merged(c).live)
    }

    @Test fun reconcile() {
        var s = DictionarySync.fromPlain(mapOf("a" to "A", "b" to "B"), 1.0)
        s = s.reconcile(mapOf("a" to "A", "c" to "C", "b" to "BB"), 9.0)
        assertEquals(mapOf("a" to "A", "b" to "BB", "c" to "C"), s.live)
        s = s.reconcile(mapOf("a" to "A"), 10.0)
        assertEquals(mapOf("a" to "A"), s.live)
        assertEquals(1.0, s.entries["a"]!!.at)
        assertNull(s.entries["b"]!!.output)
    }

    @Test fun roundTripFixtureAndLegacy() {
        val s = DictionarySync().set("cloud code", "Claude Code", 1_789_000_000.0).set("gone", "x", 0.0).remove("gone", 2.0)
        assertEquals(s, DictionarySync.decode(s.encode()))
        val fixture = File(javaClass.getResource("/dictionary-sync-fixture.json")!!.toURI()).readText()
        val f = DictionarySync.decode(fixture)
        assertEquals(mapOf("cloud code" to "Claude Code", "Atmos" to "Atmos"), f.live)
        assertNull(f.entries["jamin"]!!.output)
        assertEquals(1789000000.5, f.entries["cloud code"]!!.at)
        assertEquals(mapOf("pik" to "Pik"), DictionarySync.decode("""{"pik":"Pik"}""").live)
        assertFailsWith<DictionarySync.Companion.NotDictionaryFile> { DictionarySync.decode("""{"format":"x","version":1,"entries":{}}""") }
        assertFailsWith<DictionarySync.Companion.NewerVersion> { DictionarySync.decode("""{"format":"utuvo-type-dictionary","version":9,"entries":{}}""") }
        assertFailsWith<DictionarySync.Companion.NotDictionaryFile> { DictionarySync.decode("hello") }
    }

    @Test fun prune() {
        val s = DictionarySync().set("keep", "K", 0.0).set("old", "o", 0.0).remove("old", 1.0).set("new", "n", 0.0).remove("new", 1e9)
        val p = s.pruned(1e9 + 10)
        assertEquals(setOf("keep", "new"), p.entries.keys)
    }
}
