package com.utuvo.type

import android.view.inputmethod.InputConnection

/**
 * 連續講好幾段時的背景更正（同 iOS CorrectionSwap／CorrectionChain）：第 k 段的更正回來時，後面幾段已經貼上了。
 * 游標前面還是「第 k 段起到最後一段」的原文，才把這一串換成「第 k 段更正版＋後面各段」；對不上（使用者改過、游標移走）就不動。
 * 後面各段接續時先補的前綴（[DictationJoin.prefix]：空白、「，」「、」）夾在段與段之間，比對與換回都要算進去（W2-7）——
 * 不算的話，英文接英文補了空白之後，前一段的更正永遠對不上。
 */
class CorrectionChain {
    /** [prefix]＝這段插入前先補的接續前綴（第 k 段自己的前綴在它前面，換字時不動）。 */
    data class Entry(val id: Long, var inserted: String, var done: Boolean = false, val prefix: String = "")
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
            val later = laterText(tail)
            val previous = tail.first().inserted + later
            if (!canReplace(previous, contextBefore)) return null
            return Plan(previous, corrected + later, i)
        }

        /** 第 k 段後面各段在欄位裡的樣子：各自的接續前綴＋插入的文字。 */
        private fun laterText(tail: List<Entry>): String = tail.drop(1).joinToString("") { it.prefix + it.inserted }
    }

    val entries = ArrayList<Entry>()
    private var nextId = 1L

    fun add(inserted: String, prefix: String = ""): Long {
        val id = nextId++
        entries += Entry(id, inserted, prefix = prefix)
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
        val need = entries[i].inserted.length + laterText(entries.subList(i, entries.size)).length
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

    /** 這一段被一鍵復原收回了：不再等它的更正，前面幾段的更正照樣對得上（delivery-learning-5）。 */
    fun remove(id: Long) { entries.removeAll { it.id == id } }
}
