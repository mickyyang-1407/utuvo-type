package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 歷史檔案的舊資料相容 + 字典「自動／手動」來源的舊格式相容。
 */
class HistoryCodecTest {

    @Test
    fun `舊檔沒有 duration 讀得出來、當未知`() {
        val old = """[{"time":1750000000000,"raw":"你好","cleaned":"你好。"}]"""
        val got = HistoryCodec.decode(old)
        assertEquals(1, got.size)
        assertEquals(1750000000000L, got[0].time)
        assertEquals("你好。", got[0].cleaned)
        assertEquals(0, got[0].durationSec)
    }

    @Test
    fun `壞的 duration 當未知、不讓整份歷史讀不出來`() {
        val bad = """[{"time":1,"raw":"a","cleaned":"b","duration":-5},
                      {"time":2,"raw":"c","cleaned":"d","duration":"不是數字"},
                      {"time":3,"raw":"e","cleaned":"f","duration":12}]"""
        val got = HistoryCodec.decode(bad)
        assertEquals(3, got.size)
        assertEquals(0, got[0].durationSec)
        assertEquals(0, got[1].durationSec)
        assertEquals(12, got[2].durationSec)
    }

    @Test
    fun `空檔、壞檔、壞 JSON 都是空清單`() {
        assertTrue(HistoryCodec.decode(null).isEmpty())
        assertTrue(HistoryCodec.decode("").isEmpty())
        assertTrue(HistoryCodec.decode("{\"不是\":1}").isEmpty())
        assertTrue(HistoryCodec.decode("[[1,2],[3,4]]").isEmpty())
    }

    @Test
    fun `encode 再 decode 資料一致`() {
        val recs = listOf(
            HistoryCodec.Record(1L, "raw1", "clean1", 3),
            HistoryCodec.Record(2L, "raw2", "clean2"),   // 未知時長不寫欄位
        )
        assertEquals(recs, HistoryCodec.decode(HistoryCodec.encode(recs)))
    }

    @Test
    fun `字典舊匯出檔沒有 source 算手動`() {
        val old = """{"format":"utuvo-type-dictionary","version":1,
            "entries":{"值":{"output":"值2","at":10.0}}}"""
        val sync = DictionarySync.decode(old)
        assertEquals(DictionarySync.Source.MANUAL, sync.entries.getValue("值").source)
        assertEquals("值2", sync.live.getValue("值"))
    }

    @Test
    fun `字典 source 會記在匯出檔裡、讀回來還在`() {
        val sync = DictionarySync().set("值", "值2", 1.0, DictionarySync.Source.AUTO)
        val again = DictionarySync.decode(sync.encode())
        assertEquals(DictionarySync.Source.AUTO, again.entries.getValue("值").source)
    }

    @Test
    fun `使用者自己重加同一個詞會變回手動`() {
        var sync = DictionarySync().set("值", "值2", 1.0, DictionarySync.Source.AUTO)
        sync = sync.set("值", "值2", 2.0, DictionarySync.Source.MANUAL)
        assertEquals(DictionarySync.Source.MANUAL, sync.entries.getValue("值").source)
        // 空白字串當垃圾，不進字典
        assertEquals(sync, sync.set("   ", "x", 3.0))
    }

    @Test
    fun `字典純 map 的舊匯入仍可用`() {
        val plain = DictionarySync.decode("""{"你好":"您好"}""")
        assertEquals("您好", plain.live.getValue("你好"))
        assertEquals(DictionarySync.Source.MANUAL, plain.entries.getValue("你好").source)
    }
}