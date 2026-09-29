package com.utuvo.type

import android.content.Intent
import android.speech.RecognizerIntent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.mlkit.nl.translate.TranslateLanguage
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A5：語言徽章（聽寫語言）＋ 可設定的翻譯弧。
 *
 * 這支測的是「設定真的影響鍵盤送出去的東西」：徽章選 EN 之後 `SpeechRequest` 送的就是 en-US，
 * 弧上的順序跟主 app 選的一樣。偏好設定前存後還原（Micky 真的在用的鍵盤，不留痕跡）。
 */
@RunWith(AndroidJUnit4::class)
class LanguageBadgeArcTest {
    private val app = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefs = PrefsSnapshot(app, DictationLanguage.PREFS)

    @Before fun setUp() { prefs.restore() }   // 快照在 init 就取，這裡只是語意上先存一次

    @After fun tearDown() { prefs.restore() }

    private fun speechLanguage(): String =
        SpeechRequest.build(DictationLanguage.current(app).code)
            .getStringExtra(RecognizerIntent.EXTRA_LANGUAGE)!!

    // ── 聽寫語言徽章 ──

    @Test
    fun defaultIsTraditionalChinese() {
        assertEquals("zh-TW", speechLanguage())
    }

    @Test
    fun badgeSelectionChangesSpeechRequestLanguage() {
        for (language in DictationLanguage.all) {
            DictationLanguage.set(app, language)          // ＝使用者點徽章選單選了它
            assertEquals("選了 ${language.code} 就要送 ${language.code}", language.code, speechLanguage())
        }
    }

    @Test
    fun englishBadgeSendsEnUs() {
        DictationLanguage.set(app, DictationLanguage.ENGLISH)
        assertEquals("en-US", speechLanguage())
    }

    @Test
    fun unknownStoredLanguageFallsBackToTraditionalChinese() {
        DictationLanguage.set(app, DictationLanguage.JAPANESE)
        app.getSharedPreferences(DictationLanguage.PREFS, android.content.Context.MODE_PRIVATE)
            .edit().putString("dictationLanguage", "xx-YY").commit()
        assertEquals("壞掉的代碼要回繁中，鍵盤不能沒有語言", "zh-TW", speechLanguage())
    }

    @Test
    fun speechIntentKeepsPunctuationAndBiasing() {
        // 換語言不該把 Android 13+ 的標點／個人字典弄掉。
        DictationLanguage.set(app, DictationLanguage.ENGLISH)
        val intent: Intent = SpeechRequest.build(DictationLanguage.current(app).code, listOf("Micky"))
        assertEquals("en-US", intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            // EXTRA_ENABLE_FORMATTING 是字串（quality／latency），不是 boolean。
            assertEquals("標點要開", RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
                intent.getStringExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING))
            assertEquals(listOf("Micky"), intent.getStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS))
        }
    }

    @Test
    fun speechLanguageCodeMatchesEachBadgeLabel() {
        // 徽章短名要是「繁中／简中／EN／日本語／한국어」，一列對一個語言（UI 測試也拿它當把手）。
        val short = DictationLanguage.all.map { app.getString(it.shortRes) }
        assertEquals(listOf("繁中", "简中", "EN", "日本語", "한국어"), short)
        assertEquals(listOf("zh-TW", "zh-CN", "en-US", "ja-JP", "ko-KR"), DictationLanguage.all.map { it.code })
    }

    // ── 翻譯弧 ──

    @Test
    fun arcOrderFollowsTheSelectedOrder() {
        val picked = listOf(TranslateLanguage.GERMAN, TranslateLanguage.ENGLISH, TranslateLanguage.JAPANESE)
        Translation.setQuickPickCodes(app, picked)
        assertEquals("弧上順序要照選的順序", picked, Translation.quickPickCodes(app))
        assertEquals(picked, Translation.quickPick(app).map { it.code })
    }

    @Test
    fun arcKeepsTheStoredOrderAfterAFullFive() {
        val five = listOf("de", "fr", "ja", "ko", "en")
        Translation.setQuickPickCodes(app, five)
        assertEquals(five, Translation.quickPick(app).map { it.code })
    }

    @Test
    fun arcNeverExceedsFiveAndAlwaysHasAtLeastOne() {
        assertEquals(5, Translation.MAX_QUICK_PICK)
        val all = Translation.all.map { it.code }
        assertEquals("超過 5 個就多加不進去", all.take(5), Translation.toggled(all[5], all.take(5)))
        assertEquals("最後一個不能被移除", listOf("ja"), Translation.toggled("ja", listOf("ja")))
        assertEquals(listOf("ja", "ko"), Translation.toggled("ko", listOf("ja")))
        assertEquals("已選的再點一次＝移除（同 iOS QuickPickStore.toggled）", listOf("ko"), Translation.toggled("ja", listOf("ja", "ko")))
    }

    @Test
    fun arcDropsTheSourceLanguageAndFallsBackWhenEverythingIsGone() {
        // 說中文時弧上不該有中文（不能自己翻自己）。
        DictationLanguage.set(app, DictationLanguage.TRADITIONAL_CHINESE)
        Translation.setQuickPickCodes(app, listOf(TranslateLanguage.ENGLISH, TranslateLanguage.JAPANESE))
        assertEquals(listOf("en", "ja"), Translation.quickPick(app).map { it.code })

        // 換成英文聽寫：使用者選的弧去掉英文（不能自己翻自己），其餘照使用者的順序。
        DictationLanguage.set(app, DictationLanguage.ENGLISH)
        assertEquals(listOf("ja"), Translation.quickPick(app).map { it.code })

        // 使用者只選了英文、又改成英文聽寫：弧不能是空的，回英文來源的預設弧（含中文）。
        Translation.setQuickPickCodes(app, listOf(TranslateLanguage.ENGLISH))
        val fallback = Translation.quickPick(app).map { it.code }
        assertTrue("全被去掉時要回預設弧（含中文）：$fallback", TranslateLanguage.CHINESE in fallback)
        assertTrue("弧上不能有英文：$fallback", TranslateLanguage.ENGLISH !in fallback)
    }

    @Test
    fun arcSurvivesGarbageInStorage() {
        val p = app.getSharedPreferences(DictationLanguage.PREFS, android.content.Context.MODE_PRIVATE)
        p.edit().putString("translateQuickPick", "xx,en,en,zh").commit()
        assertEquals("壞代碼清掉、重複只留一個", listOf("en", "zh"), Translation.quickPickCodes(app))
        p.edit().remove("translateQuickPick").commit()
        assertEquals("沒設定就用預設弧", Translation.defaultFor(TranslateLanguage.CHINESE), Translation.quickPickCodes(app))
    }

    @Test
    fun sourceFollowsTheDictationLanguage() {
        DictationLanguage.set(app, DictationLanguage.TRADITIONAL_CHINESE)
        assertEquals("zh", Translation.sourceMlKit("zh-TW"))
        assertEquals("zh", Translation.sourceMlKit("zh-CN"))
        DictationLanguage.set(app, DictationLanguage.ENGLISH)
        assertEquals("en", Translation.sourceMlKit("en-US"))
        DictationLanguage.set(app, DictationLanguage.JAPANESE)
        assertEquals("ja", Translation.sourceMlKit("ja-JP"))
        DictationLanguage.set(app, DictationLanguage.KOREAN)
        assertEquals("ko", Translation.sourceMlKit("ko-KR"))
    }
}
