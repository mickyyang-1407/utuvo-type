package com.utuvo.type

import android.content.Context
import android.view.textservice.SpellCheckerSession
import android.view.textservice.SuggestionsInfo
import android.view.textservice.TextInfo
import android.view.textservice.TextServicesManager
import com.utuvo.type.core.EnglishLexicon
import com.utuvo.type.core.EnglishSuggestions

/**
 * 英文鍵盤建議列的資料來源（完全在裝置上、不連網）：
 *  1. 內附詞表 [EnglishLexicon]（`assets/english-words.txt`，SCOWL）——補完與一次編輯距離的拼字建議，**同步**算好馬上給；
 *  2. Android 系統拼字檢查——只當額外的拼字建議，回來時有新東西才再更新一次；
 *  3. 使用者自己的詞（個人字典、詞庫包詞彙）。
 * 排序與大小寫規則在 core 的 [EnglishSuggestions]。
 *
 * 對應 iOS 的 `ios/Shared/EnglishSuggester.swift`（UITextChecker 同時給補完與拼字建議，而且永遠在）。
 * Android 不能只靠系統拼字檢查：它不做補完，而且系統拼字服務（通常是 Gboard 的）字典沒載入時
 * 對每個字都回「在字典裡、零建議」——2026-09-29 模擬器實測打 Tomor 一個建議都沒有。
 *
 * [SpellCheckerSession.getSuggestions] 是**非同步**的，回應依請求順序回來（見 [pending]）；
 * 過時的結果由呼叫端比對當下的字丟掉（見 UTUVOImeService）。
 */
class EnglishSuggester(
    private val context: Context,
    private val onSuggestions: (word: String, items: List<String>) -> Unit,
) {
    private var session: SpellCheckerSession? = null
    /**
     * 送出但還沒回來的查詢，依送出順序排隊。同一個 session 的回應依請求順序回來，所以回應一律配隊首。
     * 以前只留「最新一筆」：連打 Tomo→Tomor 時 Tomo 的回應先到、被當成 Tomor 的結果，
     * 真正 Tomor 的回應到時已經沒有 pending 被丟掉。
     */
    private val pending = ArrayDeque<Query>()

    init { EnglishWords.preload(context) }

    private val listener = object : SpellCheckerSession.SpellCheckerSessionListener {
        override fun onGetSuggestions(results: Array<out SuggestionsInfo>) {
            val query = synchronized(this@EnglishSuggester) { pending.removeFirstOrNull() } ?: return
            val extra = systemGuesses(results).filter { g -> query.base.none { it.equals(g, ignoreCase = true) } }
            // 系統沒給新東西就不再更新一次（同步那次已經顯示了）。
            if (extra.isEmpty()) return
            onSuggestions(query.word, merge(query, extra))
        }

        // 整句建議我們不用（只取游標前那一個字），實作一個空的免得它是抽象的。
        override fun onGetSentenceSuggestions(results: Array<out android.view.textservice.SentenceSuggestionsInfo>?) {}
    }

    /**
     * `word`：游標前正在打的字（見 [EnglishSuggestions.currentWord]）。空字串時什麼都不做。
     * 詞表的結果在這裡同步回呼；系統拼字檢查有額外建議時再回呼一次。
     */
    fun request(word: String, userTerms: List<String>, limit: Int = EnglishSuggestions.DEFAULT_LIMIT) {
        if (word.isEmpty() || limit <= 0) return
        val lexicon = EnglishWords.lexicon
        val query = Query(
            word = word,
            userTerms = userTerms,
            limit = limit,
            // 詞表還在載入（第一次切英文的幾百毫秒）時當作「沒拼錯」：先給補完、不亂給改錯。
            misspelled = lexicon != null && !lexicon.contains(word),
            completions = lexicon?.completions(word, limit * 2).orEmpty(),
            guesses = lexicon?.guesses(word, limit).orEmpty(),
        )
        onSuggestions(word, merge(query, emptyList()))

        val s = session() ?: return
        synchronized(this) { pending.addLast(query) }
        // API 36 把整個 SpellCheckerSession 標成 deprecated，但沒有給 App 端的替代（新的
        // android.service.textservice.SpellCheckerService.Session 是給輸入法「服務」端寫的，不是鍵盤 App 用的）。
        // minSdk 29 的裝置也只有這一條路，先用著。
        @Suppress("DEPRECATION")
        runCatching { s.getSuggestions(TextInfo(word), limit) }
            .onFailure { synchronized(this) { pending.remove(query) } }
    }

    private fun systemGuesses(results: Array<out SuggestionsInfo>?): List<String> {
        val head = results?.firstOrNull() ?: return emptyList()
        return buildList {
            for (i in 0 until head.suggestionsCount) {
                val s = head.getSuggestionAt(i)
                if (!s.isNullOrEmpty()) add(s)
            }
        }
    }

    private fun merge(query: Query, systemGuesses: List<String>): List<String> =
        EnglishSuggestions.merge(
            word = query.word,
            isMisspelled = query.misspelled,
            completions = query.completions,
            guesses = query.guesses + systemGuesses,
            userTerms = query.userTerms,
            limit = query.limit,
        )

    private fun session(): SpellCheckerSession? {
        session?.let { if (!it.isSessionDisconnected) return it }
        val tsm = context.getSystemService(TextServicesManager::class.java) ?: return null
        if (!tsm.isSpellCheckerEnabled) return null
        // 舊 session 斷了：它欠的回應永遠不會來，不清掉整條隊伍會從此錯位一格。
        synchronized(this) { pending.clear() }
        // 這是英文模式的建議列：明確要英文拼字服務。以前傳系統語言＋referToSpellCheckerLanguageSettings=true，
        // 手機系統是繁中時拿到的是中文（或沒有）拼字檢查，英文字一個建議都不會有。
        val locale = android.os.LocaleList.getDefault().let { list ->
            (0 until list.size()).map { list[it] }.firstOrNull { it.language == "en" }
        } ?: java.util.Locale.US
        return runCatching { tsm.newSpellCheckerSession(null, locale, listener, false) }.getOrNull()?.also { session = it }
    }

    fun destroy() {
        runCatching { session?.close() }
        session = null
        synchronized(this) { pending.clear() }
    }
}

