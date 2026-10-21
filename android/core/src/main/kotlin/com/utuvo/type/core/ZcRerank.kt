package com.utuvo.type.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * 0c 注音整句候選重排（`Funmula/0c-sequence-d512`，MIT）。逐行照 Python 參考實作
 * `zy.py` 的 `log_prob_tree()` / `neural_tree()` / `choose()`。
 *
 * 這裡只有特徵與決策，沒有推論：推論由呼叫端用 [ZcScorer] 做（Android 上是 `ai.onnxruntime`，
 * 電腦測試是 JVM 版 onnxruntime）。任一環失敗都回 null，整案退回引擎預設（model card：
 * `correction: whole_case_fallback`、`unknown_candidate_character: whole_case_fallback`）。
 *
 * `characters` 詞彙裡可能有 BMP 外的字，所以候選字與上文一律按 code point 切，不用 `Char`。
 */

/** 0c 詞彙與執行期設定（由 `vocab.json`＋`manifest.json` 解析而來）。 */
class ZcVocab(
    val chars: Map<String, Int>,
    val bases: Map<String, Int>,
    val neutralTolerantLast: Set<String>,
) {
    /** 單字的注音 → (base id, 聲調 id)。詞彙外的 base 回 null（呼叫端整案退回）。 */
    fun syllable(reading: String): Pair<Int, Int>? {
        val tone = reading.lastOrNull()
        val toneId = if (tone == null || tone !in TONE_IDS) 1 else TONE_IDS.getValue(tone)
        val body = if (tone != null && tone in TONE_IDS) reading.dropLast(1) else reading
        val b = bases[body] ?: return null
        return b to toneId
    }

    fun charId(c: String): Int? = chars[c]

    companion object {
        /** 二、三、四、輕聲；沒標＝一聲。 */
        private val TONE_IDS = mapOf('ˊ' to 2, 'ˇ' to 3, 'ˋ' to 4, '˙' to 5)
        /** 詞彙外字在模型裡的 id（對應 vocab `specials` 的 UNK）。 */
        const val UNKNOWN_CHAR_ID = 4

        fun parse(vocabJson: String, manifestJson: String): ZcVocab {
            val v = JSONObject(vocabJson)
            val chars = HashMap<String, Int>(v.getJSONArray("characters").length() * 2)
            val charsArr = v.getJSONArray("characters")
            for (i in 0 until charsArr.length()) chars[charsArr.getString(i)] = i + 8
            val basesArr = v.getJSONArray("bases")
            val bases = HashMap<String, Int>(basesArr.length() * 2)
            for (i in 0 until basesArr.length()) bases[basesArr.getString(i)] = i + 2
            val neutral = LinkedHashSet<String>()
            val m = JSONObject(manifestJson)
            if (m.has("neutral_tolerant_last")) {
                val a: JSONArray = m.getJSONArray("neutral_tolerant_last")
                for (i in 0 until a.length()) neutral.add(a.getString(i))
            }
            return ZcVocab(chars, bases, neutral)
        }

        /** 內容量上限（manifest `limits`），照 manifest 寫死成常數。 */
        const val MIN_SYLLABLES = 2
        const val MAX_SYLLABLES = 32
        const val MAX_CANDIDATES = 16
        const val CONTEXT_RUNES = 64

        /**
         * 融合權重與門檻。`DEFAULT_WEIGHT` 依 Type 引擎分數尺度在 992 例測試集上校準
         * （ai-pipeline/tasks/type-0c-reranker-2026-10-13）。
         */
        const val DEFAULT_WEIGHT = 0.75
        const val DEFAULT_TAU = 0.5
    }
}

/**
 * 一個樹狀候選批次送進模型的九個張量（照 `zy.py` 的 `feeds`）。長度 L、`mask` 是 L×L row-major。
 * 呼叫端把它們轉成 onnxruntime 的 tensor。
 */
class ZcFeatures(
    val ids: LongArray,
    val bases: LongArray,
    val tones: LongArray,
    val types: LongArray,
    val positions: LongArray,
    val mask: BooleanArray,
    val projPos: LongArray,
    val targetNode: LongArray,
    val targetIds: LongArray,
    /** 候選數（`targetNode` 的列數）。 */
    val candidateCount: Int,
    /** 每個候選的字數（`targetNode` 的欄數；本模型字數＝音節數）。 */
    val syllableCount: Int,
)

