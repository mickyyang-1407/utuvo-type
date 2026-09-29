package com.utuvo.type

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.mlkit.nl.translate.TranslateLanguage
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 長按翻譯走的同一個 Translation.translate：中文 → 英／日，在手機上真的翻（第一次會下載模型，要連網）。
 * 用鍵盤整理後會送進來的那種句子（有全形標點）。
 */
@RunWith(AndroidJUnit4::class)
class TranslateOnDeviceTest {
    private val app = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext

    private fun translate(text: String, target: String): String {
        val t = Translation.all.first { it.code == target }
        val done = CountDownLatch(1)
        var out: Result<String>? = null
        Translation.translateOnDevice(app, text, t) { out = it; done.countDown() }
        assertTrue("翻譯 3 分鐘沒回來（模型下載？）", done.await(180, TimeUnit.SECONDS))
        val r = out!!.getOrElse { throw AssertionError("翻成 $target 失敗", it) }
        Log.i("UTUVOTranslateTest", "$target「$text」→「$r」")
        return r
    }

    @Test
    fun chineseToEnglish() {
        val en = translate("今天天氣很好，我們去公園散步吧。", TranslateLanguage.ENGLISH).lowercase()
        assertTrue("英文要講到天氣與公園：$en", en.contains("weather") && en.contains("park"))
    }

    @Test
    fun chineseToJapanese() {
        // 09-19 實測：「明天下午三點開會。」ML Kit 翻成「明日は午後に3人で会います」（三點→3人）——品質有限，
        // 這裡只驗「真的翻成日文、意思沒整句跑掉」，不拿一個翻錯的句子當通過條件。
        val ja = translate("今天天氣很好，我們去公園散步吧。", TranslateLanguage.JAPANESE)
        assertTrue("日文要有假名：$ja", ja.any { it in '\u3040'..'\u30FF' })
        assertTrue("日文要有「公園」：$ja", ja.contains("公園"))
    }

    /** 品質探針：不斷言，只把結果印出來（logcat UTUVOTranslateTest），給人看翻得像不像話。 */
    @Test
    fun qualityProbe() {
        val lines = listOf("明天下午要開會", "我們明天開會", "會議改到明天下午三點", "請幫我訂一張明天去台北的車票", "我等一下打給你", "這個方案我覺得可以，但預算要再砍一點")
        for (t in listOf(TranslateLanguage.ENGLISH, TranslateLanguage.JAPANESE)) for (l in lines) {
            translate(l, t)
        }
    }

    @Test
    fun everyQuickPickTargetIsSupportedByMlKit() {
        val supported = TranslateLanguage.getAllLanguages().toSet()
        Translation.quickPick(app).forEach { assertTrue("${it.code} 不是 ML Kit 支援的語言", it.code in supported) }
    }
}
