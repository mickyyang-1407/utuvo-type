package com.utuvo.type

import android.Manifest
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 診斷用（實機手動跑，不進 CI；沒存 key 就略過）：2026-10-20 Pixel 雲端辨識亂字的排查紀錄。
 * orderProbe＝麥克風搶用的證據；pipeProbe／fixProbe＝改成 pipe 餵系統辨識器的驗證。
 */
@RunWith(AndroidJUnit4::class)
class CloudAsrLiveProbeTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val app = inst.targetContext

    private fun samples(asset: String): FloatArray {
        val bytes = inst.context.assets.open("speech/$asset").readBytes()
        val buf = ByteBuffer.wrap(bytes, 44, bytes.size - 44).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray((bytes.size - 44) / 2) { buf.short / 32768f }
    }

    @Test fun probe() {
        val route = CloudASR.route(app)
        assumeTrue(route != null)
        val (provider, key) = route!!
        val packs = VocabularyPacks.biasing(app)
        Log.i(TAG, "provider=${provider.id} packs=${packs.size} chars=${packs.joinToString("、").length}")
        for (asset in listOf("question.wav", "connector.wav", "pauses.wav")) {
            val s = samples(asset)
            for ((label, hw) in listOf("none" to emptyList<String>(), "packs" to packs)) {
                val text = CloudASR.transcribe(s, "zh-TW", hw, provider, key)
                Log.i(TAG, "$asset [$label] → $text")
            }
        }
    }


    /** 麥克風實錄：Mac 會在第 1 秒開始唸一句。concurrent＝系統辨識器同時在聽（鍵盤實際情況）。 */
    @Test fun micProbe() {
        inst.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        val (provider, key) = CloudASR.route(app) ?: return
        val concurrent = InstrumentationRegistry.getArguments().getString("concurrent") == "1"
        var sr: SpeechRecognizer? = null
        if (concurrent) inst.runOnMainSync {
            sr = SpeechRecognizer.createSpeechRecognizer(app).apply {
                setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(p: Bundle?) {}; override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(v: Float) {}; override fun onBufferReceived(b: ByteArray?) {}
                    override fun onEndOfSpeech() {}; override fun onError(e: Int) { Log.i(TAG, "sr error $e") }
                    override fun onResults(r: Bundle?) { Log.i(TAG, "sr results ${r?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)}") }
                    override fun onPartialResults(r: Bundle?) {}; override fun onEvent(t: Int, p: Bundle?) {}
                })
                startListening(SpeechRequest.build("cmn-Hant-TW"))
            }
        }
        val rec = CloudRecorder()
        Log.i(TAG, "MIC_START concurrent=$concurrent started=${rec.start()}")
        Thread.sleep(6000)
        val s = rec.stop()
        inst.runOnMainSync { sr?.destroy() }
        val peak = s.maxOfOrNull { kotlin.math.abs(it) } ?: 0f
        val rms = if (s.isEmpty()) 0.0 else kotlin.math.sqrt(s.sumOf { (it * it).toDouble() } / s.size)
        Log.i(TAG, "MIC samples=${s.size} peak=$peak rms=$rms")
        java.io.File(app.cacheDir, "micprobe-$concurrent.wav").writeBytes(CloudASR.wav(s))
        Log.i(TAG, "MIC → ${CloudASR.transcribe(s, "zh-TW", emptyList(), provider, key)}")
    }


    /** 小聲的人聲＋手機底噪：trimSilence 會不會把說話剪掉。 */
    @Test fun quietProbe() {
        val (provider, key) = CloudASR.route(app) ?: return
        val noiseFile = java.io.File(app.cacheDir, "micprobe-false.wav")
        assumeTrue("先跑 micProbe 錄一段手機底噪", noiseFile.isFile)
        val nb = noiseFile.readBytes(); val nbuf = ByteBuffer.wrap(nb, 44, nb.size - 44).order(ByteOrder.LITTLE_ENDIAN)
        val noise = FloatArray((nb.size - 44) / 2) { nbuf.short / 32768f }
        for (asset in listOf("pauses.wav", "question.wav")) {
            val clean = samples(asset); val cp = clean.maxOf { kotlin.math.abs(it) }
            for (target in listOf(0.3f, 0.08f, 0.03f, 0.015f)) {
                val mixed = FloatArray(clean.size) { clean[it] / cp * target + noise[it % noise.size] }
                val trimmed = CloudASR.trimSilence(mixed)
                Log.i(TAG, "$asset peak=$target len=${mixed.size} trimmed=${trimmed.size} → ${CloudASR.transcribe(mixed, "zh-TW", emptyList(), provider, key)}")
            }
        }
    }


    /** 全 0 偵測（不需要講話）：系統辨識器先開 vs 自己的錄音先開，誰被靜音。 */
    @Test fun orderProbe() {
        inst.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        fun zeros(s: FloatArray) = if (s.isEmpty()) 1.0 else s.count { it == 0f }.toDouble() / s.size
        fun sr(): SpeechRecognizer { var r: SpeechRecognizer? = null; inst.runOnMainSync {
            r = SpeechRecognizer.createSpeechRecognizer(app).apply {
                setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(p: Bundle?) { Log.i(TAG, "sr ready") }; override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(v: Float) {}; override fun onBufferReceived(b: ByteArray?) {}
                    override fun onEndOfSpeech() {}; override fun onError(e: Int) { Log.i(TAG, "sr error $e") }
                    override fun onResults(r: Bundle?) {}; override fun onPartialResults(r: Bundle?) {}; override fun onEvent(t: Int, p: Bundle?) {}
                })
                startListening(SpeechRequest.build("cmn-Hant-TW"))
            } }; return r!! }
        // A：單獨
        run { val rec = CloudRecorder(); rec.start(); Thread.sleep(3000); val s = rec.stop(); Log.i(TAG, "ORDER alone zeros=${zeros(s)} n=${s.size}") }
        Thread.sleep(1500)
        // B：系統先開（鍵盤現在的順序）
        run { val r = sr(); Thread.sleep(500); val rec = CloudRecorder(); rec.start(); Thread.sleep(3000); val s = rec.stop(); inst.runOnMainSync { r.destroy() }; Log.i(TAG, "ORDER srFirst zeros=${zeros(s)} n=${s.size}") }
        Thread.sleep(1500)
        // B0：系統先開、立刻接著自己開（沒有間隔）
        run { val r = sr(); val rec = CloudRecorder(); rec.start(); Thread.sleep(3000); val s = rec.stop(); inst.runOnMainSync { r.destroy() }; Log.i(TAG, "ORDER srFirstNoGap zeros=${zeros(s)} n=${s.size}") }
        Thread.sleep(1500)
        // D：系統先開→自己開→系統中途重開（鍵盤停頓後重開辨識器）
        run { val r = sr(); Thread.sleep(300); val rec = CloudRecorder(); rec.start(); Thread.sleep(1500)
              inst.runOnMainSync { r.cancel(); r.startListening(SpeechRequest.build("cmn-Hant-TW")) }
              Thread.sleep(2000); val s = rec.stop(); inst.runOnMainSync { r.destroy() }
              val half = s.size / 2
              Log.i(TAG, "ORDER srRestart zeros=${zeros(s)} firstHalf=${zeros(s.copyOfRange(0, half))} secondHalf=${zeros(s.copyOfRange(half, s.size))}") }
        Thread.sleep(1500)
        // C：自己先開
        run { val rec = CloudRecorder(); rec.start(); Thread.sleep(500); val r = sr(); Thread.sleep(3000); val s = rec.stop(); inst.runOnMainSync { r.destroy() }; Log.i(TAG, "ORDER recFirst zeros=${zeros(s)} n=${s.size}") }
    }


    /** 用 pipe 把音訊即時餵給系統辨識器（雲端版／裝置端），看認不認。 */
    @Test fun pipeProbe() {
        for (onDevice in listOf(false, true)) {
            val bytes = inst.context.assets.open("speech/pauses.wav").readBytes()
            val pipe = android.os.ParcelFileDescriptor.createPipe()
            val out = android.os.ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
            val done = java.util.concurrent.CountDownLatch(1)
            var partial = ""; var final = ""
            var r: SpeechRecognizer? = null
            inst.runOnMainSync {
                r = (if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(app) else SpeechRecognizer.createSpeechRecognizer(app)).apply {
                    setRecognitionListener(object : RecognitionListener {
                        override fun onReadyForSpeech(p: Bundle?) { Log.i(TAG, "pipe[$onDevice] ready") }; override fun onBeginningOfSpeech() {}
                        override fun onRmsChanged(v: Float) {}; override fun onBufferReceived(b: ByteArray?) {}
                        override fun onEndOfSpeech() {}; override fun onError(e: Int) { Log.i(TAG, "pipe[$onDevice] error $e"); done.countDown() }
                        override fun onResults(b: Bundle?) { final = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty(); done.countDown() }
                        override fun onPartialResults(b: Bundle?) { partial = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: partial }
                        override fun onEvent(t: Int, p: Bundle?) {}
                    })
                    startListening(SpeechRequest.build("cmn-Hant-TW").apply {
                        putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
                        putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT)
                        putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                        putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
                    })
                }
            }
            // 即時節奏：每 100 ms 寫 3200 bytes
            var i = 44
            while (i < bytes.size) { val n = minOf(3200, bytes.size - i); out.write(bytes, i, n); i += n; Thread.sleep(100) }
            out.write(ByteArray(32000)); Thread.sleep(1000)
            done.await(8, java.util.concurrent.TimeUnit.SECONDS)
            runCatching { out.close() }
            inst.runOnMainSync { r?.destroy() }
            Log.i(TAG, "PIPE onDevice=$onDevice final=$final partial=$partial")
            Thread.sleep(1500)
        }
    }


    /** 修法驗證：自己錄（tap→pipe→系統辨識器，中途重開一次），自己的錄音不能被填 0。 */
    @Test fun fixProbe() {
        inst.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        fun zeros(s: FloatArray) = if (s.isEmpty()) 1.0 else s.count { it == 0f }.toDouble() / s.size
        val rec = CloudRecorder(); rec.start()
        val pipe = android.os.ParcelFileDescriptor.createPipe()
        val out = android.os.ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
        val q = java.util.concurrent.LinkedBlockingQueue<ByteArray>(256)
        val writer = Thread { try { while (true) { val b = q.take(); if (b.isEmpty()) break; out.write(b) } } catch (_: Exception) {} finally { runCatching { out.close() } } }.apply { start() }
        rec.pcmTap = { buf, n -> val b = ByteArray(n * 2); for (i in 0 until n) { val v = buf[i].toInt(); b[2*i] = (v and 0xFF).toByte(); b[2*i+1] = (v shr 8 and 0xFF).toByte() }; q.offer(b) }
        val intent = SpeechRequest.build("cmn-Hant-TW").apply {
            putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0].dup())
            putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT)
            putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
        }
        var r: SpeechRecognizer? = null
        inst.runOnMainSync { r = SpeechRecognizer.createSpeechRecognizer(app).apply {
            setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(p: Bundle?) { Log.i(TAG, "fix sr ready") }; override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(v: Float) {}; override fun onBufferReceived(b: ByteArray?) {}
                override fun onEndOfSpeech() {}; override fun onError(e: Int) { Log.i(TAG, "fix sr error $e") }
                override fun onResults(b: Bundle?) {}; override fun onPartialResults(b: Bundle?) {}; override fun onEvent(t: Int, p: Bundle?) {}
            })
            startListening(intent) } }
        Thread.sleep(2000)
        inst.runOnMainSync { r!!.cancel(); intent.putExtra(android.speech.RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0].dup()); r!!.startListening(intent) }
        Thread.sleep(2500)
        val s = rec.stop(); rec.pcmTap = null; q.offer(ByteArray(0)); writer.join(2000)
        inst.runOnMainSync { r?.destroy() }
        val h = s.size / 2
        Log.i(TAG, "FIX zeros=${zeros(s)} firstHalf=${zeros(s.copyOfRange(0, h))} secondHalf=${zeros(s.copyOfRange(h, s.size))} peak=${s.maxOf { kotlin.math.abs(it) }}")
    }


    @Test fun dumpBiasing() {
        Log.i(TAG, "BIAS " + VocabularyPacks.biasing(app).joinToString("|"))
        Log.i(TAG, "PROMPT " + CloudASR.groqPrompt("zh-TW", VocabularyPacks.cloudHints(app)))
    }

    companion object { const val TAG = "AsrProbe" }
}