/** 內附英文詞表：整個程序共用一份，第一次用到英文時在背景載入（九萬字，手機上約一兩百毫秒，不卡按鍵）。 */
object EnglishWords {
    const val ASSET = "english-words.txt"
    @Volatile var lexicon: EnglishLexicon? = null
        private set
    @Volatile private var loading = false

    fun preload(context: Context) {
        if (lexicon != null || loading) return
        loading = true
        val assets = context.applicationContext.assets
        Thread({
            lexicon = runCatching {
                EnglishLexicon(assets.open(ASSET).bufferedReader().use { it.readLines() })
            }.getOrNull()
            loading = false
        }, "english-words").start()
    }
}

/** 送出查詢時把詞表的結果與使用者詞一起帶著，系統拼字檢查回來（背景執行緒）時直接合併。 */
private class Query(
    val word: String,
    val userTerms: List<String>,
    val limit: Int,
    val misspelled: Boolean,
    val completions: List<String>,
    val guesses: List<String>,
) {
    val base: List<String> get() = completions + guesses
}

/** 使用者自己的詞：個人字典的兩邊（輸入與輸出）＋ 開著的詞庫包詞彙。個人字典多是中文，不會影響英文建議。 */
object EnglishUserTerms {
    @Volatile private var cached: List<String>? = null

    fun of(context: Context): List<String> {
        cached?.let { return it }
        val out = ArrayList<String>()
        for ((from, to) in DictionaryStore.entries(context)) { out.add(from); out.add(to) }
        out.addAll(VocabularyPacks.enabledTerms(context))
        val list = out.filter { it.isNotBlank() }.distinct()
        cached = list
        return list
    }

    /** 個人字典或詞庫包開關變了（鍵盤重新出現時呼叫）。 */
    fun reload() { cached = null }
}
