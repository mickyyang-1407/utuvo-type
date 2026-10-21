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
 * 2026-10-13 Typeless 對齊：鍵盤「問問題」走完整條真實路徑——
 * 鍵盤聽一段合成英文問句（debugAudioFile）→ 裝置端辨識 → 使用者自己的整理 key（Groq）→ 回答卡 → 插入。
 * key 由 instrumentation 參數 groqKey 傳入（只存進模擬器的 SecretStore，結束就刪）；沒傳就跳過。
 */
@RunWith(AndroidJUnit4::class)
class AskAnythingDeviceTest {
    private val inst get() = InstrumentationRegistry.getInstrumentation()
    private val device get() = UiDevice.getInstance(inst)
    private val app: Context get() = inst.targetContext
    private val imeId get() = app.packageName + "/" + UTUVOImeService::class.java.name
    private val prefs get() = app.getSharedPreferences("keyboard", Context.MODE_PRIVATE)
    private val keyField = SmartCleanup.Provider.GROQ.secretField

    private var savedLanguage: DictationLanguage = DictationLanguage.TRADITIONAL_CHINESE
    private var savedProvider: SmartCleanup.Provider? = null
    private var savedCloudRecognition = false
    private var hadKey = false
    private lateinit var savedHistory: List<HistoryStore.Record>

    @Before fun setUp() {
        val key = InstrumentationRegistry.getArguments().getString("groqKey").orEmpty()
        assumeTrue("沒有傳入 groqKey", key.isNotBlank())
        assumeTrue("這台沒有裝置端辨識", SpeechRecognizer.isOnDeviceRecognitionAvailable(app))
        savedHistory = HistoryStore.load(app)
        savedLanguage = DictationLanguage.current(app)
        savedProvider = SmartCleanup.provider(app)
        savedCloudRecognition = SmartCleanup.cloudRecognitionPreferred(app)
        hadKey = SecretStore.hasKey(app, keyField)
        assumeTrue("模擬器上已經有一把 Groq key，不覆蓋", !hadKey)
        SecretStore.save(app, key, keyField)
        SmartCleanup.setProvider(app, SmartCleanup.Provider.GROQ)
        SmartCleanup.setCloudRecognitionPreferred(app, false)
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
        if (!hadKey) SecretStore.delete(app, keyField)
        savedProvider?.let { SmartCleanup.setProvider(app, it) }
        SmartCleanup.setCloudRecognitionPreferred(app, savedCloudRecognition)
        DictationLanguage.set(app, savedLanguage)
        if (::savedHistory.isInitialized) HistoryStore.restore(app, savedHistory)
    }

    @Test fun askAnythingShowsAnswerAndInserts() {
        prefs.edit().putString("debugAudioFile", pcmFromAsset("speech/ask-capital-en.wav").path).commit()
        val field = device.findObject(By.desc("tryField"))
        field.text = ""
        field.click()
        var ask = device.wait(Until.findObject(By.desc(app.getString(R.string.voice_mode_ask_anything))), 15_000)
        if (ask == null) {
            // 剛 `ime set` 完，第一次點輸入框偶爾還是系統鍵盤（模擬器時序）：再切一次、再點一次。
            device.executeShellCommand("ime set $imeId")
            device.pressBack()
            device.findObject(By.desc("tryField")).click()
            ask = device.wait(Until.findObject(By.desc(app.getString(R.string.voice_mode_ask_anything))), 15_000)
        }
        assertNotNull("鍵盤上沒有「問問題」", ask)
        ask.click()
        val orb = device.wait(Until.findObject(By.desc(app.getString(R.string.orb))), 5_000)
        assertNotNull("找不到光球", orb)
        orb.click()
        Thread.sleep(6_000)   // 問句約 2 秒：聽完再停
        device.findObject(By.desc(app.getString(R.string.orb)))?.click()
        val card = device.wait(Until.findObject(By.desc(app.getString(R.string.answer_card))), 40_000)
        assertNotNull("沒有出現回答卡", card)
        val answer = card.text.orEmpty()
        assertTrue("回答不像在回答問題：「$answer」", answer.contains("Paris", ignoreCase = true))
        assertTrue("回答卡出現前就把文字貼進輸入框了", device.findObject(By.desc("tryField"))?.text.orEmpty().isBlank() ||
            !device.findObject(By.desc("tryField")).text.contains("Paris", ignoreCase = true))
        device.findObject(By.desc(app.getString(R.string.answer_insert))).click()
        val inserted = device.wait(Until.hasObject(By.desc("tryField").textContains("Paris")), 10_000)
        assertTrue("按「插入」後輸入框沒有答案：「${device.findObject(By.desc("tryField"))?.text}」", inserted)
    }

    /** 幫我寫：講要寫什麼 → 文字直接插進輸入框 → 出現復原卡 → 按「復原」整段拿掉（AGY r1：復原曾 100% 失敗）。 */
    @Test fun helpMeWriteInsertsAndUndoRemovesIt() {
        prefs.edit().putString("debugAudioFile", pcmFromAsset("speech/help-write-en.wav").path).commit()
        val field = device.findObject(By.desc("tryField"))
        field.text = ""
        field.click()
        var chip = device.wait(Until.findObject(By.desc(app.getString(R.string.voice_mode_help_write))), 15_000)
        if (chip == null) {
            device.executeShellCommand("ime set $imeId")
            device.pressBack()
            device.findObject(By.desc("tryField")).click()
            chip = device.wait(Until.findObject(By.desc(app.getString(R.string.voice_mode_help_write))), 15_000)
        }
        assertNotNull("鍵盤上沒有「幫我寫」", chip)
        chip.click()
        device.wait(Until.findObject(By.desc(app.getString(R.string.orb))), 5_000)!!.click()
        Thread.sleep(7_000)
        device.findObject(By.desc(app.getString(R.string.orb)))?.click()
        val written = device.wait(Until.hasObject(By.desc("tryField").textContains("Anna")), 40_000)
        assertTrue("幫我寫沒有把文字插進輸入框：「${device.findObject(By.desc("tryField"))?.text}」", written)
        val undo = device.wait(Until.findObject(By.desc(app.getString(R.string.answer_undo))), 5_000)
        assertNotNull("插入後沒有出現「復原」", undo)
        undo.click()
        val gone = device.wait(Until.gone(By.desc("tryField").textContains("Anna")), 5_000)
        assertTrue("按「復原」後文字還在：「${device.findObject(By.desc("tryField"))?.text}」", gone)
    }

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
