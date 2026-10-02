package com.utuvo.type

import android.content.Context
import android.content.Intent
import android.speech.SpeechRecognizer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * 2026-10-01 Micky：「只要稍微停頓一下就會自動結束」（iOS 已經不會，Android 還會）。
 * 走真的鍵盤服務：開發版的 `debugAudioFile` 讓鍵盤「聽」一段「講一句 → 停 3.5 秒 → 再講一句」的錄音，
 * 12 秒後點光球停止；輸入框裡前後兩句都要在（以前停頓那裡就斷了，只剩第一句）。
 * 需要裝置端繁中語音包（Pixel 有；模擬器沒有就跳過）；輸入法要先用 android/scripts/run-device-tests.sh 啟用。
 */
@RunWith(AndroidJUnit4::class)
class PauseKeepsDictatingTest {
    private val inst get() = InstrumentationRegistry.getInstrumentation()
    private val device get() = UiDevice.getInstance(inst)
    private val app: Context get() = inst.targetContext
    private val imeId get() = app.packageName + "/" + UTUVOImeService::class.java.name
    private val prefs get() = app.getSharedPreferences("keyboard", Context.MODE_PRIVATE)

    private lateinit var savedHistory: List<HistoryStore.Record>
    private var savedLanguage: DictationLanguage = DictationLanguage.TRADITIONAL_CHINESE
    private var savedCloudRecognition = false

    @Before fun setUp() {
        assumeTrue("這台沒有裝置端辨識", SpeechRecognizer.isOnDeviceRecognitionAvailable(app))
        savedHistory = HistoryStore.load(app)
        savedLanguage = DictationLanguage.current(app)
        savedCloudRecognition = SmartCleanup.cloudRecognitionPreferred(app)
        SmartCleanup.setCloudRecognitionPreferred(app, false)   // 走系統辨識器（雲端辨識錄的是麥克風，不吃音檔）
        device.setOrientationPortrait()
        // 重裝 APK 會清掉麥克風權限；鍵盤按光球第一步就檢查它（沒有就跳回主 app 要權限）。
        inst.uiAutomation.grantRuntimePermission(app.packageName, android.Manifest.permission.RECORD_AUDIO)
        device.executeShellCommand("ime set $imeId")
        app.startActivity(Intent(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        assertTrue(device.wait(Until.hasObject(By.desc("tryField")), 10_000))
    }

    @After fun tearDown() {
        prefs.edit().remove("debugAudioFile").commit()
        if (::savedHistory.isInitialized) HistoryStore.restore(app, savedHistory)
        DictationLanguage.set(app, savedLanguage)
        SmartCleanup.setCloudRecognitionPreferred(app, savedCloudRecognition)
    }

    /** 繁中（裝置端繁中語音包，Pixel）。 */
    @Test fun pauseInTheMiddleDoesNotEndDictation() {
        assumeTrue("沒有裝置端繁中語音包（模擬器下載不到；Pixel 有）", hasOnDeviceTraditionalChinese())
        dictate(DictationLanguage.TRADITIONAL_CHINESE, "speech/long-pause.wav", "錄音室", "耳機")
    }

    private fun hasOnDeviceTraditionalChinese(): Boolean {
        val latch = java.util.concurrent.CountDownLatch(1)
        var installed = emptyList<String>()
        var recognizer: SpeechRecognizer? = null
        inst.runOnMainSync {
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(app).apply {
                checkRecognitionSupport(SpeechRequest.build("cmn-Hant-TW"), app.mainExecutor,
                    object : android.speech.RecognitionSupportCallback {
                        override fun onSupportResult(s: android.speech.RecognitionSupport) { installed = s.installedOnDeviceLanguages; latch.countDown() }
                        override fun onError(e: Int) { latch.countDown() }
                    })
            }
        }
        latch.await(20, java.util.concurrent.TimeUnit.SECONDS)
        inst.runOnMainSync { recognizer?.destroy() }
        return installed.any { it.contains("Hant", true) || it.equals("zh-TW", true) }
    }

    /** 英文（模擬器也有英文裝置端包）：同一套「停頓不斷」機制，跟語言無關。 */
    @Test fun pauseInTheMiddleDoesNotEndDictationEnglish() =
        dictate(DictationLanguage.ENGLISH, "speech/long-pause-en.wav", "studio", "headphones")

    private fun dictate(language: DictationLanguage, asset: String, before: String, after: String) {
        assumeTrue("沒有測試錄音（公開版不附）",
            runCatching { inst.context.assets.list("speech")?.contains(asset.substringAfterLast('/')) == true }.getOrDefault(false))
        DictationLanguage.set(app, language)
        prefs.edit().putString("debugAudioFile", pcmFromAsset(asset).path).commit()
        val field = device.findObject(By.desc("tryField"))
        field.text = ""
        field.click()
        val orb = device.wait(Until.findObject(By.desc(app.getString(R.string.orb))), 15_000)
        assertNotNull("鍵盤沒出現（找不到光球）", orb)
        orb.click()
        // 錄音 7.7 秒（中間停 3.5 秒）：等它整段聽完，再點光球停止。
        Thread.sleep(12_000)
        device.findObject(By.desc(app.getString(R.string.orb)))?.click()
        val both = device.wait(Until.hasObject(By.desc("tryField").textContains(after)), 20_000)
        val text = device.findObject(By.desc("tryField"))?.text.orEmpty()
        assertTrue("停頓前那句不見了：「$text」", text.contains(before, ignoreCase = true))
        assertTrue("停頓後那句沒進來（停頓就斷了）：「$text」", both && text.contains(after, ignoreCase = true))
    }

    /** 測試素材是 WAV：取出 data 區塊（afconvert 會多塞 FLLR 之類的區塊，不能固定跳 44 bytes）。 */
    private fun pcmFromAsset(name: String): File {
        val bytes = inst.context.assets.open(name).readBytes()
        var i = 12
        var start = 44; var length = bytes.size - 44
        while (i + 8 <= bytes.size) {
            val id = String(bytes, i, 4, Charsets.US_ASCII)
            val size = (bytes[i + 4].toInt() and 0xff) or ((bytes[i + 5].toInt() and 0xff) shl 8) or
                ((bytes[i + 6].toInt() and 0xff) shl 16) or ((bytes[i + 7].toInt() and 0xff) shl 24)
            if (id == "data") { start = i + 8; length = minOf(size, bytes.size - start); break }
            i += 8 + size + (size and 1)
        }
        return File(app.cacheDir, name.substringAfterLast('/') + ".pcm").apply { writeBytes(bytes.copyOfRange(start, start + length)) }
    }
}
