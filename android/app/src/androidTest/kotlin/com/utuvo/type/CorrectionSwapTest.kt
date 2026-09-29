package com.utuvo.type

import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 背景更正換字，用真的 EditText 的 InputConnection（鍵盤實際拿到的那種）驗：
 * 連講兩段、第一段的更正晚回來 → 兩段一起換、第二段原樣保留；使用者動過 → 不動。
 */
@RunWith(AndroidJUnit4::class)
class CorrectionSwapTest {
    private val inst = InstrumentationRegistry.getInstrumentation()

    private fun onMain(block: () -> Unit) = inst.runOnMainSync(block)

    @Test
    fun laterSegmentsSurviveEarlierCorrection() = onMain {
        val field = EditText(inst.targetContext)
        val ic = field.onCreateInputConnection(EditorInfo())!!
        val chain = CorrectionChain()
        ic.commitText("前面：", 1)
        val first = "嗯我們約禮拜三，不是，禮拜四。"
        ic.commitText(first, 1); val a = chain.add(first)
        ic.commitText("然後搭到元山站。", 1); val b = chain.add("然後搭到元山站。")

        assertTrue(chain.swap(ic, a, "我們約禮拜四。"))
        assertEquals("前面：我們約禮拜四。然後搭到元山站。", field.text.toString())
        assertTrue(chain.swap(ic, b, "然後搭到圓山站。"))
        assertEquals("前面：我們約禮拜四。然後搭到圓山站。", field.text.toString())
        assertEquals(field.text.length, field.selectionEnd)
    }

    @Test
    fun userEditedMeansNoSwap() = onMain {
        val field = EditText(inst.targetContext)
        val ic = field.onCreateInputConnection(EditorInfo())!!
        val chain = CorrectionChain()
        ic.commitText("悠悠卡記得除值。", 1); val a = chain.add("悠悠卡記得除值。")
        ic.commitText("好", 1)                                  // 使用者接著自己打了字
        assertFalse(chain.swap(ic, a, "悠遊卡記得儲值。"))
        assertEquals("悠悠卡記得除值。好", field.text.toString())
    }

    @Test
    fun emojiLengthsAreUtf16() = onMain {
        val field = EditText(inst.targetContext)
        val ic = field.onCreateInputConnection(EditorInfo())!!
        val chain = CorrectionChain()
        ic.commitText("👍", 1)
        ic.commitText("好喔😀那個就這樣。", 1); val a = chain.add("好喔😀那個就這樣。")
        assertTrue(chain.swap(ic, a, "好喔😀就這樣。"))
        assertEquals("👍好喔😀就這樣。", field.text.toString())
    }
}
