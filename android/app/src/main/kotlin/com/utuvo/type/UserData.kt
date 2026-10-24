package com.utuvo.type

import android.content.Context
import android.view.inputmethod.EditorInfo
import com.utuvo.type.core.DictionarySync
import com.utuvo.type.core.HistoryCodec
import com.utuvo.type.core.HistoryRetention
import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.NormalizerOptions
import com.utuvo.type.core.TaiwanPhrases
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
    fun add(c: Context, source: String, output: String, origin: DictionarySync.Source = DictionarySync.Source.MANUAL) {
        if (source.isBlank()) return
        update(c) { it.set(source, output, now(), origin) }
    }

    fun remove(c: Context, source: String) = update(c) { it.remove(source, now()) }

    /** 字典頁用：每個詞的來源（舊資料＝手動）。 */
    fun sources(c: Context): Map<String, DictionarySync.Source> =
        syncState(c).entries.mapValues { it.value.source }

    /** 使用者把自動學到的詞刪掉／忽略 → 記進清單，同一組修正不會馬上又被學回來。 */
    private const val IGNORED = "ignored"

    private fun ignored(c: Context) = prefs(c).getStringSet(IGNORED, emptySet()).orEmpty()

    fun ignore(c: Context, wrong: String, right: String) {
        if (wrong.isBlank()) return
        prefs(c).edit().putStringSet(IGNORED, ignored(c) + keyOf(wrong, right)).apply()
    }

    fun unignore(c: Context, wrong: String, right: String) {
        prefs(c).edit().putStringSet(IGNORED, ignored(c) - keyOf(wrong, right)).apply()
    }

    fun isIgnored(c: Context, wrong: String, right: String) = keyOf(wrong, right) in ignored(c)

    private fun keyOf(wrong: String, right: String) = "$wrong\t$right"

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

/**
 * 聽寫歷史（同 iOS HistoryStore 語意）：新的在前、最多 500 筆，存 app 私有檔。
 * 檔案格式與舊資料相容的純邏輯在 core 的 `HistoryCodec`（放 core 才能在電腦上測）。
 */
object HistoryStore {
    const val MAX = HistoryCodec.MAX

    /** durationSec：錄音秒數。**舊紀錄沒有這個欄位 → 0（未知）**，decode 不准因此失敗。 */
    data class Record(val time: Long, val raw: String, val cleaned: String, val durationSec: Int = 0)

    private fun file(c: Context) = File(c.filesDir, "history.json")

    /**
     * 鍵盤（IME service）與主 app 是兩個行程元件、會同時寫同一個檔案：
     * 讀改寫整段一定要在同一把鎖裡，否則兩邊各自 load → save 會互相蓋掉。
     * 2026-10-13 修補：以前只有 append／remove／restore／applyRetention 標 `@Synchronized`
     * （各自鎖自己），`@Synchronized` 擋不住「A 的 load + B 的 save」交錯。
     */
    private val lock = Any()

    fun load(c: Context): List<Record> = synchronized(lock) { loadLocked(c) }

    private fun loadLocked(c: Context): List<Record> =
        HistoryCodec.decode(runCatching { file(c).readText() }.getOrNull())
            .map { Record(it.time, it.raw, it.cleaned, it.durationSec) }

    fun append(c: Context, raw: String, cleaned: String, durationSec: Int = 0) = synchronized(lock) {
        // 「不保留」＝之後不寫歷史，但使用數據照算（UsageStore 是另一條路，不受這裡影響）。
        if (!HistoryRetentionSetting.keepsNewRecords(HistoryRetentionSetting.setting(c))) return@synchronized
        val all = (listOf(Record(System.currentTimeMillis(), raw, cleaned, durationSec.coerceAtLeast(0))) + loadLocked(c)).take(MAX)
        saveLocked(c, all)
    }

    fun remove(c: Context, time: Long) = synchronized(lock) { saveLocked(c, loadLocked(c).filterNot { it.time == time }) }

    fun clear(c: Context) = synchronized(lock) { file(c).delete() }

    /** 原樣寫回（含時間）；測試還原使用者紀錄用。 */
    fun restore(c: Context, records: List<Record>) = synchronized(lock) { saveLocked(c, records.take(MAX)) }

