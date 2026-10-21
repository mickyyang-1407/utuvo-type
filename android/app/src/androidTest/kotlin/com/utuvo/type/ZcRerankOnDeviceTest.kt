package com.utuvo.type

import android.os.Debug
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.utuvo.type.core.ZcFeatures
import com.utuvo.type.core.ZcRerank
import com.utuvo.type.core.ZcScorer
import com.utuvo.type.core.ZcVocab
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * 0c 上下文重排在模擬器上：模型從 assets 載入、分數對得上標準答案、
 * 逐鍵打注音能重排出正確的整句，以及 PSS／耗時量測（只回報數字，不設門檻）。
 */
@RunWith(AndroidJUnit4::class)
class ZcRerankOnDeviceTest {
    private val test = InstrumentationRegistry.getInstrumentation().context
    private val app = InstrumentationRegistry.getInstrumentation().targetContext

    private fun fixtures(name: String): List<JSONObject> =
        test.assets.open(name).bufferedReader().readLines()
            .filter { it.isNotBlank() }.map { JSONObject(it) }

    private fun JSONArray.list() = (0 until length()).map { getString(it) }
    private fun JSONArray.doubles() = (0 until length()).map { getDouble(it) }

    /** 從 assets 載入模型（同步，測試用；正式鍵盤走 `ZcReranker` 的背景執行緒）。 */
    private fun scorer(): Scorer {
        val started = System.nanoTime()
        val before = Debug.getPss()
        val dir = File(app.filesDir, "zc").apply { mkdirs() }
        val model = File(dir, "zc-d512-slim-w4.ort")
        val length = app.assets.openFd("zc/zc-d512-slim-w4.ort").use { it.length }
        if (!model.isFile || model.length() != length) {
            app.assets.open("zc/zc-d512-slim-w4.ort").use { i -> model.outputStream().use { i.copyTo(it) } }
        }
        val options = ai.onnxruntime.OrtSession.SessionOptions().apply { setIntraOpNumThreads(2) }
        val session = ai.onnxruntime.OrtEnvironment.getEnvironment().createSession(model.absolutePath, options)
        val vocab = ZcVocab.parse(
            app.assets.open("zc/vocab.json").use { it.readBytes().toString(Charsets.UTF_8) },
            app.assets.open("zc/manifest.json").use { it.readBytes().toString(Charsets.UTF_8) },
        )
        val after = Debug.getPss()
        Log.i(TAG, "載入模型：${(System.nanoTime() - started) / 1_000_000} ms，PSS $before kB → $after kB（差 ${after - before} kB）")
        return Scorer(session, vocab)
    }

    private class Scorer(private val session: ai.onnxruntime.OrtSession, val vocab: ZcVocab) : ZcScorer {
        private val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
        override fun score(f: ZcFeatures): FloatArray? {
            fun longs(d: LongArray, shape: LongArray) =
                ai.onnxruntime.OnnxTensor.createTensor(env, java.nio.LongBuffer.wrap(d), shape)
            val len = f.ids.size.toLong()
            val inputs = mapOf(
                "ids" to longs(f.ids, longArrayOf(1, len)),
                "bases" to longs(f.bases, longArrayOf(1, len)),
                "tones" to longs(f.tones, longArrayOf(1, len)),
                "types" to longs(f.types, longArrayOf(1, len)),
                "positions" to longs(f.positions, longArrayOf(1, len)),
                "mask" to ai.onnxruntime.OnnxTensor.createTensor(
                    env, java.nio.ByteBuffer.wrap(ByteArray(f.mask.size) { if (f.mask[it]) 1 else 0 }),
                    longArrayOf(1, 1, len, len), ai.onnxruntime.OnnxJavaType.BOOL,
                ),
                "proj_pos" to longs(f.projPos, longArrayOf(f.projPos.size.toLong())),
                "target_node" to longs(f.targetNode, longArrayOf(f.candidateCount.toLong(), f.syllableCount.toLong())),
                "target_ids" to longs(f.targetIds, longArrayOf(f.candidateCount.toLong(), f.syllableCount.toLong())),
            )
            val r = session.run(inputs)
            return try { r["scores"]!!.get().value as FloatArray } finally { r.close() }
        }
    }

