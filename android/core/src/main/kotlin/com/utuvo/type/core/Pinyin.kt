package com.utuvo.type.core

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * 拼音輸入（移植自 Swift `UTUVOTypeCore/Pinyin/` 資料夾）。詞庫 `pinyin.dat`（簡體，rime-pinyin-simp Apache-2.0）
 * 與 `pinyin-hant.dat`（繁體，小麥注音轉拼音）跟 iOS 共用同一份檔案。
 * 行為以 Swift 版為準，由 golden/pinyin.json、golden/pinyin-hant.json 逐條把關。
 *
 * 音節 ID 區間一律用半開區間 [lo, hi)，對應 Swift 的 `Range<UInt16>`。
 */
data class IdRange(val lo: Int, val hi: Int) {
    val count: Int get() = hi - lo
    operator fun contains(id: Int) = id in lo until hi
}

/** 拼音音節表＋切分器；音節 ID＝依字母排序的索引，所以「以某字串開頭的音節」是一段連續區間。 */
class PinyinSyllables(sortedSyllables: List<String>) {
    companion object {
        /** 聲母（含零聲母 y、w）：縮寫輸入時可單獨代表「以它開頭的任何音節」。 */
        val INITIALS = setOf("b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
            "zh", "ch", "sh", "r", "z", "c", "s", "y", "w")
        val ALIASES = mapOf("lve" to "lue", "nve" to "nue")
        const val MAXIMUM_SYLLABLE_LENGTH = 6
    }

    val all: List<String> = sortedSyllables
    private val ids: Map<String, Int>
    private val prefixRanges: Map<String, IdRange>

    init {
        val idMap = HashMap<String, Int>()
        val ranges = HashMap<String, IdRange>()
        for ((i, s) in sortedSyllables.withIndex()) {
            idMap[s] = i
            for (end in 1..s.length) {
                val prefix = s.substring(0, end)
                val r = ranges[prefix]
                ranges[prefix] = if (r == null) IdRange(i, i + 1) else IdRange(minOf(r.lo, i), maxOf(r.hi, i + 1))
            }
        }
        for ((alias, target) in ALIASES) idMap[target]?.let { idMap[alias] = it }
        ids = idMap
        prefixRanges = ranges
    }

    val count: Int get() = all.size
    fun id(syllable: String): Int? = ids[syllable]
    fun isValid(syllable: String) = syllable in ids
    fun range(prefix: String): IdRange? = prefixRanges[prefix]
    fun canStartSyllable(letter: Char) = letter.toString() in prefixRanges

    /** 全部由完整音節組成的切法；音節數少的在前、同數量時照 DFS 順序（最長匹配優先）。 */
    fun segmentations(raw: String, limit: Int = 16): List<List<String>> {
        if (raw.isEmpty() || !raw.all { PinyinEngine.isInputChar(it) }) return emptyList()
        val n = raw.length
        val canFinish = BooleanArray(n + 1)
        canFinish[n] = true
        for (i in n - 1 downTo 0) {
            if (raw[i] == '\'') { canFinish[i] = canFinish[i + 1]; continue }
            for (len in 1..MAXIMUM_SYLLABLE_LENGTH) {
                if (i + len > n) break
                if (raw.substring(i, i + len).contains('\'')) break
                if (isValid(raw.substring(i, i + len)) && canFinish[i + len]) { canFinish[i] = true; break }
            }
        }
        if (!canFinish[0]) return emptyList()
        val results = ArrayList<List<String>>()
        val path = ArrayList<String>()
        val cap = maxOf(limit, 1) * 4
        fun dfs(i: Int) {
            if (results.size >= cap) return
            if (i == n) { results.add(path.toList()); return }
            if (raw[i] == '\'') { dfs(i + 1); return }
            for (len in minOf(MAXIMUM_SYLLABLE_LENGTH, n - i) downTo 1) {
                val s = raw.substring(i, i + len)
                if (s.contains('\'')) continue
                if (!isValid(s) || !canFinish[i + len]) continue
                path.add(s); dfs(i + len); path.removeAt(path.lastIndex)
            }
        }
        dfs(0)
        return results.withIndex().sortedWith(compareBy<IndexedValue<List<String>>> { it.value.size }.thenBy { it.index })
            .map { it.value }.take(limit)
    }
}

