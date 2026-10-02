package com.utuvo.type

import android.content.Context
import android.view.inputmethod.EditorInfo
import com.utuvo.type.core.DictionarySync
import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.NormalizerOptions
import com.utuvo.type.core.TaiwanPhrases
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 個人字典（同 iOS DictionaryStore）：兩種用法共用同一份資料。
 * ・新增詞彙：A→A，只當辨識提示（EXTRA_BIASING_STRINGS），比較容易聽對。
 * ・替換：聽到 A 一律改成 B（Normalizer 的 dictionary 階段）。
 * Android 鍵盤跟主 app 是同一個 app，直接共用 SharedPreferences，不需要 iOS 的 App Group。
 */
object DictionaryStore {
    private const val PREF = "dictionary"
    private const val FIELD = "entries"
    /** 同步用的完整紀錄（每筆時間＋刪除墓碑，見 core DictionarySync）；FIELD 是它的有效部分。 */
    private const val SYNC = "sync"

    private fun now() = System.currentTimeMillis() / 1000.0
    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    fun entries(c: Context): Map<String, String> {
        val raw = prefs(c).getString(FIELD, null) ?: return emptyMap()
        return runCatching { JSONObject(raw).let { o -> o.keys().asSequence().associateWith { o.getString(it) } } }.getOrDefault(emptyMap())
    }

    /** 同步紀錄；有人直接改過 entries（舊版、測試）就先對齊。 */
    @Synchronized
    fun syncState(c: Context): DictionarySync {
        val stored = prefs(c).getString(SYNC, null)?.let { runCatching { DictionarySync.decode(it) }.getOrNull() }
        val plain = entries(c)
        val state = stored?.reconcile(plain, now()) ?: DictionarySync.fromPlain(plain)
        if (state != stored) write(c, state)
        return state
    }

    private fun write(c: Context, state: DictionarySync) {
        prefs(c).edit().putString(SYNC, state.encode()).putString(FIELD, JSONObject(state.live).toString()).apply()
    }

    @Synchronized
    private fun update(c: Context, change: (DictionarySync) -> DictionarySync) = write(c, change(syncState(c)))

    /** output 空白＝詞彙（存成 A→A）。 */
    fun add(c: Context, source: String, output: String) {
        if (source.isBlank()) return
        update(c) { it.set(source, output, now()) }
    }

    fun remove(c: Context, source: String) = update(c) { it.remove(source, now()) }

    /** 匯出檔（含時間與刪除紀錄，另一台匯入時最後改的贏）。 */
    fun export(c: Context): String = syncState(c).pruned(now()).encode()

    /** 匯入：跟本機合併（最後改的贏）；回傳有幾個詞因此新增、修改或刪除。讀不懂的檔丟例外。 */
    fun import(c: Context, text: String): Int {
        val incoming = DictionarySync.decode(text)
        val before = entries(c)
        update(c) { it.merged(incoming) }
        val after = entries(c)
        return (before.keys + after.keys).count { before[it] != after[it] }
    }

    /** 詞彙排前、替換排後，各自照字母排（同 iOS）。 */
    fun sorted(c: Context): List<Pair<String, String>> =
        entries(c).toList().sortedWith(compareBy({ it.first != it.second }, { it.first }))

    /** 給辨識器的提示：詞彙本身＋替換後的寫法（使用者要的字）。 */
    fun biasing(c: Context): ArrayList<String> = ArrayList(entries(c).values.distinct())
}

/** 聽寫歷史（同 iOS HistoryStore 語意）：新的在前、最多 500 筆，存 app 私有檔。 */
object HistoryStore {
    const val MAX = 500

    data class Record(val time: Long, val raw: String, val cleaned: String)

    private fun file(c: Context) = File(c.filesDir, "history.json")

    fun load(c: Context): List<Record> = runCatching {
        val a = JSONArray(file(c).readText())
        (0 until a.length()).map { a.getJSONObject(it).let { o -> Record(o.getLong("time"), o.getString("raw"), o.getString("cleaned")) } }
    }.getOrDefault(emptyList())