/** 打分器。回 null＝這次推論失敗（整案退回引擎預設）。 */
interface ZcScorer {
    fun score(f: ZcFeatures): FloatArray?
}

/**
 * 把上文＋讀音＋候選組成樹狀特徵（照 `zy.py` 的 `log_prob_tree()`）。
 *
 * 候選有詞彙外的字、或字數跟讀音對不上時回 null。
 */
fun ZcVocab.tree(context: String, readings: List<String>, cands: List<String>): ZcFeatures? {
    val n = readings.size
    if (n <= 0 || cands.isEmpty()) return null
    // 上文：最後 64 個 code point，詞彙外的字用 UNK
    val ctx = context.codePoints().toArray()
    val from = maxOf(0, ctx.size - ZcVocab.CONTEXT_RUNES)
    val head = ArrayList<Int>(2 + (ctx.size - from))
    head.add(1) // BOS
    for (i in from until ctx.size) {
        head.add(chars[String(Character.toChars(ctx[i]))] ?: ZcVocab.UNKNOWN_CHAR_ID)
    }
    head.add(2) // SEP
    val sounds = ArrayList<Pair<Int, Int>>(n)
    for (r in readings) {
        val s = syllable(r) ?: return null
        sounds.add(s)
    }
    val candIds = ArrayList<IntArray>(cands.size)
    for (c in cands) {
        val cps = c.codePoints().toArray()
        if (cps.size != n) return null
        val row = IntArray(cps.size)
        for ((d, cp) in cps.withIndex()) {
            row[d] = chars[String(Character.toChars(cp))] ?: return null
        }
        candIds.add(row)
    }

    val out = head.size + n
    val ids = ArrayList<Long>(out + 1)
    val bases = ArrayList<Long>(out + 1)
    val tones = ArrayList<Long>(out + 1)
    val types = ArrayList<Long>(out + 1)
    val positions = ArrayList<Long>(out + 1)
    for (h in head) ids.add(h.toLong())
    repeat(head.size) { bases.add(0L); tones.add(0L); types.add(0L) }
    for (i in 0 until n) {
        ids.add(0L); bases.add(sounds[i].first.toLong()); tones.add(sounds[i].second.toLong()); types.add(1L)
    }
    ids.add(3L); bases.add(0L); tones.add(0L); types.add(0L) // OUT
    for (i in 0..out) positions.add(i.toLong())

    // 前綴樹：相同的候選前綴共用一個節點（鍵用前綴字串；id 都是小的非負數，切成 Char 不會有歧義）
    val parent = HashMap<String, Int>()
    val anc = HashMap<Int, IntArray>()
    for (cand in candIds) {
        val chars = CharArray(cand.size) { cand[it].toChar() }
        for (d in 1 until n) {
            val pre = String(chars, 0, d)
            if (parent.containsKey(pre)) continue
            val idx = ids.size
            ids.add(cand[d - 1].toLong()); bases.add(0L); tones.add(0L); types.add(2L)
            positions.add((out + d).toLong())
            val up = if (d > 1) anc.getValue(parent.getValue(String(chars, 0, d - 1))) else IntArray(0)
            anc[idx] = up + idx
            parent[pre] = idx
        }
    }

    val len = ids.size
    val mask = BooleanArray(len * len)
    for (i in 0 until out + 1) for (j in 0..i) mask[i * len + j] = true
    for ((idx, a) in anc) {
        for (j in 0 until out + 1) mask[idx * len + j] = true
        for (x in a) mask[idx * len + x] = true
    }
    val proj = ArrayList<Long>(anc.size + 1)
    proj.add(out.toLong())
    for (p in anc.keys.sorted()) proj.add(p.toLong())
    val projIndex = HashMap<Int, Int>(proj.size * 2)
    for ((i, p) in proj.withIndex()) projIndex[p.toInt()] = i

    val tnode = LongArray(cands.size * n)
    val tids = LongArray(cands.size * n)
    for ((k, cand) in candIds.withIndex()) {
        val chars = CharArray(cand.size) { cand[it].toChar() }
        for (d in 1 until n) {
            tnode[k * n + d] = projIndex.getValue(parent.getValue(String(chars, 0, d))).toLong()
        }
        for (d in 0 until n) tids[k * n + d] = (cand[d] - 6).toLong()
    }

    return ZcFeatures(
        ids.toLongArray(), bases.toLongArray(), tones.toLongArray(), types.toLongArray(), positions.toLongArray(),
        mask, proj.toLongArray(), tnode, tids, cands.size, n,
    )
}

