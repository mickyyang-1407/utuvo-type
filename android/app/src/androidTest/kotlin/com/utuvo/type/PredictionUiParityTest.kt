package com.utuvo.type

import android.content.Context
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A2 鍵盤預測接上 UI 的端對端測試（正本：`ios/Keyboard/KeyboardViewController.swift`、`TypingKeyboardView.swift`）。
 *
 * 走真的鍵盤：把 UTUVO Type 設成作用中的輸入法、在主 app 的試打框裡按注音／拼音／英文，
 * 驗候選列、整頁候選、聯想詞、英文建議列。跑在 Pixel 7 上（`connectedAndroidTest`）。
 */
@RunWith(AndroidJUnit4::class)
@org.junit.FixMethodOrder(org.junit.runners.MethodSorters.NAME_ASCENDING)
class PredictionUiParityTest {

    private val inst get() = InstrumentationRegistry.getInstrumentation()
    private val device get() = UiDevice.getInstance(inst)
    private val app: Context get() = inst.targetContext
    private val imeId = app.packageName + "/" + UTUVOImeService::class.java.name

    /**
     * 暖機（同 iOS KeyboardOrbUITests.test0WarmUpKeyboard；Android 依名稱排序，a0 才會排第一）：剛重裝 APK 後第一次叫鍵盤常叫不出來
     * （模擬器實測：永遠是第一條測試失敗）。依名稱排序這條最先跑，只叫一次鍵盤、不做斷言。
     */
    @Test fun a0WarmUpKeyboard() {}

    @get:org.junit.Rule val name = org.junit.rules.TestName()
    private val warmingUp get() = name.methodName == "a0WarmUpKeyboard"