/** 拼音詞庫：鍵＝音節 ID 序列；查詢以 ID 區間走訪（聲母縮寫、未打完的尾音節）。 */
class PinyinLexicon private constructor(
    private val buf: ByteBuffer,
    val syllables: PinyinSyllables,
    private val keyCount: Int,
    private val keyIndexOffset: Int,
    private val recordsOffset: Int,
    val maximumPhraseLength: Int,
    val entryCount: Int,
) {
    companion object {
        internal const val SCORE_SCALE = 2000.0
        private const val HEADER_SIZE = 40

        fun open(file: File): PinyinLexicon? = RandomAccessFile(file, "r").use { raf ->
            of(raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length()))
        }

        fun of(data: ByteBuffer): PinyinLexicon? {
            val b = data.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val size = b.capacity()
            if (size < HEADER_SIZE) return null
            fun u32(o: Int) = b.getInt(o).toLong() and 0xFFFFFFFFL
            if (b.get(0) != 'U'.code.toByte() || b.get(1) != 'T'.code.toByte() ||
                b.get(2) != 'P'.code.toByte() || b.get(3) != 'Y'.code.toByte() || u32(4) != 1L
            ) return null
            val nsyl = u32(8).toInt(); val nkey = u32(12).toInt(); val nent = u32(16).toInt()
            val sylOff = u32(20).toInt(); val keyOff = u32(24).toInt(); val recOff = u32(28).toInt(); val maxLen = u32(32).toInt()
            val sylBlob = sylOff + 4 * (nsyl + 1)
            if (nsyl <= 0 || nsyl > 65535 || maxLen < 1 || maxLen > 255 || sylBlob > size ||
                keyOff + 4L * nkey > size || recOff > size ||
                (nkey != 0 && recOff + u32(keyOff + 4 * (nkey - 1)) >= size)
            ) return null
            val table = ArrayList<String>(nsyl)
            for (i in 0 until nsyl) {
                val a = sylBlob + u32(sylOff + 4 * i).toInt()
                val z = sylBlob + u32(sylOff + 4 * (i + 1)).toInt()
                if (a > z || z > size) return null
                val bytes = ByteArray(z - a) { b.get(a + it) }
                val s = String(bytes, Charsets.UTF_8)
                if (s.isEmpty() || !s.all { it in 'a'..'z' } || (table.isNotEmpty() && table.last() >= s)) return null
                table.add(s)
            }
            return PinyinLexicon(b, PinyinSyllables(table), nkey, keyOff, recOff, maxLen, nent)
        }
    }

    val syllableCount: Int get() = syllables.count

    private fun u16(o: Int) = buf.getShort(o).toInt() and 0xFFFF
    private fun s16(o: Int) = buf.getShort(o).toInt()
    private fun u8(o: Int) = buf.get(o).toInt() and 0xFF
    private fun text(o: Int, len: Int) = String(ByteArray(len) { buf.get(o + it) }, Charsets.UTF_8)
    private fun recordPointer(i: Int) = recordsOffset + (buf.getInt(keyIndexOffset + 4 * i).toLong() and 0xFFFFFFFFL).toInt()

    /** 精確音節查詢。 */
    fun lookup(syllableList: List<String>): List<LexiconEntry> {
        val ranges = syllableList.map { s -> syllables.id(s)?.let { IdRange(it, it + 1) } ?: return emptyList() }
        return lookupRanges(ranges)
    }

    /** 每段是「音節前綴」（聲母縮寫、未打完的尾音節）。 */
    fun lookupPrefixes(prefixes: List<String>, limit: Int = Int.MAX_VALUE): List<LexiconEntry> {
        val ranges = prefixes.map { syllables.range(it) ?: return emptyList() }
        return lookupRanges(ranges, limit)
    }

    internal fun lookupRanges(ranges: List<IdRange>, limit: Int = Int.MAX_VALUE): List<LexiconEntry> {
        if (ranges.isEmpty() || limit <= 0) return emptyList()
        data class Hit(val q: Int, val offset: Int, val len: Int)
        val hits = ArrayList<Hit>()
        visitKeys(ranges, exactLength = true) { i ->
            var p = recordPointer(i)
            val n = u8(p)
            p += 1 + 2 * n
            val m = u16(p)
            p += 2
            for (k in 0 until minOf(m, limit)) {
                if (p + 3 > buf.capacity()) break
                val q = s16(p)
                val len = u8(p + 2)
                if (p + 3 + len > buf.capacity()) break
                hits.add(Hit(q, p + 3, len))
                p += 3 + len
            }
            true
        }
        val top = if (hits.size > 1) {
            hits.withIndex().sortedWith(compareByDescending<IndexedValue<Hit>> { it.value.q }.thenBy { it.index })
                .take(limit).map { it.value }
        } else hits
        return top.map { LexiconEntry(text(it.offset, it.len), it.q / SCORE_SCALE) }
    }

    internal fun best(ranges: List<IdRange>): LexiconEntry? {
        if (ranges.isEmpty()) return null
        var bestQ = Short.MIN_VALUE.toInt()
        var bestOffset = -1
        var bestLen = 0
        visitKeys(ranges, exactLength = true) { i ->
            var p = recordPointer(i)
            val n = u8(p)
            p += 1 + 2 * n
            if (u16(p) == 0 || p + 5 > buf.capacity()) return@visitKeys true
            p += 2
            val q = s16(p)
            val len = u8(p + 2)
            if ((bestOffset < 0 || q > bestQ) && p + 3 + len <= buf.capacity()) {
                bestQ = q; bestOffset = p + 3; bestLen = len
            }
            true
        }
        if (bestOffset < 0) return null
        return LexiconEntry(text(bestOffset, bestLen), bestQ / SCORE_SCALE)
    }

    internal fun hasKey(ranges: List<IdRange>): Boolean {
        if (ranges.isEmpty()) return true
        var found = false
        visitKeys(ranges, exactLength = false) { found = true; false }
        return found
    }

    private fun visitKeys(ranges: List<IdRange>, exactLength: Boolean, body: (Int) -> Boolean) {
        visitLevel(ArrayList(ranges.size), ranges, 0, exactLength, body)
    }

    private fun visitLevel(prefix: ArrayList<Int>, rest: List<IdRange>, restStart: Int,
                           exactLength: Boolean, body: (Int) -> Boolean): Boolean {
        if (restStart >= rest.size) {
            val i = lowerBound(prefix)
            if (i >= keyCount) return true
            val c = compareKey(i, prefix)
            if (c == EQUAL || (!exactLength && c == QUERY_IS_PREFIX)) return body(i)
            return true
        }
        val r = rest[restStart]
        prefix.add(r.lo)
        val a = lowerBound(prefix)
        prefix[prefix.lastIndex] = r.hi
        val b = if (r.hi == 65535) keyCount else lowerBound(prefix)
        prefix.removeAt(prefix.lastIndex)
        if (a >= b) return true

        if (r.count == 1) {
            prefix.add(r.lo)
            try { return visitLevel(prefix, rest, restStart + 1, exactLength, body) } finally { prefix.removeAt(prefix.lastIndex) }
        }
        if (b - a <= 48) {
            val depth = prefix.size
            val total = depth + (rest.size - restStart)
            for (i in a until b) {
                val p = recordPointer(i)
                val n = u8(p)
                if (if (exactLength) n != total else n < total) continue
                var ok = true
                var k = depth
                for (ri in restStart until rest.size) {
                    if (u16(p + 1 + 2 * k) !in rest[ri]) { ok = false; break }
                    k++
                }
                if (ok && !body(i)) return false
            }
            return true
        }
        for (id in r.lo until r.hi) {
            prefix.add(id)
            val go = visitLevel(prefix, rest, restStart + 1, exactLength, body)
            prefix.removeAt(prefix.lastIndex)
            if (!go) return false
        }
        return true
    }

    private fun compareKey(i: Int, q: List<Int>): Int {
        val p = recordPointer(i)
        val n = u8(p)
        var j = 0
        var qi = 0
        while (j < n && qi < q.size) {
            val k = u16(p + 1 + 2 * j)
            val v = q[qi]
            if (k < v) return LESS
            if (k > v) return GREATER
            j++; qi++
        }
        if (j == n && qi == q.size) return EQUAL
        if (j == n) return LESS
        return QUERY_IS_PREFIX
    }

    private fun lowerBound(q: List<Int>): Int {
        var lo = 0
        var hi = keyCount
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (compareKey(mid, q) == LESS) lo = mid + 1 else hi = mid
        }
        return lo
    }
}