    @Synchronized
    fun append(c: Context, raw: String, cleaned: String) {
        val all = (listOf(Record(System.currentTimeMillis(), raw, cleaned)) + load(c)).take(MAX)
        save(c, all)
    }

    @Synchronized
    fun remove(c: Context, time: Long) = save(c, load(c).filterNot { it.time == time })

    fun clear(c: Context) { file(c).delete() }

    /** 原樣寫回（含時間）；測試還原使用者紀錄用。 */
    @Synchronized
    fun restore(c: Context, records: List<Record>) = save(c, records.take(MAX))

    private fun save(c: Context, records: List<Record>) {
        val a = JSONArray()
        records.forEach { a.put(JSONObject().put("time", it.time).put("raw", it.raw).put("cleaned", it.cleaned)) }
        val tmp = File(c.filesDir, "history.json.tmp")
        tmp.writeText(a.toString())
        tmp.renameTo(file(c))
    }
}

/**
 * 鍵盤辨識完的整理（同 iOS TranscriptGuard）：逐字硬轉的繁體修正＋台灣站名 → 台灣用語 →
 * 個人字典替換 → 贅詞／重複／自我修正／數字／標點（後三段由 Normalizer 決定）。
 * 系統語音與雲端辨識的回來文字都走這裡。
 */
object Dictation {
    fun clean(c: Context, raw: String): String {
        ChineseFixers.configure(c)
        val fixed = ChineseFixers.fix(raw)
        return Normalizer(NormalizerOptions(
            dictionary = DictionaryStore.entries(c).filter { it.key != it.value },
            latinTerms = VocabularyPacks.latinTermsForFixer(c),
        )).normalize(TaiwanPhrases.apply(fixed)).cleaned
    }
}

/** 輸入框能不能放換行：文字類、而且標了多行才可以（單行框插換行可能直接觸發送出）。 */
object FieldShape {
    fun allowsLineBreaks(inputType: Int): Boolean =
        (inputType and android.text.InputType.TYPE_MASK_CLASS) == android.text.InputType.TYPE_CLASS_TEXT &&
            (inputType and (android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_IME_MULTI_LINE)) != 0

    /** Never attach surrounding text from a password field to an optional cloud cleanup request. */
    fun allowsContext(inputType: Int): Boolean {
        val fieldClass = inputType and android.text.InputType.TYPE_MASK_CLASS
        val variation = inputType and android.text.InputType.TYPE_MASK_VARIATION
        return when (fieldClass) {
            android.text.InputType.TYPE_CLASS_TEXT -> variation !in setOf(
                android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD,
                android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            )
            android.text.InputType.TYPE_CLASS_NUMBER -> variation != android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> true
        }
    }
}

/** Matches iOS tone handling while adding action-specific hints where Android exposes editor intent. */
internal object FieldToneHint {
    enum class Kind { DOCUMENT, CHAT, SEARCH }

    fun infer(info: EditorInfo?): Kind {
        val action = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
        return when (action) {
            EditorInfo.IME_ACTION_SEND -> Kind.CHAT
            EditorInfo.IME_ACTION_SEARCH, EditorInfo.IME_ACTION_GO -> Kind.SEARCH
            else -> Kind.DOCUMENT
        }
    }

    fun prompt(info: EditorInfo?): String? = when (infer(info)) {
        Kind.DOCUMENT -> null
        Kind.CHAT -> "短訊息欄位：保持自然、直接；單句末尾不加句號。"
        Kind.SEARCH -> "搜尋／前往欄位：保留精簡查詢，不加說明或回答。"
    }

    /**
     * 最後一句不加句號（2026-10-02 Micky：不要每句、最後都用句號，很 AI；同 iOS ToneHint.apply）。
     * 以前只有聊天框的單句訊息；現在所有欄位，分段長文（有換行）照原樣。
     */
    fun apply(text: String, kind: Kind): String = com.utuvo.type.core.SentenceMood.dropFinalPeriod(text)
}
