package com.utuvo.type

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.ArrayAdapter
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.abs

/**
 * 鍵盤畫面（全部程式建立）。版面對齊 iOS build 14：
 * 語音區＝光球置中、左排 EN／繁／简、右排 ⌫／@／送出，頂列品牌＋字幕帶；
 * 打字區＝左上「🎙 語音」、候選列、右上循環切版面，下面是鍵。
 */
@SuppressLint("ViewConstructor")
class KeyboardView(context: Context, private val listener: Listener) : LinearLayout(context) {

    enum class Surface { VOICE, EN, HANT, HANS }

    interface Listener {
        fun onOrbTap()
        /** 長按光球、滑到語言放開：用這個語言翻譯接下來講的話。 */
        fun onTranslatePick(target: Translation.Target)
        fun onTranslateArm()
        fun onTranslateCancel()
        fun onSurfaceChanged(surface: Surface)
        fun onCompose(key: Char)
        fun onInsert(text: String)
        fun onDelete()
        fun onSpace()
        fun onEnter()
        fun onPickCandidate(index: Int)
        /** 語音區右上徽章：換聽寫語言（同 iOS `languageButton` 選單）。 */
        fun onDictationLanguage(language: DictationLanguage)
        /** 候選列右端「⌄／⌃」：展開或收起整頁候選字（同 iOS `toggleCandidatePanel`）。 */
        fun onToggleCandidatePanel()
        fun onToggleHantInput()
        fun onSwitchKeyboard()
        // ── 收回（手指滑開超過 20dp、或系統取消觸控時）──
        fun onUndoInsert(text: String)
        fun onUndoCompose()
        fun onUndoDelete()
        fun onUndoSpace()
    }

