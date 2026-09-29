package com.utuvo.type

import android.speech.RecognizerIntent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 個人字典＋歷史：鍵盤真正走的整理（Dictation.clean）與辨識請求（SpeechRequest.build）都用這份資料。 */
@RunWith(AndroidJUnit4::class)
class UserDataTest {
    private val app = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var dict: PrefsSnapshot
    private var savedHistory: List<HistoryStore.Record> = emptyList()

    // 手機上是 Micky 真的在用的鍵盤：測試前後保留他的字典（含同步時間）與歷史
    @Before fun save() {
        dict = PrefsSnapshot(app, "dictionary"); savedHistory = HistoryStore.load(app)
        app.getSharedPreferences("dictionary", 0).edit().clear().commit(); HistoryStore.clear(app)
    }
    @After fun restore() {
        dict.restore()
        HistoryStore.restore(app, savedHistory)   // 原樣含時間寫回（append 會把時間全改成現在）
    }

    @Test
    fun replacementChangesTextVocabularyDoesNot() {
        DictionaryStore.add(app, " pik ", "Pik")
        DictionaryStore.add(app, "Atmos", "")
        assertEquals(mapOf("pik" to "Pik", "Atmos" to "Atmos"), DictionaryStore.entries(app))
        assertEquals(listOf("Atmos" to "Atmos", "pik" to "Pik"), DictionaryStore.sorted(app))   // 詞彙在前
        val out = Dictation.clean(app, "我在用 pik 播放器聽 atmos")
        assertTrue("替換要生效：$out", out.contains("Pik"))
        assertFalse("詞彙不該改寫原文：$out", out.contains("Atmos"))
        DictionaryStore.remove(app, "pik")
        assertTrue("刪掉後不再替換", !Dictation.clean(app, "我在用 pik 播放器").contains("Pik"))
    }

    @Test
    fun recognizerGetsDictionaryAsBiasing() {
        DictionaryStore.add(app, "Tonmeister", "")
        DictionaryStore.add(app, "pik", "Pik")
        val intent = SpeechRequest.build("zh-TW", DictionaryStore.biasing(app))
        assertEquals(setOf("Tonmeister", "Pik"), intent.getStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS)?.toSet())
        assertFalse("空字典不帶提示", SpeechRequest.build("zh-TW", emptyList()).hasExtra(RecognizerIntent.EXTRA_BIASING_STRINGS))
    }

    @Test
    fun historyNewestFirstCappedAndRemovable() {
        HistoryStore.append(app, "a", "A")
        Thread.sleep(2)
        HistoryStore.append(app, "b", "B")
        val list = HistoryStore.load(app)
        assertEquals(listOf("B", "A"), list.map { it.cleaned })
        HistoryStore.remove(app, list[0].time)
        assertEquals(listOf("A"), HistoryStore.load(app).map { it.cleaned })
        repeat(HistoryStore.MAX + 3) { HistoryStore.append(app, "r$it", "c$it") }
        val capped = HistoryStore.load(app)
        assertEquals(HistoryStore.MAX, capped.size)
        assertEquals("c${HistoryStore.MAX + 2}", capped.first().cleaned)
    }

    @Test
    fun exportImportCarriesEditsAndDeletions() {
        DictionaryStore.add(app, "cloud code", "Claude Code")
        DictionaryStore.add(app, "jamin", "Gemini")
        DictionaryStore.remove(app, "jamin")
        val file = DictionaryStore.export(app)
        assertTrue(file, file.contains("\"format\": \"utuvo-type-dictionary\""))
        // 另一台（還留著 jamin、沒有 cloud code）匯入這份 → 刪除也帶過去
        app.getSharedPreferences("dictionary", 0).edit().clear().commit()
        DictionaryStore.add(app, "Atmos", "")
        Thread.sleep(1100)
        val other = com.utuvo.type.core.DictionarySync.fromPlain(mapOf("jamin" to "Gemini"), 1.0)
        DictionaryStore.import(app, other.encode())
        assertEquals(mapOf("Atmos" to "Atmos", "jamin" to "Gemini"), DictionaryStore.entries(app))
        assertEquals("jamin 刪、cloud code 加", 2, DictionaryStore.import(app, file))
        assertEquals(mapOf("Atmos" to "Atmos", "cloud code" to "Claude Code"), DictionaryStore.entries(app))
        // iPhone／Mac 匯出的檔（Swift JSONEncoder：刪除沒有 output 欄位、時間可有小數）
        val swift = """{"entries":{"Pik":{"at":9999999999.5,"output":"Pik"},"Atmos":{"at":9999999999}},"format":"utuvo-type-dictionary","version":1}"""
        DictionaryStore.import(app, swift)
        assertEquals(mapOf("Pik" to "Pik", "cloud code" to "Claude Code"), DictionaryStore.entries(app))
        assertTrue(runCatching { DictionaryStore.import(app, "hello") }.isFailure)
    }
}
