package com.utuvo.type.core

/** 輸出形狀修整（同 Swift OutputShape）。 */
object OutputShape {
    /**
     * 單行輸入框：把分段／條列的換行接回一行（換行在單行框裡可能直接觸發送出）。
     * 前面是英文字元（含 . , !）、後面是英數字時補一個空白，其餘直接接上。
     */
    fun singleLine(text: String): String {
        if (!text.contains('\n')) return text
        val g = SwiftText.graphemes(text)
        val out = StringBuilder()
        var i = 0
        while (i < g.size) {
            if (g[i] == "\n") {
                var j = i
                while (j < g.size && g[j] == "\n") j++
                val before = out.lastOrNull()
                val after = g.getOrNull(j)?.singleOrNull()
                if (before != null && after != null && before.code < 128 && !before.isWhitespace() && after.code < 128 && after.isLetterOrDigit()) out.append(' ')
                i = j
                continue
            }
            out.append(g[i]); i++
        }
        return out.toString()
    }
}
