package com.utuvo.type

import android.content.Intent
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 選取文字＝「說出要怎麼改」（同 iOS KeyboardMode.edit）：輸入框裡選一段字，鍵盤提示要換；取消選取要換回來。
 * 需要 UTUVO Type 已是啟用的輸入法（android/scripts/run-device-tests.sh 會從電腦端啟用）。
 */
@RunWith(AndroidJUnit4::class)
class EditModeTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(inst)
    private val app get() = inst.targetContext
    private val imeId get() = app.packageName + "/" + UTUVOImeService::class.java.name

    @Before fun setUp() {
        device.setOrientationPortrait()
        device.executeShellCommand("ime set $imeId")
        app.startActivity(Intent(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        assertTrue(device.wait(Until.hasObject(By.desc("tryField")), 10_000))
    }

    private fun onField(block: (EditText) -> Unit) {
        inst.runOnMainSync {
            val activity = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).first()
            val found = ArrayList<android.view.View>()
            activity.window.decorView.findViewsWithText(found, "tryField", android.view.View.FIND_VIEWS_WITH_CONTENT_DESCRIPTION)
            val field = found.first() as EditText
            block(field)
        }
    }

    @Test fun selectingTextSwitchesToEditHintAndBack() {
        device.findObject(By.desc("tryField")).click()
        assertTrue("鍵盤沒出現", device.wait(Until.hasObject(By.text(app.getString(R.string.hint_idle))), 15_000))
        onField { it.setText("今天天氣很好"); it.requestFocus(); it.setSelection(0, 4) }
        assertTrue("選取之後提示沒換成「說出要怎麼改」", device.wait(Until.hasObject(By.text("說出要怎麼改")), 5_000))
        onField { it.setSelection(it.text.length) }
        assertTrue("取消選取之後提示沒換回來", device.wait(Until.hasObject(By.text(app.getString(R.string.hint_idle))), 5_000))
    }
}
