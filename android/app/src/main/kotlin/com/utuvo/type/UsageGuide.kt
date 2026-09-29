package com.utuvo.type

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 使用說明（對齊 iOS `UsageGuideScreen`，但只寫 Android 上「真的做得到」的事）。
 * 內容照目前 `UTUVOImeService`／`KeyboardView` 的實際行為：Android 鍵盤可以直接用麥克風，
 * 不像 iPhone 會跳到本 App；長按光球滑到語言＝翻譯；左右滑＝切換 EN／繁／简。
 */
class UsageGuide(private val a: Activity) {
    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), a.resources.displayMetrics).toInt()

    fun build(col: LinearLayout) {
        col.addView(TextView(a).apply {
            text = a.getString(R.string.guide_title); textSize = 20f
            typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(28), 0, dp(4))
        })
        col.addView(TextView(a).apply {
            text = a.getString(R.string.guide_intro); textSize = 14f; setTextColor(0xFF8A8A8A.toInt())
            setPadding(0, 0, 0, dp(8))
        })

        // ── 第一次設定 ──
        section(col, R.string.guide_setup_header)
        step(col, 1, a.getString(R.string.guide_setup_1), a.getString(R.string.guide_setup_1_detail))
        step(col, 2, a.getString(R.string.guide_setup_2), a.getString(R.string.guide_setup_2_detail))
        step(col, 3, a.getString(R.string.guide_setup_3), a.getString(R.string.guide_setup_3_detail))
        col.addView(Button(a).apply {
            text = a.getString(R.string.guide_open_settings)
            contentDescription = "guideOpenSettings"
            setOnClickListener { a.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
        })

        // ── 每次用 ──
        section(col, R.string.guide_use_header)
        step(col, 1, a.getString(R.string.guide_use_1), a.getString(R.string.guide_use_1_detail))
        step(col, 2, a.getString(R.string.guide_use_2), a.getString(R.string.guide_use_2_detail))
        step(col, 3, a.getString(R.string.guide_use_3), a.getString(R.string.guide_use_3_detail))
        note(col, a.getString(R.string.guide_use_note))

        // ── 鍵盤上會用到的手勢 ──
        section(col, R.string.guide_gesture_header)
        tip(col, a.getString(R.string.guide_gesture_1), a.getString(R.string.guide_gesture_1_detail))
        tip(col, a.getString(R.string.guide_gesture_2), a.getString(R.string.guide_gesture_2_detail))
        tip(col, a.getString(R.string.guide_gesture_3), a.getString(R.string.guide_gesture_3_detail))
        tip(col, a.getString(R.string.guide_gesture_4), a.getString(R.string.guide_gesture_4_detail))
        // A3：選取文字 → 光球轉薰衣草 → 說出要怎麼改。
        tip(col, a.getString(R.string.guide_edit_1), a.getString(R.string.guide_edit_1_detail))

        // ── 讓結果更準 ──
        section(col, R.string.guide_accuracy_header)
        tip(col, a.getString(R.string.guide_accuracy_1), a.getString(R.string.guide_accuracy_1_detail))
        tip(col, a.getString(R.string.guide_accuracy_2), a.getString(R.string.guide_accuracy_2_detail))
        tip(col, a.getString(R.string.guide_accuracy_3), a.getString(R.string.guide_accuracy_3_detail))

        // ── 遇到問題 ──
        section(col, R.string.guide_problem_header)
        tip(col, a.getString(R.string.guide_problem_1), a.getString(R.string.guide_problem_1_detail))
        tip(col, a.getString(R.string.guide_problem_2), a.getString(R.string.guide_problem_2_detail))
        tip(col, a.getString(R.string.guide_problem_3), a.getString(R.string.guide_problem_3_detail))
        col.addView(TextView(a).apply { setPadding(0, dp(24), 0, dp(8)) })
    }

    private fun section(col: LinearLayout, res: Int) {
        col.addView(TextView(a).apply {
            text = a.getString(res); textSize = 17f; typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(24), 0, dp(6))
        })
    }

    private fun step(col: LinearLayout, n: Int, title: String, detail: String) {
        val row = LinearLayout(a).apply { setPadding(0, dp(4), 0, dp(4)) }
        row.addView(TextView(a).apply {
            text = n.toString(); textSize = 14f; typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER; setTextColor(accentColor())
            contentDescription = "guideStep:$n"
        }, LinearLayout.LayoutParams(dp(24), dp(24)))
        val text = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(10), 0, 0, 0) }
        text.addView(TextView(a).apply { this.text = title; textSize = 15f; typeface = Typeface.DEFAULT_BOLD })
        text.addView(TextView(a).apply { this.text = detail; textSize = 13f; setTextColor(0xFF5A5A5A.toInt()) })
        row.addView(text, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        col.addView(row)
    }

    private fun tip(col: LinearLayout, title: String, detail: String) {
        col.addView(LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL; setPadding(0, dp(4), 0, dp(4))
            addView(TextView(a).apply { text = title; textSize = 15f; typeface = Typeface.DEFAULT_BOLD })
            addView(TextView(a).apply { text = detail; textSize = 13f; setTextColor(0xFF5A5A5A.toInt()) })
        })
    }

    private fun note(col: LinearLayout, text: String) {
        col.addView(TextView(a).apply {
            this.text = text; textSize = 12f; setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(6), 0, 0)
        })
    }

    private fun accentColor(): Int {
        val typed = TypedValue()
        return if (a.theme.resolveAttribute(android.R.attr.colorAccent, typed, true) && typed.data != 0) typed.data
        else 0xFFE8620C.toInt()
    }
}
