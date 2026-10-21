package com.utuvo.type

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.text.Editable
import android.text.Html
import android.text.InputType
import android.text.TextWatcher
import android.text.format.DateUtils
import android.text.method.LinkMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.EditText
import com.utuvo.type.core.DictionarySync
import com.utuvo.type.core.HistoryRetention
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Switch
import android.widget.Toast

/** 主 app 的「個人字典」「智慧整理」「詞庫包」「最近聽寫」幾區（同 iOS 設定頁）。 */
class MainSections(private val a: Activity) {
    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), a.resources.displayMetrics).toInt()
    private val accent = 0xFFE8620C.toInt()

    private fun header(col: LinearLayout, res: Int) =
        col.addView(TextView(a).apply { text = a.getString(res); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(32), 0, dp(4)) })

    // ── 個人字典 ──

    private lateinit var dictList: LinearLayout
    private lateinit var dictFooter: TextView
    private lateinit var dictCount: TextView
    private var vocabulary = true
    /** 字典頁分頁：全部／自動學到／自己加的。 */
    private enum class DictTab(val res: Int) { ALL(R.string.dict_tab_all), AUTO(R.string.dict_tab_auto), MANUAL(R.string.dict_tab_manual) }
    private var dictTab = DictTab.ALL
    private var dictQuery: String = ""

    fun buildDictionary(col: LinearLayout) {
        header(col, R.string.dict_title)
        val modes = RadioGroup(a).apply { orientation = RadioGroup.HORIZONTAL }
        val vocab = RadioButton(a).apply { id = View.generateViewId(); text = a.getString(R.string.dict_mode_vocab); contentDescription = "dictModeVocab" }
        val repl = RadioButton(a).apply { id = View.generateViewId(); text = a.getString(R.string.dict_mode_replace); contentDescription = "dictModeReplace" }
        modes.addView(vocab); modes.addView(repl)
        modes.check(vocab.id)
        col.addView(modes)

        val row = LinearLayout(a).apply { gravity = Gravity.CENTER_VERTICAL }
        val term = EditText(a).apply { isSingleLine = true; contentDescription = "dictionaryTerm"; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO }
        val arrow = TextView(a).apply { text = "→"; textSize = 16f; setPadding(dp(6), 0, dp(6), 0) }
        val output = EditText(a).apply { isSingleLine = true; contentDescription = "dictionaryOutput"; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO }
        val add = Button(a).apply { text = a.getString(R.string.dict_add); contentDescription = "dictionaryAdd" }
        row.addView(term, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(arrow); row.addView(output, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(add)
        col.addView(row)
        // 分頁（全部／自動／手動）＋搜尋框：詞多的時候才找得到東西。
        val tabs = RadioGroup(a).apply { orientation = RadioGroup.HORIZONTAL }
        val tabButtons = DictTab.entries.associateWith { tab ->
            RadioButton(a).apply {
                id = View.generateViewId(); text = a.getString(tab.res); textSize = 13f
                contentDescription = "dictTab:${tab.name}"
            }.also { tabs.addView(it) }
        }
        tabs.check(tabButtons.getValue(DictTab.ALL).id)
        col.addView(tabs)
        col.addView(EditText(a).apply {
            hint = a.getString(R.string.dict_search_hint); isSingleLine = true
            contentDescription = "dictionarySearch"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    dictQuery = s?.toString().orEmpty().trim(); refreshDictionary()
                }
                override fun afterTextChanged(s: Editable?) {}
            })
        })
        tabs.setOnCheckedChangeListener { _, id ->
            dictTab = tabButtons.entries.firstOrNull { it.value.id == id }?.key ?: DictTab.ALL
            refreshDictionary()
        }
        dictCount = TextView(a).apply { textSize = 12f; setTextColor(0xFF8A8A8A.toInt()); contentDescription = "dictCount" }
        col.addView(dictCount)
        dictList = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        col.addView(dictList)
        dictFooter = TextView(a).apply { textSize = 13f; setPadding(0, dp(4), 0, 0) }
        col.addView(dictFooter)

        fun applyMode() {
            arrow.visibility = if (vocabulary) View.GONE else View.VISIBLE
            output.visibility = if (vocabulary) View.GONE else View.VISIBLE
            term.hint = a.getString(if (vocabulary) R.string.dict_term_vocab else R.string.dict_term_heard)
            output.hint = a.getString(R.string.dict_output)
            dictFooter.text = a.getString(if (vocabulary) R.string.dict_footer_vocab else R.string.dict_footer_replace)
        }
        modes.setOnCheckedChangeListener { _, id -> vocabulary = id == vocab.id; applyMode() }
        add.setOnClickListener {
            val s = term.text.toString().trim()
            val o = output.text.toString().trim()
            if (s.isEmpty() || (!vocabulary && o.isEmpty())) return@setOnClickListener
            DictionaryStore.add(a, s, if (vocabulary) "" else o)
            term.setText(""); output.setText("")
            refreshDictionary()
        }
        applyMode()
        refreshDictionary()

        // 匯出／匯入（跟 iPhone、Mac 互通；存到 Google Drive 或傳給自己，另一台匯入，最後改的贏）
        val io = LinearLayout(a)
        io.addView(Button(a).apply {
            text = a.getString(R.string.dict_export); contentDescription = "dictExport"
            setOnClickListener {
                a.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/json").putExtra(Intent.EXTRA_TITLE, "UTUVO Type 字典.json"), REQ_EXPORT)
            }
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        io.addView(Button(a).apply {
            text = a.getString(R.string.dict_import); contentDescription = "dictImport"
            setOnClickListener {
                a.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*"), REQ_IMPORT)
            }
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        col.addView(io)
        dictIoMessage = TextView(a).apply { textSize = 13f; contentDescription = "dictIoMessage" }
        col.addView(dictIoMessage)
        col.addView(TextView(a).apply { text = a.getString(R.string.dict_io_explain); textSize = 12f; setTextColor(0xFF8A8A8A.toInt()) })
    }

    private lateinit var dictIoMessage: TextView

    /** MainActivity.onActivityResult 轉過來（系統檔案選擇器存／開完）。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) return
        val r = runCatching {
            when (requestCode) {
                REQ_EXPORT -> {
                    a.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(DictionaryStore.export(a).toByteArray()) }
                    a.getString(R.string.dict_exported, DictionaryStore.entries(a).size)
                }
                REQ_IMPORT -> {
                    val text = a.contentResolver.openInputStream(uri)!!.use { it.readBytes().toString(Charsets.UTF_8) }
                    val n = DictionaryStore.import(a, text)
                    refreshDictionary()
                    a.getString(R.string.dict_imported, n)
                }
                else -> return
            }
        }
        dictIoMessage.setTextColor(if (r.isSuccess) 0xFF8A8A8A.toInt() else 0xFFD32F2F.toInt())
        dictIoMessage.text = r.getOrElse { e ->
            android.util.Log.w("UTUVOType", "dictionary ${if (requestCode == REQ_EXPORT) "export" else "import"} failed", e)
            a.getString(if (e is com.utuvo.type.core.DictionarySync.Companion.NewerVersion) R.string.dict_import_newer else R.string.dict_import_failed)
        }
    }

    private companion object {
        const val REQ_EXPORT = 41; const val REQ_IMPORT = 42
        /** 歷史頁每一天最多畫幾筆（避免捲到卡住；新的在最前面）。 */
        const val HISTORY_DAY_LIMIT = 50
        /** 左滑超過鍵寬的這個比例才算刪除（同 iOS swipeActions full swipe 的門檻）。 */
        const val SWIPE_DELETE_RATIO = 0.5f
    }

    private fun refreshDictionary() {
        if (!::dictList.isInitialized) return
        dictList.removeAllViews()
        val sources = DictionaryStore.sources(a)
        val all = DictionaryStore.sorted(a)
        val visible = all.filter { (source, output) ->
            val origin = sources[source] ?: DictionarySync.Source.MANUAL
            val tabHit = when (dictTab) {
                DictTab.ALL -> true
                DictTab.AUTO -> origin == DictionarySync.Source.AUTO
                DictTab.MANUAL -> origin == DictionarySync.Source.MANUAL
            }
            tabHit && (dictQuery.isEmpty() || source.contains(dictQuery, ignoreCase = true) || output.contains(dictQuery, ignoreCase = true))
        }
        dictCount.text = a.getString(R.string.dict_count, visible.size, all.size)
        if (visible.isEmpty()) {
            dictList.addView(TextView(a).apply {
                text = a.getString(if (all.isEmpty()) R.string.dict_empty else R.string.dict_no_match)
                textSize = 14f; setPadding(0, dp(8), 0, dp(8))
            })
            return
        }
        for ((source, output) in visible) {
            val auto = sources[source] == DictionarySync.Source.AUTO
            val line = LinearLayout(a).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(0, dp(4), 0, dp(4)) }
            val label = when {
                auto -> "$source → $output　${a.getString(R.string.dict_badge_auto)}"
                source == output -> "$source　${a.getString(R.string.dict_badge_vocab)}"
                else -> "$source → $output"
            }
            line.addView(TextView(a).apply {
                textSize = 16f; text = label
                contentDescription = "dictEntry:$source"
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            line.addView(TextView(a).apply {
                text = a.getString(R.string.dict_delete); setTextColor(0xFFD32F2F.toInt()); textSize = 15f
                setPadding(dp(12), dp(8), dp(4), dp(8)); contentDescription = "dictDelete:$source"
                setOnClickListener {
                    // 自動學到的：刪掉之後記進「已忽略」，同一組修正不會馬上又被學回來。
                    if (auto) DictionaryStore.ignore(a, source, output)
                    DictionaryStore.remove(a, source)
                    refreshDictionary()
                }
            })
            dictList.addView(line)
        }
    }

    // ── 歷史（同 iOS HistoryListView：搜尋、依日分組、滑動刪除／點一下複製）──

    private lateinit var historyList: LinearLayout
    private lateinit var clearHistory: Button
    private lateinit var retentionRow: TextView
    private var historyQuery: String = ""

    fun buildHistory(col: LinearLayout) {
        header(col, R.string.history_title)
        col.addView(TextView(a).apply { text = a.getString(R.string.history_explain); textSize = 13f })
        // 保留期限：只砍歷史紀錄，**每日使用計數不受影響**（首頁數字不會跟著消失）。
        retentionRow = TextView(a).apply {
            textSize = 16f; setPadding(0, dp(12), 0, dp(12))
            contentDescription = "historyRetention"
        }
        col.addView(retentionRow)
        retentionRow.setOnClickListener { pickRetention() }
        val search = EditText(a).apply {
            hint = a.getString(R.string.history_search_hint); isSingleLine = true
            contentDescription = "historySearch"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        col.addView(search)
        historyList = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        col.addView(historyList)
        clearHistory = Button(a).apply {
            text = a.getString(R.string.history_clear)
            setOnClickListener { confirmClearHistory() }
        }
        col.addView(clearHistory)
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                historyQuery = s?.toString().orEmpty(); renderHistory(historyCache)   // 搜尋只過濾記憶體裡那份
            }
            override fun afterTextChanged(s: Editable?) {}
        })
        refreshHistoryAsync()
    }

    /** 保留期限選單；選比現在短的會先確認會少幾筆（「不保留」＝連新紀錄都不寫，但使用數據照算）。 */
    private fun pickRetention() {
        val options = HistoryRetention.entries
        val current = HistoryRetentionSetting.setting(a)
        AlertDialog.Builder(a)
            .setTitle(R.string.history_retention_title)
            .setSingleChoiceItems(options.map { a.getString(retentionLabel(it)) }.toTypedArray(), options.indexOf(current)) { dialog, which ->
                dialog.dismiss()
                val picked = options[which]
                if (picked == current) return@setSingleChoiceItems
                // 用「剛選的那個期限」算會少幾筆——用舊設定的話，換成較短的期限時確認框不會出現。
                val expired = HistoryStore.expiredCount(a, picked)
                if (expired == 0) { applyRetention(picked); return@setSingleChoiceItems }
                AlertDialog.Builder(a)
                    .setTitle(R.string.history_retention_title)
                    .setMessage(a.getString(R.string.history_retention_confirm, expired))
                    .setNegativeButton(android.R.string.cancel, null)
                    .setPositiveButton(R.string.history_retention_apply) { _, _ -> applyRetention(picked) }
                    .show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun applyRetention(picked: HistoryRetention) {
        HistoryRetentionSetting.set(a, picked)
        // 砍檔案是 IO，不在主執行緒做；回來再重畫並提示。
        Thread {
            val removed = HistoryStore.applyRetention(a, picked)
            val records = HistoryStore.load(a)
            a.runOnUiThread {
                if (a.isFinishing || a.isDestroyed) return@runOnUiThread
                renderHistory(records)
                Toast.makeText(a, a.getString(R.string.history_retention_applied, removed), Toast.LENGTH_SHORT).show()
            }
        }.start()
    }

    private fun retentionLabel(r: HistoryRetention) = when (r) {
        HistoryRetention.DAY -> R.string.history_retention_day
        HistoryRetention.WEEK -> R.string.history_retention_week
        HistoryRetention.MONTH -> R.string.history_retention_month
        HistoryRetention.YEAR -> R.string.history_retention_year
        HistoryRetention.FOREVER -> R.string.history_retention_forever
        HistoryRetention.NONE -> R.string.history_retention_none
    }

    /** 全部刪除要確認：不可逆；使用數據不受影響這件事要講清楚。 */
    private fun confirmClearHistory() {
        AlertDialog.Builder(a)
            .setTitle(R.string.history_clear)
            .setMessage(R.string.history_clear_confirm)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.history_clear) { _, _ ->
                HistoryStore.clear(a)
                refreshHistory()
                Toast.makeText(a, a.getString(R.string.history_cleared), Toast.LENGTH_SHORT).show()
            }
            .show()
    }

    /** 同 refreshHistory，但讀檔在背景執行緒（onResume 呼叫用，避免卡主執行緒）。 */
    fun refreshHistoryAsync() {
        if (!::historyList.isInitialized) return
        Thread {
            val records = HistoryStore.load(a)
            a.runOnUiThread {
                if (a.isFinishing || a.isDestroyed) return@runOnUiThread
                renderHistory(records)
            }
        }.start()
    }

    /** 同步重讀（刪除／清空這類使用者剛改過的動作後用；檔案最多 500 筆）。 */
    fun refreshHistory() = renderHistory(HistoryStore.load(a))

    /** 最近一次讀到的歷史；搜尋與重畫用它，不必每打一個字就讀一次檔。 */
    private var historyCache: List<HistoryStore.Record> = emptyList()

    private fun renderHistory(all: List<HistoryStore.Record>) {
        historyCache = all
        if (!::historyList.isInitialized) return
        historyList.removeAllViews()
        // 純邏輯在 HistoryGrouping（可 JVM 測）；資料層的紀錄在這裡換成它的 Item。
        val items = all.map { HistoryGrouping.Item(it.time, it.raw, it.cleaned, it.durationSec) }
        val hits = HistoryGrouping.filter(items, historyQuery)
        if (hits.isEmpty()) {
            historyList.addView(TextView(a).apply {
                text = a.getString(if (all.isEmpty()) R.string.history_empty else R.string.history_no_match)
                textSize = 14f; setPadding(0, dp(8), 0, dp(8))
            })
        }
        for (section in HistoryGrouping.sections(hits)) {
            historyList.addView(TextView(a).apply {
                text = section.title; textSize = 13f; typeface = Typeface.DEFAULT_BOLD
                setTextColor(accent); setPadding(0, dp(14), 0, dp(2))
                contentDescription = "historyDay:${section.title}"
            })
            for (r in section.records.take(HISTORY_DAY_LIMIT)) historyList.addView(historyRow(r.time, r.cleaned, r.durationSec))
        }
        clearHistory.visibility = if (all.isEmpty()) View.GONE else View.VISIBLE
        clearHistory.setTextColor(accent)
        if (::retentionRow.isInitialized) {
            retentionRow.text = a.getString(R.string.history_retention_row, a.getString(retentionLabel(HistoryRetentionSetting.setting(a))))
        }
    }

    /** 一筆歷史：點一下複製；往左滑超過門檻刪除（滑不滿就彈回來，不誤刪）。 */
    private fun historyRow(time: Long, cleaned: String, durationSec: Int = 0): View {
        // 刪掉之後這一次觸控的 performClick 還是會送到本來被移除的 view：那一次不能再複製。
        var deleted = false
        val row = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL; setPadding(0, dp(8), 0, dp(8))
            contentDescription = "history:$cleaned"
        }
        row.addView(TextView(a).apply { text = cleaned; textSize = 16f })
        row.addView(TextView(a).apply {
            // 舊紀錄沒有時長 → 不顯示秒數，不要假裝是 0 秒。
            val ago = DateUtils.getRelativeTimeSpanString(time, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
            text = if (durationSec > 0) "$ago　${a.getString(R.string.history_duration, durationSec)}" else "$ago"
            textSize = 12f; setTextColor(0xFF8A8A8A.toInt())
        })
        row.setOnClickListener { if (!deleted) copyHistory(cleaned) }
        // 左滑刪除：跟著手指走，滑不滿 [SWIPE_DELETE_RATIO] 就彈回原位（同 iOS swipeActions 的動作閾值）。
        // downX／dragging 要活在 listener 外面：以前宣告在 lambda 裡，每個事件都歸零，dx 永遠是正的，
        // 左滑刪除從來不會觸發（review 抓到）。用 rawX：列本身跟著手指平移，event.x 會跟著變。
        var downX = 0f
        var dragging = false
        val slop = android.view.ViewConfiguration.get(a).scaledTouchSlop
        row.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; dragging = false; v.translationX = 0f
                    false                                   // 還沒拖：點一下照常交給 OnClickListener（複製）
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    if (!dragging && dx < -slop) {
                        dragging = true
                        // 開始拖了：不讓外層 ScrollView 搶，並取消這一下的「點擊」（不然放開會去複製）。
                        v.parent?.requestDisallowInterceptTouchEvent(true)
                        MotionEvent.obtain(event).also { it.action = MotionEvent.ACTION_CANCEL; v.onTouchEvent(it); it.recycle() }
                    }
                    if (dragging && v.width > 0) v.translationX = dx.coerceIn(-v.width.toFloat(), 0f)
                    dragging
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragging) return@setOnTouchListener false
                    dragging = false
                    if (v.width > 0 && v.translationX <= -v.width * SWIPE_DELETE_RATIO) {
                        deleted = true
                        HistoryStore.remove(a, time)
                        Toast.makeText(a, a.getString(R.string.history_deleted), Toast.LENGTH_SHORT).show()
                        refreshHistory()
                    } else {
                        v.animate().translationX(0f).setDuration(120).start()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    dragging = false
                    v.animate().translationX(0f).setDuration(120).start()
                    false
                }
                else -> false
            }
        }
        return row
    }

    private fun copyHistory(cleaned: String) {
        (a.getSystemService(Activity.CLIPBOARD_SERVICE) as ClipboardManager)
            .setPrimaryClip(ClipData.newPlainText("UTUVO Type", cleaned))
        Toast.makeText(a, a.getString(R.string.history_copied), Toast.LENGTH_SHORT).show()
    }

    // ── 打字手感（震動強度關／輕／中／強＋按鍵聲音，同 iOS KeyFeedbackScreen）──

    fun buildFeel(col: LinearLayout) {
        header(col, R.string.feel_title)
        col.addView(TextView(a).apply { text = a.getString(R.string.feel_haptic); textSize = 16f })
        val group = RadioGroup(a).apply { orientation = RadioGroup.HORIZONTAL }
        val buttons = KeyFeedback.Strength.values().associateWith { s ->
            RadioButton(a).apply {
                id = View.generateViewId()
                text = a.getString(when (s) {
                    KeyFeedback.Strength.OFF -> R.string.feel_strength_off
                    KeyFeedback.Strength.LIGHT -> R.string.feel_strength_light
                    KeyFeedback.Strength.MEDIUM -> R.string.feel_strength_medium
                    KeyFeedback.Strength.STRONG -> R.string.feel_strength_strong
                })
                textSize = 14f
                contentDescription = "feelHaptic:${s.id}"
            }.also { group.addView(it) }
        }
        group.check(buttons.getValue(KeyFeedback.strength(a)).id)
        group.setOnCheckedChangeListener { _, id ->
            buttons.entries.firstOrNull { it.value.id == id }?.let { KeyFeedback.setStrength(a, it.key) }
        }
        col.addView(group)
        col.addView(Switch(a).apply {
            text = a.getString(R.string.feel_sound); textSize = 16f; contentDescription = "feelSound"
            isChecked = KeyFeedback.soundEnabled(a)
            setOnCheckedChangeListener { _, on -> KeyFeedback.setSoundEnabled(a, on) }
        })
        col.addView(TextView(a).apply { text = a.getString(R.string.feel_explain); textSize = 13f; setPadding(0, dp(2), 0, 0) })
        col.addView(Switch(a).apply {
            text = a.getString(R.string.quiet_mode_title); textSize = 16f; contentDescription = "quietMode"
            isChecked = QuietMode.isEnabled(a)
            setOnCheckedChangeListener { _, on -> QuietMode.setEnabled(a, on) }
        })
        col.addView(TextView(a).apply { text = a.getString(R.string.quiet_mode_explain); textSize = 13f; setPadding(0, dp(2), 0, 0) })
    }


    // ── 「繁」鍵盤輸入法（注音／拼音，同 iOS SettingsScreen）──

    private var hantGroup: RadioGroup? = null
    private var hantPinyinId = 0

    fun buildHantInput(col: LinearLayout) {
        header(col, R.string.hant_input_title)
        val group = RadioGroup(a).apply { orientation = RadioGroup.HORIZONTAL }
        val zhuyin = RadioButton(a).apply {
            id = View.generateViewId(); text = a.getString(R.string.hant_input_zhuyin)
            contentDescription = "hantInput:zhuyin"
        }
        val pinyin = RadioButton(a).apply {
            id = View.generateViewId(); text = a.getString(R.string.hant_input_pinyin)
            contentDescription = "hantInput:pinyin"
        }
        group.addView(zhuyin); group.addView(pinyin)
        hantGroup = group
        hantPinyinId = pinyin.id
        group.check(if (HantInput.usesPinyin(a)) pinyin.id else zhuyin.id)
        group.setOnCheckedChangeListener { _, id -> HantInput.setUsesPinyin(a, id == pinyin.id) }
        col.addView(group)
        col.addView(TextView(a).apply { text = a.getString(R.string.hant_input_explain); textSize = 13f })
        // 注音整句候選的 AI 上下文重排（0c，模型在手機上跑、不上網；關掉就永遠用引擎預設）。
        col.addView(Switch(a).apply {
            text = a.getString(R.string.zc_ai_title); textSize = 16f; contentDescription = "zhuyinAiRerank"
            isChecked = HantInput.aiRerank(a)
            setOnCheckedChangeListener { _, on -> HantInput.setAiRerank(a, on) }
        })
        col.addView(TextView(a).apply { text = a.getString(R.string.zc_ai_explain); textSize = 13f })
    }

    /** 鍵盤上按「拼／注」也會換輸入法：回到設定頁時把選擇同步回來。 */
    fun refreshHantInput() {
        val group = hantGroup ?: return
        group.check(if (HantInput.usesPinyin(a)) hantPinyinId else group.getChildAt(0).id)
    }

    // ── 語言：聽寫語言 ＋ 語言變體 ＋ 鍵盤翻譯弧（對齊 iOS DictationLanguage / TranslationLanguagesView）──

    private var dictationRow: TextView? = null
    private var variantRow: TextView? = null
    private var quickPickRow: LinearLayout? = null
    private var quickPickSource: TextView? = null
    private val langRows = mutableMapOf<String, TextView>()

    fun buildLanguages(col: LinearLayout) {
        header(col, R.string.lang_section_title)

        // 聽寫語言：與鍵盤右上徽章同一份設定，兩邊改都一樣。
        val dictation = TextView(a).apply {
            textSize = 16f
            setPadding(0, dp(12), 0, dp(6))
            contentDescription = "dictationLanguage"
        }
        col.addView(dictation)
        dictationRow = dictation
        dictation.setOnClickListener { pickDictationLanguage() }

        // 語言變體：影響提示詞與拼字習慣
        val variant = TextView(a).apply {
            textSize = 16f
            setPadding(0, 0, 0, dp(12))
            contentDescription = "dictationVariant"
            setOnClickListener { pickLanguageVariant() }
        }
        col.addView(variant)
        variantRow = variant

        col.addView(TextView(a).apply {
            text = a.getString(R.string.translate_langs_order); textSize = 14f
            typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(16), 0, dp(4))
        })
        quickPickRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        col.addView(quickPickRow)
        quickPickSource = TextView(a).apply { textSize = 13f; setPadding(0, dp(4), 0, 0) }
        col.addView(quickPickSource)
        col.addView(TextView(a).apply {
            text = a.getString(R.string.translate_langs_explain, Translation.MAX_QUICK_PICK); textSize = 13f
        })

        for (target in Translation.all) {
            val row = TextView(a).apply {
                textSize = 16f
                setPadding(0, dp(12), 0, dp(12))
                contentDescription = "translateLang:${target.code}"
                setOnClickListener { toggleTranslationLanguage(target) }
            }
            langRows[target.code] = row
            col.addView(row)
        }
        refreshLanguages()
    }

    private fun pickDictationLanguage() {
        val all = DictationLanguage.all
        val current = DictationLanguage.current(a)
        AlertDialog.Builder(a)
            .setTitle(R.string.key_dictation_language)
            .setSingleChoiceItems(all.map { a.getString(it.labelRes) }.toTypedArray(), all.indexOf(current)) { dialog, which ->
                DictationLanguage.set(a, all[which])
                dialog.dismiss()
                refreshLanguages()
                Toast.makeText(a, a.getString(R.string.hint_language_changed, a.getString(all[which].labelRes)), Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun pickLanguageVariant() {
        val language = DictationLanguage.current(a)
        val variants = language.variants
        if (variants.isEmpty()) return
        val current = DictationLanguage.currentVariant(a, language)
        AlertDialog.Builder(a)
            .setTitle(R.string.variant_title)
            .setSingleChoiceItems(variants.map { a.getString(it.labelRes) }.toTypedArray(), variants.indexOf(current)) { dialog, which ->
                DictationLanguage.setVariant(a, language, variants[which])
                dialog.dismiss()
                refreshLanguages()
                Toast.makeText(a, a.getString(R.string.hint_variant_changed, a.getString(variants[which].labelRes)), Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun toggleTranslationLanguage(target: Translation.Target) {
        Translation.setQuickPickCodes(a, Translation.toggled(target.code, Translation.quickPickCodes(a)))
        refreshLanguages()
    }

    /** 從主 app 回來（鍵盤那邊也可能改過）→ 重畫一次。 */
    fun refreshLanguages() {
        val language = DictationLanguage.current(a)
        dictationRow?.apply {
            text = a.getString(R.string.key_dictation_language) + "：" + a.getString(language.labelRes) + "  ▾"
            contentDescription = "dictationLanguage:" + language.code
        }
        val variants = language.variants
        if (variants.isNotEmpty()) {
            val variant = DictationLanguage.currentVariant(a, language)
            variantRow?.visibility = View.VISIBLE
            variantRow?.apply {
                text = a.getString(R.string.variant_title) + "：" + a.getString(variant.labelRes) + "  ▾"
                contentDescription = "dictationVariant:" + variant.id
            }
        } else {
            variantRow?.visibility = View.GONE
        }
        val source = Translation.sourceMlKit(language.code)
        val codes = Translation.quickPickCodes(a)
        quickPickSource?.text = a.getString(R.string.translate_langs_source, a.getString(language.labelRes))
        quickPickRow?.apply {
            removeAllViews()
            for (code in codes) {
                val target = Translation.all.firstOrNull { it.code == code } ?: continue
                addView(TextView(a).apply {
                    text = a.getString(target.labelRes); textSize = 13f
                    typeface = Typeface.DEFAULT_BOLD
                    setTextColor(if (code == source) 0xFF9A9A9A.toInt() else accent)
                    setPadding(dp(10), dp(6), dp(10), dp(6))
                    background = rounded(0x1FE8620C)
                }, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(8) })
            }
        }
        Translation.installedTargets(a) { installed ->
            for (target in Translation.all) {
                langRows[target.code]?.text = when {
                    target.code == source -> a.getString(target.labelRes) + "  ·  " + a.getString(R.string.translate_langs_same)
                    installed.contains(target.code) -> a.getString(target.labelRes) + "  ·  " + a.getString(R.string.translate_langs_status_on)
                    else -> a.getString(target.labelRes) + "  ·  " + a.getString(R.string.translate_langs_status_off)
                }
            }
        }
    }

    // ── 介面語言與外觀（對齊工單 android-C）──

    private var interfaceLocaleRow: TextView? = null
    private var appearanceRow: TextView? = null

    fun buildInterfaceAndAppearance(col: LinearLayout) {
        header(col, R.string.interface_section_title)

        val localeView = TextView(a).apply {
            textSize = 16f
            setPadding(0, dp(12), 0, dp(6))
            contentDescription = "interfaceLocale"
            setOnClickListener { pickInterfaceLocale() }
        }
        col.addView(localeView)
        interfaceLocaleRow = localeView

        val themeView = TextView(a).apply {
            textSize = 16f
            setPadding(0, 0, 0, dp(12))
            contentDescription = "appearanceTheme"
            setOnClickListener { pickAppearanceTheme() }
        }
        col.addView(themeView)
        appearanceRow = themeView

        refreshInterfaceAndAppearance()
    }

    private fun pickInterfaceLocale() {
        val all = AppTheme.InterfaceLocale.all
        val current = AppTheme.currentInterfaceLocale(a)
        AlertDialog.Builder(a)
            .setTitle(R.string.interface_language_title)
            .setSingleChoiceItems(all.map { a.getString(it.labelRes) }.toTypedArray(), all.indexOf(current)) { dialog, which ->
                AppTheme.setInterfaceLocale(a, all[which])
                dialog.dismiss()
                refreshInterfaceAndAppearance()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun pickAppearanceTheme() {
        val all = AppTheme.Theme.all
        val current = AppTheme.currentTheme(a)
        AlertDialog.Builder(a)
            .setTitle(R.string.appearance_title)
            .setSingleChoiceItems(all.map { a.getString(it.labelRes) }.toTypedArray(), all.indexOf(current)) { dialog, which ->
                AppTheme.setTheme(a, all[which])
                dialog.dismiss()
                refreshInterfaceAndAppearance()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    fun refreshInterfaceAndAppearance() {
        val currentLocale = AppTheme.currentInterfaceLocale(a)
        interfaceLocaleRow?.apply {
            text = a.getString(R.string.interface_language_title) + "：" + a.getString(currentLocale.labelRes) + "  ▾"
            contentDescription = "interfaceLocale:" + currentLocale.id
        }
        val currentTheme = AppTheme.currentTheme(a)
        appearanceRow?.apply {
            text = a.getString(R.string.appearance_title) + "：" + a.getString(currentTheme.labelRes) + "  ▾"
            contentDescription = "appearanceTheme:" + currentTheme.id
        }
    }


    private fun rounded(color: Int) = android.graphics.drawable.GradientDrawable().apply {
        shape = android.graphics.drawable.GradientDrawable.RECTANGLE
        cornerRadius = dp(14).toFloat(); setColor(color)
    }

    // ── 智慧整理（選配，使用者自備 key）──

    private lateinit var smartKeyStatus: TextView
    private lateinit var smartMessage: TextView
    private lateinit var smartLogView: LinearLayout
    private lateinit var smartClear: Button
    private lateinit var smartTest: Button
    private lateinit var smartSwitch: Switch

    fun buildSmart(col: LinearLayout) {
        header(col, R.string.smart_title)
        smartSwitch = Switch(a).apply {
            text = a.getString(R.string.smart_toggle); textSize = 16f; contentDescription = "smartToggle"
            isChecked = SmartCleanup.enabled(a)
            setOnCheckedChangeListener { _, on -> SmartCleanup.setEnabled(a, on) }
        }
        col.addView(smartSwitch)
        col.addView(TextView(a).apply { text = a.getString(R.string.smart_explain); textSize = 13f; setPadding(0, dp(2), 0, dp(10)) })
        buildOnDevice(col)
        col.addView(Switch(a).apply {
            text = a.getString(R.string.smart_cloud_speech_toggle); textSize = 15f
            contentDescription = "smartCloudSpeech"
            isChecked = SmartCleanup.cloudRecognitionPreferred(a)
            setOnCheckedChangeListener { _, on -> SmartCleanup.setCloudRecognitionPreferred(a, on) }
        })
        col.addView(TextView(a).apply {
            text = a.getString(R.string.smart_cloud_speech_explain); textSize = 12f
            setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(2), 0, dp(8))
        })
        // 自動條列（同 iOS／Mac，預設開）。
        col.addView(Switch(a).apply {
            text = a.getString(R.string.smart_auto_list); textSize = 15f
            contentDescription = "smartAutoList"
            isChecked = SmartCleanup.autoList(a)
            setOnCheckedChangeListener { _, on -> SmartCleanup.setAutoList(a, on) }
        })
        col.addView(TextView(a).apply {
            text = a.getString(R.string.smart_auto_list_explain); textSize = 12f
            setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(2), 0, dp(8))
        })
        // 雲端辨識：用戶自己的 key 送去辨識（跟上面那個「讓系統服務走網路」是兩件事，音訊的提供者不同）。
        val cloudAsrSwitch = Switch(a).apply {
            text = a.getString(R.string.smart_cloud_asr_toggle); textSize = 15f
            contentDescription = "smartCloudAsr"
            isChecked = CloudASR.enabled(a)
        }
        col.addView(cloudAsrSwitch)
        col.addView(TextView(a).apply {
            text = a.getString(R.string.smart_cloud_asr_explain); textSize = 12f
            setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(2), 0, dp(8))
        })
        val cloudAsrTest = Button(a).apply {
            text = a.getString(R.string.smart_cloud_asr_test); contentDescription = "smartCloudAsrTest"
        }
        col.addView(cloudAsrTest)
        var cloudTestRecorder: CloudRecorder? = null
        fun setCloudAsrReady() {
            val ready = CloudASR.route(a) != null   // 選 Claude 時用另存的 Groq／Gemini／百鍊 key
            cloudAsrSwitch.isEnabled = ready
            cloudAsrTest.isEnabled = ready
        }
        /** 停止測試錄音並送去辨識（第二次按、或超過 30 秒自動收尾都走這裡）。 */
        fun stopCloudTest() {
            val recorder = cloudTestRecorder ?: return
            cloudTestRecorder = null
            cloudAsrTest.text = a.getString(R.string.smart_cloud_asr_test)
            val samples = recorder.stop()
            val (p, key) = CloudASR.route(a) ?: return
            val hotwords = VocabularyPacks.cloudHints(a)
            cloudAsrTest.isEnabled = false
            smartMessage.setTextColor(0xFF8A8A8A.toInt()); smartMessage.text = a.getString(R.string.smart_cloud_asr_running)
            Thread {
                val started = System.currentTimeMillis()
                val text = runCatching {
                    CloudASR.transcribe(samples, "zh-TW", hotwords, p, key, log = CloudASR.defaultLog(a))
                }.getOrNull()
                val ms = (System.currentTimeMillis() - started).toInt()
                a.runOnUiThread {
                    cloudAsrTest.isEnabled = true
                    smartMessage.setTextColor(if (text.isNullOrBlank()) 0xFFD32F2F.toInt() else 0xFF2E7D32.toInt())
                    smartMessage.text = if (text.isNullOrBlank()) a.getString(R.string.smart_cloud_asr_failed)
                        else a.getString(R.string.smart_cloud_asr_ok, ms, text)
                }
            }.start()
        }
        cloudAsrSwitch.setOnCheckedChangeListener { _, on -> CloudASR.setEnabled(a, on) }
        cloudAsrTest.setOnClickListener {
            if (cloudTestRecorder != null) { stopCloudTest(); return@setOnClickListener }
            // 測試鈕就是開關的意思：按下時若還沒開就順便打開。
            if (!CloudASR.enabled(a)) { cloudAsrSwitch.isChecked = true; CloudASR.setEnabled(a, on = true) }
            val next = CloudRecorder()
            if (!next.start()) {
                smartMessage.setTextColor(0xFFD32F2F.toInt()); smartMessage.text = a.getString(R.string.smart_cloud_asr_no_mic)
                return@setOnClickListener
            }
            cloudTestRecorder = next
            cloudAsrTest.text = a.getString(R.string.smart_cloud_asr_recording)
            // 忘了再按一次也要自己收手：麥克風不能一直開著。
            android.os.Handler(a.mainLooper).postDelayed({ stopCloudTest() }, 30_000)
        }
        col.addView(Switch(a).apply {
            text = a.getString(R.string.smart_context_toggle); textSize = 15f
            contentDescription = "smartContext"
            isChecked = SmartCleanup.includeAppContext(a)
            setOnCheckedChangeListener { _, on -> SmartCleanup.setIncludeAppContext(a, on) }
        })
        col.addView(TextView(a).apply {
            text = a.getString(R.string.smart_context_explain); textSize = 12f
            setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(2), 0, dp(10))
        })
        col.addView(Button(a).apply {
            text = a.getString(R.string.smart_app_profiles_button)
            contentDescription = "smartAppToneProfiles"
            setOnClickListener { showAppToneProfiles() }
        })
        col.addView(TextView(a).apply {
            text = a.getString(R.string.smart_app_profiles_explain); textSize = 12f
            setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(2), 0, dp(10))
        })

        val providers = listOf(
            SmartCleanup.Provider.GROQ to R.string.smart_provider_groq,
            SmartCleanup.Provider.CLAUDE to R.string.smart_provider_claude,
            SmartCleanup.Provider.GEMINI to R.string.smart_provider_gemini,
            SmartCleanup.Provider.DASHSCOPE to R.string.smart_provider_dashscope,
            SmartCleanup.Provider.CUSTOM to R.string.smart_provider_custom)
        val group = RadioGroup(a)
        val ids = providers.associate { (p, res) ->
            val b = RadioButton(a).apply { id = View.generateViewId(); text = a.getString(res); contentDescription = "smartProvider:${p.id}" }
            group.addView(b)
            b.id to p
        }
        col.addView(group)

        val customBox = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        val endpoint = EditText(a).apply {
            isSingleLine = true; hint = a.getString(R.string.smart_custom_endpoint); setText(SmartCleanup.customEndpoint(a))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        val model = EditText(a).apply {
            isSingleLine = true; hint = a.getString(R.string.smart_custom_model); setText(SmartCleanup.customModel(a))
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        customBox.addView(endpoint); customBox.addView(model)
        col.addView(customBox)

        col.addView(TextView(a).apply { text = a.getString(R.string.smart_signup_title); textSize = 15f; typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(12), 0, dp(4)) })
        val steps = TextView(a).apply { textSize = 14f; setLineSpacing(0f, 1.2f) }
        col.addView(steps)
        val signup = Button(a).apply { text = a.getString(R.string.smart_open_signup); contentDescription = "smartSignup" }
        col.addView(signup)
        val privacy = TextView(a).apply { textSize = 12f; setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(2), 0, dp(8)) }
        col.addView(privacy)

        val field = EditText(a).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            isSingleLine = true; typeface = Typeface.DEFAULT
            contentDescription = "smartKeyField"; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        col.addView(field)
        val row = LinearLayout(a)
        val save = Button(a).apply { text = a.getString(R.string.cloud_save); contentDescription = "smartSave" }
        smartClear = Button(a).apply { text = a.getString(R.string.cloud_clear) }
        smartTest = Button(a).apply { text = a.getString(R.string.smart_test); contentDescription = "smartTest" }
        listOf(save, smartClear, smartTest).forEach { row.addView(it, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)) }
        col.addView(row)
        smartKeyStatus = TextView(a).apply { textSize = 13f }
        smartMessage = TextView(a).apply { textSize = 13f; contentDescription = "smartMessage" }
        col.addView(smartKeyStatus); col.addView(smartMessage)
        // 整理健康狀態（同 iOS SmartCleanupScreen）：成功／失敗次數、最後一次失敗的原因與服務、429 的額度建議。
        smartLogView = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; contentDescription = "smartLog" }
        col.addView(smartLogView)

        fun current() = SmartCleanup.provider(a)
        fun applyProvider() {
            val p = current()
            customBox.visibility = if (p == SmartCleanup.Provider.CUSTOM) View.VISIBLE else View.GONE
            steps.text = a.getString(when (p) {
                SmartCleanup.Provider.GEMINI -> R.string.smart_steps_gemini
                SmartCleanup.Provider.GROQ -> R.string.smart_steps_groq
                SmartCleanup.Provider.DASHSCOPE -> R.string.smart_steps_dashscope
                SmartCleanup.Provider.CLAUDE -> R.string.smart_steps_claude
                SmartCleanup.Provider.CUSTOM -> R.string.smart_steps_custom
            })
            privacy.text = a.getString(when (p) {
                SmartCleanup.Provider.GEMINI -> R.string.smart_privacy_gemini
                SmartCleanup.Provider.GROQ -> R.string.smart_privacy_groq
                SmartCleanup.Provider.DASHSCOPE -> R.string.smart_privacy_dashscope
                SmartCleanup.Provider.CLAUDE -> R.string.smart_privacy_claude
                SmartCleanup.Provider.CUSTOM -> R.string.smart_privacy_custom
            })
            signup.visibility = if (p.signupUrl == null) View.GONE else View.VISIBLE
            smartMessage.text = ""
            refreshSmartKey(field)
            setCloudAsrReady()
        }
        group.check(ids.entries.first { it.value == current() }.key)
        group.setOnCheckedChangeListener { _, id -> ids[id]?.let { SmartCleanup.setProvider(a, it); applyProvider() } }
        signup.setOnClickListener { current().signupUrl?.let { a.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) } }

        fun saveCustom() { if (current() == SmartCleanup.Provider.CUSTOM) SmartCleanup.setCustom(a, endpoint.text.toString(), model.text.toString()) }
        save.setOnClickListener {
            val v = field.text.toString().trim()
            if (v.isEmpty()) return@setOnClickListener
            saveCustom()
            SecretStore.save(a, v, current().secretField)
            field.setText("")
            SmartCleanup.setEnabled(a, true); smartSwitch.isChecked = true
            smartMessage.setTextColor(0xFF8A8A8A.toInt()); smartMessage.text = a.getString(R.string.cloud_saved)
            refreshSmartKey(field)
        }
        smartClear.setOnClickListener {
            SecretStore.delete(a, current().secretField)
            smartMessage.setTextColor(0xFF8A8A8A.toInt()); smartMessage.text = a.getString(R.string.cloud_cleared)
            refreshSmartKey(field)
        }
        smartTest.setOnClickListener {
            saveCustom()
            val p = current()
            val key = SmartCleanup.key(a, p).orEmpty()
            smartTest.isEnabled = false
            smartMessage.setTextColor(0xFF8A8A8A.toInt()); smartMessage.text = a.getString(R.string.smart_testing)
            Thread {
                val start = System.currentTimeMillis()
                val r = runCatching { SmartCleanup.run(a, a.getString(R.string.smart_sample), p, key, 8000) }
                val ms = (System.currentTimeMillis() - start).toInt()
                a.runOnUiThread {
                    smartTest.isEnabled = true
                    val e = r.exceptionOrNull()
                    smartMessage.setTextColor(if (e == null) 0xFF2E7D32.toInt() else 0xFFD32F2F.toInt())
                    smartMessage.text = when {
                        e == null -> a.getString(R.string.smart_test_ok, ms, r.getOrThrow())
                        e is CloudLlm.HttpError && (e.code == 401 || e.code == 403) -> a.getString(R.string.smart_test_auth, e.code)
                        e is CloudLlm.HttpError -> a.getString(R.string.smart_test_http, e.code)
                        e is java.net.SocketTimeoutException -> a.getString(R.string.smart_test_timeout)
                        e is SmartCleanup.Rejected -> a.getString(R.string.smart_test_rejected)
                        else -> a.getString(R.string.smart_test_failed, e.message ?: e.javaClass.simpleName)
                    }
                }
            }.start()
        }
        applyProvider()
        refreshSmartLog()   // 引擎標示第一次就要看得到（沒有整理紀錄時也顯示）
    }

    // ── 手機上整理（Gemma 4，選配下載；沒 key 時用）──

    private val onDevicePoll = android.os.Handler(android.os.Looper.getMainLooper())

    private fun buildOnDevice(col: LinearLayout) {
        col.addView(TextView(a).apply {
            text = a.getString(R.string.ondevice_title); textSize = 15f; typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, dp(2))
        })
        col.addView(TextView(a).apply {
            text = a.getString(R.string.ondevice_explain, OnDeviceModel.DOWNLOAD_MB, OnDeviceModel.TOTAL_GB); textSize = 12f
            setTextColor(0xFF8A8A8A.toInt()); setPadding(0, 0, 0, dp(6))
        })
        val status = TextView(a).apply { textSize = 13f; contentDescription = "onDeviceStatus" }
        col.addView(status)
        val row = LinearLayout(a)
        val action = Button(a).apply { contentDescription = "onDeviceAction" }
        val test = Button(a).apply { text = a.getString(R.string.ondevice_test); contentDescription = "onDeviceTest" }
        row.addView(action, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(test, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        col.addView(row)
        val message = TextView(a).apply { textSize = 13f; contentDescription = "onDeviceMessage"; setPadding(0, 0, 0, dp(10)) }
        col.addView(message)

        fun refresh() {
            onDevicePoll.removeCallbacksAndMessages(null)
            val state = OnDeviceModel.state(a)
            test.visibility = if (state == OnDeviceModel.State.Ready) View.VISIBLE else View.GONE
            action.visibility = if (state == OnDeviceModel.State.Unsupported || state == OnDeviceModel.State.Verifying) View.GONE else View.VISIBLE
            when (state) {
                OnDeviceModel.State.Unsupported -> status.text = a.getString(R.string.ondevice_status_unsupported)
                OnDeviceModel.State.Absent -> {
                    status.text = a.getString(R.string.ondevice_status_absent)
                    action.text = a.getString(R.string.ondevice_download, OnDeviceModel.DOWNLOAD_MB)
                }
                is OnDeviceModel.State.Failed -> {
                    status.text = when {
                        state.reason == "space" -> a.getString(R.string.ondevice_status_no_space, OnDeviceModel.TOTAL_GB)
                        state.reason == "checksum" -> a.getString(R.string.ondevice_status_checksum)
                        else -> a.getString(R.string.ondevice_status_failed, state.reason)
                    }
                    action.text = a.getString(R.string.ondevice_download, OnDeviceModel.DOWNLOAD_MB)
                }
                is OnDeviceModel.State.Downloading -> {
                    val pct = (state.bytes * 100 / state.total).toInt().coerceIn(0, 100)
                    status.text = if (state.paused) a.getString(R.string.ondevice_status_paused, pct)
                        else a.getString(R.string.ondevice_status_downloading, pct,
                            (state.bytes / 1_048_576L).toInt(), (state.total / 1_048_576L).toInt())
                    action.text = a.getString(R.string.ondevice_cancel)
                }
                OnDeviceModel.State.Verifying -> status.text = a.getString(R.string.ondevice_status_verifying)
                OnDeviceModel.State.Ready -> {
                    val error = OnDeviceLlm.lastPrepareError
                    status.text = when {
                        OnDeviceLlm.prepared(a) -> a.getString(if (SmartCleanup.usesOnDevice(a)) R.string.ondevice_status_ready
                            else R.string.ondevice_status_ready_cloud)
                        // 準備失敗不自動一直重試：講原因，按「測試」再試一次。
                        error is OnDeviceModel.NotEnoughSpace -> a.getString(R.string.ondevice_status_prepare_no_space,
                            (OnDeviceModel.CACHE_BYTES / 1_048_576L).toInt())
                        error != null -> a.getString(R.string.ondevice_status_prepare_failed, error.message ?: error.javaClass.simpleName)
                        else -> a.getString(R.string.ondevice_status_preparing)
                    }
                    action.text = a.getString(R.string.ondevice_delete)
                    // 第一次準備（GPU 編譯）在背景做；App 被收掉過就從這裡補。
                    if (!OnDeviceLlm.prepared(a) && error == null) OnDeviceLlm.warm(a)
                }
            }
            // 下載／檢查／準備中：設定頁開著就每秒更新進度；畫面關掉就停。
            val preparing = state == OnDeviceModel.State.Ready && !OnDeviceLlm.prepared(a) && OnDeviceLlm.lastPrepareError == null
            if (state is OnDeviceModel.State.Downloading || state == OnDeviceModel.State.Verifying || preparing) {
                onDevicePoll.postDelayed({ if (!a.isFinishing && !a.isDestroyed) refresh() }, 1000)
            }
        }
        action.setOnClickListener {
            when (OnDeviceModel.state(a)) {
                OnDeviceModel.State.Absent, is OnDeviceModel.State.Failed -> {
                    OnDeviceModel.startDownload(a)
                    // 下載就是要用：跟存 key 一樣順手打開智慧整理。
                    SmartCleanup.setEnabled(a, true); smartSwitch.isChecked = true
                }
                else -> OnDeviceModel.delete(a)
            }
            message.text = ""
            refresh()
        }
        test.setOnClickListener {
            test.isEnabled = false
            message.setTextColor(0xFF8A8A8A.toInt()); message.text = a.getString(R.string.ondevice_testing)
            Thread {
                val start = System.currentTimeMillis()
                val r = runCatching { SmartCleanup.runOnDevice(a, a.getString(R.string.smart_sample), 180_000L) }
                val ms = (System.currentTimeMillis() - start).toInt()
                a.runOnUiThread {
                    test.isEnabled = true
                    val e = r.exceptionOrNull()
                    if (e == null) OnDeviceLlm.lastPrepareError = null
                    refresh()
                    message.setTextColor(if (e == null) 0xFF2E7D32.toInt() else 0xFFD32F2F.toInt())
                    message.text = when {
                        e == null -> a.getString(R.string.ondevice_test_ok, ms, OnDeviceLlm.backend.uppercase(), r.getOrThrow())
                        e is SmartCleanup.Rejected -> a.getString(R.string.smart_test_rejected)
                        e is java.net.SocketTimeoutException -> a.getString(R.string.smart_test_timeout)
                        e is OnDeviceModel.NotEnoughSpace -> a.getString(R.string.ondevice_status_no_space, OnDeviceModel.TOTAL_GB)
                        else -> a.getString(R.string.smart_test_failed, e.message ?: e.javaClass.simpleName)
                    }
                }
            }.start()
        }
        refresh()
    }

    private fun showAppToneProfiles() {
        val profiles = SmartCleanup.appToneProfiles(a)
        if (profiles.isEmpty()) {
            AlertDialog.Builder(a)
                .setTitle(R.string.smart_app_profiles_button)
                .setMessage(R.string.smart_app_profile_empty)
                .setPositiveButton(android.R.string.ok, null)
                .show()
            return
        }
        val labels = profiles.map { profile ->
            if (profile.styleHint.isBlank()) profile.appName
            else a.getString(R.string.smart_app_profile_customized, profile.appName)
        }.toTypedArray()
        AlertDialog.Builder(a)
            .setTitle(R.string.smart_app_profile_title)
            .setItems(labels) { _, index -> editAppToneProfile(profiles[index]) }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun editAppToneProfile(profile: SmartCleanup.AppToneProfile) {
        val input = EditText(a).apply {
            minLines = 3
            maxLines = 6
            gravity = Gravity.TOP or Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            hint = a.getString(R.string.smart_app_profile_hint)
            setText(profile.styleHint)
            contentDescription = "smartAppTone:${profile.packageName}"
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        AlertDialog.Builder(a)
            .setTitle(profile.appName)
            .setMessage(R.string.smart_app_profile_privacy)
            .setView(input)
            .setNeutralButton(R.string.smart_app_profile_clear) { _, _ ->
                SmartCleanup.setAppTone(a, profile.packageName, "")
                Toast.makeText(a, R.string.smart_app_profile_cleared, Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                SmartCleanup.setAppTone(a, profile.packageName, input.text.toString())
                Toast.makeText(a, R.string.smart_app_profile_saved, Toast.LENGTH_SHORT).show()
            }
            .show()
    }

    private fun refreshSmartKey(field: EditText) {
        val has = SecretStore.hasKey(a, SmartCleanup.provider(a).secretField)
        smartKeyStatus.text = a.getString(if (has) R.string.cloud_has_key else R.string.cloud_no_key)
        field.hint = if (has) a.getString(R.string.cloud_replace_hint) else "API key"
        smartClear.isEnabled = has
        smartTest.isEnabled = has
        refreshSmartLog()
    }

    /**
     * 改寫／翻譯現在走哪一家（iPhone badge：裝置端／雲端（你的 key）／不可用）。
     * 沒有任何 key 就只走 ML Kit 裝置端翻譯，改寫則不可用——寫出來免得使用者以為已經能改寫。
     */
    private fun editEngineLabel(): String {
        val route = SmartCleanup.completionRoute(a) ?: return a.getString(R.string.assistant_provider_none)
        val name = SmartLog.providerNameRes(route.first.id)?.let { a.getString(it) } ?: route.first.id
        return "${a.getString(R.string.assistant_badge_cloud)}・$name"
    }

    /** 整理健康狀態（同 iOS SmartCleanupScreen 的彙總）：引擎標示一定顯示，彙總只在真的有紀錄時顯示。 */
    private fun refreshSmartLog() {
        if (!::smartLogView.isInitialized) return
        smartLogView.removeAllViews()
        fun line(text: String, color: Int) = TextView(a).apply {
            this.text = text; textSize = 12f; setTextColor(color)
        }
        // 「說出要怎麼改」與翻譯走的是 completionRoute（可能不是整理那一家的 key），要講清楚現在是誰。
        smartLogView.addView(line(a.getString(R.string.assistant_engine_label, editEngineLabel()), 0xFF8A8A8A.toInt()))
        val entries = SmartLog.load(a)
        if (entries.isEmpty()) return
        val summary = SmartLog.summary(entries)
        smartLogView.addView(line(a.getString(R.string.smart_log_summary, summary.ok, summary.failed), 0xFF8A8A8A.toInt()))
        val provider = summary.lastFailureProvider
        val reason = summary.lastFailure
        if (provider != null && reason != null) {
            val name = SmartLog.providerNameRes(provider)?.let { a.getString(it) } ?: provider
            val color = if (summary.failed > summary.ok) 0xFFD32F2F.toInt() else 0xFF8A8A8A.toInt()
            smartLogView.addView(line(a.getString(R.string.smart_log_last_failure, a.getString(reason), name), color))
            if (summary.lastFailureOutcome == "http(429)") {
                smartLogView.addView(line(a.getString(R.string.smart_log_quota_hint), 0xFF8A8A8A.toInt()))
            }
        }
    }

    // ── 詞庫包與匯入 ──

    fun buildPacks(col: LinearLayout) {
        header(col, R.string.pack_title)
        // 2026-09-20 runtime 票：先讀 catalog metadata（失敗時 catalog 為空，仍可用內建三包）。
        VocabularyPacks.loadCatalog(a)
        // 內建三包
        for (pack in VocabularyPacks.all) {
            col.addView(Switch(a).apply {
                text = "${a.getString(pack.nameRes)}\n${pack.summary}"; textSize = 15f
                contentDescription = "pack:${pack.id}"; setPadding(0, dp(4), 0, dp(4))
                isChecked = VocabularyPacks.isEnabled(a, pack)
                setOnCheckedChangeListener { _, on -> VocabularyPacks.setEnabled(a, pack, on) }
            })
        }
        // catalog 六包：預設全關；點名字展開明細（搜尋／來源／授權／版本）
        val catalog = VocabularyPacks.catalog().packs
        if (catalog.isNotEmpty()) {
            col.addView(TextView(a).apply {
                text = a.getString(R.string.pack_catalog_header); textSize = 17f
                typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(16), 0, dp(4))
            })
            for (pack in catalog) {
                val row = LinearLayout(a).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(0, dp(4), 0, dp(4)) }
                val sw = Switch(a).apply {
                    // UI-FINDINGS：列上要顯示實際詞數（metadata termCount），使用者才知道這包多大。
                    val displayName = VocabularyPacks.catalogDisplayName(a, pack.id, pack.name)
                    val displaySummary = VocabularyPacks.catalogDisplaySummary(a, pack.id, pack.summary)
                    text = "$displayName\n${a.getString(R.string.pack_row_count, pack.termCount)}\n$displaySummary"
                    textSize = 15f
                    contentDescription = "pack:${pack.id}"
                    isChecked = VocabularyPacks.enabledCatalogPacks(a).any { it.id == pack.id }
                    setOnCheckedChangeListener { _, on -> VocabularyPacks.setCatalogEnabled(a, pack, on) }
                }
                row.addView(sw, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                val details = Button(a).apply {
                    text = a.getString(R.string.pack_details); textSize = 13f
                    contentDescription = "packDetails:${pack.id}"
                    setOnClickListener { showPackDetails(pack) }
                }
                row.addView(details)
                col.addView(row)
            }
        }
        col.addView(TextView(a).apply { text = a.getString(R.string.pack_explain); textSize = 13f; setPadding(0, dp(2), 0, dp(10)) })
        val box = EditText(a).apply {
            hint = a.getString(R.string.pack_import_hint); minLines = 4; gravity = Gravity.TOP; typeface = Typeface.MONOSPACE
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            contentDescription = "vocabImport"; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        col.addView(box)
        val message = TextView(a).apply { textSize = 13f }
        col.addView(Button(a).apply {
            text = a.getString(R.string.pack_import); contentDescription = "vocabImportButton"
            setOnClickListener {
                val n = VocabularyPacks.importLines(a, box.text.toString())
                message.text = a.getString(R.string.pack_imported, n)
                if (n > 0) { box.setText(""); refreshDictionary() }
            }
        })
        col.addView(message)
        col.addView(TextView(a).apply { text = a.getString(R.string.pack_import_explain); textSize = 13f })
    }

    /** 明細對話框：唯一詞數、摘要、來源、授權、版本、搜尋（結果上限 100）。
     *  UI-FINDINGS：整包內容（含來源授權區）都放進同一個 ScrollView，鍵盤收起後捲得到底；
     *  搜尋用 packWithTermsLoaded——不管開／關都載【這一包】完整詞表，不隱式啟用、也不掃其他包。 */
    private fun showPackDetails(pack: com.utuvo.type.VocabularyCatalog.Pack) {
        val displayName = VocabularyPacks.catalogDisplayName(a, pack.id, pack.name)
        val displaySummary = VocabularyPacks.catalogDisplaySummary(a, pack.id, pack.summary)
        val scroll = ScrollView(a).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(420))
        }
        val container = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(16), dp(20), dp(16))
        }
        scroll.addView(container)
        container.addView(TextView(a).apply {
            text = a.getString(R.string.pack_details_count, pack.termCount); textSize = 14f
        })
        if (displaySummary.isNotEmpty()) {
            container.addView(TextView(a).apply { text = displaySummary; textSize = 13f; setPadding(0, dp(4), 0, dp(8)) })
        }
        val queryField = EditText(a).apply {
            hint = a.getString(R.string.pack_search_hint); isSingleLine = true
            contentDescription = "packSearch:${pack.id}"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        container.addView(queryField)
        val resultHeader = TextView(a).apply { textSize = 12f; setTextColor(0xFF8A8A8A.toInt()); setPadding(0, dp(4), 0, dp(4)) }
        container.addView(resultHeader)
        val list = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }

        fun appendSourceSection() {
            // UI-FINDINGS：source／license／attribution／version 必須真的顯示在明細（來源授權是出貨許可）。
            if (pack.sourceName.isNotEmpty()) {
                container.addView(TextView(a).apply {
                    text = a.getString(R.string.pack_source_label); textSize = 13f; setPadding(0, dp(12), 0, dp(2))
                })
                val sourceView = TextView(a).apply {
                    text = if (pack.sourceURL.isNotEmpty()) pack.sourceURL else pack.sourceName
                    textSize = 13f; setPadding(0, dp(2), 0, dp(2))
                    contentDescription = "packSource:${pack.id}"
                }
                if (pack.sourceURL.isNotEmpty()) {
                    sourceView.text = Html.fromHtml(
                        "<a href=\"${pack.sourceURL}\">${pack.sourceName}</a>", Html.FROM_HTML_MODE_LEGACY)
                    sourceView.movementMethod = LinkMovementMethod.getInstance()
                }
                container.addView(sourceView)
            }
            if (pack.licenseName.isNotEmpty()) {
                container.addView(TextView(a).apply {
                    text = a.getString(R.string.pack_license_label); textSize = 13f; setPadding(0, dp(6), 0, dp(2))
                })
                val licenseView = TextView(a).apply {
                    text = if (pack.licenseURL.isNotEmpty()) pack.licenseURL else pack.licenseName
                    textSize = 13f; setPadding(0, dp(2), 0, dp(2))
                    contentDescription = "packLicense:${pack.id}"
                }
                if (pack.licenseURL.isNotEmpty()) {
                    licenseView.text = Html.fromHtml(
                        "<a href=\"${pack.licenseURL}\">${pack.licenseName}</a>", Html.FROM_HTML_MODE_LEGACY)
                    licenseView.movementMethod = LinkMovementMethod.getInstance()
                }
                container.addView(licenseView)
            }
            if (pack.attribution.isNotEmpty()) {
                container.addView(TextView(a).apply {
                    text = pack.attribution; textSize = 12f; setPadding(0, dp(6), 0, dp(2))
                })
            }
            if (pack.version.isNotEmpty()) {
                container.addView(TextView(a).apply {
                    text = a.getString(R.string.pack_version_label, pack.version); textSize = 12f; setPadding(0, dp(4), 0, dp(2))
                })
            }
        }
        appendSourceSection()
        container.addView(list)

        fun renderResults() {
            list.removeAllViews()
            val q = queryField.text.toString().trim()
            if (q.isEmpty()) {
                resultHeader.text = ""
                return
            }
            // UI-FINDINGS：與 enabled 狀態無關——明細頁一律把這一包 terms 載起來再搜。
            val loaded = VocabularyPacks.packWithTermsLoaded(a, pack.id) ?: pack
            val matches = VocabularySelector.search(q, loaded, limit = 100)
            resultHeader.text = a.getString(R.string.pack_search_count, matches.size, loaded.termCount)
            for (t in matches) {
                list.addView(TextView(a).apply {
                    text = t; textSize = 14f
                    typeface = Typeface.MONOSPACE
                    setPadding(0, dp(2), 0, dp(2))
                    contentDescription = "packTerm:${pack.id}:$t"
                })
            }
            if (matches.isEmpty()) {
                list.addView(TextView(a).apply { text = a.getString(R.string.pack_search_empty); textSize = 13f })
            }
        }
        queryField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { renderResults() }
            override fun afterTextChanged(s: Editable?) {}
        })
        AlertDialog.Builder(a)
            .setTitle(displayName)
            .setView(scroll)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }
}