    /** 照保留期限砍掉過期的紀錄；回傳砍掉幾筆。每日計數不受影響。 */
    fun applyRetention(c: Context, retention: HistoryRetention = HistoryRetentionSetting.setting(c), now: Long = System.currentTimeMillis()): Int =
        synchronized(lock) {
            val all = loadLocked(c)
            val keep = all.filter { HistoryRetention.keeps(retention, it.time, now) }
            if (keep.size == all.size) return@synchronized 0
            saveLocked(c, keep)
            all.size - keep.size
        }

    /**
     * 照**新選的**保留期限砍完之後會少幾筆（確認對話框用，不寫檔）。
     * 2026-10-13 修補：以前用的是「還沒套用的舊設定」，所以換成較短的期限時確認框不出現。
     */
    fun expiredCount(c: Context, retention: HistoryRetention, now: Long = System.currentTimeMillis()): Int =
        synchronized(lock) { HistoryRetention.expiredCount(loadLocked(c).map { it.time }, retention, now) }

    private fun saveLocked(c: Context, records: List<Record>) {
        val json = HistoryCodec.encode(records.map { HistoryCodec.Record(it.time, it.raw, it.cleaned, it.durationSec) })
        // tmp 檔名帶 thread id：即使有漏網的並行寫，也不會搶同一個 tmp。
        val tmp = File(c.filesDir, "history.json.${Thread.currentThread().id}.tmp")
        tmp.writeText(json)
        if (!tmp.renameTo(file(c))) { file(c).writeText(json); tmp.delete() }
    }
}

/** 歷史保留期限的設定（只砍歷史紀錄；**每日計數永遠保留**）。 */
object HistoryRetentionSetting {
    private const val PREF = "history"
    private const val KEY = "retention"

    fun setting(c: Context): HistoryRetention =
        HistoryRetention.parse(c.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString(KEY, null))

    fun set(c: Context, retention: HistoryRetention) {
        c.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString(KEY, retention.id).apply()
    }

    /** 「不保留」連新紀錄都不寫。 */
    fun keepsNewRecords(r: HistoryRetention) = r != HistoryRetention.NONE

    /** 這筆時間留不留（純邏輯在 core 的 `HistoryRetention.keeps`）。 */
    fun keeps(r: HistoryRetention, time: Long, now: Long) = HistoryRetention.keeps(r, time, now)

    /** 會被砍掉幾筆（給確認對話框講清楚會少幾筆）。 */
    fun expiredCount(times: List<Long>, r: HistoryRetention, now: Long) = HistoryRetention.expiredCount(times, r, now)
}

/**
 * 鍵盤辨識完的整理（同 iOS TranscriptGuard）：逐字硬轉的繁體修正＋台灣站名 → 台灣用語 →
 * 個人字典替換 → 贅詞／重複／自我修正／數字／標點（後三段由 Normalizer 決定）。
 * 系統語音與雲端辨識的回來文字都走這裡。
 */
object Dictation {
    fun clean(c: Context, raw: String,
              language: DictationLanguage = DictationLanguage.TRADITIONAL_CHINESE,
              variant: LanguageVariant = language.defaultVariant,
              numberedLists: Boolean = true): String {
        val localized = localize(c, raw, language, variant)
        val dictionary = DictionaryStore.entries(c)
        return cleanLocalized(localized, dictionary, VocabularyPacks.latinTermsForFixer(c, dictionary), numberedLists)
    }

    /**
     * [clean] 不需要 Context 的部分（測試用）：個人字典＋英文專名（core `LatinNameFixer`，常用英文字護欄在 core 裡，
     * FX-5）→ 贅詞／重複／自我修正／數字／標點。
     */
    internal fun cleanLocalized(localized: String, dictionary: Map<String, String>, latinTerms: List<String>,
                                numberedLists: Boolean = true): String =
        Normalizer(NormalizerOptions(
            dictionary = dictionary.filter { it.key != it.value },
            latinTerms = latinTerms,
            numberedLists = numberedLists,
        )).normalize(localized).cleaned