    private val dark = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val bg = if (dark) 0xFF1C1C1E.toInt() else 0xFFD3D5DB.toInt()
    private val keyBg = if (dark) 0xFF4A4A4E.toInt() else Color.WHITE
    private val specialBg = if (dark) 0xFF323235.toInt() else 0xFFAEB2BA.toInt()
    private val ink = if (dark) Color.WHITE else 0xFF111111.toInt()
    private val ink2 = if (dark) 0xFFAAAAAA.toInt() else 0xFF5E5650.toInt()
    private val accent = 0xFFE8620C.toInt()

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)
    private fun dpi(v: Int) = dp(v.toFloat()).toInt()

    private var surface = Surface.VOICE
    private var hantPinyin = false
    private var enterLabel = context.getString(R.string.key_return)
    /** Shift 三態（同 iOS）：關／下一個字大寫／鎖住大寫。 */
    private enum class Shift { OFF, ONCE, LOCKED }
    private var shift = Shift.ONCE
    private var lastShiftTap = 0L
    private enum class Layer { LETTERS, NUMBERS, SYMBOLS }
    private var layer = Layer.LETTERS

    // 語音區
    private val voice = FrameLayout(context)
    private val brand = TextView(context)
    private val transcript = TextView(context)
    private val orb = OrbView(context)
    private val hint = TextView(context)
    private val switchKey = TextView(context)
    /** 語音區右上的聽寫語言徽章（同 iOS `languageButton`）。 */
    private val langBadge = TextView(context)

    // 長按翻譯的語言弧（要宣告在 init 之前：init 會呼叫 buildArc）
    private var topBand: View? = null
    /** 弧上要畫的目標：主 app 選的順序，來源跟聽寫語言走。換語言要重畫。 */
    private var arcTargets: List<Translation.Target> = Translation.quickPick(context)
    private val arcDots = mutableListOf<TextView>()
    private var languageMenu: android.widget.PopupWindow? = null

    /** 鍵盤收起（視窗隱藏或拆掉）時把語言選單一起關掉，不讓它殘留在下一個 app 上。 */
    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility != VISIBLE) { languageMenu?.dismiss(); languageMenu = null }
    }

    override fun onDetachedFromWindow() {
        languageMenu?.dismiss(); languageMenu = null
        super.onDetachedFromWindow()
    }
    private var arcVisible = false
    private var highlighted: Int? = null

    // 打字區
    private val typing = LinearLayout(context)
    private val candidateRow = LinearLayout(context)
    private val layoutKey = TextView(context)
    private val rows = LinearLayout(context)
    /** 打字區的容器：整頁候選字面板疊在鍵上面（同 iOS 蓋在 typingView 上的 CandidatePanelView）。 */
    private val typingHost = FrameLayout(context)
    private val panel = CandidatePanelView(context)
    /** 打字區最上面那排（🎙、候選列、⌄、EN／繁／简）：整頁面板要從它下面開始，候選列與 ⌃ 才點得到。 */
    private val topBar = LinearLayout(context)
    private val expandKey = TextView(context)
    private val candidateScroll = HorizontalScrollView(context)
    /** 候選列可見的格數；跟 ImeSession.keyboardCandidateLimit 一致（多出來的在整頁面板裡）。 */
    private val VISIBLE_LIMIT = 20
    private val candidateCells = mutableListOf<TextView>()
    private var lastItems: List<Item> = emptyList()
    private data class Item(val text: String, val index: Int, val lead: Boolean)
    /** 英文字母鍵 ＋ 它的小寫原字，改 Shift 時就地換標題用（不重建鍵盤，理由見 [setShift]）。 */
    private val letterKeys = mutableListOf<Pair<TextView, Char>>()
    private var shiftKeyView: TextView? = null

    init {
        orientation = VERTICAL
        setBackgroundColor(bg)
        buildVoice()
        buildTyping()
        addView(voice, LayoutParams(LayoutParams.MATCH_PARENT, dpi(236)))
        typingHost.addView(typing, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        typingHost.addView(panel, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(typingHost, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        panel.onPick = { listener.onPickCandidate(it) }
        setExpanded(false)
        show(Surface.VOICE, false)
        // Android 15 起鍵盤視窗也是 edge-to-edge：系統會在最下面疊一條導覽列（收起鍵盤 ⌄、切換鍵盤 🌐）。
        // 不讓出這段高度，底排的鍵會被蓋住，按「拼」其實按到「收起鍵盤」（Pixel 7／Android 17 實測）。
        setOnApplyWindowInsetsListener { _, insets ->
            val nav = insets.getInsets(WindowInsets.Type.navigationBars())
            setPadding(nav.left, 0, nav.right, nav.bottom)
            insets
        }
    }

    // ── 公開 ──

    fun show(s: Surface, hantUsesPinyin: Boolean) {
        surface = s
        hantPinyin = hantUsesPinyin
        voice.visibility = if (s == Surface.VOICE) VISIBLE else GONE
        typing.visibility = if (s == Surface.VOICE) GONE else VISIBLE
        hideCandidatePanel()      // 換版面時整頁候選過期（同 iOS setSurface）
        if (s != Surface.VOICE) {
            layoutKey.text = when (s) { Surface.HANT -> "繁"; Surface.HANS -> "简"; else -> "EN" }
            shift = Shift.ONCE
            layer = Layer.LETTERS
            buildRows()
        }
    }

    /**
     * 句首自動大寫（同 iOS `updateAutoCapitalization(contextBefore:)`）：游標前是空的、
     * 或剛打完 `.!?` 加空白、或換行之後 → 下一個字大寫；其他情況小寫。鎖定中的 Shift 不動。
     * 只在英文字母層有效。
     */
    fun updateAutoCapitalization(contextBefore: String?) {
        if (surface != Surface.EN || layer != Layer.LETTERS || shift == Shift.LOCKED) return
        val before = contextBefore ?: return
        val trimmed = before.trimEnd(' ', '\t')
        val start = before.isEmpty() ||
            (trimmed.lastOrNull()?.let { it in ".!?" } == true && before.last() == ' ') ||
            before.endsWith("\n")
        setShift(if (start) Shift.ONCE else Shift.OFF)
    }

    /** Shift 鍵：0.3 秒內點兩下＝大寫鎖定（同 iOS `shiftTapped`）。 */
    private fun shiftTapped() {
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastShiftTap < 300) setShift(Shift.LOCKED)
        else setShift(if (shift == Shift.OFF) Shift.ONCE else Shift.OFF)
        lastShiftTap = now
    }

    /**
     * 換 Shift 狀態只換字母的標題，**不重建整個鍵盤**（同 iOS `applyShiftLabels`）。
     * 重建會把手指底下那顆鍵換掉：Android 會對舊 view 送 ACTION_CANCEL，
     * 按下才插出來的字就沒機會收回，連左右滑切換語言也不會發生。
     */
    private fun setShift(s: Shift) {
        if (shift == s) return
        shift = s
        letterKeys.forEach { (view, base) -> view.text = if (s == Shift.OFF) base.toString() else base.uppercase() }
        shiftKeyView?.text = if (s == Shift.LOCKED) "⇪" else "⇧"
    }

    /** 鍵盤上左右滑切換語言：語音 → EN → 繁 → 简 → 語音（同 iOS `panned`）。 */
    private fun swipeSurface(step: Int) {
        val order = listOf(Surface.VOICE, Surface.EN, Surface.HANT, Surface.HANS)
        val next = order[(order.indexOf(surface) + step + order.size) % order.size]
        performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        listener.onSurfaceChanged(next)
    }

    /**
     * 不是按鍵的區域（空白處、頂列、語音區）也認左右滑：水平位移 > 70dp 且大於垂直 2 倍才切換，
     * 打字時手指的小幅移動不算。候選列捲動條（HorizontalScrollView）不掛：捲動優先。
     */
    private fun attachSwipe(view: View) {
        var downX = 0f
        var downY = 0f
        var done = false
        view.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { downX = e.rawX; downY = e.rawY; done = false }
                MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (!done && abs(dx) > dp(KeyFeedback.SWIPE_DP) && abs(dx) > abs(dy) * KeyFeedback.SWIPE_RATIO) {
                        done = true
                        swipeSurface(if (dx < 0) 1 else -1)
                    }
                }
            }
            false
        }
    }

    /**
     * 候選列：`conversion`＝整串最佳轉換（第 0 格），`candidates`＝句首候選（同 iOS `show(preedit:candidates:)`）。
     * 每按一鍵都會叫；格子是重用的，只換標題與索引，不每次拆掉重建（打字會頓）。
     */
    fun showCandidates(conversion: String, candidates: List<String>) {
        setExpandable(!conversion.isEmpty() && candidates.isNotEmpty())
        if (conversion.isEmpty()) {
            if (lastItems.isEmpty()) return
            applyItems(emptyList())
            return
        }
        val wanted = ArrayList<Item>(VISIBLE_LIMIT + 1)
        wanted.add(Item(conversion, -1, lead = true))
        for (i in candidates.take(VISIBLE_LIMIT).indices) {
            val c = candidates[i]
            if (c != conversion) wanted.add(Item(c, i, lead = false))
        }
        applyItems(wanted)
    }

    /** 沒有組字時的建議（聯想詞、英文補完）：沒有「整串」那一格，點第 i 格回 `onPickCandidate(i)`。空陣列＝收起來。 */
    fun showSuggestions(items: List<String>) {
        setExpandable(false)
        applyItems(items.take(VISIBLE_LIMIT).mapIndexed { i, s -> Item(s, i, lead = false) })
    }

    /** 展開中顯示「⌃」（點了收起），收起時顯示「⌄」。 */
    fun setExpanded(on: Boolean) {
        expandKey.text = if (on) "⌃" else "⌄"
        expandKey.contentDescription = context.getString(
            if (on) R.string.key_fewer_candidates else R.string.key_more_candidates)
    }

    /** 整頁候選字目前是不是展開的。 */
    fun isCandidatePanelVisible(): Boolean = panel.visibility == VISIBLE

    /** 組字一變（打字、選字、刪字）整頁候選就過期了：收起來，候選列回到一般的前 20 個。 */
    fun hideCandidatePanel() {
        if (panel.visibility != VISIBLE) return
        panel.visibility = GONE
        setExpanded(false)
    }

    /**
     * 展開整頁候選字；候選列同時換成同一份清單的前段（組字整串＋`items`），兩邊的索引才對得到同一個候選。
     * 以前把 `items[0]` 當成整串那一格：`items[1]` 的索引變成 0，點第二個會送出第一個（review 抓到）。
     */
    fun showCandidatePanel(conversion: String, items: List<String>) {
        if (items.isEmpty()) return
        showCandidates(conversion, items)
        panel.show(items)
        // 同 iOS：面板只蓋按鍵，不蓋候選列。以前 MATCH_PARENT 蓋住整個打字區，
        // 候選列看得到但點下去是面板的格子（點「时」送出「试」），⌃ 也按不到、收不回來。
        // 高度也要釘死成按鍵區的高度：MATCH_PARENT 在 WRAP_CONTENT 的容器裡會被候選字撐高，整個鍵盤跟著變高。
        (panel.layoutParams as FrameLayout.LayoutParams).let { lp ->
            val below = topBar.height
            val height = (typing.height - below).coerceAtLeast(0)
            if (lp.topMargin != below || lp.height != height) { lp.topMargin = below; lp.height = height; panel.layoutParams = lp }
        }
        panel.visibility = VISIBLE
        setExpanded(true)
    }

    private fun setExpandable(on: Boolean) {
        if (expandKey.visibility == (if (on) VISIBLE else GONE)) return
        expandKey.visibility = if (on) VISIBLE else GONE
    }

    private fun applyItems(wanted: List<Item>) {
        if (wanted == lastItems) return
        lastItems = wanted
        candidateScroll.scrollTo(0, 0)
        while (candidateCells.size < wanted.size) {
            val cell = candidateCell()
            candidateRow.addView(cell, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dpi(40)))
            candidateCells.add(cell)
        }
        for (position in candidateCells.indices) {
            val cell = candidateCells[position]
            if (position < wanted.size) {
                val item = wanted[position]
                cell.visibility = VISIBLE
                cell.tag = item.index                       // 動作讀當下的 tag，不是建立時的 index
                if (cell.text != item.text) cell.text = item.text
                cell.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, if (item.lead) 19f else 20f)
                cell.setTextColor(if (item.lead) accent else ink)
                cell.setTypeface(if (item.lead) Typeface.DEFAULT_BOLD else Typeface.DEFAULT)
            } else {
                cell.visibility = GONE
            }
        }
    }

    fun setEnterLabel(label: String) {
        enterLabel = label
        if (surface != Surface.VOICE) buildRows()
        voiceEnter?.text = label
    }

    fun showSwitchKey(show: Boolean) { switchKey.visibility = if (show) VISIBLE else GONE }

    fun setHint(text: String, error: Boolean) {
        hint.text = text
        hint.setTextColor(if (error) 0xFFD32F2F.toInt() else ink2)
    }

    fun setListening(on: Boolean) {
        orb.listening = on
        if (!on) orb.level = 0f
    }

    /** 說出要怎麼改：光球轉薰衣草（同 iOS `micButton.setTint(edit:)`）。 */
    fun setEditMode(on: Boolean) { orb.editPalette = on }

    fun setLevel(rmsDb: Float) { orb.level = ((rmsDb + 2f) / 12f).coerceIn(0f, 1f) }

    /** 字幕帶：有字就顯示逐字稿、沒字就回到品牌。 */
    fun showTranscript(text: String) {
        transcript.text = text
        transcript.visibility = if (text.isEmpty()) GONE else VISIBLE
        brand.visibility = if (text.isEmpty()) VISIBLE else GONE
    }

    // ── 語音區 ──

    private var voiceEnter: TextView? = null

    private fun buildVoice() {
        val top = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        brand.apply {
            text = context.getString(R.string.app_name)
            setTextColor(ink); textSize = 17f; typeface = Typeface.DEFAULT_BOLD
            val icon = context.getDrawable(R.mipmap.ic_launcher)?.apply { setBounds(0, 0, dpi(28), dpi(28)) }
            setCompoundDrawables(icon, null, null, null)
            compoundDrawablePadding = dpi(8)
        }
        transcript.apply {
            setTextColor(ink); textSize = 15f; maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.START
            visibility = GONE
        }
        top.addView(brand, LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        top.addView(transcript, LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        // 聽寫語言徽章（同 iOS 右上）：09-29 真機回報徽章會被擠成直排兩行、按鈕變高。
        // 一律單行、固定寬度（照字量出來），左邊的 brand／transcript 先讓寬度。
        langBadge.apply {
            gravity = Gravity.CENTER
            maxLines = 1
            isSingleLine = true
            setTextColor(ink); textSize = 13f; typeface = Typeface.DEFAULT_BOLD
            background = roundedRect(if (dark) 0xFF323235.toInt() else 0xFFEBEDF2.toInt(), dpi(15))
            contentDescription = context.getString(R.string.key_dictation_language)
        }
        val badgeLp = LinearLayout.LayoutParams(dpi(52), dpi(30)).apply { rightMargin = dpi(6) }
        top.addView(langBadge, badgeLp)
        setLanguageBadge(DictationLanguage.current(context))
        langBadge.setOnClickListener { showLanguageMenu() }
        switchKey.apply {
            text = "🌐"; textSize = 18f; gravity = Gravity.CENTER
            setOnClickListener { listener.onSwitchKeyboard() }
            contentDescription = context.getString(R.string.key_switch)
        }
        top.addView(switchKey, LinearLayout.LayoutParams(dpi(40), dpi(36)))
        voice.addView(top, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, dpi(44)).apply {
            leftMargin = dpi(16); rightMargin = dpi(16); topMargin = dpi(6)
        })

        KeyFeedback.attach(orb, KeyFeedback.Kind.SPECIAL)
        orb.setOnClickListener { listener.onOrbTap() }
        // 長按＝翻譯（同 iOS）：按住出現弧形語言點，滑到語言放開就開始錄；放開在弧以外取消。
        orb.setOnLongClickListener {
            if (orb.listening) return@setOnLongClickListener false
            it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            setArcVisible(true)
            highlight(arcDots.size / 2)
            listener.onTranslateArm()
            true
        }
        var orbDownX = 0f
        var orbDownY = 0f
        var orbSwiped = false
        orb.setOnTouchListener { v, e ->
            if (!arcVisible) {
                // 光球上左右滑一樣切換版面（同 iOS：整個鍵盤都有 pan 手勢）；認到滑動就吃掉這次觸控，不會順手觸發點擊。
                return@setOnTouchListener when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> { orbDownX = e.rawX; orbDownY = e.rawY; orbSwiped = false; false }
                    MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> {
                        val dx = e.rawX - orbDownX
                        val dy = e.rawY - orbDownY
                        val isSwipe = abs(dx) > dp(KeyFeedback.SWIPE_DP) && abs(dx) > abs(dy) * KeyFeedback.SWIPE_RATIO
                        if (!orbSwiped && isSwipe) { orbSwiped = true; swipeSurface(if (dx < 0) 1 else -1); true }
                        else orbSwiped
                    }
                    else -> orbSwiped
                }
            }
            when (e.actionMasked) {
                MotionEvent.ACTION_MOVE -> highlight(nearestDot(e.rawX, e.rawY))
                MotionEvent.ACTION_UP -> {
                    val picked = nearestDot(e.rawX, e.rawY)?.let { arcTargets.getOrNull(it) }
                    endArc(v)
                    if (picked != null) { v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY); listener.onTranslatePick(picked) }
                    else listener.onTranslateCancel()
                }
                MotionEvent.ACTION_CANCEL -> { endArc(v); listener.onTranslateCancel() }
            }
            true
        }
        orb.contentDescription = context.getString(R.string.orb)
        voice.addView(orb, FrameLayout.LayoutParams(dpi(120), dpi(120), Gravity.CENTER_HORIZONTAL).apply { topMargin = dpi(58) })
        buildArc()
        topBand = top

        hint.apply {
            text = context.getString(R.string.hint_idle); textSize = 13f; setTextColor(ink2); gravity = Gravity.CENTER
        }
        voice.addView(hint, FrameLayout.LayoutParams(dpi(200), LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL).apply { topMargin = dpi(184) })

        // 兩側對稱圓鈕：44dp、邊距 16dp、上下間距 50dp（同 iOS）
        val step = 50
        val centerY = 58 + 60
        fun side(label: String, desc: String, left: Boolean, offset: Int, bold: Boolean = true, color: Int = ink,
                 repeatMs: Long? = null, onUndo: () -> Unit = {}, action: () -> Unit): TextView =
            TextView(context).apply {
                text = label; textSize = 16f; gravity = Gravity.CENTER; setTextColor(color)
                if (bold) typeface = Typeface.DEFAULT_BOLD
                val normal = round(keyBg)
                val pressed = round(specialBg)
                background = normal
                contentDescription = desc
                val press: (Boolean) -> Unit = { down -> background = if (down) pressed else normal }
                if (repeatMs != null) KeyFeedback.bindRepeatKey(this, KeyFeedback.Kind.SPECIAL, repeatMs,
                    onUndo = onUndo, onSwipe = { s -> swipeSurface(s) }, onPress = press) { action() }
                else KeyFeedback.bindUndoKey(this, KeyFeedback.Kind.SPECIAL,
                    onUndo = onUndo, onSwipe = { s -> swipeSurface(s) }, onPress = press) { action() }
                voice.addView(this, FrameLayout.LayoutParams(dpi(44), dpi(44), if (left) Gravity.START else Gravity.END).apply {
                    topMargin = dpi(centerY + offset - 22)
                    if (left) leftMargin = dpi(16) else rightMargin = dpi(16)
                })
            }
        side("EN", context.getString(R.string.kb_english), true, -step) { listener.onSurfaceChanged(Surface.EN) }
        side("繁", context.getString(R.string.kb_hant), true, 0) { listener.onSurfaceChanged(Surface.HANT) }
        side("简", context.getString(R.string.kb_hans), true, step) { listener.onSurfaceChanged(Surface.HANS) }
        // 語音區的 ⌫：長按每 0.08 秒刪一次（同 iOS `deleteLongPress`），滑開把剛刪掉的字補回來。
        side("⌫", context.getString(R.string.key_delete), false, -step, bold = false,
            repeatMs = 80L, onUndo = { listener.onUndoDelete() }) { listener.onDelete() }
        side("@", "@", false, 0, bold = false, onUndo = { listener.onUndoInsert("@") }) { listener.onInsert("@") }
        voiceEnter = side(enterLabel, enterLabel, false, step, color = accent) { listener.onEnter() }.apply { textSize = 12f }
        attachSwipe(voice)
        attachSwipe(top)
    }

    // ── 長按翻譯的語言弧 ──

    /** 徽章文字照字量出寬度寫死：不管字幕帶多長都不會被壓成直排兩行。 */
    private fun setLanguageBadge(language: DictationLanguage) {
        val label = context.getString(language.shortRes)
        langBadge.text = label
        val w = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        val h = View.MeasureSpec.makeMeasureSpec(dpi(30), View.MeasureSpec.EXACTLY)
        langBadge.measure(w, h)
        val width = maxOf(dpi(52), langBadge.measuredWidth + dpi(20))
        (langBadge.layoutParams as? LinearLayout.LayoutParams)?.let { lp ->
            lp.width = width
            langBadge.layoutParams = lp
        }
        langBadge.contentDescription =
            context.getString(R.string.key_dictation_language) + "：" + context.getString(language.labelRes)
    }

    /** 徽章選完：換聽寫語言，順便把弧重畫（來源變了，弧上的預設語言也變）。 */
    fun setDictationLanguage(language: DictationLanguage) {
        setLanguageBadge(language)
        arcTargets = Translation.quickPick(context)
        rebuildArc()
    }

    /** 徽章的選單：五種聽寫語言，單選（同 iOS `languageButton.menu`）。 */
    private fun showLanguageMenu() {
        val current = DictationLanguage.current(context)
        val labels = DictationLanguage.all.map { context.getString(it.labelRes) }.toTypedArray()
        val checked = DictationLanguage.all.indexOf(current)
        val list = ListView(context).apply {
            adapter = ArrayAdapter(context, android.R.layout.simple_list_item_single_choice, labels)
            choiceMode = ListView.CHOICE_MODE_SINGLE
            setItemChecked(checked, true)
            divider = null
            setOnItemClickListener { _, _, index, _ ->
                languageMenu?.dismiss()
                val picked = DictationLanguage.all[index]
                if (picked != current) {
                    DictationLanguage.set(context, picked)
                    setDictationLanguage(picked)
                    listener.onDictationLanguage(picked)
                }
            }
        }
        // 鍵盤服務沒有 Activity 視窗，選單用 PopupWindow 釘在徽章上（徽章在輸入框裡，有 window token）。
        val popup = android.widget.PopupWindow(context).apply {
            contentView = list
            width = dpi(200)                        // PopupWindow 的寬高是像素值，不是 MeasureSpec
            height = minOf(labels.size * dpi(48), dpi(300))
            isOutsideTouchable = true
            setBackgroundDrawable(roundedRect(if (dark) 0xFF2A2A2E.toInt() else Color.WHITE, dpi(12)))
        }
        languageMenu = popup
        popup.showAsDropDown(langBadge, 0, -dpi(4))
    }

    private fun rebuildArc() {
        arcDots.forEach { voice.removeView(it) }
        arcDots.clear()
        buildArc()
    }


    /** 五顆語言點排在光球上方的半圓弧（半徑 86dp、左右各 70°；96dp 時最上面那顆會被鍵盤頂邊切掉，Pixel 7 實測），跟 iOS 一樣弧頂會蓋到字幕帶，所以出現時字幕帶先退場。 */
    private fun buildArc() {
        val n = arcTargets.size
        if (n < 2) { highlight(null); return }
        val radius = 86.0
        val orbCenterY = 58 + 60
        arcTargets.forEachIndexed { i, t ->
            val deg = -160.0 + 140.0 * i / (n - 1)          // -160°（左下）→ -20°（右下），往上拱
            val rad = Math.toRadians(deg)
            val dx = (radius * Math.cos(rad)).toFloat()
            val dy = (radius * Math.sin(rad)).toFloat()
            val dot = TextView(context).apply {
                text = context.getString(t.shortRes); textSize = 15f; gravity = Gravity.CENTER
                typeface = Typeface.DEFAULT_BOLD
                contentDescription = context.getString(R.string.translate_to, context.getString(t.labelRes))
                visibility = GONE
                translationX = dp(dx)
            }
            voice.addView(dot, FrameLayout.LayoutParams(dpi(44), dpi(44), Gravity.CENTER_HORIZONTAL).apply {
                topMargin = dpi((orbCenterY + dy - 22).toInt())
            })
            arcDots += dot
        }
        highlight(null)
    }

    private fun setArcVisible(visible: Boolean) {
        arcVisible = visible
        arcDots.forEach { it.visibility = if (visible) VISIBLE else GONE }
        topBand?.alpha = if (visible) 0f else 1f
        if (visible) setHint(context.getString(R.string.hint_translate_arm), error = false)
    }

    private fun endArc(orbView: View) {
        setArcVisible(false)
        highlight(null)
        orbView.isPressed = false
        orbView.animate().scaleX(1f).scaleY(1f).setDuration(180).start()
    }

    private fun highlight(index: Int?) {
        if (index != highlighted && index != null && arcVisible) performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        highlighted = index
        arcDots.forEachIndexed { i, d ->
            val on = i == index
            d.background = round(if (on) accent else keyBg)
            d.setTextColor(if (on) Color.WHITE else ink)
            d.scaleX = if (on) 1.15f else 1f; d.scaleY = d.scaleX
        }
    }

    /** 手指離哪顆最近；離所有點都超過 56dp（大約在弧外）就是 null＝放開取消。 */
    private fun nearestDot(rawX: Float, rawY: Float): Int? {
        val loc = IntArray(2)
        var best: Int? = null
        var bestD = dp(56f)
        arcDots.forEachIndexed { i, d ->
            d.getLocationOnScreen(loc)
            val cx = loc[0] + d.width / 2f
            val cy = loc[1] + d.height / 2f
            val dist = Math.hypot((rawX - cx).toDouble(), (rawY - cy).toDouble()).toFloat()
            if (dist < bestD) { bestD = dist; best = i }
        }
        return best
    }

    // ── 打字區 ──

    private fun buildTyping() {
        typing.orientation = VERTICAL
        val top = topBar.apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dpi(8), dpi(6), dpi(8), dpi(2)) }
        val voiceKey = TextView(context).apply {
            text = context.getString(R.string.key_voice); textSize = 14f; setTextColor(accent); typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER; background = pill(keyBg); setPadding(dpi(12), 0, dpi(12), 0)
            contentDescription = context.getString(R.string.key_voice_desc)
            setOnClickListener { listener.onSurfaceChanged(Surface.VOICE) }
        }
        top.addView(voiceKey, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, dpi(34)))
        val scroll = candidateScroll.apply { isHorizontalScrollBarEnabled = false }
        candidateRow.gravity = Gravity.CENTER_VERTICAL
        scroll.addView(candidateRow)
        // 候選列裡整片都是可點的格子：手指一定是從某個候選字上開始滑，捲動優先（點擊留給沒滑的情況）。
        // ScrollView 的 onInterceptTouchEvent 在垂直移動超過 slop 時會搶回觸控，所以不會被格子吃掉。
        scroll.isFillViewport = true
        top.addView(scroll, LinearLayout.LayoutParams(0, dpi(40), 1f).apply { leftMargin = dpi(6); rightMargin = dpi(2) })
        expandKey.apply {
            textSize = 16f; setTextColor(ink2); gravity = Gravity.CENTER
            contentDescription = context.getString(R.string.key_more_candidates)
            visibility = GONE
            setOnClickListener { listener.onToggleCandidatePanel() }
        }
        top.addView(expandKey, LinearLayout.LayoutParams(dpi(30), dpi(40)))
        layoutKey.apply {
            textSize = 15f; setTextColor(ink); typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            background = round(keyBg); contentDescription = context.getString(R.string.key_cycle_layout)
            setOnClickListener {
                val next = when (surface) { Surface.EN -> Surface.HANT; Surface.HANT -> Surface.HANS; else -> Surface.EN }
                listener.onSurfaceChanged(next)
            }
        }
        top.addView(layoutKey, LinearLayout.LayoutParams(dpi(44), dpi(34)))
        typing.addView(top)
        rows.orientation = VERTICAL
        rows.setPadding(dpi(3), 0, dpi(3), dpi(6))
        typing.addView(rows)
        attachSwipe(top)
        attachSwipe(typing)
    }

    private val englishRows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
    /** 大千注音，聲調在第一排（同 iOS 系統注音）。 */
    private val zhuyinRows = listOf("ㄅㄉˇˋㄓˊ˙ㄚㄞㄢㄦ", "ㄆㄊㄍㄐㄔㄗㄧㄛㄟㄣ", "ㄇㄋㄎㄑㄕㄘㄨㄜㄠㄤ", "ㄈㄌㄏㄒㄖㄙㄩㄝㄡㄥ")

    private val numberRows = listOf("1234567890", "-/:;()$&@\"", ".,?!'")
    private val symbolRows = listOf("[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'")
    /** 中文的數字／符號層用全形中文標點（同 iOS）。 */
    private val chineseNumberRows = listOf("1234567890", "，。？！、：；「」…", "（）《》～")

    private fun buildRows() {
        rows.removeAllViews()
        letterKeys.clear()
        shiftKeyView = null
        val zhuyin = surface == Surface.HANT && !hantPinyin
        if (layer != Layer.LETTERS) {
            val english = surface == Surface.EN
            val table = if (!english) chineseNumberRows else if (layer == Layer.NUMBERS) numberRows else symbolRows
            table.forEachIndexed { i, r ->
                val keys = r.map { ch ->
                    charKey(ch.toString(), 20f, onUndo = { listener.onUndoInsert(ch.toString()) }) { listener.onInsert(ch.toString()) }
                }.toMutableList<View>()
                if (i == 2) {
                    if (english) keys.add(0, special(if (layer == Layer.NUMBERS) "#+=" else "123", 1.4f, "symbols") {
                        layer = if (layer == Layer.NUMBERS) Layer.SYMBOLS else Layer.NUMBERS; buildRows()
                    })
                    keys.add(deleteKey(1.4f))
                }
                addRow(keys, 0f)
            }
        } else if (zhuyin) {
            zhuyinRows.forEachIndexed { i, r ->
                val keys = r.map { ch -> charKey(ch.toString(), 19f, onUndo = { listener.onUndoCompose() }) { listener.onCompose(ch) } }.toMutableList()
                if (i == 3) keys.add(deleteKey(1f))
                addRow(keys, 11f)
            }
        } else {
            val english = surface == Surface.EN
            englishRows.forEachIndexed { i, r ->
                val keys = r.map { ch ->
                    // 要打出去的大小寫在**按下當下**依 Shift 決定（標題可以事後被 setShift 換掉），
                    // 收回時要用同一個字，所以記在這個鍵自己的變數裡。
                    var typed = ""
                    charKey(if (english && shift != Shift.OFF) ch.uppercase() else ch.toString(), 22f, onUndo = {
                        if (english) listener.onUndoInsert(typed) else listener.onUndoCompose()
                    }) {
                        if (english) {
                            typed = if (shift == Shift.OFF) ch.toString() else ch.uppercase()
                            listener.onInsert(typed)
                            if (shift == Shift.ONCE) setShift(Shift.OFF)
                        } else listener.onCompose(ch)
                    }.also { if (english) letterKeys += it to ch }
                }.toMutableList()
                if (i == 2) {
                    if (english) {
                        val sk = special(if (shift == Shift.LOCKED) "⇪" else "⇧", 1.5f, "shift") { shiftTapped() }
                        shiftKeyView = sk
                        keys.add(0, sk)
                    } else keys.add(0, special("'", 1.5f, context.getString(R.string.key_separator), onUndo = { listener.onUndoCompose() }) { listener.onCompose('\'') })
                    keys.add(deleteKey(1.5f))
                }
                addRow(keys, 10f, inset = if (i == 1) 0.5f else 0f)
            }
        }
        // 底排：[123／ABC]＋[拼／注]（只有繁、字母層）＋空白＋送出
        val bottom = mutableListOf<View>()
        val layerLabel = if (layer == Layer.LETTERS) "123" else when {
            surface == Surface.EN -> "ABC"
            surface == Surface.HANT && !hantPinyin -> context.getString(R.string.layer_zhuyin)
            else -> context.getString(R.string.layer_pinyin)
        }
        bottom.add(special(layerLabel, 1.6f, context.getString(R.string.key_layer)) {
            layer = if (layer == Layer.LETTERS) Layer.NUMBERS else Layer.LETTERS; buildRows()
        })
        if (surface == Surface.HANT && layer == Layer.LETTERS) {
            bottom.add(special(if (hantPinyin) "注" else "拼", 1.4f,
                context.getString(if (hantPinyin) R.string.use_zhuyin else R.string.use_pinyin)) { listener.onToggleHantInput() })
        }
        bottom.add(charKey(spaceLabel(), 15f, weight = 5f, onUndo = { listener.onUndoSpace() }) { listener.onSpace() })
        bottom.add(special(enterLabel, 2f, enterLabel, release = true) { listener.onEnter() }.apply { setTextColor(accent) })
        addRow(bottom, 0f)
    }

    /** 空白鍵的標籤：注音「空白」、拼音「空格」、英文「space」（同 iOS `TypingKeyboardView:179`）。 */
    private fun spaceLabel(): String = when {
        surface == Surface.EN -> "space"
        surface == Surface.HANT && !hantPinyin -> context.getString(R.string.key_space)
        else -> context.getString(R.string.key_space_pinyin)
    }

    /**
     * 每一列按鍵的高度。同 iOS（語音 236／英文 262／注音 296／拼音 262 pt）：注音多了兩列，
     * 整個版面要比拼音／英文高 296/262 倍；英文的列高沿用原本調好的 48dp，
     * 注音的列高＝48 × (296/262) × (4 列/5 列)。
     */
    private fun rowHeight(): Int {
        val zhuyin = surface == Surface.HANT && !hantPinyin
        return if (zhuyin) dp(48f * (296f / 262f) * (4f / 5f)).toInt() else dpi(48)
    }

    /** 測試用（androidTest）：打字區每一列目前量到的高度。 */
    internal fun typingRowHeights(): List<Int> = (0 until rows.childCount).map { rows.getChildAt(it).height }

    private fun addRow(keys: List<View>, units: Float, inset: Float = 0f) {
        val row = LinearLayout(context).apply { gravity = Gravity.CENTER; setPadding(0, dpi(3), 0, dpi(3)) }
        val total = if (units > 0) units else keys.sumOf { ((it.layoutParams as? LinearLayout.LayoutParams)?.weight ?: 1f).toDouble() }.toFloat()
        if (inset > 0) row.addView(View(context), LinearLayout.LayoutParams(0, 1, inset))
        keys.forEach { k -> row.addView(k) }
        if (inset > 0) row.addView(View(context), LinearLayout.LayoutParams(0, 1, inset))
        row.weightSum = total + inset * 2
        rows.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, rowHeight()))
    }

    private fun charKey(label: String, size: Float, weight: Float = 1f, onUndo: () -> Unit = {}, action: () -> Unit) = TextView(context).apply {
        text = label; textSize = size; setTextColor(ink); gravity = Gravity.CENTER
        val normal = keyShape(keyBg)
        val pressed = keyShape(specialBg)     // 按下時反色（同 iOS applyColors(pressed:)）
        background = normal
        layoutParams = LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, weight).apply { leftMargin = dpi(3); rightMargin = dpi(3) }
        // 按下的當下就出字（放開才出會慢一拍、連打時像頓住）；手指滑開就收回。
        KeyFeedback.bindUndoKey(this, KeyFeedback.Kind.CHARACTER,
            onUndo = onUndo,
            onSwipe = { step -> swipeSurface(step) },
            onPress = { down -> background = if (down) pressed else normal },
            action = action)
    }

    private fun special(label: String, weight: Float, desc: String, release: Boolean = false, onUndo: () -> Unit = {}, action: () -> Unit) = TextView(context).apply {
        text = label; textSize = 16f; setTextColor(ink); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD
        val normal = keyShape(specialBg)
        val pressed = keyShape(keyBg)
        background = normal
        contentDescription = desc
        layoutParams = LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, weight).apply { leftMargin = dpi(3); rightMargin = dpi(3) }
        if (release) KeyFeedback.bindReleaseKey(this, KeyFeedback.Kind.SPECIAL) { action() }
        else KeyFeedback.bindUndoKey(this, KeyFeedback.Kind.SPECIAL,
            onUndo = onUndo,
            onSwipe = { step -> swipeSurface(step) },
            onPress = { down -> background = if (down) pressed else normal },
            action = action)
    }

    /** 刪除鍵：按下就刪、滑開收回（把剛刪掉的字補回來）、按住連續刪（同 iOS `deleteKey`）。 */
    private fun deleteKey(weight: Float, intervalMs: Long = 90L) = TextView(context).apply {
        text = "⌫"; textSize = 16f; setTextColor(ink); gravity = Gravity.CENTER; typeface = Typeface.DEFAULT_BOLD
        val normal = keyShape(specialBg)
        val pressed = keyShape(keyBg)
        background = normal
        contentDescription = context.getString(R.string.key_delete)
        layoutParams = LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, weight).apply { leftMargin = dpi(3); rightMargin = dpi(3) }
        KeyFeedback.bindRepeatKey(this, KeyFeedback.Kind.SPECIAL, intervalMs,
            onUndo = { listener.onUndoDelete() },
            onSwipe = { step -> swipeSurface(step) },
            onPress = { down -> background = if (down) pressed else normal },
            action = { listener.onDelete() })
    }

    /** 重用的候選格子：`tag` 會被 [applyItems] 改掉，所以動作要讀當下的 tag，不能抓建立時的 index。 */
    private fun candidateCell() = TextView(context).apply {
        textSize = 20f
        gravity = Gravity.CENTER
        setPadding(dpi(10), 0, dpi(10), 0)
        visibility = GONE
        KeyFeedback.attach(this)
        setOnClickListener { listener.onPickCandidate(tag as? Int ?: -1) }
    }

    private fun keyShape(color: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(6f) }
    private fun round(color: Int) = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }

    /** 圓角矩形（膠囊徽章、選單底用；[round] 是正圓形，不適合）。 */
    private fun roundedRect(color: Int, radiusPx: Int) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE; cornerRadius = radiusPx.toFloat(); setColor(color)
    }
    private fun pill(color: Int) = GradientDrawable().apply { setColor(color); cornerRadius = dp(17f) }
}

