package com.utuvo.type

import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** 真的 EditText 回報給鍵盤的 inputType：多行框保留分段、單行框（搜尋、單行聊天）接回一行。 */
@RunWith(AndroidJUnit4::class)
class FieldShapeTest {
    private fun reported(configure: EditText.() -> Unit): Int {
        var type = 0
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val e = EditText(InstrumentationRegistry.getInstrumentation().targetContext).apply(configure)
            val info = EditorInfo()
            e.onCreateInputConnection(info)
            type = info.inputType
        }
        return type
    }

    @Test fun defaultEditTextIsMultiLine() = assertTrue(FieldShape.allowsLineBreaks(reported { }))
    @Test fun singleLineFieldIsNot() = assertFalse(FieldShape.allowsLineBreaks(reported { isSingleLine = true }))
    @Test fun plainTextTypeIsNot() = assertFalse(FieldShape.allowsLineBreaks(reported { inputType = InputType.TYPE_CLASS_TEXT }))
    @Test fun multiLineMessageIs() = assertTrue(FieldShape.allowsLineBreaks(reported {
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_VARIATION_SHORT_MESSAGE }))
    @Test fun numberFieldIsNot() = assertFalse(FieldShape.allowsLineBreaks(reported { inputType = InputType.TYPE_CLASS_NUMBER }))
}
