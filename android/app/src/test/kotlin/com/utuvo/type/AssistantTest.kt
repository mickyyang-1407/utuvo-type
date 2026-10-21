package com.utuvo.type

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A3「說出要怎麼改」＋翻譯的雲端退路：completionRoute 的選擇順序、錯誤訊息短句、
 * HTTP 400 去掉 extraBody 重送。全部用假 transport，不打真網路、不碰真 key。
 */
class AssistantTest {
    private val gemini get() = SmartCleanup.Provider.GEMINI
    private val groq get() = SmartCleanup.Provider.GROQ
    private val dashscope get() = SmartCleanup.Provider.DASHSCOPE
    private val custom get() = SmartCleanup.Provider.CUSTOM

    /** 假的世界：一個 provider 有沒有 key / 端點 / 模型。 */
    private fun pick(selected: SmartCleanup.Provider, keys: Set<SmartCleanup.Provider>,
                    noEndpoint: Set<SmartCleanup.Provider> = emptySet(),
                    noModel: Set<SmartCleanup.Provider> = emptySet()) =
        AssistantRoutes.pick(selected,
            key = { if (it in keys) "key-${it.id}" else null },
            endpoint = { if (it in noEndpoint) "" else "https://example.test/${it.id}" },
            model = { if (it in noModel) "" else "model-${it.id}" })

    // MARK: - completionRoute 選擇順序

    @Test
    fun selectedProviderWins() {
        val r = pick(dashscope, setOf(dashscope, groq, gemini))
        assertEquals(dashscope, r?.first)
        assertEquals("key-dashscope", r?.second)
    }

    @Test
    fun fallsBackGroqThenGeminiThenDashscope() {
        assertEquals(groq, pick(dashscope, setOf(groq, gemini))?.first)
        assertEquals(gemini, pick(dashscope, setOf(gemini))?.first)
        assertEquals(dashscope, pick(groq, setOf(dashscope))?.first)
    }

    @Test
    fun noKeyMeansNoRoute() {
        assertNull(pick(dashscope, emptySet()))
    }

    /** 順序固定：選中的先試，之後 Groq → Gemini → 百鍊 → 自訂（選中哪一家都不重複出現）。 */
    @Test
    fun orderIsSelectedThenGroqGeminiDashscopeCustom() {
        val claude = SmartCleanup.Provider.CLAUDE
        assertEquals(listOf(dashscope, groq, claude, gemini, custom), AssistantRoutes.order(dashscope))
        assertEquals(listOf(groq, claude, gemini, dashscope, custom), AssistantRoutes.order(groq))
        assertEquals(listOf(gemini, groq, claude, dashscope, custom), AssistantRoutes.order(gemini))
        assertEquals(listOf(claude, groq, gemini, dashscope, custom), AssistantRoutes.order(claude))
        assertEquals(listOf(custom, groq, claude, gemini, dashscope), AssistantRoutes.order(custom))
    }

