package com.utuvo.type.core

import java.util.TreeMap

/** 選字候選：`readingCount` 是它從緩衝區開頭吃掉幾個音節（含還在組、沒收尾的最後一個）。 */
data class ZhuyinCandidate(val text: String, val readingCount: Int)

/**
 * 注音輸入引擎：緩衝區＝一串音節段＋正在組的音節 `composing`。
 * 音節段有兩種：已收尾（打了聲調鍵或空白）、沒收尾（被「放不進目前這個音節」的符號擠開）。
 * 沒收尾的段比對所有相容的音節、不分聲調（ㄋ → ㄋㄧˇ、ㄋㄚˋ…；ㄋㄧ → ㄋㄧˇ、ㄋㄧㄢˊ…），
 * 所以 ㄋㄏ → 你好（簡拼）、ㄋㄧㄏㄠ → 你好（不打聲調）。
 *
 * 整句轉換用 Viterbi（DAG 最長路徑）走「讀音網格」：每個起點最多延伸 8 個音節，
 * 節點分數取該讀音在詞庫中的最高分，路徑分數為節點分數相加。概念參考小麥注音的 Gramambular（MIT），
 * 程式碼為本專案自行撰寫。
 *
 * 鍵盤只在主執行緒用，所以沒有鎖（Swift 版的鎖是為了 Sendable）。
 */
class ZhuyinEngine(val lexicon: ZhuyinLexicon) {
    companion object {
        /** 候選數上限。 */
        const val CANDIDATE_LIMIT = 60
        /** 多字詞候選最多佔幾格，保證單字候選一定排得進來。 */
        const val PHRASE_CANDIDATE_LIMIT = 30
        /** 沒收尾的音節比對到「比打出來的多幾個符號」的音節時扣的分數（log10）。與拼音縮寫同一個值。 */
        const val PARTIAL_PENALTY = PinyinEngine.PARTIAL_PENALTY
        /** 查不到任何音節的段以原樣墊過去，每段扣的分數。 */
        internal const val RAW_PENALTY = 99.0
        /** 每次列舉讀音鍵的步數上限（很多個聲母縮寫連打時限制最壞情況的每鍵時間）。 */
        internal const val WALK_NODE_BUDGET = 5_000
        internal const val CANDIDATE_NODE_BUDGET = 20_000
    }

    /** 一個音節位置可以對到哪些音節（ID 由小到大）與各自的扣分。 */
    internal class Node(val ids: IntArray, val penalties: DoubleArray, val raw: String) {
        override fun equals(other: Any?): Boolean =
            other is Node && ids.contentEquals(other.ids) && penalties.contentEquals(other.penalties) && raw == other.raw
        override fun hashCode(): Int = (ids.contentHashCode() * 31 + penalties.contentHashCode()) * 31 + raw.hashCode()
    }

    /** 緩衝區裡的一個音節段。 */
    internal class Segment(val node: Node, val isComplete: Boolean, val composer: ZhuyinComposer) {
        fun copy() = Segment(node, isComplete, composer.copy())
        override fun equals(other: Any?): Boolean =
            other is Segment && node == other.node && isComplete == other.isComplete && composer == other.composer
        override fun hashCode(): Int = (node.hashCode() * 31 + isComplete.hashCode()) * 31 + composer.hashCode()
    }

    /** 引擎狀態的快照（取消輸入時還原用）。只能交回同一個詞庫的引擎。 */
    internal class State constructor(internal val segments: List<Segment>, internal val composer: ZhuyinComposer) {
        override fun equals(other: Any?): Boolean =
            other is State && segments == other.segments && composer == other.composer
        override fun hashCode(): Int = segments.hashCode() * 31 + composer.hashCode()
    }

    private class Shape(val consonant: Char?, val medial: Char?, val rime: Char?)

    private val segments = ArrayList<Segment>()
    private val composer = ZhuyinComposer()
    /** 音節 ID → 聲母／介音／韻母（比對沒收尾的音節用）。 */
    private val shapes: Array<Shape> = Array(lexicon.syllableCount) { id ->
        val c = ZhuyinComposer()
        for (ch in lexicon.syllable(id)) c.insert(ch)
        Shape(c.consonant, c.medial, c.rime)
    }
    private val partialCache = HashMap<String, Node>()
    private val walkCache = HashMap<List<Node>, String>()

    /** 緩衝區裡的音節段（沒收尾的段照打的樣子）。不含正在組的音節。 */
    val readings: List<String> get() = segments.map { it.node.raw }

