package com.utuvo.type.core

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.TreeMap

/**
 * 注音輸入（移植自 Swift `UTUVOTypeCore/Zhuyin/` 資料夾）。詞庫檔 `zhuyin.dat` 與 iOS 共用同一份，
 * 由 scripts/build-zhuyin-data.py 從小麥注音 McBopomofo 資料（MIT）編出；格式見該腳本檔頭。
 * 行為以 Swift 版為準，由 golden/zhuyin.json 逐條把關。
 */

/** 注音單一音節的組字器：聲母＋介音＋韻母＋聲調，同槽再打＝取代。 */
class ZhuyinComposer {
    enum class Slot { CONSONANT, MEDIAL, RIME, TONE }

    var consonant: Char? = null; private set
    var medial: Char? = null; private set
    var rime: Char? = null; private set

    val isEmpty: Boolean get() = consonant == null && medial == null && rime == null

    val composing: String
        get() = buildString { consonant?.let(::append); medial?.let(::append); rime?.let(::append) }

    fun insert(symbol: Char): Boolean {
        when (slot(symbol)) {
            Slot.CONSONANT -> consonant = symbol
            Slot.MEDIAL -> medial = symbol
            Slot.RIME -> rime = symbol
            Slot.TONE, null -> return false
        }
        return true
    }

    /** 以指定聲調組出音節字串（一聲傳 null 或「ˉ」）。空的回 null。不清空槽位。 */
    fun syllable(tone: Char?): String? {
        if (isEmpty) return null
        val s = StringBuilder(composing)
        if (tone != null && tone != FIRST_TONE_MARK) {
            if (tone !in TONE_MARKS) return null
            s.append(tone)
        }
        return s.toString()
    }

    /** 刪最後一個符號（韻母 → 介音 → 聲母）。 */
    fun backspace(): Boolean {
        if (rime != null) { rime = null; return true }
        if (medial != null) { medial = null; return true }
        if (consonant != null) { consonant = null; return true }
        return false
    }

    fun clear() { consonant = null; medial = null; rime = null }

    fun copy(): ZhuyinComposer = ZhuyinComposer().also {
        it.consonant = consonant; it.medial = medial; it.rime = rime
    }

    override fun equals(other: Any?): Boolean =
        other is ZhuyinComposer && other.consonant == consonant && other.medial == medial && other.rime == rime

    override fun hashCode(): Int =
        (consonant?.hashCode() ?: 0) * 31 * 31 + (medial?.hashCode() ?: 0) * 31 + (rime?.hashCode() ?: 0)

    override fun toString(): String = "ZhuyinComposer($composing)"

    companion object {
        val CONSONANTS = "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ".toSet()
        val MEDIALS = "ㄧㄨㄩ".toSet()
        val RIMES = "ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ".toSet()
        /** 二、三、四、輕聲；一聲不標記，「ˉ」也當一聲收尾。 */
        val TONE_MARKS = "ˊˇˋ˙".toSet()
        const val FIRST_TONE_MARK = 'ˉ'

        fun slot(symbol: Char): Slot? = when (symbol) {
            in CONSONANTS -> Slot.CONSONANT
            in MEDIALS -> Slot.MEDIAL
            in RIMES -> Slot.RIME
            in TONE_MARKS, FIRST_TONE_MARK -> Slot.TONE
            else -> null
        }
    }
}

data class LexiconEntry(val text: String, val score: Double)

/** 鍵比較結果（注音、拼音詞庫共用）：鍵 < 查詢＝LESS；查詢是鍵的前綴＝QUERY_IS_PREFIX（排序上算 greater）。 */
internal const val LESS = 0
internal const val EQUAL = 1
internal const val GREATER = 2
internal const val QUERY_IS_PREFIX = 3

