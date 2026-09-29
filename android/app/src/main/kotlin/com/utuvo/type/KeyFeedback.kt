package com.utuvo.type

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.SoundEffectConstants
import android.view.View
import kotlin.math.abs
import kotlin.math.hypot

/**
 * 打字手感（2026-09-20 Micky：「鍵盤輸入的手感不是很好」）。同 iOS KeyFeedback 的原則：
 * **按下去的當下**就震（原本是放開才震，慢一拍），而且在做事（插字、重算候選）之前。
 * 強度交給 [Strength]（關／輕／中／強，預設中，同 iOS KeyFeedbackScreen）；實際送哪個觸覺常數
 * 由 [constantFor] 決定。舊版的 boolean 總開關仍讀得到、寫得回去。
 *
 * 2026-09-29 A4：補齊 iOS KeyButton 的收回與長按行為——
 *  - [SLIDE_OFF_DP]：手指滑開這麼多就「收回」這一下按鍵（左右滑切換語言時不會留下誤打的字）。
 *  - [SWIPE_DP]／[SWIPE_RATIO]：橫向滑到門檻就是切換語言（同 iOS `panned`）。
 *  - [bindUndoKey]：按下做事、滑開收回（字母／組字／空白／刪除）。
 *  - [bindRepeatKey]：長按連續刪除。
 */
object KeyFeedback {

    /** 手指滑開超過這個距離（dp）＝收回這一下按鍵。同 iOS KeyButton 的 20pt。 */
    const val SLIDE_OFF_DP = 20f

    /** 鍵盤上左右滑切換語言的門檻（dp）：水平位移要大於它、且大於垂直位移的這個倍率。 */
    const val SWIPE_DP = 70f
    const val SWIPE_RATIO = 2f

    /** 長按連續刪除：按住這麼久之後開始重複。 */
    private const val REPEAT_DELAY_MS = 450L
    private val main = Handler(Looper.getMainLooper())
    private const val PREF = "keyboard"
    private const val HAPTIC = "hapticEnabled"
    private const val SOUND = "keySoundEnabled"
    private const val STRENGTH = "hapticStrength"

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    /**
     * 震動強度（同 iOS `KeyFeedback.Strength`）：關／輕／中／強，預設「中」。
     * Android 的 `performHapticFeedback` 沒有振幅參數，所以用「不同的觸覺常數」近似——
     * CLOCK_TICK 最輕、KEYBOARD_TAP 中、VIRTUAL_KEY 最實（功能鍵本來就比較重）。
     */
    enum class Strength(val id: String) {
        OFF("off"), LIGHT("light"), MEDIUM("medium"), STRONG("strong");

        companion object {
            fun parse(raw: String?): Strength = values().firstOrNull { it.id == raw } ?: MEDIUM
        }
    }

    fun strength(c: Context): Strength {
        val prefs = prefs(c)
        // 舊版本只存 boolean：先尊重它（關就是關），開的話交給新的四段。
        val legacy = if (prefs.contains(HAPTIC)) prefs.getBoolean(HAPTIC, true) else null
        return if (prefs.contains(STRENGTH)) Strength.parse(prefs.getString(STRENGTH, null))
        else if (legacy == false) Strength.OFF else Strength.MEDIUM
    }

    fun setStrength(c: Context, value: Strength) =
        prefs(c).edit().putString(STRENGTH, value.id).putBoolean(HAPTIC, value != Strength.OFF).apply()

    /** 舊介面（與舊版鍵盤呼叫端相容）：關＝完全不震，開＝用目前的強度。 */
    fun hapticEnabled(c: Context) = strength(c) != Strength.OFF
    fun setHapticEnabled(c: Context, on: Boolean) =
        setStrength(c, if (!on) Strength.OFF else if (strength(c) == Strength.OFF) Strength.MEDIUM else strength(c))
    fun soundEnabled(c: Context) = prefs(c).getBoolean(SOUND, true)
    fun setSoundEnabled(c: Context, on: Boolean) = prefs(c).edit().putBoolean(SOUND, on).apply()

    /**
     * 按鍵：一般鍵用 KEYBOARD_TAP，功能鍵用 VIRTUAL_KEY（比較實）。
     * 實際送哪個常數由「強度 × 鍵種」決定（見 [constantFor]）。
     */
    enum class Kind(val constant: Int) {
        CHARACTER(HapticFeedbackConstants.KEYBOARD_TAP),
        SPECIAL(HapticFeedbackConstants.VIRTUAL_KEY),
    }