    /**
     * 從測試程序裡 `ime enable` 對「目前是停用」的輸入法會回 unrecognized IME ID（模擬器 logcat 實測，
     * 從電腦 adb 下同一句就成功；重裝 APK 會保留啟用狀態）。所以啟用要在電腦端先做：
     * android/scripts/run-device-tests.sh。這裡只負責「已啟用但不是預設」時切過來。
     */
    private fun selectOurKeyboard() {
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            device.executeShellCommand("ime enable $imeId")
            device.executeShellCommand("ime set $imeId")
            val current = device.executeShellCommand("settings get secure default_input_method").trim()
            if (current == imeId || current == imeId.replace("com.utuvo.type/com.utuvo.type.", "com.utuvo.type/.")) return
            Thread.sleep(500)
        }
        throw AssertionError("選不到 UTUVO Type 輸入法：先用 android/scripts/run-device-tests.sh 跑（它會從電腦端 ime enable）")
    }

    @Before fun setUp() {
        // 無視窗模擬器的自動旋轉會自己轉橫（橫向是全螢幕擷取模式，版面不同）；這組測的是直向。
        device.setOrientationPortrait()
        selectOurKeyboard()
        val intent = Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        inst.targetContext.startActivity(intent)
        assertTrue(device.wait(Until.hasObject(By.desc("tryField")), 10_000))
        focusField()
    }

    // ── 鍵盤操作 ──

    /** 主 app 的試打框捲進畫面並點下去。 */
    private fun focusField() {
        val field = findOrNull(By.desc("tryField")) ?: run {
            device.findObject(By.scrollable(true)) ?: error("找不到捲動容器")
            repeat(6) { swipeMainAreaUp() }
            findOrNull(By.desc("tryField")) ?: error("捲到底還找不到 tryField")
        }
        field.click()
        // 鍵盤一叫出來固定在語音頁（左排 EN／繁／简），打字頁才有「🎙 語音」鍵。
        // 冷啟動第一次叫鍵盤偶爾慢（模擬器實測），沒出現就再點一次輸入框。
        if (!device.wait(Until.hasObject(By.text("繁")), 10_000)) {
            field.click()
            val shown = device.wait(Until.hasObject(By.text("繁")), 15_000)
            if (!warmingUp) assertTrue("鍵盤沒出現", shown)
        }
    }

    private fun fieldText(): String = device.findObject(By.desc("tryField")).text.orEmpty()

    /** 換版面：語音頁左排有 EN／繁／简 三顆。 */
    private fun switchTo(key: String) {
        device.wait(Until.findObject(By.text(key)), 5_000)?.click()
        device.waitForIdle(2_000)
    }

    private fun tapKey(label: String) {
        val key = device.wait(Until.findObject(By.text(label)), 3_000)
        assertNotNull("找不到鍵 $label", key)
        key.click()
        device.waitForIdle(1_000)
    }

    private fun tapKeys(vararg labels: String) { labels.forEach(::tapKey) }

    private fun tapSpace() {
        val key = device.wait(Until.findObject(By.text("空白")), 3_000)
            ?: device.wait(Until.findObject(By.text("空格")), 3_000)
        assertNotNull("找不到空白鍵", key)
        key.click()
        device.waitForIdle(2_000)
    }

    /** 候選列／整頁上的某一格（兩者都用相同的字）。 */
    private fun tapCandidate(text: String, timeoutMs: Long = 5_000): Boolean {
        val cell = device.wait(Until.findObject(By.text(text).clickable(true)), timeoutMs)
        if (cell == null) return false
        cell.click()
        device.waitForIdle(2_000)
        return true
    }

    /** 候選列右端「⌄／⌃」。 */
    private fun togglePanel() {
        val more = device.wait(Until.findObject(By.desc("更多候選字")), 5_000)
        assertNotNull("候選列沒有展開鈕", more)
        more.click()
        device.waitForIdle(1_000)
    }

    private fun findOrNull(by: BySelector): UiObject2? = device.findObject(by)

    /** 主 app 的長頁面往上捲一段。 */
    private fun swipeMainAreaUp() {
        val w = device.displayWidth
        val h = device.displayHeight
        device.swipe(w / 2, h * 3 / 4, w / 2, h / 4, 20)
        device.waitForIdle(200)
    }

    // ── 注音 ──

    @Test fun zhuyinNiAppearsAndPicks() {
        switchTo("繁")
        tapKey("ㄋ")
        assertTrue("ㄋ 沒有出現「你」", tapCandidate("你"))
        assertTrue("選完「你」輸入框不是「你」", fieldText().contains("你"))
        assertTrue("選完沒有出現聯想詞「們」", tapCandidate("們"))
        assertEquals("你們", fieldText())
    }

    @Test fun zhuyinDianNaoAppears() {
        switchTo("繁")
        tapKeys("ㄉ", "ㄋ")
        assertTrue("ㄉㄋ 沒有出現「電腦」", tapCandidate("電腦"))
        assertTrue(fieldText().contains("電腦"))
    }

    @Test fun zhuyinNiHaoCommitsOnSpace() {
        switchTo("繁")
        tapKeys("ㄋ", "ㄧ", "ㄏ", "ㄠ")
        tapSpace()
        assertEquals("你好", fieldText())
    }

    // ── 拼音：整頁候選 ──

    @Test fun pinyinPanelScrollsToThirtyFifthCandidate() {
        switchTo("简")
        tapKeys("s", "u", "o", "y", "i")
        togglePanel()
        // 面板蓋在鍵上面，要真的捲下去第 35 格才會進到畫面（uiautomator 只找看得到的）。
        // 在面板自己的範圍裡滑（面板只蓋按鍵區，螢幕中間是 app 不是面板）。
        val panel = device.wait(Until.findObject(By.desc(app.getString(R.string.candidate_panel))), 3_000)
        assertNotNull("找不到整頁候選面板", panel)
        val box = panel.visibleBounds
        var cells = device.findObjects(By.descStartsWith(CandidatePanelView.CELL_DESC_PREFIX))
        var target = cells.firstOrNull { indexOf(it) == 35 }
        for (i in 0 until 8) {
            if (target != null) break
            device.swipe(box.centerX(), box.bottom - box.height() / 8, box.centerX(), box.top + box.height() / 8, 20)
            device.waitForIdle(500)
            cells = device.findObjects(By.descStartsWith(CandidatePanelView.CELL_DESC_PREFIX))
            target = cells.firstOrNull { indexOf(it) == 35 }
        }
        assertTrue("整頁候選打開了但只看到 ${cells.size} 格，捲到底也沒有第 35 個", target != null)
        val picked = target!!.text
        target.click()
        device.waitForIdle(2_000)
        assertTrue("點第 35 個「$picked」之後輸入框是「${fieldText()}」", fieldText().startsWith(picked))
    }

    /** 展開後按 ⌃ 要收得回來（面板不能蓋住最上面那排）。 */
    @Test fun expandedPanelCollapsesWithChevron() {
        switchTo("简")
        tapKeys("s", "h", "i")
        togglePanel()
        assertTrue("整頁沒打開", device.wait(Until.hasObject(By.descStartsWith(CandidatePanelView.CELL_DESC_PREFIX)), 3_000))
        val less = device.wait(Until.findObject(By.desc("收起候選字")), 3_000)
        assertNotNull("展開後找不到收起鈕", less)
        less.click()
        assertTrue("按 ⌃ 之後整頁還在", device.wait(Until.gone(By.descStartsWith(CandidatePanelView.CELL_DESC_PREFIX)), 3_000))
    }

    /** 展開整頁時候選列換成同一份清單：點候選列上的第二個候選，送出的必須就是那個字（不是第一個）。 */
    @Test fun expandedBarPicksTheTappedCandidate() {
        switchTo("简")
        tapKeys("s", "h", "i")
        togglePanel()
        val second = device.wait(Until.findObject(By.desc("${CandidatePanelView.CELL_DESC_PREFIX}1")), 5_000)
        assertNotNull("整頁沒有第 2 格", second)
        val text = second.text
        val barCell = device.findObjects(By.text(text).clickable(true))
            .firstOrNull { it.contentDescription?.startsWith(CandidatePanelView.CELL_DESC_PREFIX) != true }
        assertNotNull("候選列上找不到「$text」", barCell)
        barCell!!.click()
        device.waitForIdle(2_000)
        assertEquals("點候選列的「$text」", text, fieldText())
    }

    // ── 英文建議列 ──

    @Test fun englishTomorrowSuggestionReplacesWord() {
        switchTo("EN")
        tapKeys("T", "o", "m", "o", "r")
        assertTrue("打 Tomor 沒有建議 Tomorrow（欄位「${fieldText()}」；畫面上：${visibleTexts()}）", tapCandidate("Tomorrow"))
        // 點建議＝把游標前那個字換成建議、後面補一個空白（同 iOS pickEnglishSuggestion）。
        assertEquals("Tomorrow ", fieldText())
    }

    private fun visibleTexts(): List<String> =
        device.findObjects(By.textContains("")).mapNotNull { it.text }.filter { it.isNotBlank() }.distinct()

    private fun indexOf(cell: UiObject2): Int =
        cell.contentDescription.removePrefix("candidatePanelCell-").toIntOrNull() ?: -1
}
