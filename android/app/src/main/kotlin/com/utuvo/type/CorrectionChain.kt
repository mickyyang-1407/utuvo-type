package com.utuvo.type

import android.view.inputmethod.InputConnection

/**
 * 連續講好幾段時的背景更正（同 iOS CorrectionSwap／CorrectionChain）：第 k 段的更正回來時，後面幾段已經貼上了。
 * 游標前面還是「第 k 段起到最後一段」的原文，才把這一串換成「第 k 段更正版＋後面各段」；對不上（使用者改過、游標移走）就不動。
 */
class CorrectionChain {
    data class Entry(val id: Long, var inserted: String, var done: Boolean = false)
    data class Plan(val previous: String, val current: String, val index: Int)

    companion object {
        const val MAX = 20

        fun canReplace(inserted: String, contextBefore: String): Boolean {
            if (inserted.isEmpty() || contextBefore.isEmpty()) return false
            if (contextBefore.endsWith(inserted)) return true
            // 輸入框只給得出一部分前文（很長的段落）：至少 8 個字對得上才換。
            return contextBefore.length >= 8 && inserted.endsWith(contextBefore)
        }

        fun plan(entries: List<Entry>, id: Long, corrected: String, contextBefore: String): Plan? {
            val i = entries.indexOfFirst { it.id == id && !it.done }
            if (i < 0) return null
            val tail = entries.subList(i, entries.size)
            val previous = tail.joinToString("") { it.inserted }
            if (!canReplace(previous, contextBefore)) return null
            return Plan(previous, corrected + tail.drop(1).joinToString("") { it.inserted }, i)
        }
    }

    val entries = ArrayList<Entry>()
    private var nextId = 1L

    fun add(inserted: String): Long {
        val id = nextId++
        entries += Entry(id, inserted)
        while (entries.size > MAX) entries.removeAt(0)
        return id
    }

    /** 換好之後記下：這段現在長這樣、不用再換。 */
    fun applied(plan: Plan, corrected: String) {
        entries[plan.index].inserted = corrected
        entries[plan.index].done = true
    }

    /** 第 id 段的更正回來了：游標前還是原文就換掉，回傳有沒有換。 */
    fun swap(ic: InputConnection, id: Long, corrected: String): Boolean {
        val i = entries.indexOfFirst { it.id == id && !it.done }
        if (i < 0) return false
        val need = entries.subList(i, entries.size).sumOf { it.inserted.length }
        val before = ic.getTextBeforeCursor(need, 0)?.toString().orEmpty()
        val plan = plan(entries, id, corrected, before) ?: return false
        ic.beginBatchEdit()
        ic.deleteSurroundingText(plan.previous.length, 0)
        ic.commitText(plan.current, 1)
        ic.endBatchEdit()
        applied(plan, corrected)
        return true
    }

    /** 使用者自己動了輸入框（打字、刪字、換輸入框）：之後的更正都對不上了。 */
    fun clear() = entries.clear()
}
