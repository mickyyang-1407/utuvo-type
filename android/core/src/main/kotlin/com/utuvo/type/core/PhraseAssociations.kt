package com.utuvo.type.core

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * 聯想詞：選完字（或整句送出）之後，建議「接下來最可能的那一段」（例：你好 → 嗎；好 → 像、的…）。
 *
 * 資料由 scripts/build-association-data.py 編出：繁體＝小麥注音自己的 associated-phrases-v2.txt，
 * 簡體＝rime-pinyin-simp 套同一條規則。分數是原詞庫的 log10 機率，同一段前文下分數越高越常接。
 * 跟詞庫一樣以 mmap 開檔、原地二分搜尋，常駐記憶體只有這個物件本身。
 */
class PhraseAssociations private constructor(
    private val buf: ByteBuffer,
    private val count: Int,
    private val indexOffset: Int,
    private val recordsOffset: Int,
) {
    companion object {
        private const val HEADER_SIZE = 20
        /** 前文最多看幾個字（詞表最長的詞也不過十來字，前文再長也不會有命中）。 */
        const val MAXIMUM_CONTEXT_LENGTH = 4
        /** 一段前文最多掃幾筆（最常見的單字約 100 筆；上限只防呆，確保每次查詢時間有界）。 */
        internal const val SCAN_LIMIT = 2_000

        fun open(file: File): PhraseAssociations? = RandomAccessFile(file, "r").use { raf ->
            of(raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length()))
        }

        /** 格式不符回 null。 */
        fun of(data: ByteBuffer): PhraseAssociations? {
            val b = data.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val size = b.capacity()
            if (size < HEADER_SIZE) return null
            if (b.get(0) != 'U'.code.toByte() || b.get(1) != 'T'.code.toByte() ||
                b.get(2) != 'A'.code.toByte() || b.get(3) != 'S'.code.toByte()
            ) return null
            fun u32(o: Int) = b.getInt(o).toLong() and 0xFFFFFFFFL
            if (u32(4) != 1L) return null
            val n = u32(8).toInt(); val idx = u32(12).toInt(); val rec = u32(16).toInt()
            if (idx + 4L * n > size || rec > size) return null
            if (n > 0 && rec + u32(idx + 4 * (n - 1)) + 3 > size) return null
            return PhraseAssociations(b, n, idx, rec)
        }
    }

    /** 詞數（僅供資訊）。 */
    val phraseCount: Int get() = count

    /**
     * 以 `text` 結尾的前文可以接什麼。先用最長的前文（最多 `MAXIMUM_CONTEXT_LENGTH` 字）找，
     * 再用較短的前文補滿；同一段接續只出現一次。回傳的是「要接著插入的字」，不含前文本身。
     */
    fun continuations(text: String, limit: Int): List<String> {
        if (limit <= 0 || text.isEmpty()) return emptyList()
        val chars = ArrayList(text.takeLast(MAXIMUM_CONTEXT_LENGTH).map { it.toString() })
        val out = ArrayList<String>()
        val seen = HashSet<String>()
        for (length in chars.size downTo 1) {
            if (out.size >= limit) break
            val context = chars.subList(chars.size - length, chars.size).joinToString("")
            for (s in continuationsOfPrefix(context)) {
                if (out.size >= limit) break
                if (seen.add(s)) out.add(s)
            }
        }
        return out
    }

    /** 所有以 `prefix` 開頭且比它長的詞，去掉開頭後依分數由高到低（同分照詞表順序）。 */
    internal fun continuationsOfPrefix(prefix: String): List<String> {
        val q = prefix.toByteArray(Charsets.UTF_8)
        var lo = 0
        var hi = count
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (compare(mid, q) < 0) lo = mid + 1 else hi = mid
        }
        class Hit(val text: String, val score: Int, val order: Int)
        val hits = ArrayList<Hit>()
        var i = lo
        while (i < count && hits.size < SCAN_LIMIT) {
            val p = record(i)
            val len = buf.get(p + 2).toInt() and 0xFF
            if (len < q.size || p + 3 + len > buf.capacity()) break
            var match = true
            for (k in q.indices) if (buf.get(p + 3 + k) != q[k]) { match = false; break }
            if (!match) break
            if (len > q.size) {
                val rest = ByteArray(len - q.size) { buf.get(p + 3 + q.size + it) }
                val score = buf.getShort(p).toInt()
                hits.add(Hit(String(rest, Charsets.UTF_8), score, i))
            }
            i += 1
        }
        return hits.sortedWith(compareByDescending<Hit> { it.score }.thenBy { it.order }).map { it.text }
    }

    private fun record(i: Int): Int =
        recordsOffset + (buf.getInt(indexOffset + 4 * i).toLong() and 0xFFFFFFFFL).toInt()

    /** 第 i 筆詞與查詢的位元組序比較（<0＝詞較小）。 */
    private fun compare(i: Int, q: ByteArray): Int {
        val p = record(i)
        val len = buf.get(p + 2).toInt() and 0xFF
        val n = minOf(len, q.size)
        for (j in 0 until n) {
            val a = buf.get(p + 3 + j)
            if (a != q[j]) return if (a < q[j]) -1 else 1
        }
        return len - q.size
    }
}
