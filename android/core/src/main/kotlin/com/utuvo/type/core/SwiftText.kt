package com.utuvo.type.core

import java.text.BreakIterator

/**
 * 讓 Kotlin 的字串處理跟 Swift 版（UTUVOTypeCore）逐字一致的小工具。
 *
 * Swift 的 `Character` 是字形叢集（一個「看得到的字」），Kotlin 的 `Char` 是 UTF-16 單位；
 * 直接用 `String` 索引會把 emoji、罕用字（Extension B+）切成兩半，跟 Swift 的結果不同。
 * 所以凡是 Swift 版用 `Array(text)` 逐字處理的地方，這裡都先切成字形叢集清單。
 */
internal object SwiftText {

    /** 等同 Swift 的 `Array(text)`：字形叢集清單。 */
    fun graphemes(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val it = BreakIterator.getCharacterInstance()
        it.setText(text)
        val out = ArrayList<String>(text.length)
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            out.add(text.substring(start, end))
            start = end
            end = it.next()
        }
        return out
    }

    /** 等同 Swift 的 `text.count`（字形叢集數）。 */
    fun count(text: String): Int = graphemes(text).size

    private fun firstCodePoint(g: String): Int = g.codePointAt(0)

    /** Swift `Character.isLetter`：看第一個 scalar 的 Unicode 類別（L*）。 */
    fun isLetter(g: String): Boolean = g.isNotEmpty() && Character.isLetter(firstCodePoint(g))

    /** Swift `Character.isNumber`：N* 類（含 Nl、No，例如「〇」「Ⅻ」）。 */
    fun isNumber(g: String): Boolean {
        if (g.isEmpty()) return false
        return when (Character.getType(firstCodePoint(g)).toByte()) {
            Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
            else -> false
        }
    }

    /** Swift `Character.isNewline`。 */
    fun isNewline(g: String): Boolean = when (g) {
        "\n", "\r", "\r\n", "", "", "", " ", " " -> true
        else -> false
    }

    /** Foundation `CharacterSet.punctuationCharacters`：Unicode P* 類，字形叢集裡每個 scalar 都要是。 */
    fun isPunctuation(g: String): Boolean {
        if (g.isEmpty()) return false
        var i = 0
        while (i < g.length) {
            val cp = g.codePointAt(i)
            when (Character.getType(cp).toByte()) {
                Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
                Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
                Character.OTHER_PUNCTUATION -> {}
                else -> return false
            }
            i += Character.charCount(cp)
        }
        return true
    }

    /** Foundation `CharacterSet.whitespacesAndNewlines`：Zs＋Tab＋換行類（含不換行空白 U+00A0，Java 的 trim 不含）。 */
    private fun isWhitespaceOrNewline(cp: Int): Boolean {
        if (cp == 0x09 || cp in 0x0A..0x0D || cp == 0x85 || cp == 0x2028 || cp == 0x2029) return true
        return Character.getType(cp).toByte() == Character.SPACE_SEPARATOR
    }

    /** 等同 Swift `trimmingCharacters(in: .whitespacesAndNewlines)`。 */
    fun trim(text: String): String {
        var start = 0
        var end = text.length
        while (start < end) {
            val cp = text.codePointAt(start)
            if (!isWhitespaceOrNewline(cp)) break
            start += Character.charCount(cp)
        }
        while (end > start) {
            val cp = text.codePointBefore(end)
            if (!isWhitespaceOrNewline(cp)) break
            end -= Character.charCount(cp)
        }
        return text.substring(start, end)
    }

    /** 等同 Swift `components(separatedBy:).count - 1`：不重疊出現次數。 */
    fun occurrences(text: String, target: String): Int {
        if (target.isEmpty()) return 0
        var n = 0
        var i = text.indexOf(target)
        while (i >= 0) {
            n++
            i = text.indexOf(target, i + target.length)
        }
        return n
    }
}