data class PinyinCandidate(val text: String, val consumed: Int)

/** 拼音引擎：a–z 與分隔號 '；聲母縮寫（nh→你好）、未打完的尾音節（nih）；整句 Viterbi。 */
class PinyinEngine(val lexicon: PinyinLexicon) {
    companion object {
        const val CANDIDATE_LIMIT = 60
        const val PHRASE_CANDIDATE_LIMIT = 30
        const val MAXIMUM_BUFFER_LENGTH = 64
        const val PARTIAL_PENALTY = 1.5
        internal const val RAW_PENALTY = 99.0
        const val APOSTROPHE = '\''

        fun isInputChar(c: Char) = c in 'a'..'z' || c == APOSTROPHE
    }

    private val raw = StringBuilder()
    private var cached: Pair<String, Analysis>? = null

    val composing: String get() = raw.toString()
    val isEmpty: Boolean get() = raw.isEmpty()

    /** 打一個字母或 '；不接受的回 false（大寫、數字、在音節開頭打 i／u／v、連打 '、緩衝區滿）。 */
    fun type(letter: Char): Boolean {
        if (!isInputChar(letter) || raw.length >= MAXIMUM_BUFFER_LENGTH) return false
        val atSegmentStart = raw.isEmpty() || raw.last() == APOSTROPHE
        if (letter == APOSTROPHE) {
            if (atSegmentStart) return false
        } else if (atSegmentStart) {
            if (!lexicon.syllables.canStartSyllable(letter)) return false
        }
        raw.append(letter)
        return true
    }

