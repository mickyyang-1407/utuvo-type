package com.utuvo.type

import android.content.Context
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 歷史分頁：往左滑過半寬刪除、滑不滿彈回不刪（同 iOS swipeActions）。 */
@RunWith(AndroidJUnit4::class)
class HistorySwipeTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(inst)
    private val app: Context get() = inst.targetContext
    private lateinit var saved: List<HistoryStore.Record>

    @Before fun setUp() {
        device.setOrientationPortrait()
        saved = HistoryStore.load(app)
        val now = System.currentTimeMillis()
        HistoryStore.restore(app, listOf(
            HistoryStore.Record(now, "滑動刪除測試", "滑動刪除測試"),
            HistoryStore.Record(now - 1_000, "短滑不動", "短滑不動"),
        ))
        app.startActivity(Intent(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        val tab = device.wait(Until.findObject(By.text(app.getString(R.string.tab_history))), 10_000)
        assertNotNull("找不到歷史分頁", tab)
        tab.click()
        device.waitForIdle(1_000)
    }

    @After fun tearDown() { HistoryStore.restore(app, saved) }

    @Test fun fullSwipeLeftDeletes() {
        val row = device.wait(Until.findObject(By.desc("history:滑動刪除測試")), 5_000)
        assertNotNull("歷史列沒出現", row)
        val b = row.visibleBounds
        // 從列中間偏右開始：手勢導覽的手機從螢幕邊緣滑＝系統「返回」，會把 app 關掉（Pixel 實測）。
        device.swipe(b.left + b.width() * 3 / 4, b.centerY(), b.left + b.width() / 20, b.centerY(), 30)
        assertTrue("滑過半寬之後這一列還在", device.wait(Until.gone(By.desc("history:滑動刪除測試")), 3_000))
        assertFalse("紀錄沒從檔案刪掉", HistoryStore.load(app).any { it.raw == "滑動刪除測試" })
        assertTrue("另一筆不該被刪", HistoryStore.load(app).any { it.raw == "短滑不動" })
    }

    @Test fun shortSwipeSpringsBackAndKeeps() {
        val row = device.wait(Until.findObject(By.desc("history:短滑不動")), 5_000)
        assertNotNull("歷史列沒出現", row)
        val b = row.visibleBounds
        device.swipe(b.left + b.width() * 3 / 4, b.centerY(), b.left + b.width() * 3 / 4 - b.width() / 5, b.centerY(), 30)
        device.waitForIdle(1_000)
        Thread.sleep(400)   // 彈回動畫 120 ms
        val after = device.findObject(By.desc("history:短滑不動"))
        assertNotNull("短滑之後這一列不見了", after)
        assertEquals("短滑之後沒有彈回原位", b.left, after.visibleBounds.left)
        assertTrue("短滑不該刪掉紀錄", HistoryStore.load(app).any { it.raw == "短滑不動" })
    }
}
