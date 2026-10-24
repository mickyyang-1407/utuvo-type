package com.utuvo.type

import android.content.Context
import android.content.Intent
import android.speech.SpeechRecognizer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.utuvo.type.core.HistoryRetention
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * W2-5 走真的鍵盤服務（開發版 `debugAudioFile` 讓鍵盤「聽」測試錄音，不開麥克風）：
 *  - mobile-keyboard-1：錄音中按 ✕ → 什麼都不貼、歷史與秒數不變；之後再講一次照常貼。
 *  - delivery-learning-5：一般聽寫貼上之後頂列有「復原」，按了收回這一段。
 *  - mobile-keyboard-2：按住光球不動、在光球上放開 → 不開始錄音，提示「不用按住」。
 * 用英文裝置端辨識（模擬器也有）；輸入法要先用 android/scripts/run-device-tests.sh 啟用。
 */
@RunWith(AndroidJUnit4::class)
class VoiceCancelUndoDeviceTest {
    private val inst get() = InstrumentationRegistry.getInstrumentation()
    private val device get() = UiDevice.getInstance(inst)
    private val app: Context get() = inst.targetContext
    private val imeId get() = app.packageName + "/" + UTUVOImeService::class.java.name
    private val prefs get() = app.getSharedPreferences("keyboard", Context.MODE_PRIVATE)

    private lateinit var savedHistory: List<HistoryStore.Record>
    private var savedLanguage: DictationLanguage = DictationLanguage.TRADITIONAL_CHINESE
    private var savedCloudRecognition = false
    private var savedRetention: HistoryRetention? = null

    @Before fun setUp() {
        assumeTrue("這台沒有裝置端辨識", SpeechRecognizer.isOnDeviceRecognitionAvailable(app))
        savedHistory = HistoryStore.load(app)
        savedLanguage = DictationLanguage.current(app)
        savedCloudRecognition = SmartCleanup.cloudRecognitionPreferred(app)
        savedRetention = HistoryRetentionSetting.setting(app)
        SmartCleanup.setCloudRecognitionPreferred(app, false)   // 走系統辨識器（雲端辨識錄的是麥克風，不吃音檔）
        HistoryRetentionSetting.set(app, HistoryRetention.FOREVER)   // 「不保留」時歷史本來就不寫，測不出「取消不寫」
        DictationLanguage.set(app, DictationLanguage.ENGLISH)
        device.setOrientationPortrait()
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
        savedRetention?.let { HistoryRetentionSetting.set(app, it) }
    }

    private fun requireAsset(name: String) = assumeTrue("沒有測試錄音（公開版不附）",
        runCatching { inst.context.assets.list("speech")?.contains(name) == true }.getOrDefault(false))

    private fun fieldText() = device.findObject(By.desc("tryField"))?.text.orEmpty()

    /** 叫出鍵盤；回傳輸入框當下讀到的文字（空的輸入框 UiAutomator 讀到的是提示字，之後拿它比對「沒有變」）。 */
    private fun openKeyboard(initial: String): String {
        val field = device.findObject(By.desc("tryField"))
        field.text = initial
        field.click()
        // 剛裝好的第一次綁定輸入法比較慢：沒出現就再點一次輸入框。
        val orb = device.wait(Until.findObject(By.desc(app.getString(R.string.orb))), 15_000)
            ?: device.findObject(By.desc("tryField")).click().let {
                device.wait(Until.findObject(By.desc(app.getString(R.string.orb))), 15_000)
            }
        assertNotNull("鍵盤沒出現（找不到光球）", orb)
        return fieldText()
    }

    private fun orb() = device.findObject(By.desc(app.getString(R.string.orb)))
    private val cancelDesc get() = app.getString(R.string.key_cancel_voice)
    private val undoDesc get() = app.getString(R.string.undo_insert_desc)
    private fun usageSeconds() = UsageStore.load(app).days.values.sumOf { it.seconds }

    @Test fun cancelWhileRecordingInsertsNothingAndTheNextTurnStillWorks() {
        requireAsset("long-pause-en.wav")
        prefs.edit().putString("debugAudioFile", pcmFromAsset("speech/long-pause-en.wav").path).commit()
        val historyBefore = HistoryStore.load(app).size
        val secondsBefore = usageSeconds()
        val empty = openKeyboard("")
        orb().click()
        val cancel = device.wait(Until.findObject(By.desc(cancelDesc)), 5_000)
        assertNotNull("錄音中要有 ✕", cancel)
        Thread.sleep(4_000)   // 聽到一部分（第一句已經出來）再取消
        cancel!!.click()
        assertTrue("要講「已取消，沒有貼上文字」",
            device.wait(Until.hasObject(By.text(app.getString(R.string.hint_voice_cancelled))), 3_000))
        assertTrue("取消之後 ✕ 要收起", device.wait(Until.gone(By.desc(cancelDesc)), 3_000))
        Thread.sleep(8_000)   // 系統辨識器晚到的 onResults／onError 都不能貼字
        assertEquals("取消了還貼字", empty, fieldText())
        assertEquals("取消不能寫歷史", historyBefore, HistoryStore.load(app).size)
        assertEquals("取消不能記秒數", secondsBefore, usageSeconds())
        // 不是把鍵盤弄壞：下一次照常聽寫、照常貼。
        prefs.edit().putString("debugAudioFile", pcmFromAsset("speech/long-pause-en.wav").path).commit()
        orb().click()
        Thread.sleep(12_000)
        orb().click()
        assertTrue("取消之後的下一次沒貼字：「${fieldText()}」",
            device.wait(Until.hasObject(By.desc("tryField").textContains("headphones")), 20_000))
    }

    @Test fun undoChipRemovesThePlainDictation() {
        requireAsset("long-pause-en.wav")
        prefs.edit().putString("debugAudioFile", pcmFromAsset("speech/long-pause-en.wav").path).commit()
        openKeyboard("Note: ")
        assertFalse("還沒聽寫不該有「復原」", device.hasObject(By.desc(undoDesc)))
        orb().click()
        Thread.sleep(12_000)
        orb().click()
        assertTrue("沒有貼字：「${fieldText()}」",
            device.wait(Until.hasObject(By.desc("tryField").textContains("headphones")), 20_000))
        val undo = device.wait(Until.findObject(By.desc(undoDesc)), 5_000)
        assertNotNull("一般聽寫貼上之後頂列要有「復原」", undo)
        undo!!.click()
        assertTrue("復原要收回這一段：「${fieldText()}」",
            device.wait(Until.hasObject(By.desc("tryField").text("Note: ")), 5_000))
        assertTrue("復原只能一次", device.wait(Until.gone(By.desc(undoDesc)), 3_000))
    }

    @Test fun holdingTheOrbStillShowsTheTapTip() {
        val empty = openKeyboard("")
        val bounds = orb().visibleBounds
        // 按住不動 1.5 秒（swipe 同一點：每步約 5ms）再放開，手指一直在光球上。
        device.swipe(bounds.centerX(), bounds.centerY(), bounds.centerX(), bounds.centerY(), 300)
        assertTrue("按住不動放開要提示「不用按住」",
            device.wait(Until.hasObject(By.text(app.getString(R.string.hint_hold_tip))), 3_000))
        assertFalse("按住放開不能開始錄音", device.hasObject(By.desc(cancelDesc)))
        Thread.sleep(1_000)
        assertEquals(empty, fieldText())
    }

    /** 測試素材是 WAV：取出 data 區塊（同 PauseKeepsDictatingTest）。 */
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
