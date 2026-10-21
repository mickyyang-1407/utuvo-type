package com.utuvo.type

import android.app.Activity
import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import androidx.appcompat.app.AppCompatDelegate
import java.util.Locale

/**
 * 介面語言與外觀設定（對齊工單 android-C；android-D 修正語言切換）。
 *
 * 介面語言：跟隨系統／繁中／簡中／English
 * 外觀：跟隨系統／淺色／深色
 *
 * ⚠️ 介面語言為什麼不用 `AppCompatDelegate.setApplicationLocales`：
 * 那支 API 只對 `AppCompatActivity`／`AppCompatDelegate` 的子類有效，而 `MainActivity`
 * 繼承的是平台的 `Activity`，呼叫會靜靜地什麼都不做（2026-10-13 android-D 的審查發現，
 * 選了 English 畫面還是中文）。所以這裡改成平台自己的做法：
 * - 選語言時：Android 13+ 用 `LocaleManager.setApplicationLocales`（系統會重啟 activity，
 *   設定頁的「每個 App 的語言」也才看得到）；Android 12 以下自己 `recreate()`。
 * - 取資源時：每個元件（MainActivity、鍵盤 IME）在 `attachBaseContext` 用
 *   [wrapContext] 蓋掉 configuration，兩種版本都一定套得到。
 *
 * 選擇存在共用 prefs，所以不需要 AppCompat 的 autoStoreLocales／AppLocalesMetadataHolderService。
 * 鍵盤 IME 也讀同一份設定，英文介面下鍵盤字串一起變英文。
 */
object AppTheme {
    private const val PREFS = DictationLanguage.PREFS
    private const val KEY_THEME = "app_theme"
    private const val KEY_LOCALE = "app_interface_locale"

    enum class Theme(val id: String, val labelRes: Int, val nightMode: Int) {
        SYSTEM("system", R.string.option_follow_system, AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM),
        LIGHT("light", R.string.option_light, AppCompatDelegate.MODE_NIGHT_NO),
        DARK("dark", R.string.option_dark, AppCompatDelegate.MODE_NIGHT_YES);

        companion object {
            val all = values().toList()
            fun resolve(raw: String?): Theme =
                all.firstOrNull { it.id.equals(raw, ignoreCase = true) } ?: SYSTEM
        }
    }

    enum class InterfaceLocale(val id: String, val labelRes: Int, val languageTag: String?) {
        SYSTEM("system", R.string.option_follow_system, null),
        ZH_TW("zh-TW", R.string.option_zh_tw, "zh-TW"),
        ZH_CN("zh-CN", R.string.option_zh_cn, "zh-CN"),
        EN("en", R.string.option_en, "en");

        companion object {
            val all = values().toList()
            fun resolve(raw: String?): InterfaceLocale =
                all.firstOrNull { it.id.equals(raw, ignoreCase = true) } ?: SYSTEM
        }
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun currentTheme(c: Context): Theme =
        Theme.resolve(prefs(c).getString(KEY_THEME, null))

    fun setTheme(c: Context, theme: Theme) {
        prefs(c).edit().putString(KEY_THEME, theme.id).apply()
        AppCompatDelegate.setDefaultNightMode(theme.nightMode)
    }

    fun isDark(c: Context): Boolean = when (currentTheme(c)) {
        Theme.LIGHT -> false
        Theme.DARK -> true
        Theme.SYSTEM -> (c.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    }

    /**
     * 目前生效的介面語言。
     *
     * Android 13+ 以 [LocaleManager] 為準：使用者也可以直接在**系統的「應用程式語言」**
     * 改，那份不會寫進我們的 prefs，只看 prefs 會顯示舊的選擇（審查抓到）。
     * Android 12 以下沒有這支 API，才讀自己的偏好。
     */
    fun currentInterfaceLocale(c: Context): InterfaceLocale {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val manager = c.getSystemService(Context.LOCALE_SERVICE) as? LocaleManager
            if (manager != null) {
                val tags = manager.applicationLocales.toLanguageTags()
                if (tags.isBlank()) return InterfaceLocale.SYSTEM
                return InterfaceLocale.all.firstOrNull { it.languageTag.equals(tags, ignoreCase = true) }
                    ?: InterfaceLocale.SYSTEM
            }
        }
        return InterfaceLocale.resolve(prefs(c).getString(KEY_LOCALE, null))
    }

    /**
     * 把 base context 的資源語言蓋成使用者選的介面語言。
     * 「跟隨系統」時原樣返回，系統語言照走。
     *
     * 每個需要跟著 App 語言走的元件都要在 `attachBaseContext` 呼叫一次
     * （MainActivity、UTUVOImeService），這是平台 Activity／Service 都會用到的路徑。
     *
     * ⚠️ 為什麼是**空的** `Configuration()`，不是 `Configuration(base.resources.configuration)`：
     * 整份複製會把方向、深色、字體大小、螢幕寬度一起鎖死在呼叫的那一刻。輸入法是 Service，
     * 旋轉或切深色都不會重建，鍵盤就會用舊的寬度與深色畫面（android-D 審查）。
     * 只覆寫 locale、其餘欄位全部交給系統，與 AppCompatDelegate 的 per-app locale 做法相同。
     */
    fun wrapContext(base: Context): Context {
        val tag = currentInterfaceLocale(base).languageTag ?: return base
        val locale = Locale.forLanguageTag(tag)
        Locale.setDefault(locale)
        val cfg = Configuration()
        // `Configuration.updateFrom` 只在 fontScale > 0 時才套用；空物件預設是 1.0，
        // 那等於把使用者的字體大小鎖死在 1.0（實測：模擬器調到 1.3，鍵盤文字完全不變大）。
        // 給 0＝不覆寫，字體大小照系統。AppCompatDelegate 的 per-app locale 也是這樣處理。
        cfg.fontScale = 0f
        cfg.setLocales(LocaleList(locale))
        cfg.setLayoutDirection(locale)
        return base.createConfigurationContext(cfg)
    }

    fun setInterfaceLocale(c: Context, locale: InterfaceLocale) {
        prefs(c).edit().putString(KEY_LOCALE, locale.id).apply()
        val tags = locale.languageTag
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+：交給系統，activity 會被重啟；設定裡「每個 App 的語言」也看得到這份。
            val manager = c.getSystemService(Context.LOCALE_SERVICE) as? LocaleManager
            if (manager != null) {
                manager.applicationLocales = if (tags == null) LocaleList.getEmptyLocaleList()
                else LocaleList.forLanguageTags(tags)
                return
            }
        }
        // Android 12 以下沒有 per-app locale API，只能自己重啟 activity 讓 attachBaseContext 生效。
        (c as? Activity)?.recreate()
    }

    fun applySavedSettings(c: Context) {
        AppCompatDelegate.setDefaultNightMode(currentTheme(c).nightMode)
    }
}
