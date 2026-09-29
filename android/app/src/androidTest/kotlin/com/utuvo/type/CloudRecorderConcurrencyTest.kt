package com.utuvo.type

import android.Manifest
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/**
 * B2 的實機風險：雲端辨識要自己錄音，同時系統 SpeechRecognizer 也在聽（做即時預覽／退路）。
 * Android 同時有兩個錄音者時，其中一個可能只拿到全 0（被系統靜音）。這條直接在手機上量：
 * 系統辨識器開著的時候，CloudRecorder 錄到的樣本不能整段都是 0。
 */
@RunWith(AndroidJUnit4::class)
class CloudRecorderConcurrencyTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val app = inst.targetContext

    private fun peak(samples: FloatArray) = samples.maxOfOrNull { abs(it) } ?: 0f

    @Test fun recorderAloneHearsTheRoom() {
        inst.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        val rec = CloudRecorder()
        assertTrue("錄音器啟動失敗", rec.start())
        Thread.sleep(1500)
        val s = rec.stop()
        println("CONCURRENCY alone samples=${s.size} peak=${peak(s)}")
        assertTrue("單獨錄音就拿不到聲音（樣本 ${s.size}、峰值 ${peak(s)}）", s.isNotEmpty() && peak(s) > 0f)
    }

    @Test fun recorderStillHearsWhileSystemRecognizerListens() {
        inst.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        var sr: SpeechRecognizer? = null
        val events = mutableListOf<String>()
        inst.runOnMainSync {
            sr = SpeechRecognizer.createSpeechRecognizer(app)
            sr!!.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(p: Bundle?) { events += "ready" }
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(v: Float) {}
                override fun onBufferReceived(b: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(e: Int) { events += "error$e" }
                override fun onResults(r: Bundle?) { events += "results" }
                override fun onPartialResults(r: Bundle?) {}
                override fun onEvent(t: Int, p: Bundle?) {}
            })
            sr!!.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-TW")
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true))
        }
        Thread.sleep(800)   // 讓系統辨識器先開麥克風
        val rec = CloudRecorder()
        val started = rec.start()
        Thread.sleep(2000)
        val s = rec.stop()
        inst.runOnMainSync { sr?.cancel(); sr?.destroy() }
        println("CONCURRENCY with-recognizer started=$started samples=${s.size} peak=${peak(s)} events=$events")
        assertTrue("系統辨識器開著時 CloudRecorder 啟動失敗（events=$events）", started)
        assertTrue("系統辨識器開著時 CloudRecorder 只錄到靜音（樣本 ${s.size}、峰值 ${peak(s)}，events=$events）",
            s.isNotEmpty() && peak(s) > 0f)
    }
}