/** 0c 重排：特徵、神經分數、融合選字。全部照 `zy.py`。 */
object ZcRerank {
    /**
     * 每個候選的模型分數（照 `neural_tree()`，一次樹狀推論；句尾輕聲再推一次取大者）。
     * 任一候選字數≠音節數或含詞彙外字 → null。
     */
    fun neural(scorer: ZcScorer, vocab: ZcVocab, context: String, readings: List<String>, cands: List<String>): DoubleArray? {
        if (readings.isEmpty() || cands.isEmpty()) return null
        for (c in cands) {
            if (c.codePointCount(0, c.length) != readings.size) return null
        }
        val f = vocab.tree(context, readings, cands) ?: return null
        val s = scorer.score(f)?.let { DoubleArray(it.size) { i -> it[i].toDouble() } } ?: return null
        if (s.size != cands.size) return null
        val last = readings.last()
        val tone = last.lastOrNull()
        val base = if (tone != null && tone in "ˊˇˋ˙") last.dropLast(1) else last
        if (base in vocab.neutralTolerantLast && tone != '˙') {
            val alt = vocab.tree(context, readings.dropLast(1) + (base + "˙"), cands) ?: return s
            val s2 = scorer.score(alt)?.let { DoubleArray(it.size) { i -> it[i].toDouble() } } ?: return s
            if (s2.size != s.size) return s
            for (i in s.indices) if (s2[i] > s[i]) s[i] = s2[i]
        }
        return s
    }

    /**
     * 融合引擎分數與模型分數（照 `choose()`）：贏過第 0 名且贏幅大於 `tau` 才換，
     * 否則維持第 0 名。`neural` 為 null 直接回 0。
     */
    fun choose(engine: DoubleArray, neural: DoubleArray?, w: Double, tau: Double): Int {
        if (neural == null) return 0
        val n = minOf(engine.size, neural.size)
        if (n <= 0) return 0
        var best = 0
        var bestScore = engine[0] + w * neural[0]
        for (i in 1 until n) {
            val f = engine[i] + w * neural[i]
            if (f > bestScore) { bestScore = f; best = i }
        }
        return if (best != 0 && bestScore - (engine[0] + w * neural[0]) > tau) best else 0
    }

    /**
     * 整條重排流程：候選先濾掉不合格的（字數≠音節數或含詞彙外字），第 0 名不合格就整案不重排（回 null）。
     * 音節數不在 `MIN_SYLLABLES..MAX_SYLLABLES` → null。
     * 回傳選到的文字；選到第 0 名時也回第 0 名。
     */
    fun rerank(
        scorer: ZcScorer,
        vocab: ZcVocab,
        context: String,
        readings: List<String>,
        kbest: List<Pair<String, Double>>,
        w: Double = ZcVocab.DEFAULT_WEIGHT,
        tau: Double = ZcVocab.DEFAULT_TAU,
    ): String? {
        if (readings.size !in ZcVocab.MIN_SYLLABLES..ZcVocab.MAX_SYLLABLES) return null
        if (kbest.isEmpty()) return null
        val usable = kbest.filter { (text, _) ->
            text.codePointCount(0, text.length) == readings.size && text.codePoints().allMatch {
                vocab.chars.containsKey(String(Character.toChars(it)))
            }
        }
        if (usable.isEmpty()) return null
        if (usable.size != kbest.size && usable.none { it.first == kbest[0].first }) return null
        val cands = usable.map { it.first }
        val engine = DoubleArray(usable.size) { usable[it].second }
        val neural = neural(scorer, vocab, context, readings, cands) ?: return null
        return cands[choose(engine, neural, w, tau)]
    }
}