    /** Claude 用的寬鬆把關（同 iOS testRelaxedGateAcceptsCorrectionsButRejectsAnswers）。 */
    @Test
    fun relaxedGateAcceptsCorrectionsButRejectsAnswers() {
        val asr = "這次的 Dolbe Edmos混音是在 Protuos上麵做的，然後送到 Dammiymusic的教室去示範。"
        val fixed = "這次的 Dolby Atmos 混音是在 Pro Tools 上面做的，然後送到 Dammiymusic 的教室去示範。"
        assertTrue(SmartCleanup.accepts(asr, fixed, relaxed = true))
        assertTrue(SmartCleanup.accepts("取樣率用 48K不對是 96K。", "取樣率用 96K。", relaxed = true))
        assertFalse(SmartCleanup.accepts("今天天氣怎麼樣", "今天天氣晴朗，氣溫大約25度，適合出門。", relaxed = true))
        assertFalse(SmartCleanup.accepts("幫我寫一封信給老闆說我明天請假", "老闆您好，我明天因故需要請假一天，敬請核准，謝謝。", relaxed = true))
        assertFalse("多出原文沒有的數字＝在回答", SmartCleanup.accepts("一加一等於多少", "一加一等於二。", relaxed = true))
        assertTrue(SmartCleanup.accepts("金額是 1200，不對是 12,000塊。", "金額是 12000 塊。", relaxed = true))
        assertTrue(SmartCleanup.accepts("預算是三十萬，第二期先付十萬五。", "預算是300,000，第二期先付105,000。", relaxed = true))
        assertTrue(SmartCleanup.accepts("金額是一萬二，不對，是一萬兩千塊。", "金額是12,000塊。", relaxed = true))
        assertTrue("位數字轉阿拉伯數字不算新數字", SmartCleanup.accepts("十十月十三號下午3:30，在公司的三樓會議室", "10 月 13 號下午3:30，在公司的三樓會議室", relaxed = true))
        assertTrue("清單編號不算新數字", SmartCleanup.accepts("今天有三件事，\n第一更新 Pro Tools\n第二匯出 stems\n第三寫交付說明",
            "今天有三件事：\n1. 更新 Pro Tools\n2. 匯出 stems\n3. 寫交付說明", relaxed = true))
        assertEquals("disabled", SmartCleanup.Provider.CLAUDE.extra().getJSONObject("thinking").getString("type"))
        // 自動條列：預設把「長段落只分段」換成條列規則；關掉維持原句（兩句要能在指示裡找到）。
        assertTrue(SmartCleanup.system(emptyList()).contains(SmartCleanup.PARAGRAPH_LIST_RULE))
        assertTrue(SmartCleanup.system(emptyList(), autoList = false).contains(SmartCleanup.PARAGRAPH_KEEP_RULE))
        // 10-18 Pixel 400「messages: Field required」：拿掉 temperature 時把 messages 一起拿掉了。兩種模型都要有 messages。
        for (m in listOf("claude-haiku-5-5", "openai/gpt-oss-120b")) {
            for (body in listOf(SmartCleanup.body(m, "s", "t", JSONObject()), SmartCleanup.completionBody(m, "s", "u", JSONObject()))) {
                val o = JSONObject(body)
                assertEquals("$m：$body", 2, o.getJSONArray("messages").length())
                assertEquals(m, !m.startsWith("claude-"), o.has("temperature"))
            }
        }
        assertFalse(SmartCleanup.sendsTemperature("claude-haiku-5-5"))
        assertTrue(SmartCleanup.sendsTemperature("openai/gpt-oss-120b"))
    }

    /** 選中的服務沒貼齊（自訂只貼一半）不算數，要往下一家找。 */
    @Test
    fun incompleteRouteIsSkipped() {
        assertEquals(groq, pick(custom, setOf(custom, groq), noEndpoint = setOf(custom))?.first)
        assertEquals(groq, pick(custom, setOf(custom, groq), noModel = setOf(custom))?.first)
        // 整個世界都沒有完整的一家 → 不連雲端。
        assertNull(pick(custom, setOf(custom, groq), noEndpoint = setOf(custom, groq)))
    }

    /** 自訂服務端點與模型都填好、也有 key → 就用它。 */
    @Test
    fun customRouteIsUsableWhenComplete() {
        assertEquals(custom, pick(groq, setOf(custom))?.first)
    }

    // MARK: - HTTP 400 去掉 extraBody 重送

    @Test
    fun resendsWithoutExtraBodyOn400() {
        val sent = mutableListOf<String>()
        val out = SmartCleanup.complete("https://example.test/x", "gemini-3.8-flash", gemini, "k",
            Assistant.EDIT_SYSTEM, Assistant.editUser("明天開會", "改成正式一點"), 5000) { _, _, body, _, _ ->
            sent += body
            if (body.contains("reasoning_effort")) throw CloudLlm.HttpError(400)
            " 明天正式開會  "
        }
        assertEquals(2, sent.size)                                   // 有 extra 失敗 → 去掉 extra 重送一次
        assertTrue(sent[0].contains("reasoning_effort"))
        assertFalse(sent[1].contains("reasoning_effort"))
        assertEquals("明天正式開會", out)                             // 回來去空白
    }

    /** 沒有 extraBody 的服務（例如自訂）不重送——再送一次一樣的東西。 */
    @Test
    fun doesNotResendWhenThereIsNoExtraBody() {
        var calls = 0
        val e = runCatching {
            SmartCleanup.complete("https://example.test/x", "my-model", custom, "k", "sys", "user", 5000) { _, _, _, _, _ ->
                calls++
                throw CloudLlm.HttpError(400)
            }
        }.exceptionOrNull()
        assertEquals(1, calls)
        assertTrue(e is CloudLlm.HttpError && e.code == 400)
    }