    fun backspace(): Boolean {
        if (raw.isEmpty()) return false
        raw.setLength(raw.length - 1)
        return true
    }

    fun reset() { raw.setLength(0) }

    val preedit: String get() = analysis().walk.joinToString("") { it.text }

    val bestSegmentation: List<String> get() = analysis().walk.flatMap { it.pieces }

    fun segment(text: String): List<String> {
        if (text.isEmpty() || !text.all(::isInputChar)) return emptyList()
        return Analysis(text, lexicon).walk.flatMap { it.pieces }
    }

    val candidates: List<PinyinCandidate> get() = candidates(CANDIDATE_LIMIT)

    /** 只計算呼叫端實際要顯示的候選數，避免每按一鍵都整理 60 個候選。 */
    fun candidates(limit: Int): List<PinyinCandidate> = analysis().candidates(lexicon, limit)

    fun select(candidate: PinyinCandidate): String {
        if (candidate.consumed <= 0 || candidate.consumed > raw.length) return ""
        raw.delete(0, candidate.consumed)
        while (raw.isNotEmpty() && raw[0] == APOSTROPHE) raw.deleteCharAt(0)
        return candidate.text
    }

    fun commitAll(): String {
        val text = analysis().walk.joinToString("") { it.text }
        raw.setLength(0)
        return text
    }

    private fun analysis(): Analysis {
        val key = raw.toString()
        cached?.let { if (it.first == key) return it.second }
        return Analysis(key, lexicon).also { cached = key to it }
    }

    internal class Token(val end: Int, val next: Int, val range: IdRange, val partial: Boolean, val letters: String)
    internal class Segment(val text: String, val pieces: List<String>)

    internal class Analysis(private val raw: String, lexicon: PinyinLexicon) {
        val count = raw.length
        val start: Int
        val tokens: Array<MutableList<Token>>
        val walk: List<Segment>
        private val maxLength = lexicon.maximumPhraseLength

        private fun skip(i: Int): Int {
            var j = i
            while (j < count && raw[j] == APOSTROPHE) j++
            return j
        }

        init {
            val n = count
            start = skip(0)
            val syl = lexicon.syllables
            tokens = Array(n + 1) { mutableListOf() }
            for (i in 0 until n) {
                if (raw[i] == APOSTROPHE) continue
                for (len in 1..PinyinSyllables.MAXIMUM_SYLLABLE_LENGTH) {
                    if (i + len > n) break
                    if (raw[i + len - 1] == APOSTROPHE) break
                    val s = raw.substring(i, i + len)
                    val next = skip(i + len)
                    val id = syl.id(s)
                    val prefixRange = syl.range(s)
                    if (id == null && prefixRange == null) break
                    if (id != null) tokens[i].add(Token(i + len, next, IdRange(id, id + 1), false, s))
                    if (prefixRange != null && (prefixRange.count > 1 || id == null) &&
                        (s in PinyinSyllables.INITIALS || i + len == n)
                    ) tokens[i].add(Token(i + len, next, prefixRange, true, s))
                }
                // 能讀出更長的完整音節時，較短的縮寫不算
                val longestExact = tokens[i].filter { !it.partial }.maxOfOrNull { it.end - i } ?: 0
                tokens[i].removeAll { it.partial && it.end - i < longestExact }
            }
            walk = viterbi(lexicon)
        }