    /** 正在組的音節符號（尚未收尾）。 */
    val composing: String get() = composer.composing

    val isEmpty: Boolean get() = segments.isEmpty() && composer.isEmpty

    /** 緩衝區裡有沒收尾的音節段（簡拼或沒打聲調）。這時空白鍵不當一聲，而是送出整句。 */
    val hasUncompletedSyllables: Boolean get() = segments.any { !it.isComplete }

    internal val state: State get() = State(segments.map { it.copy() }, composer.copy())

    internal fun restore(state: State) {
        segments.clear()
        segments.addAll(state.segments.map { it.copy() })
        setComposer(state.composer.copy())
    }

    // ── 輸入 ──

    /**
     * 打一個注音符號或聲調記號。回 false＝這個符號沒有被接受（非注音符號、空的時候打聲調、不合法音節）。
     * 放不進正在組的音節時（例：已有 ㄋ 再打 ㄏ、已有 ㄠ 再打 ㄧ），把它擠成「沒收尾」的一段、另起新音節。
     */
    fun type(symbol: Char): Boolean {
        val slot = ZhuyinComposer.slot(symbol) ?: return false
        if (slot == ZhuyinComposer.Slot.TONE) return completeSyllable(symbol)
        if (startsNewSyllable(slot)) {
            segments.add(Segment(partialNode(composer.copy()), false, composer.copy()))
            composer.clear()
        }
        return composer.insert(symbol)
    }

    private fun startsNewSyllable(slot: ZhuyinComposer.Slot): Boolean = when (slot) {
        ZhuyinComposer.Slot.CONSONANT -> !composer.isEmpty
        ZhuyinComposer.Slot.MEDIAL -> composer.medial != null || composer.rime != null
        ZhuyinComposer.Slot.RIME -> composer.rime != null
        ZhuyinComposer.Slot.TONE -> false
    }

    /**
     * 空白鍵：把正在組的音節以一聲收尾。以下情況什麼都不做、回 false（交給呼叫端：送出整句或送空白）：
     * 沒有正在組的音節、一聲音節不在詞庫裡或只對到注音符號本身（例 ㄋ）、緩衝區裡有沒收尾的音節。
     */
    fun space(): Boolean {
        if (segments.any { !it.isComplete }) return false
        return completeSyllable(null)
    }

    private fun completeSyllable(tone: Char?): Boolean {
        val s = composer.syllable(tone) ?: return false
        val id = lexicon.syllableId(s) ?: return false
        // 只有聲母的一聲（例「ㄋ」）在詞庫裡唯一的詞就是注音符號本身：空白鍵不收成它，交給呼叫端送出最佳猜測
        if (tone == null && lexicon.lookup(intArrayOf(id), 0, 1, 1).firstOrNull()?.text == s) return false
        segments.add(Segment(Node(intArrayOf(id), doubleArrayOf(0.0), s), true, ZhuyinComposer()))
        composer.clear()
        return true
    }

    /**
     * 倒退：先刪正在組的最後一個符號；沒有就刪最後一個音節段。刪到正在組的音節空了、前一段又沒收尾，
     * 就把那一段拿回來繼續組（ㄋㄏ 倒退一次 → 正在組 ㄋ）。整個緩衝區是空的回 false。
     */
    fun backspace(): Boolean {
        if (composer.backspace()) {
            reopenTrailingPartial()
            return true
        }
        if (segments.isEmpty()) return false
        segments.removeAt(segments.size - 1)
        reopenTrailingPartial()
        return true
    }

    /** 不變式：正在組的音節是空的時候，最後一段一定是已收尾的。 */
    private fun reopenTrailingPartial() {
        if (!composer.isEmpty) return
        val last = segments.lastOrNull() ?: return
        if (last.isComplete) return
        setComposer(last.composer.copy())
        segments.removeAt(segments.size - 1)
    }

    fun reset() {
        segments.clear()
        composer.clear()
    }

    // ── 轉換 ──

    /**
     * 宿主輸入框裡顯示的組字：已收尾的音節顯示轉換結果，沒收尾的段與正在組的符號照打的樣子顯示
     * （簡拼時看得到自己打了什麼；要送出什麼看 `conversion`）。
     */
    val preedit: String
        get() {
            val out = StringBuilder()
            val run = ArrayList<Node>()
            for (s in segments) {
                if (s.isComplete) {
                    run.add(s.node)
                } else {
                    out.append(walk(run)).append(s.node.raw)
                    run.clear()
                }
            }
            return out.append(walk(run)).append(composer.composing).toString()
        }

