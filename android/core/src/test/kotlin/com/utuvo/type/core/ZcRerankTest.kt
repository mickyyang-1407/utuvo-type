package com.utuvo.type.core

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 0c 重排：樹狀特徵（照 `zy.py` 的 `log_prob_tree()`）、融合選字、與真跑模型的分數。
 * 標準答案＝`core/src/test/resources/zc/{features,choose,scores}.jsonl`。
 */
class ZcRerankTest {
    private lateinit var vocab: ZcVocab

    @BeforeTest
    fun setUp() {
        val model = File(System.getProperty("zc.model") ?: error("缺 zc.model"))
        vocab = ZcVocab.parse(File(model, "vocab.json").readText(), File(model, "manifest.json").readText())
    }

    private fun fixture(name: String) =
        File(System.getProperty("zc.fixtures") ?: error("缺 zc.fixtures"), name)
            .readLines().filter { it.isNotBlank() }.map { JSONObject(it) }

    private fun JSONArray.strings() = List(length()) { getString(it) }
    private fun JSONArray.doubles() = List(length()) { getDouble(it) }

    /** 用 JVM 版 onnxruntime 真跑模型。 */
    private class OnnxScorer(path: String) : ZcScorer, java.io.Closeable {
        private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
        private val session: OrtSession
        init {
            val opts = OrtSession.SessionOptions().apply { setIntraOpNumThreads(1) }
            session = env.createSession(path, opts)
        }

        override fun score(f: ZcFeatures): FloatArray? = try {
            fun longTensor(name: String, data: LongArray, shape: LongArray): OnnxTensor =
                OnnxTensor.createTensor(env, java.nio.LongBuffer.wrap(data), shape)
            val inputs = mapOf(
                "ids" to longTensor("ids", f.ids, longArrayOf(1, f.ids.size.toLong())),
                "bases" to longTensor("bases", f.bases, longArrayOf(1, f.bases.size.toLong())),
                "tones" to longTensor("tones", f.tones, longArrayOf(1, f.tones.size.toLong())),
                "types" to longTensor("types", f.types, longArrayOf(1, f.types.size.toLong())),
                "positions" to longTensor("positions", f.positions, longArrayOf(1, f.positions.size.toLong())),
                "mask" to OnnxTensor.createTensor(
                    env, java.nio.ByteBuffer.wrap(ByteArray(f.mask.size) { if (f.mask[it]) 1 else 0 }),
                    longArrayOf(1, 1, f.ids.size.toLong(), f.ids.size.toLong()), ai.onnxruntime.OnnxJavaType.BOOL,
                ),
                "proj_pos" to longTensor("proj_pos", f.projPos, longArrayOf(f.projPos.size.toLong())),
                "target_node" to longTensor(
                    "target_node", f.targetNode,
                    longArrayOf(f.candidateCount.toLong(), f.syllableCount.toLong()),
                ),
                "target_ids" to longTensor(
                    "target_ids", f.targetIds,
                    longArrayOf(f.candidateCount.toLong(), f.syllableCount.toLong()),
                ),
            )
            val r = session.run(inputs)
            try {
                (r["scores"]!!.get().value) as FloatArray
            } finally {
                r.close()
            }
        } catch (e: Exception) {
            System.err.println("ZcScorer failed: $e")
            null
        }

        override fun close() { session.close() }
    }

    private fun scorer(): OnnxScorer {
        val dir = File(System.getProperty("zc.model") ?: error("缺 zc.model"))
        val f = File(dir, "zc-d512-slim-w4.ort")
        assertTrue(f.isFile, "模型不在 ${f.path}")
        return OnnxScorer(f.absolutePath)
    }

    @Test
    fun treeMatchesOracleFeeds() {
        val cases = fixture("features.jsonl")
        assertEquals(4, cases.size, "標準答案應該有 4 例")
        for ((i, o) in cases.withIndex()) {
            val f = assertNotNull(
                vocab.tree(o.getString("context"), o.getJSONArray("reading").strings(), o.getJSONArray("cands").strings()),
                "第 ${i + 1} 例：特徵組不起來",
            )
            val feeds = o.getJSONObject("feeds")
            fun longs(name: String, got: LongArray) {
                val want = feeds.getJSONArray(name).getJSONArray(0)
                assertEquals(want.length(), got.size, "第 ${i + 1} 例 $name 長度")
                for (d in got.indices) assertEquals(want.getLong(d), got[d], "第 ${i + 1} 例 $name[$d]")
            }
            longs("ids", f.ids); longs("bases", f.bases); longs("tones", f.tones)
            longs("types", f.types); longs("positions", f.positions)
            val len = f.ids.size
            assertEquals(len * len, f.mask.size, "第 ${i + 1} 例 mask 大小")
            val wantMask = feeds.getJSONArray("mask").getJSONArray(0).getJSONArray(0)
            assertEquals(len, wantMask.length(), "第 ${i + 1} 例 mask 維度")
            for (r in 0 until len) {
                val row = wantMask.getJSONArray(r)
                for (c in 0 until len) {
                    assertEquals(
                        if (f.mask[r * len + c]) 1 else 0, row.getInt(c),
                        "第 ${i + 1} 例 mask[$r][$c]",
                    )
                }
            }
            val proj = feeds.getJSONArray("proj_pos")
            assertEquals(proj.length(), f.projPos.size, "第 ${i + 1} 例 proj_pos 長度")
            for (d in f.projPos.indices) assertEquals(proj.getLong(d), f.projPos[d], "第 ${i + 1} 例 proj_pos[$d]")
            val tn = feeds.getJSONArray("target_node")
            val ti = feeds.getJSONArray("target_ids")
            assertEquals(tn.length() * tn.getJSONArray(0).length(), f.targetNode.size)
            for (r in 0 until tn.length()) for (c in 0 until tn.getJSONArray(0).length()) {
                assertEquals(tn.getJSONArray(r).getLong(c), f.targetNode[r * tn.getJSONArray(0).length() + c], "第 ${i + 1} 例 target_node[$r][$c]")
                assertEquals(ti.getJSONArray(r).getLong(c), f.targetIds[r * ti.getJSONArray(0).length() + c], "第 ${i + 1} 例 target_ids[$r][$c]")
            }
        }
    }