/**
 * 展開的整頁候選字（疊在鍵上面，同 iOS 的 CandidatePanelView）：依字寬換行排列、可以上下捲、點了就選。
 *
 * 捲動：Android 的 ScrollView 會在垂直移動超過 slop 時於 onInterceptTouchEvent 搶回觸控，
 * 所以「手指從某個候選字上開始滑」照樣捲得動，不需要 iOS 那種 touchesShouldCancel。
 * （iPhone 踩過的坑：捲動區裡整片按鈕會把滑動吃掉。）
 */
class CandidatePanelView(context: Context) : FrameLayout(context) {
    companion object {
        /** 整頁候選每一格的 contentDescription 前綴，後面接 0 起的索引（UI 測試靠它分辨第幾個）。 */
        const val CELL_DESC_PREFIX = "candidatePanelCell-"
    }

    var onPick: ((Int) -> Unit)? = null
    private val scroll = ScrollView(context).apply { isVerticalScrollBarEnabled = false }
    private val wrap = WrapLayout(context)
    private val cells = mutableListOf<TextView>()
    private val rowHeight = dp(46f).toInt()
    /** 每格要自己一個：drawable 的 bounds 跟著 view 走，共用一個時寬度不同的格子會用到別格的 bounds 畫底。 */
    private fun cellBackground() = GradientDrawable().apply { cornerRadius = dp(8f); setColor(0xFFFFFFFF.toInt()) }