        private fun viterbi(lexicon: PinyinLexicon): List<Segment> {
            val n = count
            if (start >= n) return emptyList()
            val maxLen = lexicon.maximumPhraseLength
            val best = DoubleArray(n + 1) { Double.NEGATIVE_INFINITY }
            val backFrom = IntArray(n + 1) { -1 }
            val backSeg = arrayOfNulls<Segment>(n + 1)
            best[start] = 0.0
            val ranges = ArrayList<IdRange>()
            val pieces = ArrayList<String>()
            for (i in start until n) {
                if (best[i] == Double.NEGATIVE_INFINITY || raw[i] == APOSTROPHE) continue
                fun extend(pos: Int, penalty: Double) {
                    for (t in tokens[pos]) {
                        ranges.add(t.range); pieces.add(t.letters)
                        try {
                            if (!lexicon.hasKey(ranges)) continue
                            val p = penalty - (if (t.partial) PARTIAL_PENALTY else 0.0)
                            lexicon.best(ranges)?.let { top ->
                                val score = best[i] + top.score + p
                                if (score > best[t.next]) {
                                    best[t.next] = score
                                    backFrom[t.next] = i
                                    backSeg[t.next] = Segment(top.text, pieces.toList())
                                }
                            }
                            if (ranges.size < maxLen) extend(t.next, p)
                        } finally {
                            ranges.removeAt(ranges.lastIndex); pieces.removeAt(pieces.lastIndex)
                        }
                    }
                }
                extend(i, 0.0)
                val j = skip(i + 1)
                val score = best[i] - RAW_PENALTY
                if (score > best[j]) {
                    best[j] = score
                    backFrom[j] = i
                    backSeg[j] = Segment(raw.substring(i, j), listOf(raw.substring(i, i + 1)))
                }
            }
            val out = ArrayList<Segment>()
            var pos = n
            while (pos > start) {
                val seg = backSeg[pos] ?: break
                out.add(seg)
                pos = backFrom[pos]
            }
            return out.asReversed()
        }

        fun candidates(lexicon: PinyinLexicon, requestedLimit: Int = CANDIDATE_LIMIT): List<PinyinCandidate> {
            val limit = minOf(maxOf(requestedLimit, 0), CANDIDATE_LIMIT)
            val n = count
            if (start >= n || limit <= 0) return emptyList()
            val reach = BooleanArray(n + 1)
            reach[start] = true
            var far = start
            for (i in start until n) {
                if (!reach[i]) continue
                for (t in tokens[i]) { reach[t.next] = true; far = maxOf(far, t.next) }
            }
            val viable = BooleanArray(n + 1)
            viable[far] = true
            for (i in far - 1 downTo start) viable[i] = tokens[i].any { it.next <= far && viable[it.next] }

            class Hit(val text: String, val consumed: Int, val score: Double, val isPhrase: Boolean, val order: Int)
            val hits = ArrayList<Hit>()
            val index = HashMap<String, Int>()
            val ranges = ArrayList<IdRange>()
            fun extend(pos: Int, penalty: Double) {
                for (t in tokens[pos]) {
                    if (t.next > far || !viable[t.next]) continue
                    ranges.add(t.range)
                    try {
                        if (!lexicon.hasKey(ranges)) continue
                        val p = penalty - (if (t.partial) PARTIAL_PENALTY else 0.0)
                        val isPhrase = ranges.size > 1
                        val lookupLimit = if (isPhrase) minOf(PHRASE_CANDIDATE_LIMIT, limit) else limit
                        for (e in lexicon.lookupRanges(ranges, lookupLimit)) {
                            val key = "${t.next}|${e.text}"
                            val s = e.score + p
                            val k = index[key]
                            if (k != null) {
                                if (s > hits[k].score) hits[k] = Hit(e.text, t.next, s, isPhrase, hits[k].order)
                            } else {
                                index[key] = hits.size
                                hits.add(Hit(e.text, t.next, s, isPhrase, hits.size))
                            }
                        }
                        if (ranges.size < maxLength) extend(t.next, p)
                    } finally {
                        ranges.removeAt(ranges.lastIndex)
                    }
                }
            }
            extend(start, 0.0)

            val ordered = compareByDescending<Hit> { it.consumed }.thenByDescending { it.score }.thenBy { it.order }
            val phraseLimit = minOf(PHRASE_CANDIDATE_LIMIT, limit)
            val phrases = hits.filter { it.isPhrase }.sortedWith(ordered).take(phraseLimit)
            val singles = hits.filter { !it.isPhrase }.sortedWith(ordered)
            val room = limit - phrases.size
            val levels = singles.map { it.consumed }.toSet().size
            val picked = ArrayList<Hit>()
            val rest = ArrayList<Hit>()
            if (levels > 0) {
                val quota = maxOf(8, room / levels)
                val used = HashMap<Int, Int>()
                for (h in singles) {
                    val u = used.getOrDefault(h.consumed, 0)
                    if (u < quota) { used[h.consumed] = u + 1; picked.add(h) } else rest.add(h)
                }
            }
            val chosenSingles = (picked.sortedWith(ordered).take(room) + rest).take(room)
            return (phrases + chosenSingles).sortedWith(ordered).take(limit)
                .map { PinyinCandidate(it.text, it.consumed) }
        }
    }
}