    @Test
    fun chooseMatchesOracle() {
        val cases = fixture("choose.jsonl")
        assertEquals(271, cases.size, "標準答案應該有 271 例")
        for ((i, o) in cases.withIndex()) {
            val got = ZcRerank.choose(
                o.getJSONArray("engine").doubles().toDoubleArray(),
                o.getJSONArray("neural").doubles().toDoubleArray(),
                o.getDouble("w"), o.getDouble("tau"),
            )
            assertEquals(o.getInt("index"), got, "第 ${i + 1} 例")
        }
    }

    @Test
    fun neuralScoresMatchOracle() {
        val cases = fixture("scores.jsonl")
        assertEquals(40, cases.size, "標準答案應該有 40 例")
        scorer().use { s ->
            for ((i, o) in cases.withIndex()) {
                val got = assertNotNull(
                    ZcRerank.neural(s, vocab, o.getString("context"), o.getJSONArray("reading").strings(), o.getJSONArray("cands").strings()),
                    "第 ${i + 1} 例：分數是 null",
                )
                val want = o.getJSONArray("scores").doubles()
                assertEquals(want.size, got.size, "第 ${i + 1} 例：分數個數")
                for (d in want.indices) {
                    assertTrue(
                        kotlin.math.abs(want[d] - got[d]) < 2e-3,
                        "第 ${i + 1} 例第 ${d + 1} 個分數：期望 ${want[d]}，得到 ${got[d]}",
                    )
                }
            }
        }
    }

    // kbest.jsonl 裡沒有「我忘記帶健保卡」這例（讀音與引擎候選由 `zy.py` 的
    // `Lexicon.annotate()`／`kbest()` 產生，見工單 ZC1 步驟 2 的例外條款）：
    // ㄨㄛˇ ㄨㄤˋ ㄐㄧˋ ㄉㄞˋ ㄐㄧㄢˋ ㄅㄠˇ ㄎㄚˇ → 引擎第 0 名「我忘記代健保卡」(-15.128)，
    // 第 1 名才是「我忘記帶健保卡」(-15.3705)。
    private val kaibaReadings = listOf("ㄨㄛˇ", "ㄨㄤˋ", "ㄐㄧˋ", "ㄉㄞˋ", "ㄐㄧㄢˋ", "ㄅㄠˇ", "ㄎㄚˇ")

    private fun kaibaKBest(): List<Pair<String, Double>> {
        val resources = File(System.getProperty("utuvo.resources") ?: error("缺 utuvo.resources"))
        val lexicon = assertNotNull(ZhuyinLexicon.open(File(resources, "zhuyin.dat")))
        val e = ZhuyinEngine(lexicon)
        for (r in kaibaReadings) {
            val tone = r.lastOrNull()!!.toChar()
            for (ch in r.dropLast(1)) e.type(ch)
            e.type(tone)
        }
        assertEquals("我忘記代健保卡", e.kBest(16).first().first, "這例的前題：引擎第 0 名要是「我忘記代健保卡」")
        return e.kBest(16)
    }

    @Test
    fun rerankFixesInsuranceCardSentence() {
        scorer().use { s ->
            assertEquals(
                "我忘記帶健保卡",
                ZcRerank.rerank(s, vocab, "", kaibaReadings, kaibaKBest()),
                "上文空白時應把「我忘記代健保卡」換成「我忘記帶健保卡」",
            )
        }
    }

    @Test
    fun rerankReturnsNullWhenFirstCandidateInvalid() {
        scorer().use { s ->
            assertNull(
                ZcRerank.rerank(s, vocab, "", kaibaReadings, listOf("太短" to -1.0)),
                "第 0 名不合格就不重排",
            )
            assertNull(
                ZcRerank.rerank(s, vocab, "", listOf("ㄨㄛˇ"), kaibaKBest()),
                "音節數不足就不重排",
            )
        }
    }
}