    /** scores.jsonl 前 5 例的分數要跟 Python 參考實作對得上（差 < 2e-3）。 */
    @Test
    fun onDeviceScoresMatchOracle() {
        val cases = fixtures("scores.jsonl").take(5)
        assertEquals(5, cases.size)
        val s = scorer()
        for ((i, o) in cases.withIndex()) {
            val got = ZcRerank.neural(
                s, s.vocab, o.getString("context"), o.getJSONArray("reading").list(), o.getJSONArray("cands").list(),
            ) ?: throw AssertionError("第 ${i + 1} 例：分數是 null")
            val want = o.getJSONArray("scores").doubles()
            assertEquals(want.size, got.size)
            for (d in want.indices) {
                assertTrue(
                    "第 ${i + 1} 例第 ${d + 1} 個分數：期望 ${want[d]}，得到 ${got[d]}",
                    kotlin.math.abs(want[d] - got[d]) < 2e-3,
                )
            }
        }
    }

    /**
     * 逐鍵打出「我忘記帶健保卡」的注音：
     * ㄨㄛˇ ㄨㄤˋ ㄐㄧˋ ㄉㄞˋ ㄐㄧㄢˋ ㄅㄠˇ ㄎㄚˇ（讀音由 `zy.py` 的 `Lexicon.annotate()` 產生）。
     * 開著 AI 選字時 `commitAll()` 要給「我忘記帶健保卡」，關掉時是引擎原本的「我忘記代健保卡」。
     */
    @Test
    fun rerankFixesInsuranceCardSentenceOnDevice() {
        val prefs = PrefsSnapshot(app, "keyboard")
        val readings = listOf("ㄨㄛˇ", "ㄨㄤˋ", "ㄐㄧˋ", "ㄉㄞˋ", "ㄐㄧㄢˋ", "ㄅㄠˇ", "ㄎㄚˇ")
        try {
            HantInput.setAiRerank(app, false)
            val off = session().apply { readings.forEach { typeReading(it) } }
            val readingsOff = off.rerankInput() ?: throw AssertionError("整句讀音已定應該能重排")
            val kbestOff = off.kBestForRerank(readingsOff)
            assertEquals("關掉時第 0 名是引擎的字", "我忘記代健保卡", kbestOff.first().first)

            HantInput.setAiRerank(app, true)
            val on = session().apply { readings.forEach { typeReading(it) } }
            val readingsOn = on.rerankInput() ?: throw AssertionError("整句讀音已定應該能重排")
            val kbest = on.kBestForRerank(readingsOn)
            val started = System.nanoTime()
            val text = ZcReranker.rerankNow(app, "", readingsOn, kbest)
                ?: throw AssertionError("重排應該回傳文字")
            Log.i(TAG, "單次 rerank：${(System.nanoTime() - started) / 1_000_000} ms")
            on.applyRerank(readingsOn, text)
            assertEquals("重排後送出的應該是正確的整句", "我忘記帶健保卡", on.commitAll())
            assertEquals("關掉 AI 選字時送出的應該是引擎的字", "我忘記代健保卡", off.commitAll())
        } finally {
            prefs.restore()
        }
    }

    /** 量一次：載入前後的 PSS 差與單次 rerank 耗時（不設門檻，只回報數字）。 */
    @Test
    fun measureMemoryAndSpeed() {
        val before = Debug.getPss()
        val s = scorer()
        val loaded = Debug.getPss()
        val ime = session()
        listOf("ㄨㄛˇ", "ㄨㄤˋ", "ㄐㄧˋ", "ㄉㄞˋ", "ㄐㄧㄢˋ", "ㄅㄠˇ", "ㄎㄚˇ").forEach { ime.typeReading(it) }
        val readings = ime.rerankInput() ?: throw AssertionError("整句讀音已定應該能重排")
        val kbest = ime.kBestForRerank(readings)
        val samples = (0 until 5).map {
            val t0 = System.nanoTime()
            ZcRerank.rerank(s, s.vocab, "", readings, kbest)
            (System.nanoTime() - t0) / 1_000_000
        }
        Log.i(TAG, "PSS：載入前 $before kB、載入後 $loaded kB（差 ${loaded - before} kB）")
        Log.i(TAG, "單次 rerank 5 次：$samples ms，中位數 ${samples.sorted()[samples.size / 2]} ms")
        assertTrue("載入模型後 PSS 應該不會變小：$before → $loaded", loaded >= before)
    }

    private val sentence = listOf("ㄨㄛˇ", "ㄨㄤˋ", "ㄐㄧˋ", "ㄉㄞˋ", "ㄐㄧㄢˋ", "ㄅㄠˇ", "ㄎㄚˇ")