    init {
        visibility = GONE
        setBackgroundColor(0xFFF2F2F7.toInt())
        contentDescription = context.getString(R.string.candidate_panel)
        // 同 iOS CandidatePanelView.layoutSubviews：外框 8、間距 6、每格至少 52 寬、字左右各 12。
        dp(8f).toInt().let { wrap.setPadding(it, it, it, it) }
        wrap.gap = dp(6f).toInt()
        scroll.addView(wrap, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun show(items: List<String>) {
        while (cells.size < items.size) {
            val cell = TextView(context).apply {
                textSize = 22f
                gravity = Gravity.CENTER
                setTextColor(0xFF111111.toInt())
                background = cellBackground()
                minWidth = dp(52f).toInt()
                dp(12f).toInt().let { setPadding(it, 0, it, 0) }
                maxLines = 1
                visibility = GONE
                KeyFeedback.attach(this)
                setOnClickListener { onPick?.invoke(tag as? Int ?: -1) }
            }
            wrap.addView(cell, LayoutParams(LayoutParams.WRAP_CONTENT, rowHeight))
            cells.add(cell)
        }
        for (i in cells.indices) {
            val cell = cells[i]
            if (i >= items.size) { cell.visibility = GONE; continue }
            cell.visibility = VISIBLE
            cell.tag = i
            // 帶索引的描述：整頁裡同樣的字可能出現不只一次，UI 測試要分辨第幾個。
            cell.contentDescription = "$CELL_DESC_PREFIX$i"
            if (cell.text != items[i]) cell.text = items[i]
        }
        scroll.scrollTo(0, 0)
        requestLayout()
    }

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)
}

/** 依子字的寬度換行排列（同 iOS CandidatePanelView.layoutSubviews 的手動換行）。 */
class WrapLayout(context: Context) : ViewGroup(context) {
    /** 格與格之間的間距（px），同 iOS CandidatePanelView.gap（6pt）。外框用 padding。 */
    var gap = 0

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val maxWidth = MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight
        var x = 0
        var y = 0
        var rowHeight = 0
        val childWidthSpec = MeasureSpec.makeMeasureSpec(maxOf(0, maxWidth), MeasureSpec.AT_MOST)
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child.visibility == GONE) continue
            child.measure(childWidthSpec, MeasureSpec.makeMeasureSpec(child.layoutParams.height, MeasureSpec.EXACTLY))
            if (x > 0 && x + child.measuredWidth > maxWidth) { x = 0; y += rowHeight + gap; rowHeight = 0 }
            x += child.measuredWidth + gap
            rowHeight = maxOf(rowHeight, child.measuredHeight)
        }
        val height = paddingTop + paddingBottom + y + rowHeight
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), resolveSize(height, heightMeasureSpec))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val right = r - l - paddingRight
        var x = paddingLeft
        var y = paddingTop
        var rowHeight = 0
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child.visibility == GONE) continue
            if (x > paddingLeft && x + child.measuredWidth > right) {
                x = paddingLeft; y += rowHeight + gap; rowHeight = 0
            }
            child.layout(x, y, x + child.measuredWidth, y + child.measuredHeight)
            x += child.measuredWidth + gap
            rowHeight = maxOf(rowHeight, child.measuredHeight)
        }
    }
}