/** 注音詞庫：原地二分搜尋 ByteBuffer（Android 上是 mmap 的 APK 資源），不把詞庫讀進 Map。 */
class ZhuyinLexicon private constructor(
    private val buf: ByteBuffer,
    private val syllables: List<String>,
    private val syllableIds: Map<String, Int>,
    private val keyCount: Int,
    private val keyIndexOffset: Int,
    private val recordsOffset: Int,
    val entryCount: Int,
) {
    companion object {
        /** 小麥注音 walk 的最大跨度（Gramambular 的 kMaximumSpanLength）。 */
        const val MAXIMUM_PHRASE_LENGTH = 8
        internal const val SCORE_SCALE = 2000.0

        fun open(file: File): ZhuyinLexicon? = RandomAccessFile(file, "r").use { raf ->
            of(raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length()))
        }

        /** 格式不符回 null。 */
        fun of(data: ByteBuffer): ZhuyinLexicon? {
            val b = data.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val size = b.capacity()
            if (size < 32) return null
            fun u32(o: Int) = b.getInt(o).toLong() and 0xFFFFFFFFL
            if (b.get(0) != 'U'.code.toByte() || b.get(1) != 'T'.code.toByte() ||
                b.get(2) != 'Z'.code.toByte() || b.get(3) != 'Y'.code.toByte() || u32(4) != 1L
            ) return null
            val nsyl = u32(8).toInt(); val nkey = u32(12).toInt(); val nent = u32(16).toInt()
            val sylOff = u32(20).toInt(); val keyOff = u32(24).toInt(); val recOff = u32(28).toInt()
            val sylBlob = sylOff + 4 * (nsyl + 1)
            if (nsyl <= 0 || nsyl > 65536 || sylBlob > size || keyOff + 4L * nkey > size || recOff > size) return null
            val table = ArrayList<String>(nsyl)
            val ids = HashMap<String, Int>(nsyl * 2)
            for (i in 0 until nsyl) {
                val a = sylBlob + u32(sylOff + 4 * i).toInt()
                val z = sylBlob + u32(sylOff + 4 * (i + 1)).toInt()
                if (a > z || z > size) return null
                val s = utf8(b, a, z - a)
                table.add(s)
                ids[s] = i
            }
            return ZhuyinLexicon(b, table, ids, nkey, keyOff, recOff, nent)
        }

        private fun utf8(b: ByteBuffer, offset: Int, len: Int): String {
            val bytes = ByteArray(len)
            for (i in 0 until len) bytes[i] = b.get(offset + i)
            return String(bytes, Charsets.UTF_8)
        }
    }

    val syllableCount: Int get() = syllables.size

    fun isValidSyllable(syllable: String) = syllable in syllableIds

    fun syllableId(syllable: String): Int? = syllableIds[syllable]

    internal fun syllable(id: Int): String = syllables.getOrElse(id) { "" }

    private fun ids(readings: List<String>): IntArray? {
        val out = IntArray(readings.size)
        for ((i, r) in readings.withIndex()) out[i] = syllableIds[r] ?: return null
        return out
    }

    /** 精確讀音查詢，最佳分數在前（小麥注音的 log10 機率）。 */
    fun lookup(readings: List<String>): List<LexiconEntry> {
        if (readings.isEmpty()) return emptyList()
        return lookup(ids(readings) ?: return emptyList(), 0, readings.size)
    }

    fun hasPhrase(withPrefix: List<String>): Boolean {
        if (withPrefix.isEmpty()) return false
        val ids = ids(withPrefix) ?: return false
        return hasKey(ids, 0, ids.size)
    }

    /** 不分聲調查詢：沒有聲調記號的音節展開成五種，組合上限 125，同詞取最高分、最佳在前（同分保留先出現的）。 */
    fun lookupIgnoringTone(readings: List<String>): List<LexiconEntry> {
        if (readings.isEmpty()) return emptyList()
        var combos: List<IntArray> = listOf(IntArray(0))
        for (r in readings) {
            val hasTone = r.lastOrNull()?.let { it in ZhuyinComposer.TONE_MARKS } ?: false
            val variants = if (hasTone) listOf(r) else listOf(r, r + "ˊ", r + "ˇ", r + "ˋ", r + "˙")
            val vids = variants.mapNotNull { syllableIds[it] }
            if (vids.isEmpty()) return emptyList()
            val next = ArrayList<IntArray>()
            for (c in combos) for (v in vids) if (next.size < 125) next.add(c + v)
            combos = next
        }
        val best = LinkedHashMap<String, Double>()
        for (c in combos) for (e in lookup(c, 0, c.size)) {
            val old = best[e.text]
            if (old == null || e.score > old) best[e.text] = e.score
        }
        return best.entries.withIndex()
            .sortedWith(compareByDescending<IndexedValue<Map.Entry<String, Double>>> { it.value.value }.thenBy { it.index })
            .map { LexiconEntry(it.value.key, it.value.value) }
    }

    // ── 音節 ID 介面（引擎內部用）──

    internal fun lookup(ids: IntArray, from: Int, to: Int, limit: Int = Int.MAX_VALUE): List<LexiconEntry> {
        val i = lowerBound(ids, from, to)
        if (i >= keyCount || compareKey(i, ids, from, to) != EQUAL) return emptyList()
        var p = recordPointer(i)
        val n = buf.get(p).toInt() and 0xFF
        p += 1 + 2 * n
        val m = buf.getShort(p).toInt() and 0xFFFF
        p += 2
        val count = minOf(m, limit)
        val out = ArrayList<LexiconEntry>(count)
        repeat(count) {
            if (p + 3 > buf.capacity()) return out
            val q = buf.getShort(p).toInt()            // Int16 帶正負號
            val len = buf.get(p + 2).toInt() and 0xFF
            p += 3
            if (p + len > buf.capacity()) return out
            out.add(LexiconEntry(utf8(buf, p, len), q / SCORE_SCALE))
            p += len
        }
        return out
    }

    internal fun best(ids: IntArray, from: Int, to: Int): LexiconEntry? = lookup(ids, from, to, 1).firstOrNull()

    /** 第 `keyIndex` 把鍵的詞條（最佳在前）。鍵索引來自 `forEachKey(matching:…)`。 */
    internal fun entriesAt(keyIndex: Int, limit: Int = Int.MAX_VALUE): List<LexiconEntry> {
        if (keyIndex < 0 || keyIndex >= keyCount) return emptyList()
        var p = recordPointer(keyIndex)
        val n = buf.get(p).toInt() and 0xFF
        p += 1 + 2 * n
        val m = buf.getShort(p).toInt() and 0xFFFF
        p += 2
        val out = ArrayList<LexiconEntry>(minOf(m, limit))
        repeat(minOf(m, limit)) {
            if (p + 3 > buf.capacity()) return out
            val q = buf.getShort(p).toInt()            // Int16 帶正負號
            val len = buf.get(p + 2).toInt() and 0xFF
            p += 3
            if (p + len > buf.capacity()) return out
            out.add(LexiconEntry(utf8(buf, p, len), q / SCORE_SCALE))
            p += len
        }
        return out
    }

    /** 第 `keyIndex` 把鍵最佳詞條的分數（不解字串；排序、剪枝用）。 */
    internal fun topScoreAt(keyIndex: Int): Double? {
        if (keyIndex < 0 || keyIndex >= keyCount) return null
        var p = recordPointer(keyIndex)
        p += 1 + 2 * (buf.get(p).toInt() and 0xFF)
        val n = buf.getShort(p).toInt() and 0xFFFF
        if (n <= 0 || p + 4 > buf.capacity()) return null
        return buf.getShort(p + 2).toDouble() / SCORE_SCALE
    }

    /**
     * 列出所有「長度 1…maxLength、第 d 個音節落在 `sets[d]` 裡」的讀音鍵。`sets[d]` 必須由小到大、不重複。
     *
     * 不逐一試遍 sets 的所有組合（三個聲母縮寫就是上百萬種）：以某段讀音開頭的鍵在索引裡是連續一段，
     * 段內下一個音節 ID 也由小到大，所以每層在「段內實際出現的 ID」與 `sets[d]` 之間交替二分（leapfrog），
     * 只走詞庫裡真的存在的前綴。`visit(keyIndex, path, topScore)` 的 `path[d]`＝第 d 個音節在 `sets[d]` 裡的位置；
     * 走訪超過 `nodeBudget` 步就停（回 false），確保最壞情況下每次按鍵的時間有界。
     */
    internal fun forEachKey(
        sets: List<IntArray>,
        maxLength: Int,
        nodeBudget: Int = 20_000,
        visit: (keyIndex: Int, path: IntArray, topScore: Double) -> Unit,
    ): Boolean {
        val depthLimit = minOf(maxLength, sets.size)
        if (depthLimit <= 0 || keyCount == 0) return true
        var budget = nodeBudget
        val path = ArrayList<Int>(depthLimit)

        fun element(i: Int, d: Int): Int = buf.getShort(recordPointer(i) + 1 + 2 * d).toInt() and 0xFFFF

        /** 段 [lo, hi) 內第一把「第 d 個音節 ≥ v」（strict 時 > v）的鍵；段內鍵的長度都 > d。 */
        fun bound(d: Int, v: Int, lo0: Int, hi0: Int, strict: Boolean): Int {
            var lo = lo0
            var hi = hi0
            while (lo < hi) {
                val mid = (lo + hi) ushr 1
                val e = element(mid, d)
                if (e < v || (strict && e == v)) lo = mid + 1 else hi = mid
            }
            return lo
        }

        fun walk(d: Int, lo0: Int, hi0: Int): Boolean {
            var i = lo0
            // 段內第一把可能就是前綴本身（前綴排在所有更長的鍵前面）
            if (d > 0 && i < hi0) {
                val p = recordPointer(i)
                if ((buf.get(p).toInt() and 0xFF) == d) {
                    val q = p + 1 + 2 * d
                    if ((buf.getShort(q).toInt() and 0xFFFF) > 0) {
                        visit(i, path.toIntArray(), buf.getShort(q + 2).toDouble() / SCORE_SCALE)
                    }
                    i += 1
                }
            }
            if (d >= depthLimit) return true
            val set = sets[d]
            var si = 0
            while (i < hi0 && si < set.size) {
                budget -= 1
                if (budget < 0) return false
                val v = element(i, d)
                if (set[si] < v) {
                    // set 裡第一個 ≥ v
                    var a = si + 1
                    var b = set.size
                    while (a < b) { val m = (a + b) ushr 1; if (set[m] < v) a = m + 1 else b = m }
                    si = a
                    if (si >= set.size) break
                }
                val s = set[si]
                if (s == v) {
                    val j = bound(d, v, i, hi0, strict = true)
                    path.add(si)
                    val ok = walk(d + 1, i, j)
                    path.removeAt(path.size - 1)
                    if (!ok) return false
                    i = j
                    si += 1
                } else {
                    i = bound(d, s, i, hi0, strict = false)
                }
            }
            return true
        }

        return walk(0, 0, keyCount)
    }

    internal fun hasKey(ids: IntArray, from: Int, to: Int): Boolean {
        val i = lowerBound(ids, from, to)
        if (i >= keyCount) return false
        val c = compareKey(i, ids, from, to)
        return c == EQUAL || c == QUERY_IS_PREFIX
    }

    private fun recordPointer(i: Int): Int =
        recordsOffset + (buf.getInt(keyIndexOffset + 4 * i).toLong() and 0xFFFFFFFFL).toInt()

    /** 第 i 把鍵相對於查詢 ids[from, to) 的順序。 */
    private fun compareKey(i: Int, q: IntArray, from: Int, to: Int): Int {
        val p = recordPointer(i)
        val n = buf.get(p).toInt() and 0xFF
        var j = 0
        var qi = from
        while (j < n && qi < to) {
            val k = buf.getShort(p + 1 + 2 * j).toInt() and 0xFFFF
            val v = q[qi]
            if (k < v) return LESS
            if (k > v) return GREATER
            j++; qi++
        }
        if (j == n && qi == to) return EQUAL
        if (j == n) return LESS
        return QUERY_IS_PREFIX
    }

    private fun lowerBound(q: IntArray, from: Int, to: Int): Int {
        var lo = 0
        var hi = keyCount
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (compareKey(mid, q, from, to) == LESS) lo = mid + 1 else hi = mid
        }
        return lo
    }

}