    /**
     * 連續 300 次 `rerankNow`，原生堆不該長超過 5 MB（長時間打字的穩定性）。
     * ⚠️ 2026-10-13 orchestrator 實測：把 `OnnxScorer.score` 關輸入 tensor 的那行拿掉，這個測試**仍然是綠的**
     * ——沒關的 tensor 主要是 Java 端緩衝，會被 GC 回收，原生層殘留很小。所以它只證明現行版本不會越用越肥，
     * 不能當「tensor 有沒有 close」的守門；那件事靠程式碼審查。
     */
    @Test
    fun nativeHeapStableAcross300Reranks() {
        val ime = session().apply { sentence.forEach { typeReading(it) } }
        val readings = ime.rerankInput() ?: throw AssertionError("整句讀音已定應該能重排")
        val kbest = ime.kBestForRerank(readings)
        // 先跑幾次讓 ORT 的內部配置與 lazy init 收斂，再量。
        val pssCold = Debug.getPss()
        repeat(5) { ZcReranker.rerankNow(app, "", readings, kbest) }
        val pssLoaded = Debug.getPss()
        Log.i(TAG, "第一次 rerank（含載入模型）PSS：$pssCold kB → $pssLoaded kB（差 ${pssLoaded - pssCold} kB）")
        System.gc()
        val before = Debug.getNativeHeapAllocatedSize()
        val pssBefore = Debug.getPss()
        var last: String? = null
        for (i in 0 until 300) {
            last = ZcReranker.rerankNow(app, "", readings, kbest)
            if (i % 50 == 0) {
                Log.i(
                    TAG,
                    "第 $i 次：native heap ${Debug.getNativeHeapAllocatedSize() / 1024} kB，PSS ${Debug.getPss()} kB",
                )
            }
        }
        val after = Debug.getNativeHeapAllocatedSize()
        val pssAfter = Debug.getPss()
        Log.i(TAG, "300 次 rerank：native heap ${before / 1024} kB → ${after / 1024} kB（差 ${(after - before) / 1024} kB）")
        Log.i(TAG, "300 次 rerank：PSS $pssBefore kB → $pssAfter kB（差 ${pssAfter - pssBefore} kB）")
        assertTrue("重排結果不該是 null", last != null)
        assertTrue(
            "300 次 rerank 的原生堆成長 ${(after - before) / 1024} kB，超過 5 MB（多半是輸入 tensor 沒關）",
            after - before < 5L * 1024 * 1024,
        )
    }

    /**
     * 推論排隊中／進行中呼叫 `release()`：不該閃退，而且之後還能再重排
     * （`release()` 把關閉丟到推論執行緒跟推論序列化，主執行緒不碰 session）。
     * 時機無法精準控制，所以重複 30 次、每次在排入推論後 0–40 ms 之間呼叫 release，涵蓋排隊中與推論中兩種情況；
     * 原生層 use-after-free 會讓整個測試程序崩潰（instrumentation 會回報 Process crashed），不需要另外接例外。
     */
    @Test
    fun releaseDuringBackgroundInferenceDoesNotCrash() {
        val ime = session().apply { sentence.forEach { typeReading(it) } }
        val readings = ime.rerankInput() ?: throw AssertionError("整句讀音已定應該能重排")
        val kbest = ime.kBestForRerank(readings)
        assertTrue("先確定能重排", ZcReranker.rerankNow(app, "", readings, kbest) != null)
        val rounds = 30
        val done = java.util.concurrent.CountDownLatch(rounds)
        var released = 0
        for (i in 0 until rounds) {
            ZcReranker.rerankOnBackground(app, "", readings, kbest) { done.countDown() }
            Thread.sleep((i * 7 % 41).toLong())
            ZcReranker.release()
            released++
        }
        assertTrue("每一輪的重排回呼都要回來（不能卡死）", done.await(120, java.util.concurrent.TimeUnit.SECONDS))
        assertEquals(rounds, released)
        // release 之後要能重新載入並再重排一次。
        val after = ZcReranker.rerankNow(app, "", readings, kbest)
        assertTrue("release 之後還要能重排", after != null)
    }

    private fun session() = ImeSession(app, ImeSession.Kind.ZHUYIN)

    private fun ImeSession.typeReading(reading: String) {
        for (ch in reading.dropLast(1)) type(ch)
        type(reading.last())
    }

    private companion object {
        const val TAG = "ZcRerankOnDevice"
    }
}
