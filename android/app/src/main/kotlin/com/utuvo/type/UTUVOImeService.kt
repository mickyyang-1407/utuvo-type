package com.utuvo.type

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.utuvo.type.core.DictationClock
import com.utuvo.type.core.DictionarySync
import com.utuvo.type.core.SpeechPunctuation
import com.utuvo.type.core.EditScope
import com.utuvo.type.core.VoiceMode
import com.utuvo.type.core.VoiceModes
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo

/**
 * UTUVO Type 鍵盤（Android）。行為對齊 iOS build 14：
 * - 語音：點光球開始、再點一下停止；講話中逐字稿只在字幕帶預覽，停止後整理好的文字只插一次。
 * - 打字：EN／繁（注音或拼音）／简（拼音），選字中的字用 Android 原生組字（底線）顯示。
 * 與 iOS 不同：Android 鍵盤可以自己開麥克風，不需要跳主 app 代錄。
 */
class UTUVOImeService : InputMethodService() {
    /** android-D：鍵盤的字串要跟著主 app 的介面語言（設定裡選 English，鍵盤也全英文）。 */
    override fun attachBaseContext(newBase: Context) {
        rawBase = newBase
        super.attachBaseContext(AppTheme.wrapContext(newBase))
    }

    /**
     * `attachBaseContext` 送進來、**還沒套語言**的原始 base。
     * App 內換語言後要重建鍵盤，只能從它重新包（拿已經包過的當基底會套兩層）。
     */
    private var rawBase: Context? = null
    /** 目前這份 [localeContext] 對應的語言（`*`＝跟隨系統），變了就重新包。 */
    private var localeKey: String? = null
    private var localeContext: Context? = null
    /**
     * **目前畫面上那個鍵盤**是用哪一種語言做的。
     * 不能拿 [localeKey] 代替：服務只要讀一次字串（提示、模式列）就會把 [localeKey] 更新，
     * 鍵盤畫面卻還是舊語言——畫面與快取對不上，判斷永遠認為不用重建。
     */
    private var keyboardLocale: String? = null

    /** 介面語言的識別字串；跟著系統時用 `*`。 */
    private fun localeTag(): String = AppTheme.currentInterfaceLocale(this).languageTag ?: "*"

    /**
     * 拿當下語言的 context：App 裡換語言時鍵盤不會自己重建，這裡每次都要重算，
     * 不能沿用 `attachBaseContext` 那一次包的（Service 不會因語言變化而重建）。
     */
    private fun localeContext(): Context {
        val tag = localeTag()
        val cached = localeContext
        if (cached != null && localeKey == tag) return cached
        val ctx = rawBase?.let { AppTheme.wrapContext(it) }
        if (ctx == null) return this          // attachBaseContext 還沒跑（系統讀資源的早期），別自己套自己
        localeKey = tag
        localeContext = ctx
        return ctx
    }

    /**
     * 提示、模式列等字串一律走當下的語言，別用 Service 啟動時包好的那份資源。
     * （`Context.getString` 是 final，攔不到；改由 [getResources] 換掉整份資源。）
     */
    override fun getResources(): android.content.res.Resources =
        if (rawBase == null) super.getResources() else localeContext().resources

    private companion object {
        const val TAG = "UTUVOIme"
        /** 雲端辨識目前只做這一段語音（與 iOS 的兩段指示相同）；其他語言照系統辨識。 */
        const val CLOUD_LANGUAGE = "zh-TW"
    }

    /** 徽章選的聽寫語言（存在共用 prefs，每次讀，別處改了也會跟到）。 */
    private fun dictation() = DictationLanguage.current(this)

    private var keyboard: KeyboardView? = null
    private var recognizer: SpeechRecognizer? = null
    private var onDeviceRecognizer: SpeechRecognizer? = null
    private var cloudRecognizer: SpeechRecognizer? = null
    private var listening = false
    private var lastPartial = ""
    /** 上一段聽寫插入的文字：最後一句的句號被拿掉了，緊接著再講時先補回去（SentenceMood.continuationPrefix）。 */
    private var lastDictationOutput: String? = null
    /** 這一次聽寫（點光球到再點一次）。辨識器每段結束交回一段，沒按停就重新開始聽（見 [ContinuousDictation]）。 */
    private var session: ContinuousDictation? = null
    /** 這次聽寫開始的時間戳；用來算說了幾秒（記使用數據用，0＝還沒開始）。 */
    private var listeningStartedAt = 0L

    /**
     * 這一次聽寫的秒數，在**停止聽寫的那一刻**算好（見 [DictationClock.freeze]）。
     * 交付常常晚好幾秒才跑完（雲端重辨識、翻譯），那時再去讀時鐘會算成 0。
     */
    private var dictationSeconds = 0
    private var activeIntent: Intent? = null
    private var restartPending = false
    private var restartRetries = 0
    private val restartRunnable = Runnable { restartRecognizer() }
    /** 重開排程掛在服務自己的主執行緒 Handler：掛在鍵盤 view 上，view 在兩段之間被重建（例：轉向）就永遠不會跑（review 抓到）。 */
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var activeCleanupContext = SmartCleanup.CleanupContext()
    /** 這一次錄音要翻成哪個語言（長按弧選的）；null＝一般聽寫。 */
    private var translateTarget: Translation.Target? = null
    /**
     * 這一次要錄的是什麼（同 iOS `KeyboardMode`）：有選取＝說出要怎麼改；長按滑到語言＝翻譯；其餘＝聽寫。
     * 開始錄音時定下來，宿主在我們改寫期間動了選取就整段作廢。
     */
    private var mode: KeyboardMode = KeyboardMode.Dictate

    // ── 鍵盤語音模式（聽寫／幫我寫／改寫／問問題）──

