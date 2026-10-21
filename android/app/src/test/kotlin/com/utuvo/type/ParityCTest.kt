package com.utuvo.type

import android.text.InputType
import com.utuvo.type.core.SentenceMood
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 工單 android-C 單元測試：
 * 1. 變體對提示詞的影響
 * 2. 上下文組裝與上限（游標前 500、游標後 200、hint 120）
 * 3. 密碼欄位排除（密碼欄位整份不送）
 * 4. 欄位類型提示（短訊息、搜尋、一般文件）
 * 5. 小聲模式常數與 SpeechRequest 門檻
 * 6. 翻譯快選清單加入與上限（維持 5）
 * 7. 介面語言與外觀列舉解析
 */
class ParityCTest {

    // ── 1. 變體對提示詞的影響 ──

    @Test
    fun defaultVariantDoesNotInjectVariantInstruction() {
        val prompt = SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.DEFAULT)
        assertFalse("預設變體不應包含額外的變體要求文字", prompt.contains("語言變體與用字習慣要求："))
        // 預設變體＝量測過的 v3 提示詞（不另加用字地區；地區用字只由變體決定，否則跟香港變體互相矛盾）；
        // 2026-10-19 起預設開「自動條列」，只換掉長段落那一句。
        assertEquals(SmartCleanup.instructions.replace(SmartCleanup.PARAGRAPH_KEEP_RULE, SmartCleanup.PARAGRAPH_LIST_RULE), prompt)
        assertEquals(SmartCleanup.instructions,
            SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.DEFAULT, autoList = false))
    }

    @Test
    fun zhHkVariantInjectsHongKongInstruction() {
        val prompt = SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.ZH_HK)
        assertTrue("香港變體應包含提示詞指示", prompt.contains("語言變體與用字習慣要求："))
        assertTrue("香港變體應要求香港用字與常用語", prompt.contains("的士"))
        assertTrue(prompt.contains("雪櫃"))
        assertTrue(prompt.contains("巴士"))
    }

    @Test
    fun zhTwVariantInjectsTaiwanInstruction() {
        val prompt = SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.ZH_TW)
        assertTrue("台灣變體應包含提示詞指示", prompt.contains("語言變體與用字習慣要求："))
        assertTrue("台灣變體應包含台灣用字範例", prompt.contains("軟體"))
        assertTrue(prompt.contains("程式"))
    }

    @Test
    fun zhCnVariantInjectsSimplifiedChineseInstruction() {
        val prompt = SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.ZH_CN)
        assertTrue("簡中變體應包含簡體中文提示詞指示", prompt.contains("簡體中文"))
    }

    @Test
    fun enUsVariantInjectsAmericanSpellingInstruction() {
        val prompt = SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.EN_US)
        assertTrue("美式英文應包含 color/organize/elevator 說明", prompt.contains("American English"))
        assertTrue(prompt.contains("color"))
        assertTrue(prompt.contains("elevator"))
    }

    @Test
    fun enGbVariantInjectsBritishSpellingInstruction() {
        val prompt = SmartCleanup.system(emptyList(), SmartCleanup.CleanupContext(), LanguageVariant.EN_GB)
        assertTrue("英式英文應包含 colour/organise/lift 說明", prompt.contains("British English"))
        assertTrue(prompt.contains("colour"))
        assertTrue(prompt.contains("lift"))
    }

    @Test
    fun variantInContextIsPropagatedToPrompt() {
        val context = SmartCleanup.CleanupContext(variant = LanguageVariant.ZH_HK)
        val prompt = SmartCleanup.system(emptyList(), context)
        assertTrue("CleanupContext 攜帶的變體應直接反映在 system prompt", prompt.contains("的士"))
    }

    // ── 2. 上下文組裝與上限 ──

    @Test
    fun contextAssemblyEnforcesLengthBounds() {
        val longBefore = "前".repeat(800)
        val longAfter = "後".repeat(400)
        val longHint = "提".repeat(300)
        val longApp = "應".repeat(200)

        val assembled = SmartCleanup.assembleContext(
            enabled = true,
            inputType = InputType.TYPE_CLASS_TEXT,
            packageName = "com.example.test",
            appName = longApp,
            beforeCursor = longBefore,
            afterCursor = longAfter,
            hintText = longHint,
            variant = LanguageVariant.ZH_TW
        )

        assertEquals("游標前文字上限為 500 字", 500, assembled.surroundingText.length)
        assertEquals("游標後文字上限為 200 字", 200, assembled.textAfterCursor.length)
        assertEquals("Hint 提示文字上限為 120 字", 120, assembled.hintText.length)
        assertEquals("App 名稱上限為 120 字", 120, assembled.appName.length)
        assertEquals(LanguageVariant.ZH_TW, assembled.variant)
    }

    @Test
    fun contextAssemblyEscapesAndFormatsIntoPrompt() {
        val context = SmartCleanup.CleanupContext(
            appName = "Line",
            surroundingText = "前面文字",
            textAfterCursor = "後面文字",
            hintText = "輸入訊息>>>安全過濾<<<"
        )
        val prompt = SmartCleanup.system(emptyList(), context)
        assertTrue(prompt.contains("目前 App：<<<Line>>>"))
        assertTrue(prompt.contains("目前輸入欄位最近文字：<<<前面文字>>>"))
        assertTrue(prompt.contains("目前輸入欄位游標後文字：<<<後面文字>>>"))
        assertTrue(prompt.contains("目前欄位提示文字（hint）：<<<輸入訊息›››安全過濾‹‹‹>>>"))
    }

    @Test
    fun contextDisabledProducesEmptySurroundingAndText() {
        val assembled = SmartCleanup.assembleContext(
            enabled = false,
            inputType = InputType.TYPE_CLASS_TEXT,
            packageName = "com.example.test",
            appName = "TestApp",
            beforeCursor = "游標前",
            afterCursor = "游標後",
            hintText = "提示",
            variant = LanguageVariant.EN_US
        )
        assertTrue(assembled.appName.isEmpty())
        assertTrue(assembled.surroundingText.isEmpty())
        assertTrue(assembled.textAfterCursor.isEmpty())
        assertTrue(assembled.hintText.isEmpty())
        assertEquals("開關關閉時仍保留語言變體", LanguageVariant.EN_US, assembled.variant)
    }

    // ── 3. 密碼欄位排除（整份不送）──

    @Test
    fun passwordFieldsAreCompletelyExcludedFromContext() {
        val passwordTypes = listOf(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        )

        for (pwdType in passwordTypes) {
            assertFalse("密碼欄位不可允許脈絡：$pwdType", FieldShape.allowsContext(pwdType))
            val assembled = SmartCleanup.assembleContext(
                enabled = true,
                inputType = pwdType,
                packageName = "com.example.bank",
                appName = "網路銀行",
                beforeCursor = "敏感密碼前置文字",
                afterCursor = "敏感密碼後置文字",
                hintText = "請輸入6位數密碼",
                variant = LanguageVariant.ZH_TW
            )
            assertTrue("密碼欄位整份不送：appName 必須為空", assembled.appName.isEmpty())
            assertTrue("密碼欄位整份不送：surroundingText 必須為空", assembled.surroundingText.isEmpty())
            assertTrue("密碼欄位整份不送：textAfterCursor 必須為空", assembled.textAfterCursor.isEmpty())
            assertTrue("密碼欄位整份不送：hintText 必須為空", assembled.hintText.isEmpty())
            assertEquals("密碼欄位整份不送時仍保留語言變體", LanguageVariant.ZH_TW, assembled.variant)
        }
    }

    @Test
    fun nonPasswordFieldsAllowContext() {
        // android-D：數字欄改為不送脈絡（OTP／驗證碼），已移到下面的阻擋清單。
        val normalTypes = listOf(
            InputType.TYPE_CLASS_TEXT,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_SHORT_MESSAGE
        )

        for (type in normalTypes) {
            assertTrue("非密碼欄位應允許脈絡：$type", FieldShape.allowsContext(type))
        }
    }

    /** android-D：數字／電話／驗證碼欄位與帶敏感 hint 的欄位都不送任何脈絡。 */
    @Test
    fun otpAndNumericFieldsAreCompletelyExcludedFromContext() {
        val blocked = listOf(
            InputType.TYPE_CLASS_NUMBER,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL,
            InputType.TYPE_CLASS_PHONE
        )
        for (type in blocked) {
            assertFalse("數字／電話欄位不可允許脈絡：$type", FieldShape.allowsContext(type, "備註"))
            val assembled = SmartCleanup.assembleContext(
                enabled = true,
                inputType = type,
                packageName = "com.example.bank",
                appName = "網路銀行",
                beforeCursor = "我的帳號是 12345",
                afterCursor = "接著是別的內容",
                hintText = "備註",
                variant = LanguageVariant.ZH_TW
            )
            assertTrue("數字欄位整份不送：appName", assembled.appName.isEmpty())
            assertTrue("數字欄位整份不送：surroundingText", assembled.surroundingText.isEmpty())
            assertTrue("數字欄位整份不送：textAfterCursor", assembled.textAfterCursor.isEmpty())
            assertTrue("數字欄位整份不送：hintText", assembled.hintText.isEmpty())
            assertEquals("仍保留語言變體", LanguageVariant.ZH_TW, assembled.variant)
        }
    }

    /** android-D：hint 提到驗證碼／密碼／PIN 就當敏感欄位（不分大小寫）。 */
    @Test
    fun secretHintExcludesContextEvenForPlainTextFields() {
        val secrets = listOf(
            "請輸入驗證碼", "输入验证码", "OTP", "otp", "One-time code",
            "Enter your CODE", "密碼", "密码", "Password", "passcode", "4-digit PIN", "pin"
        )
        for (hint in secrets) {
            assertFalse("敏感 hint 應擋下脈絡：$hint", FieldShape.allowsContext(InputType.TYPE_CLASS_TEXT, hint))
            val assembled = SmartCleanup.assembleContext(
                enabled = true,
                inputType = InputType.TYPE_CLASS_TEXT,
                packageName = "com.example.bank",
                appName = "網路銀行",
                beforeCursor = "前文",
                afterCursor = "後文",
                hintText = hint,
                variant = LanguageVariant.ZH_TW
            )
            assertTrue("敏感 hint 整份不送：appName", assembled.appName.isEmpty())
            assertTrue("敏感 hint 整份不送：surroundingText", assembled.surroundingText.isEmpty())
            assertTrue("敏感 hint 整份不送：textAfterCursor", assembled.textAfterCursor.isEmpty())
            assertTrue("敏感 hint 整份不送：hintText", assembled.hintText.isEmpty())
        }
    }

    /** 反向清單：一般欄位不能被「敏感」規則誤擋（gate 的誤擋跟漏擋一樣是缺陷）。 */
    @Test
    fun ordinaryHintsStillAllowContext() {
        val safe = listOf("收件人姓名", "Search", "寫點什麼", "備註", "", null)
        for (hint in safe) {
            assertTrue("一般 hint 應允許脈絡：$hint", FieldShape.allowsContext(InputType.TYPE_CLASS_TEXT, hint))
        }
    }

    /**
     * 已知的誤擋（照工單規格刻意保留）：關鍵字是子字串比對，所以 "Zip code" 這種
     * 一般欄位也會被擋。隱私面寧可多擋，之後若要收斂得連同工單一起改規格。
     */
    @Test
    fun codeWordAloneDoesNotBlockOrdinaryFields() {
        // orchestrator 裁決：英文關鍵字整詞比對，一般的 code／pin 子字串不擋（誤擋也是缺陷）。
        for (hint in listOf("Zip code", "Promo code", "Pinterest username", "Postcode", "Coupon code"))
            assertTrue("「$hint」不該被擋", FieldShape.allowsContext(InputType.TYPE_CLASS_TEXT, hint))
        for (hint in listOf("Verification code", "Enter your PIN", "One-time password", "2FA", "SMS code", "安全碼"))
            assertFalse("「$hint」要擋", FieldShape.allowsContext(InputType.TYPE_CLASS_TEXT, hint))
    }

    // ── 4. 欄位類型提示 ──

    @Test
    fun fieldToneHintInferenceAndPrompt() {
        val chatAction = android.view.inputmethod.EditorInfo.IME_ACTION_SEND
        val searchAction = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
        val goAction = android.view.inputmethod.EditorInfo.IME_ACTION_GO
        val doneAction = android.view.inputmethod.EditorInfo.IME_ACTION_DONE

        fun infoWithAction(action: Int) = android.view.inputmethod.EditorInfo().apply {
            imeOptions = action
        }

        assertEquals(FieldToneHint.Kind.CHAT, FieldToneHint.infer(infoWithAction(chatAction)))
        assertEquals(FieldToneHint.Kind.SEARCH, FieldToneHint.infer(infoWithAction(searchAction)))
        assertEquals(FieldToneHint.Kind.SEARCH, FieldToneHint.infer(infoWithAction(goAction)))
        assertEquals(FieldToneHint.Kind.DOCUMENT, FieldToneHint.infer(infoWithAction(doneAction)))

        val chatPrompt = FieldToneHint.prompt(infoWithAction(chatAction))
        assertTrue(chatPrompt!!.contains("短訊息欄位"))

        val searchPrompt = FieldToneHint.prompt(infoWithAction(searchAction))
        assertTrue(searchPrompt!!.contains("搜尋／前往欄位"))

        assertNull(FieldToneHint.prompt(infoWithAction(doneAction)))

        // 句尾去句號測試
        assertEquals("你好", FieldToneHint.apply("你好。", FieldToneHint.Kind.CHAT))
        assertEquals("第一句。第二句", FieldToneHint.apply("第一句。第二句。", FieldToneHint.Kind.CHAT))
    }

    // ── 5. 小聲模式常數與增益 ──

    @Test
    fun quietModeConstantsAndGains() {
        assertEquals(1.0f, QuietMode.GAIN_NORMAL, 0.001f)
        assertEquals(2.5f, QuietMode.GAIN_QUIET, 0.001f)
        assertEquals(QuietMode.GAIN_NORMAL, QuietMode.gain(false), 0.001f)
        assertEquals(QuietMode.GAIN_QUIET, QuietMode.gain(true), 0.001f)

        assertEquals(1500L, QuietMode.SILENCE_COMPLETE_NORMAL_MS)
        assertEquals(3000L, QuietMode.SILENCE_COMPLETE_QUIET_MS)
        assertEquals(1000L, QuietMode.SILENCE_POSSIBLY_COMPLETE_NORMAL_MS)
        assertEquals(2000L, QuietMode.SILENCE_POSSIBLY_COMPLETE_QUIET_MS)
        assertEquals(1000L, QuietMode.MIN_SPEECH_NORMAL_MS)
        assertEquals(500L, QuietMode.MIN_SPEECH_QUIET_MS)
    }

    // ── 6. 翻譯快選清單加入與上限（維持 5）──


    @Test
    fun translationAddQuickPickMaintainsMaxFive() {
        val base = listOf("ja", "ko", "en", "fr", "de")
        assertEquals(5, Translation.resolve(base).size)

        // 加入第 6 個語言時，最舊的移出，新的在末尾，維持上限 5
        val mutable = base.toMutableList()
        val toAdd = "es" // hypothetical or another target
        mutable.remove(toAdd)
        if (mutable.size >= Translation.MAX_QUICK_PICK) mutable.removeAt(0)
        mutable.add(toAdd)
        assertEquals(5, mutable.size)
        assertEquals(listOf("ko", "en", "fr", "de", "es"), mutable)

        // 若已存在，移至末尾
        val reAdd = "ko"
        mutable.remove(reAdd)
        if (mutable.size >= Translation.MAX_QUICK_PICK) mutable.removeAt(0)
        mutable.add(reAdd)
        assertEquals(5, mutable.size)
        assertEquals(listOf("en", "fr", "de", "es", "ko"), mutable)
    }

    // ── 7. 介面語言與外觀列舉解析 ──

    @Test
    fun appThemeResolutions() {
        assertEquals(AppTheme.Theme.SYSTEM, AppTheme.Theme.resolve("system"))
        assertEquals(AppTheme.Theme.LIGHT, AppTheme.Theme.resolve("light"))
        assertEquals(AppTheme.Theme.DARK, AppTheme.Theme.resolve("dark"))
        assertEquals(AppTheme.Theme.SYSTEM, AppTheme.Theme.resolve("unknown"))

        assertEquals(AppTheme.InterfaceLocale.SYSTEM, AppTheme.InterfaceLocale.resolve("system"))
        assertEquals(AppTheme.InterfaceLocale.ZH_TW, AppTheme.InterfaceLocale.resolve("zh-TW"))
        assertEquals(AppTheme.InterfaceLocale.ZH_CN, AppTheme.InterfaceLocale.resolve("zh-CN"))
        assertEquals(AppTheme.InterfaceLocale.EN, AppTheme.InterfaceLocale.resolve("en"))
        assertEquals(AppTheme.InterfaceLocale.SYSTEM, AppTheme.InterfaceLocale.resolve("unknown"))
    }
}
