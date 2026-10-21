package com.utuvo.type

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import android.content.Context
import android.util.Log
import com.utuvo.type.core.ZcFeatures
import com.utuvo.type.core.ZcRerank
import com.utuvo.type.core.ZcScorer
import com.utuvo.type.core.ZcVocab
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.LongBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 0c 注音整句候選重排在手機上的執行環境（`Funmula/0c-sequence-d512`，MIT）。
 *
 * 模型檔在 assets 裡（不壓縮），開 session 時直接 mmap（不複製到 filesDir）。
 * 任何一步失敗（模型開不起來、IO、推論例外）都只記一行 Log 並在這次程序內停用——鍵盤照舊用引擎的字，
 * 不會崩潰。推論一律在單一背景執行緒跑，主執行緒不碰。
 */
object ZcReranker {
    private const val TAG = "ZcReranker"
    private const val MODEL_ASSET = "zc/zc-d512-slim-w4.ort"
    private const val VOCAB_ASSET = "zc/vocab.json"
    private const val MANIFEST_ASSET = "zc/manifest.json"

    @Volatile private var session: OrtSession? = null
    @Volatile private var vocab: ZcVocab? = null
    @Volatile private var disabled = false
    private var executor: ExecutorService? = null

    /** 推論執行緒（單一，避免同時開多個 OrtSession 工作）。 */
    fun executor(): ExecutorService = executor ?: synchronized(this) {
        executor ?: Executors.newSingleThreadExecutor { r -> Thread(r, "zc-rerank") }.also { executor = it }
    }

    private fun session(context: Context): OrtSession? {
        if (disabled) return null
        session?.let { return it }
        synchronized(this) {
            session?.let { return it }
            if (disabled) return null
            val created = try {
                // 直接把 assets 裡的模型 mmap 成 direct ByteBuffer 開 session（`openFd` 需要未壓縮，
                // build.gradle 有 `noCompress += "ort"`）。不複製到 filesDir，磁碟與寫入時間都省下來。
                val options = OrtSession.SessionOptions().apply { setIntraOpNumThreads(2) }
                // fd 只交給 AutoCloseInputStream 關一次：另外包一個 FileInputStream 再關會對同一個 fd
                // 關兩次（Android fdsan 會把它當錯誤，可能直接中止程序）。mmap 在 fd 關掉之後仍然有效。
                val afd = context.assets.openFd(MODEL_ASSET)
                val buffer = afd.createInputStream().use { stream ->
                    stream.channel.map(FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength)
                }
                val created = OrtEnvironment.getEnvironment().createSession(buffer, options)
                // 舊版複製到 filesDir/zc/ 的模型（35.8 MB）沒人會再讀，清掉。
                runCatching { File(context.filesDir, "zc").deleteRecursively() }
                vocab = ZcVocab.parse(
                    context.assets.open(VOCAB_ASSET).use { it.readBytes().toString(Charsets.UTF_8) },
                    context.assets.open(MANIFEST_ASSET).use { it.readBytes().toString(Charsets.UTF_8) },
                )
                created
            } catch (e: OrtException) {
                fail("OrtException：${e.message}"); null
            } catch (e: UnsatisfiedLinkError) {
                fail("UnsatisfiedLinkError：${e.message}"); null
            } catch (e: IOException) {
                fail("IOException：${e.message}"); null
            } catch (e: Exception) {
                fail("載入模型失敗：${e.message}"); null
            }
            if (created != null) session = created
            return created
        }
    }

    private fun fail(reason: String) {
        disabled = true
        Log.w(TAG, "0c 重排停用（本次程序）：$reason")
    }

    /** 已載入詞彙（測試用；沒載入回 null）。 */
    fun vocabOrNull(context: Context): ZcVocab? {
        session(context)
        return vocab
    }

