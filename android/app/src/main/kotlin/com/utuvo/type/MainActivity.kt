package com.utuvo.type

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * 主 app：聽寫／歷史／設定三個分頁（同 iPhone `UTUVOTypeIOSApp` 的 TabView）。
 * 聽寫頁＝試打區＋把鍵盤設定好的三個步驟＋使用說明；設定頁＝打字手感、「繁」輸入法、個人字典、
 * 智慧整理、詞庫包、雲端 key。
 */
class MainActivity : Activity() {
    private lateinit var micStatus: TextView
    private lateinit var enableStatus: TextView
    private lateinit var switchStatus: TextView
    private val sections = MainSections(this)
    private val pages = mutableMapOf<Int, View>()
    private lateinit var host: FrameLayout
    private fun matchParent() =
        FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)

    private companion object { val ACCENT = 0xFFE8620C.toInt() }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)   // 大標題自己畫，不要系統標題列
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        host = FrameLayout(this)
        root.addView(host, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(tabBar())
        // Android 15 起強制延伸到螢幕邊緣：自己讓出狀態列／導覽列的高度，標題才不會被蓋住。
        root.setOnApplyWindowInsetsListener { v, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        setContentView(root)
        show(0)
    }

    private lateinit var tabButtons: List<Button>

    private fun tabBar(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(0xFFF2F2F2.toInt())
            setPadding(0, dp(4), 0, dp(4))
        }
        tabButtons = listOf(
            R.string.tab_dictate to 0, R.string.tab_history to 1, R.string.tab_settings to 2
        ).map { (res, index) ->
            Button(this).apply {
                text = getString(res)
                contentDescription = "tab:$index"
                setOnClickListener { show(index) }
            }.also { bar.addView(it, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)) }
        }
        return bar
    }

    /** 切分頁：第一次進來才把那頁組出來（設定頁最重，不在啟動時組）。 */
    private fun show(index: Int) {
        val page = pages.getOrPut(index) {
            when (index) {
                1 -> buildHistoryPage()
                2 -> buildSettingsPage()
                else -> buildDictatePage()
            }
        }
        if (page.parent !== host) host.addView(page, matchParent())
        page.visibility = View.VISIBLE
        pages.forEach { (i, view) -> if (i != index) view.visibility = View.GONE }
        tabButtons.forEachIndexed { i, b ->
            b.isSelected = i == index
            b.setTextColor(if (i == index) ACCENT else 0xFF444444.toInt())
            b.setTypeface(if (i == index) Typeface.DEFAULT_BOLD else Typeface.DEFAULT)
        }
    }

    /** 一頁＝捲動容器裡的一條直欄。 */
    private fun page(build: (LinearLayout) -> Unit): View {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(20), dp(24), dp(24))
        }
        build(col)
        return ScrollView(this).apply { addView(col) }
    }

    private fun title(): LinearLayout {
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(TextView(this).apply {
            text = getString(R.string.app_name); textSize = 30f; typeface = Typeface.DEFAULT_BOLD
            val icon = getDrawable(R.mipmap.ic_launcher)?.apply { setBounds(0, 0, dp(56), dp(56)) }
            setCompoundDrawables(icon, null, null, null); compoundDrawablePadding = dp(14); gravity = Gravity.CENTER_VERTICAL
        })
        col.addView(TextView(this).apply { text = getString(R.string.tagline); textSize = 16f; setPadding(0, dp(6), 0, dp(24)) })
        return col
    }

    // ── 聽寫頁：設定鍵盤的三步驟＋試打框＋使用說明（本機高準確辨識不在本票）──

    private fun buildDictatePage(): View = page { col ->
        col.addView(title())
        fun step(title: Int, button: Int, onClick: () -> Unit): TextView {
            col.addView(TextView(this).apply { text = getString(title); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(12), 0, dp(4)) })
            val status = TextView(this).apply { textSize = 14f }
            col.addView(status)
            col.addView(Button(this).apply { text = getString(button); setOnClickListener { onClick() } })
            return status
        }
        micStatus = step(R.string.step_mic, R.string.btn_mic) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
        enableStatus = step(R.string.step_enable, R.string.btn_enable) {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        switchStatus = step(R.string.step_switch, R.string.btn_switch) {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
        }
        col.addView(TextView(this).apply { text = getString(R.string.try_here); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(24), 0, dp(6)) })
        col.addView(EditText(this).apply { hint = getString(R.string.try_hint); minLines = 3; gravity = Gravity.TOP; contentDescription = "tryField" })
        UsageGuide(this).build(col)
    }

    // ── 歷史頁 ──

    private fun buildHistoryPage(): View = page { col ->
        col.addView(title())
        sections.buildHistory(col)
    }

    // ── 設定頁 ──

    private fun buildSettingsPage(): View = page { col ->
        col.addView(title())
        sections.buildFeel(col)
        sections.buildHantInput(col)
        sections.buildLanguages(col)
        sections.buildDictionary(col)
        sections.buildSmart(col)
        sections.buildPacks(col)
        buildCloudKey(col)
    }

    // ── 雲端翻譯（選配，同 iOS）：key 只存 Keystore 加密密文、不回顯 ──

    private lateinit var keyStatus: TextView
    private lateinit var keyMessage: TextView
    private lateinit var clearKey: Button

    private fun buildCloudKey(col: LinearLayout) {
        col.addView(TextView(this).apply { text = getString(R.string.cloud_title); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; setPadding(0, dp(32), 0, dp(4)) })
        col.addView(TextView(this).apply { text = getString(R.string.cloud_explain); textSize = 14f; setPadding(0, 0, 0, dp(6)) })
        val field = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            isSingleLine = true
            typeface = Typeface.DEFAULT        // 密碼欄預設是等寬字，跟整頁不搭
            contentDescription = "cloudKeyField"
            importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO
        }
        col.addView(field)
        val row = LinearLayout(this)
        val save = Button(this).apply { text = getString(R.string.cloud_save) }
        clearKey = Button(this).apply { text = getString(R.string.cloud_clear) }
        row.addView(save, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(clearKey, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        col.addView(row)
        keyStatus = TextView(this).apply { textSize = 13f }
        keyMessage = TextView(this).apply { textSize = 13f }
        col.addView(keyStatus); col.addView(keyMessage)
        save.setOnClickListener {
            val v = field.text.toString().trim()
            if (v.isEmpty()) return@setOnClickListener
            SecretStore.save(this, v)
            field.setText("")
            keyMessage.text = getString(R.string.cloud_saved)
            refreshKey(field)
        }
        clearKey.setOnClickListener {
            SecretStore.delete(this)
            field.setText("")
            keyMessage.text = getString(R.string.cloud_cleared)
            refreshKey(field)
        }
        refreshKey(field)
    }

    private fun refreshKey(field: EditText) {
        val has = SecretStore.hasKey(this)
        keyStatus.text = getString(if (has) R.string.cloud_has_key else R.string.cloud_no_key)
        field.hint = getString(if (has) R.string.cloud_replace_hint else R.string.cloud_field_hint)
        clearKey.isEnabled = has
    }

    @Deprecated("系統檔案選擇器的結果（字典匯出／匯入）")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        sections.onActivityResult(requestCode, resultCode, data)
    }

    override fun onResume() {
        super.onResume()
        refresh()
        if (pages.containsKey(1)) sections.refreshHistory()
        sections.refreshHantInput()
        sections.refreshLanguages()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) { super.onWindowFocusChanged(hasFocus); if (hasFocus) refresh() }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults); refresh()
    }

    /** 鍵盤三步驟的狀態（在聽寫頁；還沒開過那一頁就沒有東西可更新）。 */
    private fun refresh() {
        if (!::micStatus.isInitialized) return
        val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        val ours = imm.enabledInputMethodList.any { it.packageName == packageName }
        val current = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD).orEmpty().startsWith("$packageName/")
        val mic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        fun mark(v: TextView, ok: Boolean) { v.text = getString(if (ok) R.string.status_done else R.string.status_todo) }
        mark(micStatus, mic); mark(enableStatus, ours); mark(switchStatus, current)
    }
}
