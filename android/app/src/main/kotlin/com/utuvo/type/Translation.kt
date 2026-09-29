package com.utuvo.type

import android.content.Context
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation as MlKit
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions

/**
 * 長按光球翻譯（對應 iOS 的 FastTranslator）：ML Kit 裝置端翻譯，模型第一次用時下載（每個語言約 30 MB），
 * 之後離線、文字不離開手機。
 *
 * 弧上要出現哪些語言由主 app 選（對應 iOS `TranslationLanguagesView` / `QuickPickStore`），
 * 存在鍵盤共用 prefs；**來源跟聽寫語言走**（iOS 也是：長按翻譯是把剛說的那句翻出去）。
 */
object Translation {
    data class Target(val code: String, val labelRes: Int, val shortRes: Int, val english: String)

    /** 主 app 選單列出的全部可選目標（順序＝選單順序）。 */
    val all = listOf(
        Target(TranslateLanguage.JAPANESE, R.string.lang_ja, R.string.lang_ja_short, "Japanese"),
        Target(TranslateLanguage.KOREAN, R.string.lang_ko, R.string.lang_ko_short, "Korean"),
        Target(TranslateLanguage.ENGLISH, R.string.lang_en, R.string.lang_en_short, "English"),
        Target(TranslateLanguage.CHINESE, R.string.lang_zh, R.string.lang_zh_short, "Chinese"),
        Target(TranslateLanguage.FRENCH, R.string.lang_fr, R.string.lang_fr_short, "French"),
        Target(TranslateLanguage.GERMAN, R.string.lang_de, R.string.lang_de_short, "German"),
    )

    /** 弧上最多幾個（同 iOS `QuickPickStore.maxCount`）。 */
    const val MAX_QUICK_PICK = 5

    /**
     * 預設弧。來源是中文（預設繁中）時照原來那組；iOS 預設弧上有「繁體中文」是給說外文的人用的，
     * 這裡來源已經是中文就換成德文。改聽寫語言成非中文時，預設弧要把中文放回來。
     */
    fun defaultFor(source: String): List<String> =
        if (source == TranslateLanguage.CHINESE)
            listOf(TranslateLanguage.JAPANESE, TranslateLanguage.KOREAN, TranslateLanguage.ENGLISH,
                TranslateLanguage.FRENCH, TranslateLanguage.GERMAN)
        else
            listOf(TranslateLanguage.CHINESE, TranslateLanguage.JAPANESE, TranslateLanguage.KOREAN,
                TranslateLanguage.FRENCH, TranslateLanguage.GERMAN)

    private const val PREFS = DictationLanguage.PREFS
    private const val KEY = "translateQuickPick"

    /** 清掉不認得的代碼與重複、最多 [MAX_QUICK_PICK] 個；清完是空的就回預設（長按不能沒有語言）。純函式。 */
    fun resolve(stored: List<String>?): List<String> {
        val known = all.map { it.code }.toSet()
        var seen = HashSet<String>()
        val cleaned = (stored ?: emptyList())
            .filter { known.contains(it) && seen.add(it) }
            .take(MAX_QUICK_PICK)
        return cleaned.ifEmpty { defaultFor(TranslateLanguage.CHINESE) }
    }

    /**
     * 在已選清單裡切換一個語言：已選就移除（最後一個不能移除），未選就加到最後（滿 5 個不加）。純函式。
     * 同 iOS `QuickPickStore.toggled`。
     */
    fun toggled(code: String, current: List<String>): List<String> {
        val i = current.indexOf(code)
        if (i >= 0) {
            if (current.size <= 1) return current
            return current.toMutableList().also { it.removeAt(i) }
        }
        if (current.size >= MAX_QUICK_PICK) return current
        return current + code
    }

    // 順序本身就是設定（弧上誰在左邊誰在右邊、中間那個是預選），所以用逗號接的字串存，
    // 不用 StringSet——Set 沒有順序，存進去順序就沒了。
    fun quickPickCodes(c: Context): List<String> =
        resolve(c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.split(','))