    /**
     * 使用者選的語音模式。聽寫以外的三個都走同一條引擎選擇路線
     * （使用者的整理 key → [AssistantRoutes.pick]），提示詞在 [VoiceModes]。
     */
    private var voiceMode: VoiceMode = VoiceMode.DICTATE
    /** 改寫模式沒有選取文字時，使用者選了「這一段」還是「全部文字」；null＝還沒選。 */
    private var pendingScope: EditScope? = null
    /**
     * 一次性的復原：剛插入或剛改寫掉的文字。只留一次，再動一次就作廢。
     *
     * [insertEnd] 是插入／改寫**當下**的游標絕對位置（也就是剛寫的那段的結尾）。
     * 復原前要確認游標還停在這裡，否則使用者自己動過位置，刪掉的就不是我們寫的那一段。
     */
    private data class VoiceUndo(val rewritten: String, val original: String, val insertEnd: Int)
    private var voiceUndo: VoiceUndo? = null
    /** 游標前後各取多少字來算範圍（InputConnection 的 n 是 UTF-16 偏移）。 */
    private val cursorWindow = 100_000
    private var ime: ImeSession? = null
    private val sessions = HashMap<ImeSession.Kind, ImeSession>()
    /** 這次組字按下來的按鍵序列：空白收回時要靠它重打回去（Android 的 ImeSession 沒有 snapshot）。 */
    private val composedKeys = StringBuilder()
    /** 0c 重排用的上文：這次組字開始前游標前的 64 個字。 */
    private var composeContext: String = ""
    /** 每次排重排遞增；背景推論回來時對不上就丟掉那份結果（使用者又打字了）。 */
    private var rerankGeneration = 0
    /** 按下就送出、送出後手指滑開的那一下空白：記住按鍵序列與送出的字，收回時照原樣還原。 */
    private data class SpaceUndo(val keys: List<Char>, val inserted: String)
    private var spaceUndo: SpaceUndo? = null
    /** 按下就刪掉的那一個字；滑開＝其實是要切換鍵盤，把它補回去。 */
    private var lastDeleted: Char? = null
    /** 自動學字典：語音貼上後，刪掉重打的同音字記進個人字典。 */
    private val learner = CorrectionLearner()
    /** 智慧整理（選配）：先貼手機結果，背景整理好再換；連講多段也對得上。 */
    private val chain = CorrectionChain()
    private var refining = 0
    private val pendingCleanupRequests = mutableSetOf<CleanupCancellation>()
    /** 雲端語音辨識（選配）：有開關、有 key、語言支援時才錄一份給雲端；失敗照用系統結果。 */
    private val cloudRecorder = CloudRecorder()
    /** 每次離開輸入框就加一：非同步結果回來時用它判斷還是不是同一個欄位。 */
    private var inputGeneration = 0
    /** onStartInputView 看到的 fieldId：同 App 內換欄位時用它分辨「換欄位」與「同一欄重開鍵盤」。 */
    private var lastStartedFieldId = -1
    private val cloudWorker = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "cloud-asr-worker").apply { isDaemon = true }
    }
    private var cloudSamples: FloatArray? = null
    /** Q3 邊錄邊傳：錄音中先送前面的段，講完只等最後一段（null＝沒走分段，走整段一次送）。 */
    private var liveCloud: LiveCloudASR? = null
    /** Q3：還沒講完的最後一段（stop 之後才拿得到）。 */
    private var liveCloudLastChunk: FloatArray? = null
    private var cloudKey: String? = null
    private var cloudProvider: SmartCleanup.Provider? = null
    private var cloudAsrRunning = false

    // ── 候選列的預測（對齊 iOS `KeyboardViewController`）──

    private sealed interface Suggestions {
        data object None : Suggestions
        /** `context`＝剛送出的文字（接著點聯想詞會一路累加，用結尾找下一段）。 */
        data class Association(val context: String, val items: List<String>) : Suggestions
        data class English(val items: List<String>) : Suggestions
    }

    private var suggestions: Suggestions = Suggestions.None
    /** 系統拼字檢查是非同步的：回來時在這裡判斷是不是同一個字、同一個輸入框，不是就丟掉。 */
    private var englishSuggester: EnglishSuggester? = null

    private fun suggester(): EnglishSuggester = englishSuggester ?: EnglishSuggester(this) { word, items ->
        val generation = inputGeneration
        keyboard?.post {
            if (generation != inputGeneration) return@post          // 換了輸入框
            if (ime != null) return@post                            // 換回中文
            if (com.utuvo.type.core.EnglishSuggestions.currentWord(englishWord) != word) return@post  // 字早被改掉
            suggestions = if (items.isEmpty()) Suggestions.None else Suggestions.English(items)
            keyboard?.showSuggestions(items)
        }
    }.also { englishSuggester = it }
    /** 英文：游標前正在打的字。自己插的字母直接累加（打字熱路徑不問宿主）；刪字、外部變動時從游標前文字重算。 */
    private var englishWord = ""
    private var englishRefreshScheduled = false

    private val prefs by lazy { getSharedPreferences("keyboard", MODE_PRIVATE) }
    private var hantUsesPinyin: Boolean
        get() = HantInput.usesPinyin(this)
        set(v) { HantInput.setUsesPinyin(this, v) }

    /** 繁中修正的詞表（OpenCC 約 1 MB）要先讀；鍵盤服務一開就丟背景執行緒載，別拖到第一次貼上逐字稿。 */
    private fun preloadFixers() {
        if (ChineseFixers.ready()) return
        Thread({ runCatching { ChineseFixers.configure(this) } }, "chinese-fixers-warmup")
            .apply { isDaemon = true; start() }
    }

    override fun onCreateInputView(): View = createKeyboardView()

    /**
     * 組出鍵盤畫面。用的是**當下介面語言**的 context，
     * 語言換掉時要整個重畫（Service 不會因語言變化而重建）。
     */
    private fun createKeyboardView(): KeyboardView {
        val ctx = localeContext()
        keyboardLocale = localeTag()
        val v = KeyboardView(ctx, object : KeyboardView.Listener {
            override fun onOrbTap() {
                if (!listening) { translateTarget = null; refreshContext() }
                toggleListening()
            }
            override fun onTranslateArm() { keyboard?.showTranscript("") }
            override fun onTranslateCancel() {
                translateTarget = null
                mode = KeyboardMode.Dictate
                refreshContext()
            }
            override fun onTranslatePick(target: Translation.Target) {
                translateTarget = target
                mode = KeyboardMode.Translate(target)
                keyboard?.setEditMode(false)
                Translation.prepare(this@UTUVOImeService, target.code)   // 講話的這幾秒先下載模型（第一次）
                startListening()
            }
            override fun onDictationLanguage(language: DictationLanguage) {
                // KeyboardView 自己寫進 prefs 了；這裡只要讓提示與雲端路徑知道現在講哪一種語言。
                keyboard?.setHint(getString(R.string.hint_language_changed, getString(language.labelRes)), error = false)
            }
            override fun onSurfaceChanged(surface: KeyboardView.Surface) = switchSurface(surface)
            override fun onCompose(key: Char) { compose(key) }
            override fun onInsert(text: String) = insert(text)
            override fun onDelete() = delete()
            override fun onSpace() = space()
            override fun onEnter() = enter()
            override fun onPickCandidate(index: Int) = pick(index)
            override fun onToggleCandidatePanel() = toggleCandidatePanel()
            override fun onToggleHantInput() {
                commitComposition()
                hantUsesPinyin = !hantUsesPinyin
                switchSurface(KeyboardView.Surface.HANT)
            }
            override fun onSwitchKeyboard() { switchToNextInputMethod(false) }
            override fun onVoiceModeSelected(mode: VoiceMode) { selectVoiceMode(mode) }
            override fun onEditScopePicked(scope: EditScope) { pickEditScope(scope) }
            override fun onAnswerInsert(text: String) {
                if (text.isEmpty()) undoVoiceEdit() else insertAnswerAtCursor(text)
            }
            override fun onAnswerCopy(text: String) { copyAnswer(text) }
            override fun onAnswerDismiss() { dismissAnswer() }
            override fun onUndoInsert(text: String) = undoInsert(text)
            override fun onUndoCompose() = undoCompose()
            override fun onUndoDelete() = undoDelete()
            override fun onUndoSpace() = undoSpace()
        })
        keyboard = v
        return v
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        // App 內（或系統設定）換了介面語言：鍵盤畫面還是舊語言的，重建再用。
        if (keyboard != null && keyboardLocale != null && keyboardLocale != localeTag()) {
            val v = createKeyboardView()
            keyboard = v
            setInputView(v)
        }
        super.onStartInputView(info, restarting)
        // 2026-10-14（Q3-repair1 review-agy ⑤）：同一個 App 內換欄位不會走 onFinishInputView，
        // 只會再走一次 onStartInputView。雲端辨識／英文建議還在路上時這裡要作廢，
        // 否則回來貼進的是新欄位（同 onFinishInputView 的理由，只是換了觸發點）。
        // 只在 fieldId 真的換了才加：restarting（同一個欄位重開鍵盤，例如轉向）不該作廢等中的結果。
        val fieldId = info?.fieldId ?: -1
        if (fieldId != lastStartedFieldId) {
            lastStartedFieldId = fieldId
            inputGeneration++
        }
        preloadFixers()
        // 每次叫出鍵盤從語音開始（打字是修正用的）。錄音中不切。
        // 提示也重設：錄音被中斷（鍵盤收起又叫出）時，否則會一直卡在「整理中…」（真機實測）。
        if (!listening) {
            switchSurface(KeyboardView.Surface.VOICE)
            keyboard?.showTranscript("")
            keyboard?.showModeRow(true)
            keyboard?.setHint(getString(R.string.hint_idle), error = false)
            // 別處（主 app）改過聽寫語言或翻譯語言：叫出鍵盤時同步回徽章與弧。
            keyboard?.setDictationLanguage(dictation())
        }
        refreshContext()
        // 個人字典／詞庫包可能在別處改過：重新抓使用者詞，英文建議才不會用到舊的。
        EnglishUserTerms.reload()
        clearSuggestions()
        englishWord = ""
        keyboard?.setEnterLabel(enterLabel(info))
        keyboard?.showSwitchKey(shouldOfferSwitchingToNextInputMethod())
        syncAutoCapitalization()
    }

    /** 游標在別的地方（或換了一個輸入框）→ 重新判斷句首要不要大寫（同 iOS `textDidChange` 路徑）。 */
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStartIndex: Int, candidatesEndIndex: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStartIndex, candidatesEndIndex)
        syncAutoCapitalization()
        // 使用者自己選了一段字（或取消選取）→ 提示與光球顏色要立刻跟上（同 iOS `refreshContext`）。
        // 組字中不算：Android 在輸入期間會把組字區報成選取，那會讓光球一直顯示「說出要怎麼改」。
        if (!listening && ime == null) refreshContext()
        // 宿主那邊的文字或游標變了（不是我們插的）：英文模式重讀游標前的字。
        if (ime == null) {
            val word = com.utuvo.type.core.EnglishSuggestions.currentWord(textBeforeCursor())
            if (word != englishWord) {
                englishWord = word
                scheduleEnglishSuggestions()
            }
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        inputGeneration++   // 雲端辨識／英文建議還在路上：回來時已經不是這個輸入框了，丟掉（同 iOS 的 commandID 比對）
        cancelPendingCleanups()
        commitComposition()
        clearSuggestions()
        englishWord = ""
        chain.clear()
        translateTarget = null
        mode = KeyboardMode.Dictate
        if (listening) stopListening()
        dropCloudRecording()
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(restartRunnable)
        cancelPendingCleanups()
        onDeviceRecognizer?.destroy()
        cloudRecognizer?.destroy()
        recognizer = null
        dropCloudRecording()
        cloudWorker.shutdownNow()
        englishSuggester?.destroy()
        englishSuggester = null
        rerankGeneration++
        ZcReranker.release()
        super.onDestroy()
    }

    /** 記憶體吃緊：把 0c 的 OrtSession 關掉（下次需要時會重新從 assets 載入）。 */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_RUNNING_LOW) {
            rerankGeneration++
            ZcReranker.release()
        }
    }

    // ── 打字 ──

    private fun switchSurface(surface: KeyboardView.Surface) {
        commitComposition()
        ime = when (surface) {
            KeyboardView.Surface.HANT -> session(if (hantUsesPinyin) ImeSession.Kind.PINYIN_HANT else ImeSession.Kind.ZHUYIN)
            KeyboardView.Surface.HANS -> session(ImeSession.Kind.PINYIN)
            else -> null
        }
        clearSuggestions()
        englishWord = ""
        keyboard?.show(surface, hantUsesPinyin)
        if (surface == KeyboardView.Surface.EN) {
            englishWord = com.utuvo.type.core.EnglishSuggestions.currentWord(textBeforeCursor())
            scheduleEnglishSuggestions()
        }
        refreshComposition()
    }

    private fun session(kind: ImeSession.Kind) = sessions.getOrPut(kind) { ImeSession(this, kind) }

    /** 游標前的文字（英文建議、英文選字都要以宿主當下的文字為準，不靠累加的 englishWord）。 */
    private fun textBeforeCursor(n: Int = 64): String? = currentInputConnection?.getTextBeforeCursor(n, 0)?.toString()

    private fun refreshComposition() {
        // 組字一變（打字、選字、刪字）整頁候選就過期了：收起來，候選列回到一般的前 20 個。
        keyboard?.hideCandidatePanel()
        val s = ime
        if (s == null || s.isEmpty) {
            keyboard?.showCandidates("", emptyList())
            return
        }
        currentInputConnection?.setComposingText(s.preedit, 1)
        if (!s.isEmpty) suggestions = Suggestions.None
        // 第 0 格＝整串送出會得到的字（注音簡拼時輸入框顯示 ㄋㄏ、第 0 格顯示 你好）。
        keyboard?.showCandidates(s.conversion, s.candidates)
        scheduleRerank()
    }

    /**
     * 0c 上下文重排（AI 選字）：整句讀音已定時，把引擎的 K-best 候選丟給模型重新排序。
     * 主執行緒只取讀音與上文（都很便宜），延遲 80 ms 後整條（K-best ＋ 推論）在推論執行緒跑。
     * 回來時 generation 沒變、讀音也沒變才套用。送出不等推論——推論沒回來就用引擎原本的字。
     */
    private fun scheduleRerank() {
        val s = ime ?: return
        if (!HantInput.aiRerank(this)) return
        val readings = s.rerankInput() ?: return
        val generation = ++rerankGeneration
        val contextText = composeContext
        val handler = Handler(Looper.getMainLooper())
        handler.postDelayed({
            if (generation != rerankGeneration) return@postDelayed
            ZcReranker.executor().execute {
                val kbest = s.kBestForRerank(readings)
                if (kbest.isEmpty()) return@execute
                ZcReranker.rerankOnBackground(this, contextText, readings, kbest) { text ->
                    handler.post {
                        val now = ime ?: return@post
                        // 這期間使用者又打字了（讀音變了）或又排了一次序 → 這份結果丟掉
                        if (generation != rerankGeneration) return@post
                        if (text == null || now.completeReadingsForRerank() != readings) return@post
                        val before = now.conversion
                        now.applyRerank(readings, text)
                        if (now.conversion == before) return@post   // 選到的就是第 0 名，不用動畫面
                        currentInputConnection?.setComposingText(now.preedit, 1)
                        keyboard?.showCandidates(now.conversion, now.candidates)
                    }
                }
            }
        }, 80)
    }

    /** 打一個組字鍵；新的組字從頭開始記按鍵序列（空白收回時要重打回去）。 */
    private fun compose(key: Char) {
        // 新的組字從空開始：這時的游標前文字就是 0c 重排用的上文（一定要在 setComposingText 之前取，
        // 否則上文會含組字本身）。
        if (ime?.isEmpty != false) { composedKeys.clear(); composeContext = textBeforeCursor(64).orEmpty() }
        ime?.type(key)
        composedKeys.append(key)
        refreshComposition()
    }

    /** 送出整段組字；回傳送出的文字（空白收回要知道剛剛送出去幾個字）。 */
    private fun commitComposition(): String? {
        val s = ime ?: return null
        if (s.isEmpty) { composedKeys.clear(); return null }
        val text = s.commitAll()
        currentInputConnection?.commitText(text, 1)
        learnTyped(text)
        keyboard?.showCandidates("", emptyList())
        return text
    }

    private fun insert(text: String) {
        chain.clear()
        commitComposition()
        currentInputConnection?.commitText(text, 1)
        learnTyped(text)
        syncAutoCapitalization()
        noteEnglishInserted(text)
    }

    /** 打回的字剛好修掉一個語音同音錯字 → 記進個人字典並提示（主 app 字典列表可刪）。 */
    private fun learnTyped(text: String) {
        val (wrong, right) = learner.didType(text) ?: return
        // 使用者已經在字典頁忽略過同一組修正：不要再學回來。
        if (DictionaryStore.isIgnored(this, wrong, right)) return
        DictionaryStore.add(this, wrong, right, DictionarySync.Source.AUTO)
        keyboard?.setHint(getString(R.string.hint_learned, wrong, right), error = false)
    }

    private fun delete() {
        val s = ime
        if (s != null && s.backspace()) {
            // 組字引擎裡退掉的那一下不在文件裡，滑開也沒有東西要補回來（同 iOS）。
            lastDeleted = null
            if (composedKeys.isNotEmpty()) composedKeys.deleteCharAt(composedKeys.length - 1)
            if (s.isEmpty) currentInputConnection?.setComposingText("", 1)
            refreshComposition()
            return
        }
        chain.clear()
        val before = currentInputConnection?.getTextBeforeCursor(1, 0)?.lastOrNull()
        lastDeleted = before
        learner.willDelete(before)
        sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
        syncAutoCapitalization()
        // 刪字可能把整個字刪掉：從游標前的文字重算（不靠累加的 englishWord）。
        if (ime == null) {
            englishWord = com.utuvo.type.core.EnglishSuggestions.currentWord(textBeforeCursor())
            scheduleEnglishSuggestions()
        }
    }

    private fun space() {
        val s = ime
        if (s != null && !s.isEmpty) {
            // 注音：空白＝一聲收尾（還有打到一半的音時）；space() 回 false（簡拼／沒打聲調／只有聲母）
            // 就整串送出。拼音：直接送出。
            if (s.kind == ImeSession.Kind.ZHUYIN && s.hasComposing && s.space()) {
                spaceUndo = SpaceUndo(composedKeys.toList(), "")   // 沒送出字，只要收回聲調
                refreshComposition()
                return
            }
            val inserted = commitComposition().orEmpty()
            spaceUndo = SpaceUndo(composedKeys.toList(), inserted)
            // 整串送出後接著給聯想詞（你好 → 嗎）：打字時空白最常用，聯想詞要跟著出現。
            if (inserted.isNotEmpty()) showAssociations(inserted)
            return
        }
        clearSuggestions()
        englishWord = ""
        spaceUndo = SpaceUndo(emptyList(), " ")
        currentInputConnection?.commitText(" ", 1)
        syncAutoCapitalization()
    }

    // ── 收回：手指滑開（> 20dp）或觸控被取消時，把按下去時做出的東西還原 ──

    /** 收回剛插的字／符號：把游標前面那幾個字刪掉。 */
    private fun undoInsert(text: String) {
        if (text.isEmpty()) return
        deleteCharsBeforeCursor(text)
        syncAutoCapitalization()
    }

    /** 收回剛刪的字：補回去。 */
    private fun undoDelete() {
        val text = lastDeleted ?: return
        lastDeleted = null
        currentInputConnection?.commitText(text.toString(), 1)
        syncAutoCapitalization()
    }

    /** 收回剛組出來的音節：引擎退一格（同 iOS `typingUndoCompose` 的引擎倒退）。 */
    private fun undoCompose() {
        val s = ime ?: return
        if (s.isEmpty) return
        s.backspace()
        if (composedKeys.isNotEmpty()) composedKeys.deleteCharAt(composedKeys.length - 1)
        // 退到空：走 setComposingText("") 而不是只 unmark，否則會留 ghost 字。
        if (s.isEmpty) currentInputConnection?.setComposingText("", 1)
        refreshComposition()
    }

    /**
     * 收回空白：中文組字送出時可能一次插了幾個字，先刪掉，再把原本的按鍵序列重打回去
     * （Android 的 ImeSession 沒有 snapshot/restore，只能重打）。
     */
    private fun undoSpace() {
        val undo = spaceUndo ?: return
        spaceUndo = null
        if (undo.inserted.isNotEmpty()) deleteCharsBeforeCursor(undo.inserted)
        if (undo.keys.isNotEmpty()) replayComposition(undo.keys)
        syncAutoCapitalization()
    }

    /** 把這次組字清空再照順序重打一次（引擎已經是空的就直接打）。 */
    private fun replayComposition(keys: List<Char>) {
        val s = ime ?: return
        var guard = 0
        while (!s.isEmpty && guard++ < 256) s.backspace()
        keys.forEach { s.type(it) }
        composedKeys.setLength(0)
        keys.forEach { composedKeys.append(it) }
        refreshComposition()
    }

    /** 刪掉游標前剛剛插進去的那幾個字；內容對不上就不動（不要誤刪文件裡既有的字）。 */
    private fun deleteCharsBeforeCursor(expected: String) {
        val n = expected.length
        if (n == 0) return
        val ic = currentInputConnection ?: return
        val before = ic.getTextBeforeCursor(n + 8, 0)?.toString().orEmpty()
        if (!before.endsWith(expected)) return
        ic.deleteSurroundingText(n, 0)
    }

    /** 句首自動大寫：游標前的文字變了就把英文鍵盤的 Shift 狀態更新（同 iOS `updateAutoCapitalization`）。 */
    private fun syncAutoCapitalization() {
        keyboard?.updateAutoCapitalization(textBeforeCursor())
    }

    private fun enter() {
        val s = ime
        if (s != null && !s.isEmpty) { commitComposition(); return }
        clearSuggestions()
        englishWord = ""
        val info = currentInputEditorInfo
        val action = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
        val noEnterAction = ((info?.imeOptions ?: 0) and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0
        if (!noEnterAction && action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
            currentInputConnection?.performEditorAction(action)
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    /** 候選列／整頁的某一格。索引對應當下顯示的那份清單（聯想詞、英文建議、候選字共用一條路徑）。 */
    private fun pick(index: Int) {
        when (val s = suggestions) {
            is Suggestions.Association ->
                if (index in s.items.indices) return pickAssociation(s.items[index], s.context)
            is Suggestions.English ->
                if (index in s.items.indices) return pickEnglishSuggestion(s.items[index])
            Suggestions.None -> Unit
        }
        pickCandidate(index)
    }

    private fun pickCandidate(index: Int) {
        val s = ime ?: return
        val text = if (index < 0) s.commitAll() else s.select(index)
        if (text.isNotEmpty()) { currentInputConnection?.commitText(text, 1); learnTyped(text) }
        // 選字送出之後、refreshComposition 重算之前，ime 若還有剩餘組字，上文已經多出剛送出的字——
        // 這時不更新，後面 0c 重排會用到過期的上文（少了選中的那一段）。
        if (ime?.isEmpty == false) composeContext = textBeforeCursor(64).orEmpty()
        // 選字後 ime 可能還剩半段（例拼音吃掉「ni」、剩「hao」），refreshComposition 會更新輸入框的組字。
        refreshComposition()
        // 整串選完：接著給聯想詞（你好 → 嗎）。
        if (s.isEmpty && text.isNotEmpty()) showAssociations(text)
    }

    /** 候選列右端「⌄／⌃」：展開或收起整頁候選字。 */
    private fun toggleCandidatePanel() {
        if (keyboard?.isCandidatePanelVisible() == true) { keyboard?.hideCandidatePanel(); refreshComposition(); return }
        val s = ime ?: return
        if (s.isEmpty) return
        val items = s.allCandidates()
        if (items.isEmpty()) return
        // 候選列也換成同一份清單的前段，兩邊的索引才對得到同一個候選。
        suggestions = Suggestions.None
        keyboard?.showCandidatePanel(s.conversion, items)
    }

    // ── 聯想詞與英文建議 ──

    private fun showAssociations(after: String) {
        val s = ime ?: return
        if (!s.isEmpty) return
        val items = s.associationsAfter(after)
        suggestions = if (items.isEmpty()) Suggestions.None else Suggestions.Association(after, items)
        keyboard?.showSuggestions(if (items.isEmpty()) emptyList() else items)
    }

    private fun pickAssociation(text: String, context: String) {
        currentInputConnection?.commitText(text, 1)
        learnTyped(text)
        showAssociations(context + text)
    }

    private fun clearSuggestions() {
        if (suggestions === Suggestions.None) return
        suggestions = Suggestions.None
        keyboard?.showSuggestions(emptyList())
    }

    /** 英文插了字之後更新目前的字：字母（與字中撇號）累加，其他字元（空白、標點、數字）結束這個字。 */
    private fun noteEnglishInserted(text: String) {
        if (ime != null) return
        if (text.length == 1 && com.utuvo.type.core.EnglishSuggestions.isWordCharacter(text[0])) englishWord += text
        else englishWord = ""
        scheduleEnglishSuggestions()
    }

    /**
     * 建議列在字插進宿主之後才算（下一輪主執行緒），查字典不拖慢按鍵本身；連打時只算最後一次。
     * 系統拼字檢查自己是背景非同步的，回來時由 englishSuggester 的 callback 判斷還算不算數。
     */
    private fun scheduleEnglishSuggestions() {
        if (englishRefreshScheduled) return
        englishRefreshScheduled = true
        keyboard?.post {
            englishRefreshScheduled = false
            if (ime != null) return@post
            val word = com.utuvo.type.core.EnglishSuggestions.currentWord(englishWord)
            if (word.isEmpty()) {
                if (suggestions is Suggestions.English) { suggestions = Suggestions.None }
                keyboard?.showSuggestions(emptyList())
                return@post
            }
            suggester().request(word, EnglishUserTerms.of(this))
        }
    }

    /** 點英文建議：把游標前正在打的字換成建議、後面補一個空白（跟系統鍵盤一樣）。 */
    private fun pickEnglishSuggestion(suggestion: String) {
        // 以宿主當下的游標前文字為準重算要換掉的字，不靠累加的 englishWord（避免跟宿主不同步時刪錯字）。
        val word = com.utuvo.type.core.EnglishSuggestions.currentWord(textBeforeCursor())
        clearSuggestions()
        englishWord = ""
        if (word.isEmpty()) return
        currentInputConnection?.deleteSurroundingText(word.length, 0)
        val inserted = suggestion + " "
        currentInputConnection?.commitText(inserted, 1)
        keyboard?.updateAutoCapitalization(inserted)
    }

    private fun enterLabel(info: EditorInfo?): String = when (info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION)) {
        EditorInfo.IME_ACTION_SEND -> getString(R.string.key_send)
        EditorInfo.IME_ACTION_SEARCH -> getString(R.string.key_search)
        EditorInfo.IME_ACTION_GO -> getString(R.string.key_go)
        EditorInfo.IME_ACTION_DONE -> getString(R.string.key_done)
        EditorInfo.IME_ACTION_NEXT -> getString(R.string.key_next)
        else -> getString(R.string.key_return)
    }

    // ── 語音 ──

    private fun toggleListening() = if (listening) stopListening() else startListening()

    /** 宿主目前選取中的文字（沒選取回 null）。Android 對應 iOS `textDocumentProxy.selectedText`。 */
    private fun selectedText(): String? = currentInputConnection?.getSelectedText(0)?.toString()

    // ── 語音模式（聽寫／幫我寫／改寫／問問題）──

    /** 切換語音模式。改寫模式且沒有選取文字時，先請使用者選範圍再開始講。 */
    private fun selectVoiceMode(next: VoiceMode) {
        voiceMode = next
        pendingScope = null
        keyboard?.hideAnswerCard()
        keyboard?.showModeRow(true)
        keyboard?.setVoiceMode(next)
        when (next) {
            VoiceMode.SPEAK_TO_EDIT ->
                if (selectedText()?.trim().isNullOrEmpty()) keyboard?.showScopePicker(allTextAvailable())
                else keyboard?.hideScopePicker()
            else -> keyboard?.hideScopePicker()
        }
        refreshContext()
    }

    /**
     * 使用者選了改寫範圍。還沒選之前按光球不會開始錄音——避免不知道在改哪一段就送出指示。
     * 「全部文字」拿不到完整文字就不給（UI 那邊已經藏起來，這裡再擋一次）。
     */
    private fun pickEditScope(scope: EditScope) {
        if (scope == EditScope.ALL && !allTextAvailable()) {
            keyboard?.setHint(getString(R.string.assistant_all_unavailable), error = true)
            return
        }
        pendingScope = scope
        keyboard?.hideScopePicker()
        refreshContext()
        startListening()
    }

    /**
     * 能不能做「全部文字」。
     *
     * 兩個條件都要過：
     *  1. [android.view.inputmethod.ExtractedText] 為 null、或被宿主截斷
     *     （partialStartOffset／partialEndOffset 不為 0）→ 不做。
     *  2. **游標前後讀到的文字加起來要等於 ExtractedText 的全文長度**。
     *     只看 1 會被「ExtractedText 完整、但 getTextBeforeCursor 視窗被截斷」的宿主騙到，
     *     那時去改「全部文字」會吃掉我們根本沒讀到的字（review 抓到）。
     */
    private fun allTextAvailable(): Boolean {
        val ic = currentInputConnection ?: return false
        return runCatching {
            val extracted = ic.getExtractedText(null, 0) ?: return false
            if (extracted.partialStartOffset > 0 || extracted.partialEndOffset > 0) return false
            val w = readCursorWindow(ic) ?: return false
            VoiceModes.canUseAll(w.before, w.after, extracted.text?.length ?: 0)
        }.getOrDefault(false)
    }

    /** 游標前後各一段文字（相對游標的 UTF-16 偏移都從 0 起算）。 */
    private data class CursorWindow(val before: String, val after: String)

    private fun cursorWindow(): CursorWindow? = currentInputConnection?.let { readCursorWindow(it) }

    private fun readCursorWindow(ic: android.view.inputmethod.InputConnection): CursorWindow? = runCatching {
        CursorWindow(
            before = ic.getTextBeforeCursor(cursorWindow, 0)?.toString().orEmpty(),
            after = ic.getTextAfterCursor(cursorWindow, 0)?.toString().orEmpty()
        )
    }.getOrNull()

    /**
     * 游標的絕對位置（UTF-16 偏移）。
     *
     * 有完整 ExtractedText 就用 selectionStart。宿主截斷時 selectionStart 是**相對**偏移、
     * 不能當絕對位置用，改用「游標前文字的長度」當代理：同一個位置就有同樣的長度，
     * 使用者把游標移開就一定對不上。兩種算法在呼叫端與記錄時必須一致。
     */
    private fun cursorOffset(ic: android.view.inputmethod.InputConnection): Int? = runCatching {
        // ExtractedText.startOffset＋selectionStart 就是絕對位置（宿主只回一段文字時也成立）。
        // 拿不到 ExtractedText 就不給復原——「前文長度」當代理在兩處長度相同時會刪錯（luna-review B r2）。
        val extracted = ic.getExtractedText(android.view.inputmethod.ExtractedTextRequest(), 0)
            ?: return@runCatching null
        if (extracted.selectionStart < 0) null else extracted.startOffset + extracted.selectionStart
    }.getOrNull()

    /** 這一次要改寫的範圍（相對游標的偏移）與原文。 */
    private data class EditTarget(val back: Int, val forward: Int, val original: String)

    private fun editTarget(): EditTarget? {
        val scope = pendingScope ?: return null
        val w = cursorWindow() ?: return null
        if (scope == EditScope.ALL && !allTextAvailable()) return null
        val range = if (scope == EditScope.ALL) VoiceModes.allRange(w.before, w.after)
        else VoiceModes.paragraphAt(w.before, w.after)
        if (range.length <= 0) return null
        return EditTarget(
            back = w.before.length - range.start,
            forward = range.end - w.before.length,
            original = range.slice(w.before, w.after)
        )
    }

    /**
     * 所有失敗路徑（取消錄音、辨識錯誤、網路失敗、沒有 key）共用的收尾。
     *
     * 漏掉任何一項都會留下「看起來還在錄音／還在問問題」的假狀態：
     *  - [pendingScope] 沒清 → 下次按光球又跳回範圍選擇
     *  - 模式切換列沒回來 → 卡片收起後按不到模式
     *  - [voiceMode] 沒回聽寫 → 使用者還停在「幫我寫」，下一句講話被當成「要寫什麼」
     */
    private fun resetVoiceModeState() {
        pendingScope = null
        keyboard?.hideScopePicker()
        keyboard?.showModeRow(true)
        if (voiceMode != VoiceMode.DICTATE) {
            voiceMode = VoiceMode.DICTATE
            keyboard?.setVoiceMode(VoiceMode.DICTATE)
        }
        mode = KeyboardMode.Dictate
        keyboard?.setEditMode(false)
    }

    /**
     * 選取狀態一變，提示與光球顏色跟著變（同 iOS `refreshContext`）。
     * 有選取＝「說出要怎麼改」（光球薰衣草）；其餘＝一般聽寫。
     */
    private fun refreshContext() {
        if (listening) return
        val current = updateMode()
        // 走字串資源（簡中介面才翻得到）；文字與 KeyboardMode.idleHint／iOS KeyboardMode.idleHint 相同。
        val hint = when (current) {
            KeyboardMode.Dictate -> when (voiceMode) {
                VoiceMode.HELP_WRITE -> getString(R.string.hint_help_write_idle)
                VoiceMode.ASK_ANYTHING -> getString(R.string.hint_ask_idle)
                // 改寫沒有選取文字又還沒選範圍 → 先請他選範圍，不要直接開始錄
                VoiceMode.SPEAK_TO_EDIT ->
                    if (selectedText()?.trim().isNullOrEmpty()) getString(R.string.hint_scope_pick)
                    else getString(R.string.hint_edit_idle)
                VoiceMode.DICTATE -> getString(R.string.hint_idle)
            }
            is KeyboardMode.Edit -> getString(R.string.hint_edit_idle)
            is KeyboardMode.Translate -> getString(R.string.hint_translate_idle, getString(current.target.labelRes))
        }
        keyboard?.setHint(hint, error = false)
    }

    /**
     * 只更新模式與光球顏色，不動提示。
     * 剛顯示錯誤訊息時用這個收尾——錯誤要留在畫面上，不能被一般提示蓋掉。
     */
    private fun updateMode(): KeyboardMode {
        val current = KeyboardMode.decide(selectedText(), translateTarget, voiceMode)
        mode = current
        keyboard?.setEditMode(current.isEdit)
        return current
    }

    private fun startListening() {
        // 改寫模式、沒有選取文字、又還沒選範圍：先請他選「這一段／全部文字」，不要盲錄。
        // 範圍選擇已經在畫面上時，光球是「取消」——不然模式切換列被蓋住就回不去了。
        if (voiceMode == VoiceMode.SPEAK_TO_EDIT &&
            selectedText()?.trim().isNullOrEmpty() && pendingScope == null) {
            if (keyboard?.isScopePickerVisible() == true) {
                // 取消錄音：光球在範圍選擇畫面上是「取消」。狀態要全部歸零，
                // 否則 pendingScope 留著、模式列藏著，下次按光球還是卡在同一個畫面。
                resetVoiceModeState()
                refreshContext()
                return
            }
            keyboard?.showScopePicker(allTextAvailable())
            keyboard?.setHint(getString(R.string.hint_scope_pick), error = false)
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            keyboard?.setHint(getString(R.string.hint_need_mic), error = true)
            // 鍵盤不能直接跳權限視窗：打開主 app 讓使用者授權。
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        cancelPendingCleanups()
        commitComposition()
        // 選取／翻譯目標在按下光球的瞬間就定下來（開始錄音前 commitComposition 會動游標，重新判斷一次）。
        // 帶上 voiceMode：使用者選了「幫我寫／問問題／改寫」時，有選取也不走「說出要怎麼改」。
        mode = KeyboardMode.decide(selectedText(), translateTarget, voiceMode)
        keyboard?.setEditMode(mode.isEdit)
        listening = true
        lastPartial = ""
        listeningStartedAt = System.currentTimeMillis()
        dictationSeconds = 0
        session = ContinuousDictation()
        restartRetries = 0
        val editor = currentInputEditorInfo
        val dictLang = dictation()
        val variant = DictationLanguage.currentVariant(this, dictLang)
        activeCleanupContext = if (editor != null) {
            val packageName = editor.packageName.orEmpty()
            val appName = runCatching {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString()
            }.getOrDefault("")
            val before = currentInputConnection?.getTextBeforeCursor(500, 0)?.toString()
            val after = currentInputConnection?.getTextAfterCursor(200, 0)?.toString()
            val hint = editor.hintText
            val appProfile = SmartCleanup.rememberApp(this, packageName, appName)
            SmartCleanup.assembleContext(
                enabled = SmartCleanup.includeAppContext(this),
                inputType = editor.inputType,
                packageName = packageName,
                appName = appName,
                beforeCursor = before,
                afterCursor = after,
                hintText = hint,
                styleHint = FieldToneHint.prompt(editor),
                appStyleHint = appProfile?.styleHint,
                variant = variant
            )
        } else SmartCleanup.CleanupContext(variant = variant)
        if (translateTarget == null) SmartCleanup.warmUp(this)   // 講話的時候先連上智慧整理服務
        startCloudRecording()
        keyboard?.setListening(true)

        val intent = recognizeIntent()
        if (attachDebugAudio(intent)) dropCloudRecording()   // 測試音檔取代麥克風：沒有雲端錄音可送
        else attachMicPipe(intent)
        if (translateTarget == null && cloudAsrAvailable() && SmartCleanup.cloudRecognitionPreferred(this)) {
            // Explicitly permit network recognition. The selected Android speech service still controls its route.
            intent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
            beginCloud(intent)
            return
        }
        // 裝置端有中文語音包就用裝置端（音訊不離開手機）；沒有就請系統在背景下載，這次先走雲端並講明。
        // Pixel 7／Android 17 實測：裝置端引擎存在但 zh-TW 語言包沒下載 → 一開錄就 error 13（LANGUAGE_UNAVAILABLE）。
        // 這條路徑認的是「有沒有裝繁中包」（[isTraditionalChinese]），所以只在聽繁中時走；
        // 換成别的語言照系統辨識器送選好的 EXTRA_LANGUAGE，別讓它把語言改回繁中。
        if (dictation() == DictationLanguage.TRADITIONAL_CHINESE && Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) {
            val onDevice = onDeviceRecognizer ?: SpeechRecognizer.createOnDeviceSpeechRecognizer(this).also { onDeviceRecognizer = it }
            onDevice.checkRecognitionSupport(intent, mainExecutor, object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    Log.i(TAG, "on-device installed=${support.installedOnDeviceLanguages} pending=${support.pendingOnDeviceLanguages} supported=${support.supportedOnDeviceLanguages} online=${support.onlineLanguages.size}")
                    if (!listening) return
                    val installed = support.installedOnDeviceLanguages.firstOrNull(::isTraditionalChinese)
                    if (installed != null) {
                        // 要用引擎回報的語言代碼：已裝的包叫 cmn-Hant-TW，送 zh-TW 會找不到包（error 13，Pixel 7 實測）。
                        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, installed)
                        begin(onDevice, intent, onDevice = true)
                    } else {
                        if (support.supportedOnDeviceLanguages.any(::isTraditionalChinese) && support.pendingOnDeviceLanguages.none(::isTraditionalChinese)) {
                            onDevice.triggerModelDownload(intent)
                        }
                        beginCloud(intent)
                    }
                }
                override fun onError(error: Int) {
                    Log.w(TAG, "checkRecognitionSupport error $error")
                    if (listening) beginCloud(intent)
                }
            })
        } else {
            beginCloud(intent)
        }
    }

    /**
     * 輸入框沒標成多行（搜尋列、單行聊天框）→ 分段換行接回一行：換行在單行框裡可能直接觸發送出。
     * 同 iOS ToneHint.allowsLineBreaks。
     */
    private fun fitField(text: String, tone: FieldToneHint.Kind = FieldToneHint.infer(currentInputEditorInfo),
                         inputType: Int? = currentInputEditorInfo?.inputType, mood: Boolean = true): String {
        // 句尾語氣（2026-10-02 Micky：不要每句都句號）：SpeechPunctuation／智慧整理之後才做，它們都可能補回句號。
        // 翻譯輸出不做（日文也用「。」、也有「誰」這類字）。
        val toned = FieldToneHint.apply(if (mood) com.utuvo.type.core.SentenceMood.apply(text) else text, tone)
        val type = inputType ?: return toned
        return if (FieldShape.allowsLineBreaks(type)) toned else com.utuvo.type.core.OutputShape.singleLine(toned)
    }

    private fun recognizeIntent() =
        SpeechRequest.build(dictation().code, VocabularyPacks.biasing(this), quietMode = QuietMode.isEnabled(this))

    /**
     * 只在開發版：裝置測試把一段 16 kHz 單聲道 PCM 的路徑寫進偏好 `debugAudioFile`，鍵盤就「聽」這個檔、不開麥克風。
     * 同一個檔案描述子跨段重用（辨識器每段結束後重開，會從檔案目前的位置接著讀），用來在真機上驗「停頓不會斷」。
     */
    private var debugAudio: android.os.ParcelFileDescriptor? = null

    private fun attachDebugAudio(intent: Intent): Boolean {
        runCatching { debugAudio?.close() }
        debugAudio = null
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) return false
        val path = prefs.getString("debugAudioFile", null) ?: return false
        val file = java.io.File(path)
        if (!file.isFile) return false
        val pfd = android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
        debugAudio = pfd
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pfd.dup())
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
        return true
    }

    private fun isTraditionalChinese(tag: String) =
        tag.equals("zh-TW", true) || tag.startsWith("cmn-Hant", true) || tag.startsWith("zh-Hant", true)

    /** 雲端 ASR 目前只做繁中（[CLOUD_LANGUAGE]）；換了聽寫語言就不是同一件事，不要走這條路。 */
    private fun cloudAsrAvailable() = dictation() == DictationLanguage.TRADITIONAL_CHINESE

    private fun beginCloud(intent: Intent) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            listening = false
            resetVoiceModeState()   // 沒有辨識器＝這次不會有結果，語音模式要回到聽寫
            dropCloudRecording()   // 沒有系統辨識器就不會有雲端重辨識的機會，麥克風別留著
            keyboard?.setListening(false)
            keyboard?.setHint(getString(R.string.hint_no_recognizer), error = true)
            return
        }
        val cloud = cloudRecognizer ?: SpeechRecognizer.createSpeechRecognizer(this).also { cloudRecognizer = it }
        begin(cloud, intent, onDevice = false)
    }

    private fun begin(r: SpeechRecognizer, intent: Intent, onDevice: Boolean) {
        recognizer = r
        activeIntent = intent
        r.setRecognitionListener(listener)
        r.startListening(intent)
        when (val current = mode) {
            is KeyboardMode.Edit -> {
                val engine = engineLabel()
                keyboard?.setHint(getString(R.string.hint_editing_engine, engine), error = false)
            }
            is KeyboardMode.Translate -> {
                val target = current.target
                val name = getString(target.labelRes)
                keyboard?.setHint(getString(R.string.hint_listening_translate, name), error = false)
                Translation.isReady(this@UTUVOImeService, target.code) { ready ->
                    // 沒有任何雲端路徑（A3：completionRoute）時翻譯只能等裝置端模型，才提示下載中。
                    if (!ready && listening && translateTarget == target && SmartCleanup.completionRoute(this@UTUVOImeService) == null)
                        keyboard?.setHint(getString(R.string.hint_translate_download, name), error = false)
                }
            }
            KeyboardMode.Dictate -> keyboard?.setHint(
                getString(if (onDevice) R.string.hint_listening_device else R.string.hint_listening_cloud), error = false)
        }
    }

    /** 目前改寫／翻譯的引擎標示（iPhone badge：裝置端／雲端（你的 key）／不可用）。 */
    private fun engineLabel(): String {
        val route = SmartCleanup.completionRoute(this)
        val engine = Assistant.engine(route != null)
        val res = route?.first?.id?.let { AssistantErrors.providerNameRes(it) }
        val badge = getString(when (engine) {
            Assistant.Engine.CLOUD -> R.string.assistant_badge_cloud
            Assistant.Engine.UNAVAILABLE -> R.string.assistant_badge_none
        })
        return if (res == null) badge else "$badge・${getString(res)}"
    }

    private fun stopListening() {
        val s = session
        s?.requestStop()
        if (restartPending) {
            // 正在兩段之間（辨識器剛結束、還沒重新開始）：沒有下一段會回來了，直接收尾。
            mainHandler.removeCallbacks(restartRunnable)
            restartPending = false
            finishSession(s?.finish().orEmpty())
            return
        }
        recognizer?.stopListening()
        finishCloudRecording()
        listening = false
        keyboard?.setListening(false)
        keyboard?.setHint(getString(R.string.hint_finishing), error = false)
        // 就在使用者按停的這一刻把秒數算好：之後的雲端重辨識／翻譯延遲不再影響記錄。
        freezeSessionSeconds()
    }

    // ── 雲端語音辨識（選配；失敗一律退回系統 SpeechRecognizer 的結果）──

    /** 開關＋key＋語言都對才錄音；翻譯模式不錄（那裡要的是翻好的文字，不是逐字稿）。錄不起來就當沒這回事。 */
    private fun startCloudRecording() {
        stopLiveCloud()
        liveCloudLastChunk = null
        cloudSamples = null
        cloudKey = null
        cloudProvider = null
        if (translateTarget != null) return
        if (!cloudAsrAvailable()) return
        val language = CLOUD_LANGUAGE
        if (!CloudASR.isReady(this, language)) return
        val (provider, routeKey) = CloudASR.route(this) ?: return
        if (!cloudRecorder.start(QuietMode.isEnabled(this))) { Log.i(TAG, "cloud ASR recording unavailable, staying on system recognizer"); return }
        cloudKey = routeKey
        cloudProvider = provider
        // Q3 邊錄邊傳：錄音中偵測到停頓就先送那一段；講完只等最後一段。
        val live = LiveCloudASR(provider, cloudKey.orEmpty(), language, VocabularyPacks.cloudHints(this))
        liveCloud = live
        cloudRecorder.setChunkSink { chunk -> live.submit(chunk) }
    }

    /** 收掉背景分段工作（定稿、取消、換輸入框都會走到）。 */
    private fun stopLiveCloud() {
        cloudRecorder.setChunkSink(null)
        liveCloud?.abandon()
        liveCloud = null
    }

    /** 停聽時取回整段錄音；沒錄到就清空（後面就不會送網路）。 */
    private fun finishCloudRecording() {
        if (!cloudRecorder.isActive) { cloudSamples = null; closeMicPipe(); return }
        cloudSamples = cloudRecorder.stop()
        closeMicPipe()
        // 除錯版：記下這次錄音的音量（10-20 Pixel 雲端錄到全 0 的問題）。正式版不記。
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            cloudSamples?.let { s ->
                val peak = s.maxOfOrNull { kotlin.math.abs(it) } ?: 0f
                Log.i(TAG, "cloud recording samples=${s.size} peak=$peak quiet=${QuietMode.isEnabled(this)} chunked=${liveCloud != null}")
            }
        }
        // Q3：還沒講完的最後一段，講完時才送（前面幾段錄音中就送完了）。
        liveCloudLastChunk = cloudRecorder.takeFinalChunk()
    }

    /** 使用者放棄（鍵盤收起、換模式、辨識出錯）→ 丟掉錄音。 */
    private fun dropCloudRecording() {
        stopLiveCloud()
        liveCloudLastChunk = null
        cloudSamples = null
        cloudKey = null
        cloudProvider = null
        if (cloudRecorder.isActive) cloudRecorder.cancel()
        closeMicPipe()
    }

    // ── 麥克風只開一個：雲端錄音開著時，系統辨識器改聽我們經 pipe 轉給它的聲音 ──
    // 2026-10-20 Pixel 7 實測（CloudAsrLiveProbeTest.orderProbe）：系統辨識器與我們的 AudioRecord 同時錄，
    // 後開麥克風的那一方拿到聲音、先開的被系統填 0（同時開：0 佔 100%；辨識器停頓後重開：後半段 100%）。
    // 雲端收到整段靜音，Whisper 就補出「MING PAO CANADA」「字幕由 Amara.org 社群提供」。
    // EXTRA_AUDIO_SOURCE（Android 13+）裝置端與雲端辨識器都吃（pipeProbe 實測即時結果正確）。
    private var micPipeThread: Thread? = null
    private val micPipeQueue = java.util.concurrent.LinkedBlockingQueue<ByteArray>(256)

    private fun attachMicPipe(intent: Intent) {
        closeMicPipe()
        if (!cloudRecorder.isActive || Build.VERSION.SDK_INT < 33) return
        val pipe = runCatching { android.os.ParcelFileDescriptor.createPipe() }.getOrNull() ?: return
        val out = android.os.ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
        val queue = micPipeQueue.also { it.clear() }
        // 讀的那端留在我們手上（同測試音檔：每段給辨識器一份複本，[restartRecognizer] 會再 dup）。
        debugAudio = pipe[0]
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0].dup())
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
        // 寫 pipe 在自己的執行緒：辨識器兩段之間沒在讀時 pipe 會滿，不能卡住錄音執行緒（滿了就丟，雲端那份不受影響）。
        micPipeThread = Thread({
            try {
                while (true) {
                    val chunk = queue.take()
                    if (chunk.isEmpty()) break
                    out.write(chunk)
                }
            } catch (_: Exception) {
            } finally { runCatching { out.close() } }
        }, "mic-pipe").apply { isDaemon = true; start() }
        cloudRecorder.pcmTap = { buffer, count ->
            val bytes = ByteArray(count * 2)
            for (i in 0 until count) {
                val v = buffer[i].toInt()
                bytes[2 * i] = (v and 0xFF).toByte(); bytes[2 * i + 1] = (v shr 8 and 0xFF).toByte()
            }
            queue.offer(bytes)
        }
    }

    /** 收掉 pipe：寫完佇列裡剩下的再關（辨識器讀到檔尾就收尾）。 */
    private fun closeMicPipe() {
        cloudRecorder.pcmTap = null
        micPipeThread ?: return
        micPipeThread = null
        if (!micPipeQueue.offer(ByteArray(0))) { micPipeQueue.clear(); micPipeQueue.offer(ByteArray(0)) }
    }

    /**
     * 系統結果到了：先取走這次的雲端錄音（只取一次，onResults 可能晚到）。
     * 有錄音就先問雲端，成功用雲端文字、失敗／逾時用系統原文；兩邊都走同一條輸出流程。
     */
    private fun deliverWithCloud(raw: String, onNothing: () -> Unit = {}) {
        val samples = cloudSamples
        val key = cloudKey
        val provider = cloudProvider
        val live = liveCloud
        val liveLast = liveCloudLastChunk
        liveCloud = null
        liveCloudLastChunk = null
        cloudSamples = null; cloudKey = null; cloudProvider = null
        if (samples == null || samples.isEmpty() || key.isNullOrEmpty() || provider == null || translateTarget != null) {
            if (raw.isNotEmpty()) deliver(raw) else onNothing()
            return
        }
        if (cloudAsrRunning) { if (raw.isNotEmpty()) deliver(raw) else onNothing(); return }
        cloudAsrRunning = true
        keyboard?.setHint(getString(R.string.hint_cloud_listening), error = false)
        val hotwords = VocabularyPacks.cloudHints(this)
        val app = applicationContext
        val generation = inputGeneration
        cloudWorker.execute {
            // Q3：分段送（前面幾段錄音中就送完了）→ 只等最後一段；沒分段就整段一次送。
            val cloudGuard = CloudASR.Guard { value, language, _ ->
                    // 雲端回來的中文可能是簡體；繁中要轉回來（與 iOS TranscriptGuard.clean 同一個理由）。
                    val converted = if (language.startsWith("zh-TW") || language.startsWith("zh-Hant")
                        || language.startsWith("zh-HK")) toTraditional(value) else value
                    CloudASR.trimGuard(converted, language, 0.0)
                }
            val text = if (live != null) {
                // 分段：前面幾段錄音中就送完了，這裡只等最後一段（沒有段就整段一次送）。
                live.finish(last = liveLast, whole = samples,
                            log = CloudASR.defaultLog(app), guard = cloudGuard)
            } else {
                CloudASR.transcribe(samples, CLOUD_LANGUAGE, hotwords, provider, key,
                    log = CloudASR.defaultLog(app), guard = cloudGuard)
            }
            keyboard?.post {
                cloudAsrRunning = false
                // 使用者在等雲端的期間換了輸入框或收起鍵盤：不能貼到新的欄位去。
                if (generation != inputGeneration) return@post
                // 兩邊都沒東西就不要貼一個空字串出去（系統出錯時會走這裡）。
                // Whisper 補的「謝謝大家收看」：系統辨識沒聽到這句才去掉（說出要怎麼改時這句會被當成指示）。
                val kept = text?.let { CloudASR.dropOutroHallucination(it, reference = raw) }?.ifEmpty { null }
                if (kept != null) deliver(kept) else if (raw.isNotEmpty()) deliver(raw) else onNothing()
            }
        }
    }

    /** 裝置上的簡轉繁（Android ICU；沒有轉換器就原樣回傳，不要因此丟掉整段）。 */
    private fun toTraditional(text: String): String = runCatching {
        android.icu.text.Transliterator.getInstance("Hans-Hant").transliterate(text)
    }.getOrDefault(text)

    /** 系統辨識錯誤的提示（雲端也沒救回來時才顯示）。 */
    private fun showRecognitionError(error: Int) {
        val msg = when (error) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> getString(R.string.hint_no_speech)
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> getString(R.string.hint_need_mic)
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> getString(R.string.hint_network)
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE, SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> getString(R.string.hint_language_pack)
            else -> getString(R.string.hint_error, error)
        }
        keyboard?.setHint(msg, error = error != SpeechRecognizer.ERROR_NO_MATCH && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT)
    }

    /**
     * 一次聽寫完成：寫歷史（**看保留期限**）＋記使用數據（**永遠記**，只有數字）。
     * 這是使用數據的唯一寫入點，App 內與鍵盤內都走這裡。
     */
    private fun noteDictation(raw: String, output: String) {
        val seconds = sessionSeconds()
        val app = applicationContext
        // 歷史寫檔是磁碟 IO，丟背景去，不要卡住輸入法（與語音功能的寫入同一條路）。
        cloudWorker.execute {
            runCatching { HistoryStore.append(app, raw, output, seconds) }
                .onFailure { Log.w(TAG, "history append failed", it) }
        }
        UsageStore.record(this, output, seconds)
    }

    /**
     * 這次聽寫說了幾秒。
     *
     * 連續聽寫沒按停就再講，時間從第一次開始算（會累加）。
     * 2026-10-13 修補：停止聽寫時就用 [freezeSessionSeconds] 把秒數算好存起來——
     * 交付（雲端重辨識／翻譯）晚多久都不影響，也不會是 0。
     */
    private fun sessionSeconds(): Int =
        dictationSeconds.takeIf { it > 0 } ?: DictationClock.freeze(listeningStartedAt, System.currentTimeMillis())

    /** 停止聽寫：算好這次的秒數並歸零起始時間（重複呼叫安全）。 */
    private fun freezeSessionSeconds() {
        if (dictationSeconds > 0) { listeningStartedAt = 0L; return }
        dictationSeconds = DictationClock.freeze(listeningStartedAt, System.currentTimeMillis())
        listeningStartedAt = 0L
    }

    /** 系統或雲端拿到的逐字稿走同一條輸出流程（整理 → 貼上 → 背景智慧整理）。 */
    private fun deliver(raw: String) {
        // 說出要怎麼改：raw 是指示，不是要貼上的內容。改寫完取代選取。
        if (mode is KeyboardMode.Edit) { deliverEdit(raw); return }
        // 鍵盤語音模式（幫我寫／改寫／問問題）都在聽寫之外，走各自那條路。
        // 翻譯優先：長按弧選了語言時 translateTarget 有值，不能被模式蓋掉。
        if (translateTarget == null) {
            when (voiceMode) {
                VoiceMode.HELP_WRITE -> { deliverHelpWrite(raw); return }
                VoiceMode.SPEAK_TO_EDIT -> { deliverSpeakToEdit(raw); return }
                VoiceMode.ASK_ANYTHING -> { deliverAskAnything(raw); return }
                VoiceMode.DICTATE -> Unit
            }
        }
        val tone = FieldToneHint.infer(currentInputEditorInfo)
        val inputType = currentInputEditorInfo?.inputType
        // 同一套整理：台灣用語 → 贅詞／重複／自我修正／數字／標點
        // 整理萬一出錯，送原文、記下錯誤——鍵盤閃退會讓使用者剛講的話整段不見（09-19 真機實測過一次）。
        val cleaned = runCatching {
            val field = when (tone) {
                FieldToneHint.Kind.DOCUMENT -> SpeechPunctuation.Field.DOCUMENT
                FieldToneHint.Kind.CHAT -> SpeechPunctuation.Field.CHAT
                FieldToneHint.Kind.SEARCH -> SpeechPunctuation.Field.SEARCH
            }
            val language = dictation()
            fitField(SpeechPunctuation.restore(
                Dictation.clean(this, raw, language, DictationLanguage.currentVariant(this, language)), field), tone, inputType)
        }
            .getOrElse { Log.e(TAG, "normalize failed, inserting raw transcript", it); raw }
        val target = translateTarget
        translateTarget = null
        mode = KeyboardMode.Dictate
        if (target == null) {
            // 緊接在上一段後面講：上一段拿掉的句號先補回去，兩段才不會黏成一句。
            val ic = currentInputConnection
            val prefix = com.utuvo.type.core.SentenceMood.continuationPrefix(
                ic?.getTextBeforeCursor(200, 0)?.toString(), lastDictationOutput)
            if (prefix.isNotEmpty()) ic?.commitText(prefix, 1)
            ic?.commitText(cleaned, 1)
            if (cleaned.isNotEmpty()) lastDictationOutput = cleaned
            noteDictation(raw, cleaned)
            learner.dictationInserted(cleaned)
            refine(cleaned, raw, activeCleanupContext, tone, inputType)
            return
        }
        keyboard?.setHint(getString(R.string.hint_translating), error = false)
        keyboard?.showTranscript(cleaned)
        // 翻譯是非同步的：翻好時鍵盤可能已經換到別的輸入框，要插進當下那一個（跟使用者看到的一致）。
        Translation.translate(this, cleaned, target) { result ->
            keyboard?.showTranscript("")
            result.onSuccess { translated ->
                keyboard?.setHint(getString(R.string.hint_idle), error = false)
                val output = fitField(translated.trim(), tone, inputType, mood = false)
                currentInputConnection?.commitText(output, 1)
                noteDictation(raw, output)
            }.onFailure {
                Log.w(TAG, "translate to ${target.code} failed", it)
                keyboard?.setHint(getString(R.string.assistant_translate_failed, AssistantErrors.detail(it)), error = true)
                currentInputConnection?.commitText(cleaned, 1)
                noteDictation(raw, cleaned)
            }
        }
    }

    /**
     * 說出要怎麼改：把選取與指示送去改寫，回來時選取還在就取代它（同 iOS `case .edit`）。
     *
     * 沒有雲端 key 時不打任何網路，直接講清楚要去哪裡加（iPhone 的 AssistantError.unavailable）。
     */
    private fun deliverEdit(instruction: String) {
        val selection = (mode as? KeyboardMode.Edit)?.selection.orEmpty()
        mode = KeyboardMode.Dictate
        keyboard?.showTranscript("")
        if (instruction.isBlank() || currentInputConnection == null) { refreshContext(); return }
        if (SmartCleanup.completionRoute(this) == null) {
            resetVoiceModeState()
            keyboard?.setHint(getString(R.string.assistant_no_key), error = true)
            return
        }
        keyboard?.setHint(getString(R.string.hint_editing, engineLabel()), error = false)
        val generation = inputGeneration
        SmartCleanup.completeAsync(this, Assistant.EDIT_SYSTEM, Assistant.editUser(selection, instruction)) { result ->
            keyboard?.showTranscript("")
            // 使用者在等的期間換了輸入框或收起鍵盤：不能貼到新的欄位去。
            if (generation != inputGeneration) return@completeAsync
            result.onSuccess { rewritten ->
                // 選取還是原本那一段才取代；使用者中途取消或改選別段就不動他的文字
                // （以前只檢查「還有選取」：等待時改選別段，改寫結果會蓋到新選的那段——review 抓到）。
                if (selectedText()?.trim() != selection) {   // Edit 存的是 trim 過的選取
                    resetVoiceModeState()
                    keyboard?.setHint(getString(R.string.assistant_selection_gone), error = true)
                    return@onSuccess
                }
                currentInputConnection?.commitText(rewritten, 1)
                logVoiceResult(instruction, rewritten)
                refreshContext()
            }.onFailure {
                Log.w(TAG, "edit failed", it)
                resetVoiceModeState()
                keyboard?.setHint(editFailureMessage(it), error = true)
            }
        }
    }

    /** 改寫失敗的短句（含補救方法），不丟系統訊息。 */
    private fun editFailureMessage(error: Throwable): String = when (error) {
        is SmartCleanup.NotConfigured -> getString(R.string.assistant_no_key)
        is SmartCleanup.EmptyOutput -> getString(R.string.assistant_empty)
        else -> AssistantErrors.detail(error)
    }

    // ── 幫我寫（Help me write）──

    /**
     * 說「要寫什麼」→ 產生一段可送出的文字，插在游標處。
     *
     * 參考游標前文字當上下文（500 字上限、沿用既有整理開關），讓回覆接得上對話。
     * 寫好直接插入，並留一次復原。
     *
     * 有選取文字時（使用者切到這個模式又選了一段）：選取是**參考上下文**，
     * 產出插在選取**之後**，不取代——取代掉使用者自己選的東西不是他要的。
     */
    private fun deliverHelpWrite(instruction: String) {
        val ic = currentInputConnection
        keyboard?.showTranscript("")
        if (instruction.isBlank() || ic == null) { refreshContext(); return }
        val selection = selectedText()?.trim().orEmpty()
        if (!ensureCompletionRoute()) return
        val before = ic.getTextBeforeCursor(VoiceModes.CONTEXT_LIMIT, 0)?.toString().orEmpty()
        keyboard?.setHint(getString(R.string.hint_writing, engineLabel()), error = false)
        val generation = inputGeneration
        SmartCleanup.completeAsync(
            this, VoiceModes.HELP_WRITE_SYSTEM,
            VoiceModes.helpWriteUser(before, instruction, if (selection.isNotEmpty()) selection else "")
        ) { result ->
            keyboard?.showTranscript("")
            if (generation != inputGeneration) return@completeAsync
            result.onSuccess { reply ->
                val text = VoiceModes.cleanAnswer(reply).trim()
                if (text.isEmpty()) {
                    resetVoiceModeState(); keyboard?.setHint(getString(R.string.assistant_empty), error = true); return@onSuccess
                }
                // 等待期間的選取還在 → 插在選取之後；選取不見了 → 照游標處插入（別去改他的文字）。
                // 用目前選取的「原樣」文字（含前後空白）放回去，復原只刪產出的字，選取原文一字不少（luna-review B r2）。
                val rawNow = selectedText().orEmpty()
                val stillSelected = selection.isNotEmpty() && rawNow.trim() == selection
                ic.commitText(if (stillSelected) VoiceModes.insertAfterSelection(rawNow, text) else text, 1)
                rememberVoiceUndo(VoiceUndo(rewritten = text, original = "", insertEnd = cursorOffset(ic) ?: -1))
                logVoiceResult(instruction, text)
                showVoiceUndoCard(text)
            }.onFailure {
                Log.w(TAG, "help me write failed", it)
                resetVoiceModeState()
                keyboard?.setHint(editFailureMessage(it), error = true)
            }
        }
    }

    // ── 改寫（Speak to edit，沒有選取文字時）──

    /**
     * 沒有選取文字的改寫：使用者先選了「這一段」或「全部文字」，再講指令。
     *
     * 取代用 [android.view.inputmethod.InputConnection.deleteSurroundingText]（往前 back、往後 forward）
     * 而不是 setSelection——setSelection 要的是整份文件的絕對偏移，而我們只拿得到游標前後的相對文字，
     * 宿主截斷時那個絕對值根本推不出來。刪掉前後再插入，游標正好停在段落開頭。
     */
    private fun deliverSpeakToEdit(instruction: String) {
        val ic = currentInputConnection
        keyboard?.showTranscript("")
        val target = editTarget()
        pendingScope = null
        if (instruction.isBlank() || ic == null || target == null) {
            if (target == null && instruction.isNotBlank()) {
                resetVoiceModeState(); keyboard?.setHint(getString(R.string.assistant_all_unavailable), error = true)
            } else refreshContext()
            return
        }
        if (!ensureCompletionRoute()) return
        keyboard?.setHint(getString(R.string.hint_editing_scope, engineLabel()), error = false)
        val generation = inputGeneration
        SmartCleanup.completeAsync(
            this, VoiceModes.SPEAK_TO_EDIT_SYSTEM,
            VoiceModes.speakToEditUser(target.original, instruction)
        ) { result ->
            keyboard?.showTranscript("")
            if (generation != inputGeneration) return@completeAsync
            result.onSuccess { reply ->
                val rewritten = VoiceModes.cleanAnswer(reply).trim()
                if (rewritten.isEmpty()) {
                    resetVoiceModeState(); keyboard?.setHint(getString(R.string.assistant_empty), error = true); return@onSuccess
                }
                // 送去改寫的這一段還在原處才取代；使用者中途動過（移動游標、刪字）就不動他的文字。
                // 長度先驗（VoiceModes.targetStillThere 內做）：舊版 drop(負數) 會讓整個鍵盤崩掉。
                val w = cursorWindow()
                if (w == null || !VoiceModes.targetStillThere(w.before, w.after, target.back, target.forward, target.original)) {
                    // 文字變動就不取代，但別把使用者等的結果弄丟：改成回答卡把改好的內容顯示出來。
                    showAnswerCard(rewritten)
                    keyboard?.setHint(getString(R.string.assistant_text_changed), error = true)
                    return@onSuccess
                }
                ic.deleteSurroundingText(target.back, target.forward)
                ic.commitText(rewritten, 1)
                rememberVoiceUndo(VoiceUndo(rewritten, target.original, cursorOffset(ic) ?: -1))
                logVoiceResult(instruction, rewritten)
                showVoiceUndoCard(rewritten)
            }.onFailure {
                Log.w(TAG, "speak to edit failed", it)
                resetVoiceModeState()
                keyboard?.setHint(editFailureMessage(it), error = true)
            }
        }
    }

    // ── 問問題（Ask anything）──

    /**
     * 講問題 → 回答卡（可捲動）＋插入／複製／關閉。
     *
     * 有選取文字時模型可回 replace 取代選取，但**只有整個回應就是那個 JSON 才准取代**，
     * 其餘一律當回答（Mac 版踩過的坑，見 [VoiceModes.parseAskReply]）。
     * 取代前還要確認選取沒變，變了就改成回答卡。
     */
    private fun deliverAskAnything(question: String) {
        val ic = currentInputConnection
        keyboard?.showTranscript("")
        if (question.isBlank() || ic == null) { refreshContext(); return }
        val selection = selectedText()?.trim().orEmpty()
        val hasSelection = selection.isNotEmpty()
        if (hasSelection && !VoiceModes.selectionWithinLimit(selection)) {
            resetVoiceModeState(); keyboard?.setHint(getString(R.string.assistant_selection_too_long), error = true); return
        }
        if (!ensureCompletionRoute()) return
        keyboard?.setHint(getString(R.string.hint_asking, engineLabel()), error = false)
        val generation = inputGeneration
        val (system, user) = if (hasSelection) {
            VoiceModes.ASK_WITH_SELECTION_SYSTEM to VoiceModes.askWithSelectionUser(selection, question)
        } else {
            VoiceModes.ASK_ANYTHING_SYSTEM to VoiceModes.askAnythingUser(question)
        }
        SmartCleanup.completeAsync(this, system, user) { result ->
            keyboard?.showTranscript("")
            if (generation != inputGeneration) return@completeAsync
            result.onSuccess { reply ->
                val parsed = VoiceModes.parseAskReply(reply, hasSelection)
                if (parsed.isReplace) {
                    // 選取沒變才取代；變了就是使用者在我們送去改寫時動過手，改成回答卡。
                    if (VoiceModes.canReplace(selection, selectedText()?.trim().orEmpty())) {
                        ic.commitText(parsed.text, 1)
                        rememberVoiceUndo(VoiceUndo(parsed.text, selection, cursorOffset(ic) ?: -1))
                        logVoiceResult(question, parsed.text)
                        showVoiceUndoCard(parsed.text)
                        return@onSuccess
                    }
                }
                if (parsed.text.isBlank()) {
                    resetVoiceModeState(); keyboard?.setHint(getString(R.string.assistant_empty), error = true); return@onSuccess
                }
                showAnswerCard(parsed.text)
            }.onFailure {
                Log.w(TAG, "ask anything failed", it)
                resetVoiceModeState()
                keyboard?.setHint(editFailureMessage(it), error = true)
            }
        }
    }

    /** 沒有雲端 key 就不打任何網路，直接講清楚要去哪裡加（與既有改寫路徑同一句）。 */
    private fun ensureCompletionRoute(): Boolean {
        if (SmartCleanup.completionRoute(this) != null) return true
        resetVoiceModeState()
        keyboard?.setHint(getString(R.string.assistant_no_key), error = true)
        return false
    }

    /**
     * 寫語音功能的歷史。**丟到背景執行緒**——HistoryStore 會讀檔、加鎖、寫檔，
     * 在主執行緒做會卡住輸入法（review 抓到 :1147／:1203／:1249）。
     */
    private fun logVoiceResult(instruction: String, output: String) {
        val app = applicationContext
        cloudWorker.execute {
            runCatching { HistoryStore.append(app, instruction, output) }
                .onFailure { Log.w(TAG, "history append failed", it) }
        }
    }

    // ── 回答卡與復原 ──

    private fun showAnswerCard(text: String) {
        keyboard?.hideScopePicker()
        keyboard?.showAnswerCard(text)
        keyboard?.showModeRow(false)
        keyboard?.setHint(getString(R.string.hint_idle), error = false)
    }

    /** 幫我寫／改寫已經把文字插進欄位了，卡片唯一的用途是復原。 */
    private fun showVoiceUndoCard(text: String) {
        keyboard?.hideScopePicker()
        keyboard?.showUndoCard(text)
        keyboard?.showModeRow(false)
        keyboard?.setHint(getString(R.string.hint_idle), error = false)
    }

    private fun rememberVoiceUndo(record: VoiceUndo) { voiceUndo = record }

    private fun dismissAnswer() {
        keyboard?.hideAnswerCard()
        keyboard?.showModeRow(true)   // 卡片收起後模式切換列要回來
        voiceUndo = null
        refreshContext()
    }

    /** 插入回答卡的文字到游標處。 */
    private fun insertAnswerAtCursor(text: String) {
        if (text.isBlank()) return
        val ic = currentInputConnection ?: return
        ic.commitText(text, 1)
        rememberVoiceUndo(VoiceUndo(text, "", cursorOffset(ic) ?: -1))
        keyboard?.hideAnswerCard()
        keyboard?.showModeRow(true)
        refreshContext()
    }

    /** 複製回答卡的文字（不動輸入欄位）。 */
    private fun copyAnswer(text: String) {
        if (text.isBlank()) return
        val cm = getSystemService(android.content.ClipboardManager::class.java)
        cm?.setPrimaryClip(android.content.ClipData.newPlainText(getString(R.string.answer_card), text))
        keyboard?.setHint(getString(R.string.answer_copied), error = false)
    }

    /**
     * 復原剛插入／剛改寫的文字：刪掉剛寫的，再把原文補回去。
     *
     * 只留一次——使用者自己又動了欄位就作廢，不要復原到一個跟他現在看到的不一樣的狀態。
     *
     * 刪之前要**兩個條件都成立**（[VoiceModes.undoStillApplies]）：游標還停在插入的結尾、
     * 前文結尾就是插入的那段。舊版只看 endsWith：使用者把游標移到插入段中間、或前面有同樣的字時，
     * 會刪掉錯的那一段，而且原文還補回去，變成兩份。
     */
    private fun undoVoiceEdit() {
        val record = voiceUndo
        voiceUndo = null
        keyboard?.hideAnswerCard()
        keyboard?.showModeRow(true)
        if (record == null) { refreshContext(); return }
        val ic = currentInputConnection ?: return
        if (record.rewritten.isNotEmpty()) {
            val before = ic.getTextBeforeCursor(record.rewritten.length, 0)?.toString().orEmpty()
            val cursor = cursorOffset(ic) ?: -1
            if (!VoiceModes.undoStillApplies(before, cursor, record.insertEnd, record.rewritten)) {
                refreshContext()
                keyboard?.setHint(getString(R.string.hint_undo_unavailable), error = true)
                return
            }
            ic.deleteSurroundingText(record.rewritten.length, 0)
        }
        if (record.original.isNotEmpty()) ic.commitText(record.original, 1)
        syncAutoCapitalization()
        refreshContext()
        keyboard?.setHint(getString(R.string.hint_undone), error = false)
    }

    /** 智慧整理：背景送出剛貼上的這段，回來時游標前還是原文才換（使用者動過就不換）。 */
    private fun refine(inserted: String, raw: String, context: SmartCleanup.CleanupContext = SmartCleanup.CleanupContext(),
                       tone: FieldToneHint.Kind = FieldToneHint.infer(currentInputEditorInfo),
                       inputType: Int? = currentInputEditorInfo?.inputType) {
        if (!SmartCleanup.isEnabled(this)) return
        val id = chain.add(inserted)
        refining++
        keyboard?.setHint(getString(R.string.hint_refining), error = false)
        var request: CleanupCancellation? = null
        val cleanupRequest = SmartCleanup.clean(this, raw, { result ->
            request?.let(pendingCleanupRequests::remove)
            refining--
            val corrected = result?.let { fitField(it, tone, inputType) }
            var swapped = false
            val ic = currentInputConnection
            if (corrected != null && corrected != inserted && ic != null && chain.swap(ic, id, corrected)) {
                if (lastDictationOutput == inserted) lastDictationOutput = corrected   // 之後接著講要比對換過的文字
                learner.dictationInserted(corrected)
                swapped = true
            }
            if (!listening && refining == 0) {
                keyboard?.setHint(getString(if (swapped) R.string.hint_refined else R.string.hint_idle), error = false)
            }
        }, context = context, validationSource = inserted)
        request = cleanupRequest
        pendingCleanupRequests += cleanupRequest
    }

    private fun cancelPendingCleanups() {
        val requests = pendingCleanupRequests.toList()
        pendingCleanupRequests.clear()
        requests.forEach(CleanupCancellation::cancel)
    }

    /** 兩段之間重新開始聽（同一個辨識器、同一份請求）。要在回呼之外做：回呼裡直接 startListening 會 BUSY。 */
    private fun scheduleRestart(delayMillis: Long = 0) {
        restartPending = true
        mainHandler.removeCallbacks(restartRunnable)
        mainHandler.postDelayed(restartRunnable, delayMillis)
    }

    private fun restartRecognizer() {
        restartPending = false
        val s = session ?: return
        val r = recognizer
        val intent = activeIntent
        if (!listening || s.stopRequested || r == null || intent == null) return
        // 測試音檔：每段給一份複本（dup 共用讀取位置）。系統讀完一段可能把它拿到的那份關掉，原檔要留在我們手上。
        debugAudio?.let { intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, it.dup()) }
        r.startListening(intent)
    }

    /** 整次聽寫收尾：段落接好的文字走原本的輸出流程（雲端重辨識 → 整理 → 貼上，只貼一次）。 */
    private fun finishSession(text: String) {
        // 60 秒沒講話自動收尾、或出錯收尾時沒經過 stopListening：雲端錄音在這裡收。
        // 只在還在錄時才收——finishCloudRecording 對已停的錄音會把取好的樣本清掉。
        if (cloudRecorder.isActive) finishCloudRecording()
        session = null
        restartPending = false
        mainHandler.removeCallbacks(restartRunnable)
        runCatching { debugAudio?.close() }
        debugAudio = null
        listening = false
        keyboard?.setListening(false)
        keyboard?.showTranscript("")
        keyboard?.setHint(getString(R.string.hint_idle), error = false)
        // 沒有經過 stopListening（60 秒自動收尾、出錯）的路徑，在這裡補算秒數。
        freezeSessionSeconds()
        if (text.isEmpty()) { dropCloudRecording(); return }
        deliverWithCloud(text)
    }

    private val listener = object : RecognitionListener {
        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
            lastPartial = text
            // 停頓後即時結果會歸零、從下一句重來：交給 session 收起前一句（只預覽，不動輸入框）。
            keyboard?.showTranscript(session?.partial(text) ?: text)
        }

        override fun onResults(results: Bundle?) {
            // 有些情況最終結果是空的、字只在即時結果裡（音訊檔來源實測），這時用最後一次即時結果，不讓講的話消失。
            val final = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty().trim()
            val s = session
            // 這一段的完整文字：停頓前已經講完、但即時結果歸零而沒進最終結果的句子要接回來（模擬器實測會丟第一句）。
            val raw = s?.segmentText(final) ?: final.ifEmpty { lastPartial.trim() }
            lastPartial = ""
            restartRetries = 0
            // 系統聽到停頓就送出一段：使用者還沒按停 → 收起這段、繼續聽（2026-10-01 Micky：停頓一下就自動結束）。
            if (s != null && s.onSegment(raw) == ContinuousDictation.Next.RESTART) {
                keyboard?.showTranscript(s.preview())
                scheduleRestart()
                return
            }
            finishSession(s?.finish() ?: raw)
        }

        override fun onError(error: Int) {
            Log.w(TAG, "recognition error $error")
            val s = session
            if (s != null) {
                val pending = s.segmentText("")
                lastPartial = ""
                when (error) {
                    // 這一段沒聽到字（停頓太久）：不是錯，照樣繼續聽；按停了或太久沒講話才收尾。
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                        val next = if (pending.isNotEmpty()) s.onSegment(pending) else s.onSilence()
                        if (next == ContinuousDictation.Next.RESTART) { scheduleRestart(); return }
                        val text = s.finish()
                        if (text.isNotEmpty()) { finishSession(text); return }
                    }
                    // 剛結束一段馬上重開，辨識器偶爾回「忙碌」：稍等再試，三次都不行才照錯誤處理。
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_CLIENT ->
                        if (!s.stopRequested && listening && restartRetries < 3) {
                            // 剛取出的這段先收進 session 再重試，不然重試期間就丟了（review 指出）。
                            if (pending.isNotEmpty()) s.onSegment(pending)
                            restartRetries++
                            scheduleRestart(300L * restartRetries)
                            return
                        }
                }
                // 其他錯誤：前面已經聽到的字不能丟，照樣送出。
                val text = s.finish(pending)
                if (text.isNotEmpty()) { finishSession(text); return }
                session = null
            }
            listening = false
            freezeSessionSeconds()   // 出錯走雲端救援也要在這裡凍結秒數，不能把網路延遲算進去
            // 麥克風同時有兩個人在用（辨識器＋我們的錄音），系統有可能因此報錯。
            // 這種時候手上還有錄音就丟給雲端救；雲端也沒救回來才照原本的錯誤提示走。
            if (cloudRecorder.isActive) finishCloudRecording()
            if (cloudSamples?.isNotEmpty() == true && translateTarget == null) {
                keyboard?.setListening(false)
                keyboard?.showTranscript("")
                deliverWithCloud("") { showRecognitionError(error) }
                return
            }
            translateTarget = null
            resetVoiceModeState()
            dropCloudRecording()
            keyboard?.setListening(false)
            keyboard?.showTranscript("")
            showRecognitionError(error)
        }

        override fun onRmsChanged(rmsdB: Float) { keyboard?.setLevel(rmsdB) }
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}