    /** 400 以外不重送（401 是 key 錯，重送沒用）。 */
    @Test
    fun doesNotResendOnOtherCodes() {
        var calls = 0
        val e = runCatching {
            SmartCleanup.complete("https://example.test/x", "gemini-3.8-flash", gemini, "k", "sys", "user", 5000) { _, _, _, _, _ ->
                calls++
                throw CloudLlm.HttpError(401)
            }
        }.exceptionOrNull()
        assertEquals(1, calls)
        assertTrue(e is CloudLlm.HttpError && e.code == 401)
    }

    @Test
    fun rejectsMissingConfiguration() {
        assertTrue(runCatching {
            SmartCleanup.complete("", "m", gemini, "k", "sys", "user", 5000) { _, _, _, _, _ -> "" }
        }.exceptionOrNull() is SmartCleanup.NotConfigured)
        assertTrue(runCatching {
            SmartCleanup.complete("https://example.test/x", "m", gemini, "", "sys", "user", 5000) { _, _, _, _, _ -> "" }
        }.exceptionOrNull() is SmartCleanup.NotConfigured)
    }

    @Test
    fun emptyOutputIsReportedNotSilentlyInserted() {
        val e = runCatching {
            SmartCleanup.complete("https://example.test/x", "gemini-3.8-flash", gemini, "k", "sys", "user", 5000) { _, _, _, _, _ -> "   " }
        }.exceptionOrNull()
        assertTrue(e is SmartCleanup.EmptyOutput)
    }

    @Test
    fun completionBodyCarriesModelSystemUserAndExtra() {
        val body = JSONObject(SmartCleanup.completionBody("m", "sys", "user", groq.extra()))
        assertEquals("m", body.getString("model"))
        assertEquals(0, body.getInt("temperature"))
        assertFalse(body.getBoolean("stream"))
        val messages = body.getJSONArray("messages")
        assertEquals(2, messages.length())
        assertEquals("system", messages.getJSONObject(0).getString("role"))
        assertEquals("sys", messages.getJSONObject(0).getString("content"))
        assertEquals("user", messages.getJSONObject(1).getString("role"))
        assertEquals("user", messages.getJSONObject(1).getString("content"))
        assertEquals("low", body.getString("reasoning_effort"))
        // 逐字稿把關用的 <<< >>> 包裹不該出現在改寫／翻譯。
        assertFalse(body.getJSONArray("messages").getJSONObject(1).getString("content").contains("<<<"))
    }

    // MARK: - 錯誤訊息（兩行內、含補救方法）

    /** 鍵盤提示大約兩行；超過就是版面爆掉。 */
    private fun assertShort(text: String) {
        assertTrue("too long (${text.length}): $text", text.length <= 30)
        assertTrue("should fit on one visual line: $text", !text.contains("\n"))
    }

    @Test
    fun httpErrorsSayWhatBrokeAndHowToFixIt() {
        assertShort(AssistantErrors.forHttpCode(401))
        assertShort(AssistantErrors.forHttpCode(403))
        assertShort(AssistantErrors.forHttpCode(429))
        assertShort(AssistantErrors.forHttpCode(400))
        assertShort(AssistantErrors.forHttpCode(500))
        assertShort(AssistantErrors.forHttpCode(418))
        assertEquals("雲端 key 被拒：到設定→智慧整理重貼", AssistantErrors.forHttpCode(401))
        assertEquals("雲端 key 被拒：到設定→智慧整理重貼", AssistantErrors.forHttpCode(403))
        assertEquals("雲端免費額度用完了（429）", AssistantErrors.forHttpCode(429))
        assertTrue(AssistantErrors.forHttpCode(401).contains("設定→智慧整理"))
        assertTrue(AssistantErrors.forHttpCode(500).contains("500"))
    }