    fun setQuickPickCodes(c: Context, codes: List<String>) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, resolve(codes).joinToString(",")).apply()
    }

    /** 弧上實際要畫的目標：清掉跟來源同一個語言的（不能自己翻自己），全被清掉就回該來源的預設弧。 */
    fun quickPick(c: Context, source: String = sourceMlKit(DictationLanguage.current(c).code)): List<Target> {
        val picked = quickPickCodes(c).filter { it != source }
        val codes = picked.ifEmpty { defaultFor(source) }
        return codes.mapNotNull { code -> all.firstOrNull { it.code == code } }
    }

    /** 聽寫語言 → ML Kit 來源語言代碼。繁簡中文在 ML Kit 都是 `zh`。 */
    fun sourceMlKit(dictationCode: String): String = when (DictationLanguage.resolve(dictationCode)) {
        DictationLanguage.TRADITIONAL_CHINESE, DictationLanguage.SIMPLIFIED_CHINESE -> TranslateLanguage.CHINESE
        DictationLanguage.ENGLISH -> TranslateLanguage.ENGLISH
        DictationLanguage.JAPANESE -> TranslateLanguage.JAPANESE
        DictationLanguage.KOREAN -> TranslateLanguage.KOREAN
    }

    // 快取鍵要把來源也帶進去：換了聽寫語言就是另一個翻譯器。
    private val translators = HashMap<String, Translator>()

    private fun translator(source: String, target: String): Translator = translators.getOrPut("$source>$target") {
        MlKit.getClient(TranslatorOptions.Builder()
            .setSourceLanguage(source)
            .setTargetLanguage(target)
            .build())
    }

    /** 模型是否已經在手機上（決定提示要不要說「下載中」）。 */
    fun isReady(context: Context, target: String, done: (Boolean) -> Unit) {
        val source = sourceMlKit(DictationLanguage.current(context).code)
        val models = RemoteModelManager.getInstance()
        models.getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnSuccessListener { set ->
                done(set.any { it.language == target } && set.any { it.language == source })
            }
            .addOnFailureListener { done(false) }
    }

    /** 裝置上已下載翻譯模型的目標語言（主 app 選單上標「已下載」）。 */
    fun installedTargets(context: Context, done: (Set<String>) -> Unit) {
        // 來源跟聽寫語言走（以前寫死中文：英文聽寫時中文模型明明下載了，卻被當成來源扣掉——review 抓到）。
        val source = sourceMlKit(DictationLanguage.current(context).code)
        RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnSuccessListener { set -> done(set.mapNotNull { it.language }.toSet() - source) }
            .addOnFailureListener { done(emptySet()) }
    }

    /** 預先下載（長按選到語言、開始錄音時就叫，講話的幾秒內下載）。 */
    fun prepare(context: Context, target: String) {
        val source = sourceMlKit(DictationLanguage.current(context).code)
        if (source == target) return
        translator(source, target).downloadModelIfNeeded(DownloadConditions.Builder().build())
    }

    /**
     * 有使用者自己的雲端 key → 先走雲端（ML Kit 中文實測品質不夠：「明天下午要開會」→ Save tomorrow afternoon），
     * 雲端失敗（沒網路、key 錯）再退回裝置端。沒 key → 只用裝置端，絕不連雲端。
     *
     * 雲端走的是 [SmartCleanup.completionRoute]（目前選的服務，否則 Groq→Gemini→百鍊→自訂），
     * 不再只認百鍊那把 key——跟 iPhone 的 `OnDeviceAssistant.translate` 同一份選擇順序。
     */
    fun translate(context: Context, text: String, target: Target, done: (Result<String>) -> Unit) {
        val route = SmartCleanup.completionRoute(context)
        if (route == null) { translateOnDevice(context, text, target, done); return }
        val system = Assistant.translateSystem(context.getString(target.labelRes), target.english)
        SmartCleanup.completeAsync(context, system, text) { cloud ->
            cloud.onSuccess { done(Result.success(it)) }.onFailure {
                android.util.Log.w("UTUVOTranslate", "cloud translate failed (${it.message}), falling back to on-device")
                translateOnDevice(context, text, target, done)
            }
        }
    }

    /**
     * 這次翻譯會走哪一邊（提示與設定頁用）。回 null＝沒有雲端 key，只能用 ML Kit 裝置端。
     */
    fun cloudRoute(context: Context): Pair<SmartCleanup.Provider, String>? = SmartCleanup.completionRoute(context)

    /** 裝置端（ML Kit）。 */
    fun translateOnDevice(context: Context, text: String, target: Target, done: (Result<String>) -> Unit) {
        val source = sourceMlKit(DictationLanguage.current(context).code)
        if (source == target.code) { done(Result.failure(IllegalArgumentException("source equals target"))); return }
        val t = translator(source, target.code)
        t.downloadModelIfNeeded(DownloadConditions.Builder().build())
            .continueWithTask { dl -> if (!dl.isSuccessful) throw dl.exception ?: IllegalStateException("download failed") else t.translate(text) }
            .addOnSuccessListener { done(Result.success(it)) }
            .addOnFailureListener { done(Result.failure(it)) }
    }
}