    /** 強度 × 鍵種 → 實際送給系統的觸覺常數；回 null 代表這次不震。 */
    fun constantFor(context: Context, kind: Kind): Int? =
        when (strength(context)) {
            Strength.OFF -> null
            // 輕：功能鍵也用最輕的那個，不因為是功能鍵就變重（使用者說關就是要柔）。
            Strength.LIGHT -> HapticFeedbackConstants.CLOCK_TICK
            Strength.MEDIUM -> kind.constant
            Strength.STRONG -> if (kind == Kind.SPECIAL) HapticFeedbackConstants.LONG_PRESS else HapticFeedbackConstants.VIRTUAL_KEY
        }

    /** 手指按下去就回饋；`View.setOnTouchListener` 回 false，點擊照常由 OnClickListener 處理。 */
    fun onDown(view: View, kind: Kind = Kind.CHARACTER) {
        val context = view.context
        constantFor(context, kind)?.let { constant ->
            // IGNORE_GLOBAL_SETTING 不加：使用者在系統把觸覺關掉就該是關的。
            view.performHapticFeedback(constant, HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING)
        }
        if (soundEnabled(context)) view.playSoundEffect(SoundEffectConstants.CLICK)
    }

    /** 掛在按鍵上：按下就回饋，點擊行為不變（給不是「按下就動作」的鍵用，例如候選字）。 */
    fun attach(view: View, kind: Kind = Kind.CHARACTER) {
        view.setOnTouchListener { v, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) onDown(v, kind)
            false
        }
    }

    /**
     * 打字鍵：**按下的當下就回饋＋做事**（同 iOS，2026-09-20 Micky：打字頓頓的）。
     * 仍然掛 OnClickListener，因為 TalkBack／UI 測試的 performClick 不會送觸控事件；
     * 有走過 ACTION_DOWN 的那一次點擊就跳過，不會做兩次。
     */
    fun bindKey(view: View, kind: Kind = Kind.CHARACTER, action: () -> Unit) =
        bindUndoKey(view, kind, action = action)

    /**
     * 打字鍵（同 iOS `KeyButton` 的 onDown／onUndo）：**按下的當下就做事**，手指滑開超過
     * [SLIDE_OFF_DP] 或被系統取消就收回（`onUndo`），在原位放開才交給 `onCommit`（自動學字典等收尾用）。
     *
     * - `onSwipe`：橫向滑過 [SWIPE_DP] 且水平大於垂直 [SWIPE_RATIO] 倍 → 切換語言；
     *   這時這一下按鍵已經被滑開規則收回了，不會在文件裡留下誤打的字（同 iOS `panned` 的配套）。
     * - `onPress`：按下／放開的外觀（呼叫端換背景色）。
     * - OnClickListener 保留給 TalkBack／測試的 `performClick`（沒有觸控事件時的入口）。
     */
    fun bindUndoKey(
        view: View,
        kind: Kind = Kind.CHARACTER,
        onUndo: () -> Unit = {},
        onCommit: () -> Unit = {},
        onSwipe: ((Int) -> Unit)? = null,
        onPress: ((Boolean) -> Unit)? = null,
        action: () -> Unit,
    ) {
        // 這一次觸控已經在按下時做過事了 → 放開觸發的 performClick 要跳過（否則同一個字會出兩次）。
        var pressHandled = false
        var undone = false
        var swiped = false
        var downX = 0f
        var downY = 0f
        fun undoOnce() { if (!undone) { undone = true; onUndo() } }
        view.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    onDown(v, kind)
                    downX = event.x; downY = event.y
                    undone = false; swiped = false
                    onPress?.invoke(true)
                    pressHandled = true
                    action()
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.x - downX
                    val dy = event.y - downY
                    // 滑開 ＝ 收回：立刻把按下去時做出的字／刪除收回去，之後的 UP 不再做事。
                    if (!undone && hypot(dx, dy) >= view.slideOff()) {
                        onPress?.invoke(false)
                        undoOnce()
                    }
                    // 橫向長滑 ＝ 切換語言（同 iOS `panned`）；這一下按鍵已經收回了，不會留下誤打的字。
                    if (onSwipe != null && !swiped && abs(dx) > view.slideOff(SWIPE_DP) && abs(dx) > abs(dy) * SWIPE_RATIO) {
                        swiped = true
                        onPress?.invoke(false)
                        undoOnce()
                        onSwipe(if (dx < 0) 1 else -1)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    onPress?.invoke(false)
                    // MOVE 沒送到（例如事件被吃掉）但 UP 自帶大位移：一樣要收回，
                    // 否則 onDown 插進去的字會留在文件裡。
                    if (hypot(event.x - downX, event.y - downY) >= view.slideOff()) undoOnce()
                    if (!undone) onCommit()
                    // pressHandled 留著給這次 UP 的 performClick 消費（見 setOnClickListener）。
                }
                MotionEvent.ACTION_CANCEL -> {
                    onPress?.invoke(false)
                    undoOnce()
                    pressHandled = false     // CANCEL 不會有 performClick
                }
            }
            false
        }
        view.setOnClickListener {
            if (pressHandled) { pressHandled = false; return@setOnClickListener }
            onDown(view, kind)
            action()
        }
    }

    /**
     * 刪除鍵：按下就刪（同系統鍵盤），滑開收回，**按住連續刪**（`intervalMs` 一次，
     * 語音區 0.08 秒、打字區 0.09 秒，同 iOS）。滑開或放開立刻停住 repeat。
     */
    fun bindRepeatKey(
        view: View,
        kind: Kind = Kind.SPECIAL,
        intervalMs: Long = 90L,
        onUndo: () -> Unit = {},
        onSwipe: ((Int) -> Unit)? = null,
        onPress: ((Boolean) -> Unit)? = null,
        action: () -> Unit,
    ) {
        // 鍵盤在按住期間被收起來時不一定會收到 ACTION_CANCEL：按鍵曾經在畫面上、現在不在了就停，不能一直刪下去。
        // （從沒掛上視窗的情況——例如測試直接建 view——照常連刪。）
        var everShown = view.isAttachedToWindow
        val repeat = object : Runnable {
            override fun run() {
                if (view.isAttachedToWindow) everShown = true
                if (everShown && (!view.isAttachedToWindow || !view.isShown)) return
                action()
                main.postDelayed(this, intervalMs)
            }
        }
        fun stopRepeat() = main.removeCallbacks(repeat)
        view.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) { everShown = true }
            override fun onViewDetachedFromWindow(v: View) = stopRepeat()
        })
        bindUndoKey(view, kind,
            onUndo = { stopRepeat(); onUndo() },
            onCommit = { stopRepeat() },
            onSwipe = { step -> stopRepeat(); onSwipe?.invoke(step) },
            onPress = { pressed -> if (!pressed) stopRepeat(); onPress?.invoke(pressed) },
            action = {
                action()
                stopRepeat()
                main.postDelayed(repeat, REPEAT_DELAY_MS)
            })
    }

    private fun View.slideOff(dpValue: Float = SLIDE_OFF_DP): Float = dpValue * resources.displayMetrics.density



    /**
     * 按住放開才做事的鍵（Return／Send／Search…）：按下只回饋不做事；放開還在按鍵範圍內才送出；
     * 滑出或 ACTION_CANCEL 不送出。`performClick` 照樣可用（給 TalkBack 與無障礙服務）。
     *
     * 跟 `bindKey` 的差別只在時機：Return 必須放開才送，按住放開前想取消（滑出去）都還能取消。
     * 觸控事件一律自己消費（`OnTouchListener` 回 `true`），不再交給 `View.onTouchEvent`，
     * 也就不會被系統再發一次 `performClick`；有效 UP 統一走 `view.performClick()` 這條單一出口，
     * TalkBack／測試呼叫 `performClick` 走的是同一條路徑。
     *
     * 回饋（震動）只在 **手指按下去的那一下**：UP 雖然會走到 `OnClickListener`，
     * 但因為 UP 觸發的 `performClick` 是同步呼叫，`suppressClickHaptic` 只在那一次呼叫期間為真，
     * 結束後立刻清掉；獨立 `performClick`（TalkBack／測試）旗標為假，仍然會震。旗標不殘留。
     */
    fun bindReleaseKey(view: View, kind: Kind = Kind.CHARACTER, action: () -> Unit) {
        var cancelled = false
        // 同步 performClick 期間為真：把這次 click 的回饋壓掉，避免 UP 再震一次
        var suppressClickHaptic = false
        view.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    onDown(v, kind)
                    cancelled = false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!inside(v, event)) cancelled = true
                }
                MotionEvent.ACTION_UP -> {
                    if (!cancelled && inside(v, event)) {
                        suppressClickHaptic = true
                        try { v.performClick() } finally { suppressClickHaptic = false }
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    cancelled = true
                }
            }
            true
        }
        view.setOnClickListener {
            if (!suppressClickHaptic) onDown(view, kind)
            action()
        }
    }

    /** 用 event 本地座標（view 範圍內 [0,width]×[0,height]）判斷觸控是否在 view 上；未量到的 view 一律算裡面。 */
    private fun inside(v: View, event: MotionEvent): Boolean {
        if (v.width <= 0 || v.height <= 0) return true
        val x = event.x; val y = event.y
        return x >= 0f && x <= v.width.toFloat() && y >= 0f && y <= v.height.toFloat()
    }
}
