package com.utuvo.type.core

/** 輸出形狀修整（同 Swift OutputShape）。 */
object OutputShape {
    private val inlineOrdinal = Regex("""(?:^|(?<=[ \t，,、：:；;]))([1-9][0-9]{0,2})[.、)](?![0-9])[ \t]*""")
    private val itemBridge = Regex("""(還有(?:最重要的)?|以及|最重要的)[ \t]*$""")

    /** Expand only an explicit contiguous 1…N list, preserving all item words and values. Same as Swift. */
    fun expandingInlineNumberedList(text: String): String {
        if ('\n' in text || '`' in text) return text
        val markers = inlineOrdinal.findAll(text).toList()
        if (markers.size < 2 || markers.withIndex().any { (i, m) -> m.groupValues[1].toIntOrNull() != i + 1 }) return text
        val bodies = markers.mapIndexed { i, m ->
            text.substring(m.range.last + 1, markers.getOrNull(i + 1)?.range?.first ?: text.length).trim(' ', '\t')
        }.toMutableList()
        if (bodies.any { it.isEmpty() }) return text
        for (i in 0 until bodies.lastIndex) {
            val bridge = itemBridge.find(bodies[i]) ?: continue
            val before = bodies[i].substring(0, bridge.range.first).trim(' ', '\t')
            if (before.isEmpty()) continue
            bodies[i] = before
            bodies[i + 1] = bridge.value.trim(' ', '\t') + bodies[i + 1]
        }
        var intro = text.substring(0, markers.first().range.first).trim(' ', '\t')
        if (intro.isNotEmpty() && !intro.endsWith(':') && !intro.endsWith('：')) intro += "："
        val lines = bodies.mapIndexed { i, body -> "${i + 1}. $body" }
        return (if (intro.isEmpty()) lines else listOf(intro) + lines).joinToString("\n")
    }

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
                if (before != null && after != null && before.code < 128 && !before.isWhitespace() && after.code < 128 && after.isLetterOrDigit()) {
                    out.append(' ')
                } else if (out.isNotEmpty() && endsWithLetterOrNumber(out) && startsNumberedItem(g, j)) {
                    // 編號清單接成一行（同 Swift，2026-10-22 W2-6）：「買牛奶\n2. 回信」→「買牛奶 2. 回信」。
                    out.append(' ')
                }
                i = j
                continue
            }
            out.append(g[i]); i++
        }
        return out.toString()
    }

    /** 最後一個字（字形叢集的第一個 scalar）是字母或數字：同 Swift `Character.isLetter || isNumber`。 */
    private fun endsWithLetterOrNumber(out: StringBuilder): Boolean {
        val last = SwiftText.graphemes(out.toString()).lastOrNull() ?: return false
        return SwiftText.isLetter(last) || SwiftText.isNumber(last)
    }

    /** 從 `index` 開始是「數字＋. ＋空白」（編號清單的一項）。 */
    private fun startsNumberedItem(g: List<String>, index: Int): Boolean {
        var k = index
        while (k < g.size && g[k].length == 1 && g[k][0] in '0'..'9') k++
        return k > index && k + 1 < g.size && g[k] == "." && g[k + 1] == " "
    }
}