    /** 整句送出時的文字（＝`commitAll()` 會回傳的）：所有音節段一起轉換，正在組的音節當沒收尾的音節一起猜。 */
    val conversion: String get() = walk(commitLattice())

    /** 緩衝區開頭的候選（正在組的音節也算一個位置）：長詞在前，同長度內分數高的在前；含單字。 */
    val candidates: List<ZhuyinCandidate> get() = candidates(CANDIDATE_LIMIT)

    /**
     * 只計算呼叫端實際要顯示的候選數。完整上限保留給需要完整候選清單的呼叫端，鍵盤則只需要前幾格。
     * 多字詞最多佔顯示數的四分之三（`phraseCandidateLimit`），保證單字一定排得進來。
     */
    fun candidates(requestedLimit: Int): List<ZhuyinCandidate> {
        val limit = minOf(maxOf(requestedLimit, 0), CANDIDATE_LIMIT)
        val nodes = ArrayList(segments.map { it.node })
        if (!composer.isEmpty) nodes.add(partialNode(composer.copy()))
        if (nodes.isEmpty() || limit <= 0) return emptyList()

        class KeyHit(val key: Int, val penalty: Double, val top: Double)

        val byLength = TreeMap<Int, MutableList<KeyHit>>()
        lexicon.forEachKey(nodes.map { it.ids }, ZhuyinLexicon.MAXIMUM_PHRASE_LENGTH, CANDIDATE_NODE_BUDGET) { key, path, top ->
            var penalty = 0.0
            for (d in path.indices) penalty += nodes[d].penalties[path[d]]
            byLength.getOrPut(path.size) { ArrayList() }.add(KeyHit(key, penalty, top))
        }

        /**
         * 同一個長度裡分數最高的 `need` 個詞（跨讀音去重、留最高分）。依鍵的最佳分數由高到低讀，
         * 已經湊滿且下一把鍵的最佳分數贏不了第 need 名就停，不把每把鍵的詞都解成字串。
         */
        fun best(hits: List<KeyHit>, need: Int): List<String> {
            if (need <= 0) return emptyList()
            val score = HashMap<String, Double>()
            val order = ArrayList<String>()
            var nth = Double.NEGATIVE_INFINITY
            val sorted = hits.sortedByDescending { it.top - it.penalty }
            for (h in sorted) {
                if (order.size >= need && h.top - h.penalty <= nth) break
                for (e in lexicon.entriesAt(h.key, need)) {
                    val s = e.score - h.penalty
                    if (order.size >= need && s <= nth) break
                    val old = score[e.text]
                    if (old != null) {
                        if (s > old) score[e.text] = s
                    } else {
                        score[e.text] = s
                        order.add(e.text)
                    }
                }
                if (order.size >= need) nth = order.map { score[it]!! }.sortedDescending()[need - 1]
            }
            return order.indices.sortedWith(
                compareBy({ -score[order[it]]!! }, { it })
            ).take(need).map { order[it] }
        }

        val phrases = ArrayList<ZhuyinCandidate>()
        // 多字詞最多佔四分之三：簡拼時兩個聲母就對得到幾百個詞，不留位置的話單字會整個被擠掉
        val phraseLimit = minOf(PHRASE_CANDIDATE_LIMIT, maxOf(1, limit * 3 / 4))
        for (k in byLength.keys.sortedDescending()) {
            if (k <= 1) continue
            for (text in best(byLength[k]!!, phraseLimit - phrases.size)) {
                phrases.add(ZhuyinCandidate(text, k))
            }
        }
        val singles = best(byLength[1] ?: emptyList(), limit).map { ZhuyinCandidate(it, 1) }
        return (phrases + singles).take(limit)
    }

    /**
     * 選一個候選：從緩衝區開頭移除它涵蓋的音節（涵蓋到正在組的音節就連它一起清掉），回傳要送出的文字。
     * `readingCount` 超過目前的位置數（候選已過期）時不動緩衝區、回空字串。
     */
    fun select(candidate: ZhuyinCandidate): String {
        val total = segments.size + if (composer.isEmpty) 0 else 1
        if (candidate.readingCount <= 0 || candidate.readingCount > total) return ""
        if (candidate.readingCount > segments.size) {
            segments.clear()
            composer.clear()
        } else {
            repeat(candidate.readingCount) { segments.removeAt(0) }
            reopenTrailingPartial()
        }
        return candidate.text
    }

