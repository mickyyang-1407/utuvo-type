package com.utuvo.type

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.TypedValue
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import com.utuvo.type.core.UsageStats
import kotlin.math.max
import kotlin.math.roundToLong

/**
 * 首頁的使用數據（Typeless 手機版的 Home insights）：講了多少字、省下多少時間、平均說話速度、
 * 總聽寫時間，加一張最近 26 週的活動熱圖與連續天數。
 *
 * 數字全部來自 [UsageStore] 的每日計數（只存數字），不受歷史筆數或刪除歷史影響。
 */
class UsagePanel(private val a: Activity) {
    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), a.resources.displayMetrics).toInt()

    private var heatmap: HeatmapView? = null
    private var totalsView: TextView? = null
    private var streakView: TextView? = null

    fun build(col: LinearLayout) {
        col.addView(TextView(a).apply {
            text = a.getString(R.string.usage_title); textSize = 17f; typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(28), 0, dp(4)); contentDescription = "usagePanel"
        })
        heatmap = HeatmapView(a)
        col.addView(heatmap, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(78)))
        totalsView = TextView(a).apply { textSize = 15f; setLineSpacing(dp(4).toFloat(), 1f); contentDescription = "usageTotals" }
        col.addView(totalsView)
        streakView = TextView(a).apply { textSize = 13f; setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(6), 0, 0) }
        col.addView(streakView)
        refreshAsync()   // 讀檔不在主執行緒（luna-review r2：冷啟動時同步讀 usage.json）
    }

    /** 主 app 回前景時重算，讓剛才在鍵盤講的話立刻出現（第一次 build 之後才有意義）。 */
    fun refresh(now: Long = System.currentTimeMillis()) {
        val heatmap = heatmap ?: return
        val totalsView = totalsView ?: return
        val streakView = streakView ?: return
        val stats = UsageStore.load(a)
        val today = UsageStore.today(now)
        bind(heatmap, totalsView, streakView, stats, today)
    }

    /**
     * 同一份資料，但讀檔與統計丟到背景執行緒（2026-10-13 修補：onResume 讀 usage.json 會卡主執行緒）。
     */
    fun refreshAsync(now: Long = System.currentTimeMillis()) {
        val heatmap = heatmap ?: return
        val totalsView = totalsView ?: return
        val streakView = streakView ?: return
        Thread {
            val stats = UsageStore.load(a)
            val today = UsageStore.today(now)
            a.runOnUiThread {
                if (a.isFinishing || a.isDestroyed) return@runOnUiThread
                bind(heatmap, totalsView, streakView, stats, today)
            }
        }.start()
    }

    private fun bind(heatmap: HeatmapView, totalsView: TextView, streakView: TextView, stats: UsageStats, today: String) {
        heatmap.bind(stats.heatmap(today, WEEKS), today)
        val t = stats.totals(today)
        totalsView.text = listOf(
            a.getString(R.string.usage_words, t.words),
            a.getString(R.string.usage_saved, formatMinutes(t.minutesSaved)),
            a.getString(R.string.usage_wpm, t.wordsPerMinute.roundToLong()),
            a.getString(R.string.usage_total_time, formatMinutes(t.seconds / 60.0)),
            a.getString(R.string.usage_sessions, t.sessions),
        ).joinToString("\n")
        streakView.text = a.getString(R.string.usage_streaks, t.currentStreak, t.longestStreak, t.activeDays)
    }

    /** 分鐘數講成人看得懂的樣子：不到一分鐘顯示秒，否則四捨五入到分。 */
    fun formatMinutes(minutes: Double): String =
        if (minutes < 1.0) a.getString(R.string.usage_seconds_short, (minutes * 60).roundToLong().coerceAtLeast(0))
        else a.getString(R.string.usage_minutes, minutes.roundToLong())

    companion object { const val WEEKS = 26; private const val ACCENT = 0xFFE8620C.toInt() }

    /** 活動熱圖：欄＝週、列＝星期日～六（本機時區），5 階顏色跟著日／夜走。 */
    class HeatmapView(context: Activity) : View(context) {
        private val cellPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var columns: List<List<com.utuvo.type.core.HeatCell>> = emptyList()
        private var today: String = ""

        fun bind(cells: List<List<com.utuvo.type.core.HeatCell>>, todayKey: String) {
            columns = cells; today = todayKey; contentDescription = "usageHeatmap"
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (columns.isEmpty()) return
            val empty = emptyColor()
            val steps = stepColors()
            val gap = dp3(2f)
            val cell = max(1f, (width - gap * (columns.size - 1)) / columns.size)
            val h = cell * 7 + gap * 6
            val size = minOf(cell, (height - gap * 6) / 7)
            val r = RectF()
            for ((ci, col) in columns.withIndex()) {
                for ((ri, cellValue) in col.withIndex()) {
                    val left = ci * (cell + gap)
                    val top = ri * (size + gap)
                    // 今天之後的日子還沒到：不畫顏色（否則看起來像「那天沒活動」）。
                    if (cellValue.future) continue
                    cellPaint.color = if (cellValue.level <= 0) empty else steps[cellValue.level.coerceAtMost(4) - 1]
                    r.set(left, top, left + size, top + size)
                    canvas.drawRoundRect(r, dp3(2f), dp3(2f), cellPaint)
                }
            }
        }

        /**
         * 空格＝前景文字色 8%，有活動的 4 階＝品牌橘 ACCENT 的 30% / 55% / 80% / 100%。
         * 2026-10-13 修補：以前寫死淺色，深色模式整張刺眼；accent 用 App 現有的品牌橘，不新增顏色。
         * 文字色用 resolve() 拿，跟隨目前的日／夜設定。
         */
        private fun emptyColor(): Int = withAlpha(foregroundColor(), 0.10f)

        private fun stepColors(): IntArray =
            floatArrayOf(0.30f, 0.55f, 0.80f, 1.0f).map { withAlpha(ACCENT, it) }.toIntArray()

        // textColorPrimary 通常是 ColorStateList 資源；typed.data 會是資源 id 不是顏色，要用 obtainStyledAttributes 取真正的色值。
        private fun foregroundColor(): Int {
            val arr = context.theme.obtainStyledAttributes(intArrayOf(android.R.attr.textColorPrimary))
            return try { arr.getColor(0, 0xFF1C1C1E.toInt()) } finally { arr.recycle() }
        }

        private fun withAlpha(color: Int, fraction: Float): Int {
            val alpha = (255 * fraction).toInt().coerceIn(0, 255)
            return (color and 0x00FFFFFF) or (alpha shl 24)
        }

        private fun dp3(v: Float) =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)
    }
}