    /**
     * 照聽寫語言／變體決定用字（10-18 Micky：Pixel 選簡體，出來還是繁體——原本不分語言一律轉台灣繁體）。
     * 台灣繁體：逐字硬轉修正＋站名＋台灣用語；簡體：繁轉簡；香港：只轉繁體字形、不套台灣用語；其他語言不碰。
     */
    fun localize(c: Context, raw: String, language: DictationLanguage, variant: LanguageVariant): String = when {
        LanguageVariant.traditionalFixerTarget(variant, language.code) -> {
            ChineseFixers.configure(c)
            TaiwanPhrases.apply(ChineseFixers.fix(raw))
        }
        variant == LanguageVariant.ZH_CN -> transliterate(raw, "Hant-Hans")
        variant == LanguageVariant.ZH_HK -> transliterate(raw, "Hans-Hant")
        else -> raw
    }

    private fun transliterate(text: String, id: String): String = runCatching {
        android.icu.text.Transliterator.getInstance(id).transliterate(text)
    }.getOrDefault(text)
}

/** 輸入框能不能放換行：文字類、而且標了多行才可以（單行框插換行可能直接觸發送出）。 */
object FieldShape {
    /**
     * 編號清單（1. 2. 3.）只在能換行的框裡出：單行框收成一行會變成「1. 買菜 2. 煮飯」，
     * 那時保留整理前的頓號寫法（2026-10-22 W2-6 修正）。沒有欄位資訊（null）照多行處理。
     */
    fun allowsNumberedLists(inputType: Int?): Boolean = inputType == null || allowsLineBreaks(inputType)

    fun allowsLineBreaks(inputType: Int): Boolean =
        (inputType and android.text.InputType.TYPE_MASK_CLASS) == android.text.InputType.TYPE_CLASS_TEXT &&
            (inputType and (android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_IME_MULTI_LINE)) != 0

    /**
     * 這個欄位可不可以把脈絡（App 名稱／前文／後文／hint）送到雲端整理服務。
     *
     * 2026-10-13 android-D 修正：以前只擋密碼，但 OTP／驗證碼欄位也是敏感資料——
     * 使用者正在輸入的六位數字會連同 hint 一起上傳。現在一律不送：
     * - TYPE_CLASS_NUMBER（數字欄，不論有沒有 password variation）
     * - TYPE_CLASS_PHONE（電話欄常拿來收驗證碼）
     * - 所有 password variation（文字與數字）
     * - hintText 含驗證碼關鍵字（不分大小寫；中文與英文都擋）
     *
     * 一般文字欄與 Email 欄照舊允許（Email 欄在 SmartCleanupTest 有既測試）。
     */
    fun allowsContext(inputType: Int, hintText: CharSequence? = null): Boolean {
        if (looksLikeSecret(hintText)) return false
        val fieldClass = inputType and android.text.InputType.TYPE_MASK_CLASS
        val variation = inputType and android.text.InputType.TYPE_MASK_VARIATION
        return when (fieldClass) {
            android.text.InputType.TYPE_CLASS_TEXT -> variation !in setOf(
                android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD,
                android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            )
            android.text.InputType.TYPE_CLASS_NUMBER,
            android.text.InputType.TYPE_CLASS_PHONE -> false
            else -> true
        }
    }

    /** hint 提到驗證碼／密碼／PIN，就當成敏感欄位（不分大小寫，中英文都看）。 */
    fun looksLikeSecret(hintText: CharSequence?): Boolean {
        val text = hintText?.toString()?.lowercase() ?: return false
        if (text.isBlank()) return false
        if (SECRET_HINTS_CJK.any { it in text } || SECRET_PHRASES.any { it in text }) return true
        // 英文單字整詞比對：「Zip code」「Promo code」「Pinterest」不算（誤擋跟漏擋一樣是缺陷）。
        val words = text.split(Regex("[^a-z0-9]+")).toSet()
        return SECRET_WORDS.any { it in words }
    }

    private val SECRET_HINTS_CJK = listOf("驗證碼", "验证码", "密碼", "密码", "安全碼", "安全码")
    private val SECRET_WORDS = setOf("otp", "totp", "2fa", "password", "passcode", "passwd", "pin")
    private val SECRET_PHRASES = listOf(
        "verification code", "security code", "one-time", "one time code", "sms code", "auth code",
        "authentication code", "access code", "confirmation code", "login code",
        "your code", "enter the code", "digit code"
    )
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
