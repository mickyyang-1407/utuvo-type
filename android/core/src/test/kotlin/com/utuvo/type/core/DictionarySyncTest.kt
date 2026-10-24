package com.utuvo.type.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

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

    // 純詞表匯入（app-shell-6；同 Swift DictionarySyncTests，同一份樣本）

    @Test fun wordListOneWordPerLineAndFirstCsvColumn() {
        val text = "\uFEFFAtmos\r\nPro Tools\n\n\"DAMI music\",note\nAtmos\n"
        assertFalse(DictionarySync.looksLikeJson(text))
        assertEquals(listOf("Atmos", "Pro Tools", "DAMI music"), DictionarySync.parseWordList(text))
    }

    @Test fun wordListErrors() {
        assertFailsWith<DictionarySync.Companion.NoWords> { DictionarySync.parseWordList("") }
        assertFailsWith<DictionarySync.Companion.NoWords> { DictionarySync.parseWordList("\uFEFF\n  \r\n,x\n") }
        assertFailsWith<DictionarySync.Companion.WordListTooLarge> {
            DictionarySync.parseWordList("a".repeat(DictionarySync.MAX_WORD_LIST_BYTES + 1))
        }
        assertEquals(listOf("a"), DictionarySync.parseWordList("a" + "\n".repeat(DictionarySync.MAX_WORD_LIST_BYTES - 1)))
    }

    @Test fun jsonLookingContentIsNeverAWordList() {
        assertTrue(DictionarySync.looksLikeJson(DictionarySync().set("cloud code", "Claude Code", 1.0).encode()))
        assertTrue(DictionarySync.looksLikeJson("\uFEFF  \n {\"pik\":\"Pik\"}"))
        assertTrue(DictionarySync.looksLikeJson("[\"Atmos\"]"))
        val broken = "{\n  \"format\" : \"utuvo-type-dictionary\",\n  \"version\" : 1,\n"
        assertTrue(DictionarySync.looksLikeJson(broken))
        assertFailsWith<DictionarySync.Companion.NotDictionaryFile> { DictionarySync.decode(broken) }
        assertFalse(DictionarySync.looksLikeJson("Atmos\n{curly}\n"))
    }

    @Test fun addingWordsKeepsExistingOutputsAndRevivesDeleted() {
        val s = DictionarySync().set("Atmos", "Dolby Atmos", 1.0).set("gone", "x", 1.0).remove("gone", 2.0)
        assertEquals(listOf("gone", "Pro Tools"), s.newWords(listOf("Atmos", "gone", "Pro Tools", "Pro Tools", " ")))
        val t = s.addingWords(listOf("Atmos", "gone", "Pro Tools"), 10.0)
        assertEquals(mapOf("Atmos" to "Dolby Atmos", "gone" to "gone", "Pro Tools" to "Pro Tools"), t.live)
        assertEquals(10.0, t.entries["Pro Tools"]!!.at)
        assertEquals(1.0, t.entries["Atmos"]!!.at)
        assertEquals(DictionarySync.Source.MANUAL, t.entries["Pro Tools"]!!.source)
    }

    // 來源標記（delivery-learning-4；Swift DictionarySyncTests 讀同一份樣本）：Mac／iPhone 只寫 "AUTO"、手動的不寫欄位。

    @Test fun sourceFixtureDecodesLikeSwift() {
        val fixture = File(javaClass.getResource("/dictionary-sync-source-fixture.json")!!.toURI()).readText()
        val s = DictionarySync.decode(fixture)
        val auto = DictionarySync.Source.AUTO
        val manual = DictionarySync.Source.MANUAL
        assertEquals(auto, s.entries.getValue("Atmus").source)
        assertEquals(auto, s.entries.getValue("UTUVO").source)
        assertEquals(manual, s.entries.getValue("cloud code").source)
        assertEquals(manual, s.entries.getValue("pik").source, "缺欄位＝手動")
        assertEquals(manual, s.entries.getValue("odd").source, "看不懂的值＝手動")
        assertNull(s.entries.getValue("gone").output)
        assertEquals(
            mapOf("Atmus" to "Atmos", "UTUVO" to "UTUVO", "cloud code" to "Claude Code", "pik" to "Pik", "odd" to "Odd"),
            s.live,
        )
        assertEquals(s, DictionarySync.decode(s.encode()))
    }

    /** Swift 寫出來的檔（自動才有 source、手動沒有）Android 讀得對，再匯出還是自動。 */
    @Test fun swiftShapedFileKeepsAutoThroughAndroid() {
        val swift = """
            {"format":"utuvo-type-dictionary","version":1,"entries":{
              "Atmus":{"at":2,"output":"Atmos","source":"AUTO"},
              "cloud code":{"at":1,"output":"Claude Code"}}}
        """.trimIndent()
        val back = DictionarySync.decode(DictionarySync.decode(swift).encode())
        assertEquals(DictionarySync.Source.AUTO, back.entries.getValue("Atmus").source)
        assertEquals(DictionarySync.Source.MANUAL, back.entries.getValue("cloud code").source)
    }

    @Test fun wordListFixtureMatchesSwiftParser() {
        val fixture = File(javaClass.getResource("/dictionary-wordlist-fixture.txt")!!.toURI()).readText()
        assertFalse(DictionarySync.looksLikeJson(fixture))
        assertEquals(
            listOf("Atmos", "Pro Tools", "DAMI music", "Logic Pro", "Say \"Hi\", ok", "Dolby", "UTUVO", "unterminated quote"),
            DictionarySync.parseWordList(fixture),
        )
    }

    // 2026-10-22 修補（verifier mac-learning2；同 Swift testMergeIsCommutativeWhenOnlyTheSourceDiffers）：
    // 舊版把 AUTO 讀成手動再寫回 → 同時間、同寫法、只差來源。合併結果要不看順序（手動贏），兩台才不會互相覆寫。
    @Test fun mergeIsCommutativeWhenOnlyTheSourceDiffers() {
        val auto = DictionarySync().set("UTUVO", "", 1000.0, DictionarySync.Source.AUTO)
        val manual = DictionarySync(mapOf("UTUVO" to DictionarySync.Entry("UTUVO", 1000.0)))
        assertEquals(auto.merged(manual), manual.merged(auto))
        assertEquals(DictionarySync.Source.MANUAL, auto.merged(manual).entries.getValue("UTUVO").source)
        assertEquals(DictionarySync.Source.MANUAL, manual.merged(auto).entries.getValue("UTUVO").source)

        val autoGone = DictionarySync(mapOf("x" to DictionarySync.Entry(null, 5.0, DictionarySync.Source.AUTO)))
        val manualGone = DictionarySync(mapOf("x" to DictionarySync.Entry(null, 5.0)))
        assertEquals(autoGone.merged(manualGone), manualGone.merged(autoGone), "墓碑也一樣")
        assertEquals(DictionarySync.Source.MANUAL, autoGone.merged(manualGone).entries.getValue("x").source)
    }
}