    /** 供鍵盤用：在背景執行緒重排，回 null＝不重排（設定關、模型不可用、推論失敗）。 */
    fun rerankOnBackground(
        context: Context,
        contextText: String,
        readings: List<String>,
        kbest: List<Pair<String, Double>>,
        onDone: (String?) -> Unit,
    ) {
        executor().execute { onDone(infer(context, contextText, readings, kbest)) }
    }

    /** 只在推論執行緒上呼叫：唯一會碰 `session` 的地方（與 `release()` 序列化）。 */
    private fun infer(
        context: Context,
        contextText: String,
        readings: List<String>,
        kbest: List<Pair<String, Double>>,
    ): String? = try {
        val s = session(context)
        val v = vocab
        if (s == null || v == null) null
        else ZcRerank.rerank(OnnxScorer(s), v, contextText, readings, kbest)
    } catch (e: Exception) {
        Log.w(TAG, "重排失敗：${e.message}")
        null
    }

    /**
     * 關掉 session 釋放記憶體（`onTrimMemory`／`onDestroy` 用）。之後需要時會重新載入。
     * 關閉工作丟到推論執行緒跟推論序列化——主執行緒直接 `close()` 會跟背景的
     * `session.run` 撞到，原生層可能 use-after-free 閃退（實測 SIGSEGV）。
     */
    fun release() {
        executor().execute {
            synchronized(this) {
                try { session?.close() } catch (_: Exception) { }
                session = null
                vocab = null
            }
        }
    }

    /**
     * 測試用的同步入口：呼叫端等結果，但工作仍然丟到推論執行緒上跑，
     * 這樣連同 `release()` 都序列化在唯一碰 session 的執行緒上
     * （在呼叫端執行緒直接推論會跟排隊中的 `release()` 撞到 → 實測 SIGSEGV）。
     * 不要從推論執行緒自己呼叫（會自己等自己）。
     */
    fun rerankNow(context: Context, contextText: String, readings: List<String>, kbest: List<Pair<String, Double>>): String? = try {
        executor().submit<String?> { infer(context, contextText, readings, kbest) }.get()
    } catch (e: Exception) {
        Log.w(TAG, "重排失敗：${e.message}")
        null
    }

    /** 把九個特徵張量轉成 ONNX 的輸入。 */
    private class OnnxScorer(private val session: OrtSession) : ZcScorer {
        override fun score(f: ZcFeatures): FloatArray? {
            val env = OrtEnvironment.getEnvironment()
            fun longs(data: LongArray, shape: LongArray) = OnnxTensor.createTensor(env, LongBuffer.wrap(data), shape)
            val len = f.ids.size.toLong()
            val inputs = mapOf(
                "ids" to longs(f.ids, longArrayOf(1, len)),
                "bases" to longs(f.bases, longArrayOf(1, len)),
                "tones" to longs(f.tones, longArrayOf(1, len)),
                "types" to longs(f.types, longArrayOf(1, len)),
                "positions" to longs(f.positions, longArrayOf(1, len)),
                "mask" to OnnxTensor.createTensor(
                    env, ByteBuffer.wrap(ByteArray(f.mask.size) { if (f.mask[it]) 1 else 0 }),
                    longArrayOf(1, 1, len, len), OnnxJavaType.BOOL,
                ),
                "proj_pos" to longs(f.projPos, longArrayOf(f.projPos.size.toLong())),
                "target_node" to longs(
                    f.targetNode, longArrayOf(f.candidateCount.toLong(), f.syllableCount.toLong()),
                ),
                "target_ids" to longs(
                    f.targetIds, longArrayOf(f.candidateCount.toLong(), f.syllableCount.toLong()),
                ),
            )
            // 九個輸入張量與 result 都要關掉；忘了 close 會累積原生記憶體（每次推論 9 個）。
            var result: ai.onnxruntime.OrtSession.Result? = null
            try {
                result = session.run(inputs)
                return (result["scores"]!!.get().value) as FloatArray
            } finally {
                try { result?.close() } catch (_: Exception) { }
                inputs.values.forEach { t -> try { t.close() } catch (_: Exception) { } }
            }
        }
    }
}