/** 光球：橘色漸層圓，錄音時跟著音量縮放。（iOS 的流體 Metal shader 之後用 AGSL 做。） */
class OrbView(context: Context) : View(context) {
    var listening = false
        set(v) { field = v; if (v) pulse.start() else { pulse.cancel(); scale = 1f; invalidate() } }
    var level = 0f
        set(v) { field = v; invalidate() }
    /** 說出要怎麼改：光球轉薰衣草，一眼看出現在講的是指示（同 iOS `setTint(edit:)`）。 */
    var editPalette = false
        set(v) { if (field != v) { field = v; invalidate() } }
    private var scale = 1f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pulse = ValueAnimator.ofFloat(0.98f, 1.02f).apply {
        duration = 1500; repeatMode = ValueAnimator.REVERSE; repeatCount = ValueAnimator.INFINITE
        addUpdateListener { scale = it.animatedValue as Float; invalidate() }
    }

    init { isClickable = true }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = minOf(width, height) / 2f * 0.82f * scale * (1f + level * 0.06f)
        paint.shader = RadialGradient(cx - r * 0.35f, cy - r * 0.4f, r * 1.6f,
            if (editPalette) LAVENDER else VOICE,
            floatArrayOf(0f, 0.35f, 0.7f, 1f), Shader.TileMode.CLAMP)
        canvas.drawCircle(cx, cy, r, paint)
    }

    private companion object {
        val VOICE = intArrayOf(0xFFFFD08A.toInt(), 0xFFFB8B24.toInt(), 0xFFE8620C.toInt(), 0xFFC2410C.toInt())
        val LAVENDER = intArrayOf(0xFFE4DBFB.toInt(), 0xFFB49BEE.toInt(), 0xFF8A6BD1.toInt(), 0xFF5F44A0.toInt())
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_DOWN) animate().scaleX(0.93f).scaleY(0.93f).setDuration(120).start()
        if (event.action == MotionEvent.ACTION_UP || event.action == MotionEvent.ACTION_CANCEL) animate().scaleX(1f).scaleY(1f).setDuration(180).start()
        return super.onTouchEvent(event)
    }
}