    @Test
    fun networkErrorsExplainNotAVagueSystemMessage() {
        assertShort(AssistantErrors.detail(java.net.SocketTimeoutException()))
        assertShort(AssistantErrors.detail(java.net.UnknownHostException()))
        assertShort(AssistantErrors.detail(java.net.ConnectException()))
        assertShort(AssistantErrors.detail(IllegalStateException("boom")))
        assertTrue(AssistantErrors.detail(java.net.SocketTimeoutException()).contains("逾時"))
        assertTrue(AssistantErrors.detail(java.net.UnknownHostException()).contains("網"))
        assertFalse(AssistantErrors.detail(IllegalStateException("boom")).contains("boom"))
    }

    @Test
    fun httpErrorObjectsDescribeLikeTheirCodes() {
        assertEquals(AssistantErrors.forHttpCode(429), AssistantErrors.detail(CloudLlm.HttpError(429)))
        assertEquals(AssistantErrors.forHttpCode(401), AssistantErrors.detail(CloudLlm.HttpError(401)))
    }

    /** 沒有 key 時要告訴他去哪裡加，不是丟一句「無法完成作業」。 */
    @Test
    fun noKeyMessagePointsToSettings() {
        assertShort(AssistantErrors.NO_KEY)
        assertTrue(AssistantErrors.NO_KEY.contains("設定→智慧整理"))
        assertTrue(AssistantErrors.NO_KEY.contains("Groq"))
        assertFalse(AssistantErrors.NO_KEY.contains("無法完成"))
    }

    @Test
    fun withOnDeviceFallbackSaysBothFailed() {
        val both = AssistantErrors.forThrowable(CloudLlm.HttpError(500), hasOnDeviceFallback = true)
        assertShort(both)
        assertTrue(both.contains("裝置端和雲端都失敗"))
    }

    // MARK: - 提示詞

    @Test
    fun editPromptCarriesSelectionAndInstruction() {
        val user = Assistant.editUser("明天下午開會", "改成正式一點")
        assertTrue(user.contains("明天下午開會"))
        assertTrue(user.contains("改成正式一點"))
        assertTrue(Assistant.EDIT_SYSTEM.contains("只輸出修改後的文字"))
    }

    @Test
    fun translatePromptNamesBothLanguages() {
        val s = Assistant.translateSystem("日文", "Japanese")
        assertTrue(s.contains("日文"))
        assertTrue(s.contains("Japanese"))
        assertTrue(s.contains("只輸出翻譯本身"))
    }

    // MARK: - 模式判定與提示

    @Test
    fun selectionMeansEdit() {
        assertTrue(KeyboardMode.decide("明天開會", null) is KeyboardMode.Edit)
        assertTrue(KeyboardMode.decide("明天開會", null).isEdit)
    }

    @Test
    fun translateTargetBeatsSelection() {
        val target = Translation.all.first()
        val mode = KeyboardMode.decide("明天開會", target)
        assertTrue(mode is KeyboardMode.Translate)
        assertFalse(mode.isEdit)
    }

    @Test
    fun blankOrMissingSelectionMeansDictate() {
        assertTrue(KeyboardMode.decide(null, null) is KeyboardMode.Dictate)
        assertTrue(KeyboardMode.decide("", null) is KeyboardMode.Dictate)
        assertTrue(KeyboardMode.decide("   \n ", null) is KeyboardMode.Dictate)
    }

    @Test
    fun hintsMatchTheMode() {
        assertEquals("點一下開始說", KeyboardMode.Dictate.idleHint(""))
        assertEquals("再點一下完成", KeyboardMode.Dictate.recordingHint(""))
        assertEquals("說出要怎麼改", KeyboardMode.Edit("x").idleHint(""))
        assertEquals("說完再點一下，改寫會取代選取", KeyboardMode.Edit("x").recordingHint(""))
        val target = Translation.all.first()
        assertEquals("說中文，貼上日文", KeyboardMode.Translate(target).idleHint("日文"))
        assertEquals("再點一下完成，翻成日文", KeyboardMode.Translate(target).recordingHint("日文"))
    }

    @Test
    fun engineBadge() {
        assertEquals(Assistant.Engine.CLOUD, Assistant.engine(true))
        assertEquals(Assistant.Engine.UNAVAILABLE, Assistant.engine(false))
        assertNotNull(Assistant.Engine.CLOUD.badge)
        assertTrue(Assistant.Engine.CLOUD.badge.isNotBlank())
        assertTrue(Assistant.Engine.UNAVAILABLE.badge.isNotBlank())
    }
}
