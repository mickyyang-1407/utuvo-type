package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 字典詞的來源（手動／自動，2026-10-13 修補項 5）。
 * 規則：已存在且是手動的詞，被自動學到時維持手動；只有新詞或原本就是自動的才標自動；
 * 使用者手動加入一律是手動。
 */
class DictionarySourceTest {
    private val MANUAL = DictionarySync.Source.MANUAL
    private val AUTO = DictionarySync.Source.AUTO

    @Test
    fun `新詞被自動學到 → 自動`() {
        val d = DictionarySync().set("台梗", "抬槓", at = 100.0, origin = AUTO)
        assertEquals(AUTO, d.entries.getValue("台梗").source)
    }

    @Test
    fun `已存在的手動詞被自動學到 → 維持手動`() {
        var d = DictionarySync().set("台梗", "抬槓", at = 100.0, origin = MANUAL)
        // 之後又從聽寫學到同一個詞（origin = AUTO）：不能把使用者自己加的詞變成自動。
        d = d.set("台梗", "抬槓", at = 200.0, origin = AUTO)
        assertEquals(MANUAL, d.entries.getValue("台梗").source)
        assertEquals(200.0, d.entries.getValue("台梗").at)
    }

    @Test
    fun `本來就是自動的詞再被學到 → 還是自動`() {
        var d = DictionarySync().set("台梗", "抬槓", at = 100.0, origin = AUTO)
        d = d.set("台梗", "抬槓", at = 200.0, origin = AUTO)
        assertEquals(AUTO, d.entries.getValue("台梗").source)
    }

    @Test
    fun `使用者手動加入或覆蓋一律手動`() {
        var d = DictionarySync().set("台梗", "抬槓", at = 100.0, origin = AUTO)
        d = d.set("台梗", "抬頭", at = 300.0, origin = MANUAL)
        assertEquals(MANUAL, d.entries.getValue("台梗").source)
        assertEquals("抬頭", d.entries.getValue("台梗").output)
        // 刪掉後重新手動加入 → 手動
        d = d.remove("台梗", at = 400.0).set("台梗", "抬槓", at = 500.0, origin = MANUAL)
        assertEquals(MANUAL, d.entries.getValue("台梗").source)
    }

    @Test
    fun `編碼解碼後來源不變`() {
        val d = DictionarySync().set("a", "A", 1.0, AUTO).set("b", "B", 2.0, MANUAL)
        val back = DictionarySync.decode(d.encode())
        assertEquals(AUTO, back.entries.getValue("a").source)
        assertEquals(MANUAL, back.entries.getValue("b").source)
    }
}