    /** 整句送出並清空，回傳值與 `conversion` 相同。 */
    fun commitAll(): String {
        val text = walk(commitLattice())
        reset()
        return text
    }

    /** 正在組的音節一律當「沒收尾」：只差聲調的不扣分，所以一聲照樣選得到，其他聲調由詞頻決定。 */
    private fun commitLattice(): List<Node> {
        val nodes = ArrayList(segments.map { it.node })
        if (!composer.isEmpty) nodes.add(partialNode(composer.copy()))
        return nodes
    }

    /**
     * 沒收尾的音節可以對到的所有音節。
     * 打到的最後一個槽位（含）之前的槽位要完全相同，之後的槽位不限；聲調不限。
     * 槽位完全相同（只差聲調）的不扣分，多延伸的扣 `PARTIAL_PENALTY`。
     */
    private fun partialNode(c: ZhuyinComposer): Node {
        val raw = c.composing
        partialCache[raw]?.let { return it }
        // 最後一個打到的槽位：之前（含）的槽位要完全相同，之後的不限
        val last = if (c.rime != null) 2 else if (c.medial != null) 1 else 0
        val ids = ArrayList<Int>()
        val penalties = ArrayList<Double>()
        for (id in shapes.indices) {
            val shape = shapes[id]
            if (shape.consonant != c.consonant) continue
            if (last >= 1 && shape.medial != c.medial) continue
            if (last >= 2 && shape.rime != c.rime) continue
            ids.add(id)
            val exact = shape.medial == c.medial && shape.rime == c.rime
            penalties.add(if (exact) 0.0 else PARTIAL_PENALTY)
        }
        val node = Node(ids.toIntArray(), penalties.toDoubleArray(), raw)
        if (partialCache.size > 256) partialCache.clear()
        partialCache[raw] = node
        return node
    }

    // ── Viterbi ──

    /** 在讀音網格上找分數最高的切分，回傳串起來的文字。 */
    private fun walk(nodes: List<Node>): String {
        if (nodes.isEmpty()) return ""
        walkCache[nodes]?.let { return it }
        val n = nodes.size
        // best[i]：走到位置 i 的最高累積分數；back[i]：最後一段的起點與內容
        val best = DoubleArray(n + 1) { Double.NEGATIVE_INFINITY }
        // backFrom[i]：起點；backKey[i] >= 0 是那把鍵的索引，-1 是以注音原樣墊過去
        val backFrom = IntArray(n + 1)
        val backKey = IntArray(n + 1) { -1 }
        best[0] = 0.0
        for (i in 0 until n) {
            if (best[i] == Double.NEGATIVE_INFINITY) continue
            var hit = false
            val sets = ArrayList<IntArray>(n - i)
            for (d in i until n) sets.add(nodes[d].ids)
            lexicon.forEachKey(sets, ZhuyinLexicon.MAXIMUM_PHRASE_LENGTH, WALK_NODE_BUDGET) { key, path, top ->
                var score = best[i] + top
                for (d in path.indices) score -= nodes[i + d].penalties[path[d]]
                if (path.size == 1) hit = true
                if (score > best[i + path.size]) {
                    best[i + path.size] = score
                    backFrom[i + path.size] = i
                    backKey[i + path.size] = key
                }
            }
            // 這個位置對不到任何單字（沒收尾的段組不出音節，例 ㄅㄩ）→ 以注音原樣墊過去
            if (!hit && best[i] - RAW_PENALTY > best[i + 1]) {
                best[i + 1] = best[i] - RAW_PENALTY
                backFrom[i + 1] = i
                backKey[i + 1] = -1
            }
        }
        val parts = ArrayList<String>()
        var pos = n
        while (pos > 0) {
            val k = backKey[pos]
            parts.add(if (k >= 0) lexicon.entriesAt(k, 1).firstOrNull()?.text ?: "" else nodes[backFrom[pos]].raw)
            pos = backFrom[pos]
        }
        val text = parts.asReversed().joinToString("")
        if (walkCache.size > 32) walkCache.clear()
        walkCache[nodes] = text
        return text
    }

    private fun setComposer(c: ZhuyinComposer) {
        composer.clear()
        c.consonant?.let { composer.insert(it) }
        c.medial?.let { composer.insert(it) }
        c.rime?.let { composer.insert(it) }
    }
}
