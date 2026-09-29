package com.utuvo.type

import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.SpeechPunctuation
import com.utuvo.type.core.TaiwanPhrases
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 不用對著手機講話也能驗語音：androidTest/assets/speech/ 裡的 wav（Mac `say -v Meijia` 產生、16 kHz 單聲道，
 * 句中用 [[slnc 700]] 做停頓）直接餵給裝置端辨識器（Android 13+ 的 EXTRA_AUDIO_SOURCE），
 * 請求用鍵盤同一份 SpeechRequest.build，辨識完走鍵盤同一套整理。
 *
 * 09-19 實測：沒開 EXTRA_ENABLE_FORMATTING 時三句全部零標點（Micky 回報「完全沒有標點符號」）。
 * 音訊檔來源時最終結果是空的、字只在即時結果裡，所以這裡跟鍵盤一樣用最後一次即時結果墊底。
 */
@RunWith(AndroidJUnit4::class)
class RecognizeFileTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val app = inst.targetContext

    /** 連續送請求時辨識服務偶爾還沒放掉上一個工作（error 11 SERVER_DISCONNECTED）：間隔一下、遇到就重試一次。 */
    private fun recognize(asset: String): String {
        Thread.sleep(1500)
        val first = recognizeOnce(asset)
        if (first.second != SpeechRecognizer.ERROR_SERVER_DISCONNECTED) return first.first
        Thread.sleep(3000)
        return recognizeOnce(asset).first
    }

    private fun recognizeOnce(asset: String): Pair<String, Int?> {
        val bytes = inst.context.assets.open("speech/$asset").readBytes()
        val pcm = File(app.cacheDir, "$asset.pcm").apply { writeBytes(bytes.copyOfRange(44, bytes.size)) }   // 去掉 wav 檔頭
        val pfd = ParcelFileDescriptor.open(pcm, ParcelFileDescriptor.MODE_READ_ONLY)
        val done = CountDownLatch(1)
        var final = ""
        var lastPartial = ""
        var error: Int? = null
        var recognizer: SpeechRecognizer? = null
        val intent: Intent = SpeechRequest.build("cmn-Hant-TW").apply {
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pfd)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
        }
        inst.runOnMainSync {
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(app).apply {
                setRecognitionListener(object : RecognitionListener {
                    override fun onResults(results: Bundle) {
                        final = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                        done.countDown()
                    }
                    override fun onPartialResults(partialResults: Bundle?) {
                        lastPartial = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: lastPartial
                    }
                    override fun onError(code: Int) { Log.w(TAG, "$asset error $code"); error = code; done.countDown() }
                    override fun onReadyForSpeech(params: Bundle?) {}
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {}
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })
                startListening(intent)
            }
        }
        done.await(30, TimeUnit.SECONDS)
        inst.runOnMainSync { recognizer?.destroy() }
        pfd.close()
        val raw = final.trim().ifEmpty { lastPartial.trim() }
        val cleaned = SpeechPunctuation.restore(
            Normalizer().normalize(TaiwanPhrases.apply(raw)).cleaned,
            SpeechPunctuation.Field.DOCUMENT
        )
        Log.i(TAG, "$asset raw=「$raw」 cleaned=「$cleaned」")
        return cleaned to error
    }

    @Test
    fun speechGetsPunctuation() {
        assumeTrue("這台沒有裝置端辨識", SpeechRecognizer.isOnDeviceRecognitionAvailable(app))
        // 錄音是 Mac `say -v Meijia` 合成的：系統語音授權只到個人、非商業使用，所以公開 repo 不帶這三個 wav。
        assumeTrue("沒有測試錄音（公開版不附）", runCatching { inst.context.assets.list("speech")?.contains("pauses.wav") == true }.getOrDefault(false))
        val pauses = recognize("pauses.wav")
        val question = recognize("question.wav")
        val connector = recognize("connector.wav")
        assertTrue("辨識不到字：「$pauses」", pauses.length >= 10)
        assertTrue("停頓要有逗號或句號：「$pauses」", pauses.contains('，') || pauses.contains('。'))
        assertTrue("「你要一起來嗎」要有問號：「$pauses」", pauses.endsWith("？"))
        assertTrue("「要吃什麼」要有問號：「$question」", question.endsWith("？"))
        assertTrue("「但是／所以」前要有逗號：「$connector」", connector.count { it == '，' } >= 1)
    }

    private companion object { const val TAG = "UTUVOSpeechTest" }
}
