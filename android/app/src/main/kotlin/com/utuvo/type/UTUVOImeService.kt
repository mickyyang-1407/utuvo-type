package com.utuvo.type

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.utuvo.type.core.SpeechPunctuation
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
    private var activeCleanupContext = SmartCleanup.CleanupContext()
    /** 這一次錄音要翻成哪個語言（長按弧選的）；null＝一般聽寫。 */
    private var translateTarget: Translation.Target? = null
    /**
     * 這一次要錄的是什麼（同 iOS `KeyboardMode`）：有選取＝說出要怎麼改；長按滑到語言＝翻譯；其餘＝聽寫。
     * 開始錄音時定下來，宿主在我們改寫期間動了選取就整段作廢。
     */
    private var mode: KeyboardMode = KeyboardMode.Dictate
    private var ime: ImeSession? = null
    private val sessions = HashMap<ImeSession.Kind, ImeSession>()
    /** 這次組字按下來的按鍵序列：空白收回時要靠它重打回去（Android 的 ImeSession 沒有 snapshot）。 */
    private val composedKeys = StringBuilder()
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
    /** 雲端語音辨識（選配）：有開關、有 key、語言支援時才錄一份給雲端；失敗照用系統結果。 */
    private val cloudRecorder = CloudRecorder()
    /** 每次離開輸入框就加一：非同步結果回來時用它判斷還是不是同一個欄位。 */
    private var inputGeneration = 0
    private val cloudWorker = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "cloud-asr-worker").apply { isDaemon = true }
    }
    private var cloudSamples: FloatArray? = null
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

    override fun onCreateInputView(): View {
        val v = KeyboardView(this, object : KeyboardView.Listener {
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
            override fun onUndoInsert(text: String) = undoInsert(text)
            override fun onUndoCompose() = undoCompose()
            override fun onUndoDelete() = undoDelete()
            override fun onUndoSpace() = undoSpace()
        })
        keyboard = v
        return v
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        preloadFixers()
        // 每次叫出鍵盤從語音開始（打字是修正用的）。錄音中不切。
        // 提示也重設：錄音被中斷（鍵盤收起又叫出）時，否則會一直卡在「整理中…」（真機實測）。
        if (!listening) {
            switchSurface(KeyboardView.Surface.VOICE)
            keyboard?.showTranscript("")
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
        onDeviceRecognizer?.destroy()
        cloudRecognizer?.destroy()
        recognizer = null
        dropCloudRecording()
        cloudWorker.shutdownNow()
        englishSuggester?.destroy()
        englishSuggester = null
        super.onDestroy()
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
    }

    /** 打一個組字鍵；新的組字從頭開始記按鍵序列（空白收回時要重打回去）。 */
    private fun compose(key: Char) {
        if (ime?.isEmpty != false) composedKeys.clear()
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
        DictionaryStore.add(this, wrong, right)
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

    /**
     * 選取狀態一變，提示與光球顏色跟著變（同 iOS `refreshContext`）。
     * 有選取＝「說出要怎麼改」（光球薰衣草）；其餘＝一般聽寫。
     */
    private fun refreshContext() {
        if (listening) return
        val current = updateMode()
        // 走字串資源（簡中介面才翻得到）；文字與 KeyboardMode.idleHint／iOS KeyboardMode.idleHint 相同。
        val hint = when (current) {
            KeyboardMode.Dictate -> getString(R.string.hint_idle)
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
        val current = KeyboardMode.decide(selectedText(), translateTarget)
        mode = current
        keyboard?.setEditMode(current.isEdit)
        return current
    }

    private fun startListening() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            keyboard?.setHint(getString(R.string.hint_need_mic), error = true)
            // 鍵盤不能直接跳權限視窗：打開主 app 讓使用者授權。
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        commitComposition()
        // 選取／翻譯目標在按下光球的瞬間就定下來（開始錄音前 commitComposition 會動游標，重新判斷一次）。
        mode = KeyboardMode.decide(selectedText(), translateTarget)
        keyboard?.setEditMode(mode.isEdit)
        listening = true
        lastPartial = ""
        val editor = currentInputEditorInfo
        activeCleanupContext = if (SmartCleanup.includeAppContext(this) && editor != null && FieldShape.allowsContext(editor.inputType)) {
            val packageName = editor.packageName.orEmpty()
            val appName = runCatching {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString()
            }.getOrDefault("")
            val before = currentInputConnection?.getTextBeforeCursor(500, 0)?.toString().orEmpty()
            val appProfile = SmartCleanup.rememberApp(this, packageName, appName)
            SmartCleanup.CleanupContext(
                appName = appName,
                surroundingText = before,
                styleHint = FieldToneHint.prompt(editor).orEmpty(),
                appStyleHint = appProfile?.styleHint.orEmpty()
            )
        } else SmartCleanup.CleanupContext()
        if (translateTarget == null) SmartCleanup.warmUp(this)   // 講話的時候先連上智慧整理服務
        startCloudRecording()
        keyboard?.setListening(true)
        val intent = recognizeIntent()
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
                         inputType: Int? = currentInputEditorInfo?.inputType): String {
        val toned = FieldToneHint.apply(text, tone)
        val type = inputType ?: return toned
        return if (FieldShape.allowsLineBreaks(type)) toned else com.utuvo.type.core.OutputShape.singleLine(toned)
    }

    private fun recognizeIntent() = SpeechRequest.build(dictation().code, VocabularyPacks.biasing(this))

    private fun isTraditionalChinese(tag: String) =
        tag.equals("zh-TW", true) || tag.startsWith("cmn-Hant", true) || tag.startsWith("zh-Hant", true)

    /** 雲端 ASR 目前只做繁中（[CLOUD_LANGUAGE]）；換了聽寫語言就不是同一件事，不要走這條路。 */
    private fun cloudAsrAvailable() = dictation() == DictationLanguage.TRADITIONAL_CHINESE

    private fun beginCloud(intent: Intent) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            listening = false
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
        recognizer?.stopListening()
        finishCloudRecording()
        listening = false
        keyboard?.setListening(false)
        keyboard?.setHint(getString(R.string.hint_finishing), error = false)
    }

    // ── 雲端語音辨識（選配；失敗一律退回系統 SpeechRecognizer 的結果）──

    /** 開關＋key＋語言都對才錄音；翻譯模式不錄（那裡要的是翻好的文字，不是逐字稿）。錄不起來就當沒這回事。 */
    private fun startCloudRecording() {
        cloudSamples = null
        cloudKey = null
        cloudProvider = null
        if (translateTarget != null) return
        if (!cloudAsrAvailable()) return
        val language = CLOUD_LANGUAGE
        if (!CloudASR.isReady(this, language)) return
        val provider = SmartCleanup.provider(this)
        if (!cloudRecorder.start()) { Log.i(TAG, "cloud ASR recording unavailable, staying on system recognizer"); return }
        cloudKey = SmartCleanup.key(this, provider).orEmpty()
        cloudProvider = provider
    }

    /** 停聽時取回整段錄音；沒錄到就清空（後面就不會送網路）。 */
    private fun finishCloudRecording() {
        if (!cloudRecorder.isActive) { cloudSamples = null; return }
        cloudSamples = cloudRecorder.stop()
    }

    /** 使用者放棄（鍵盤收起、換模式、辨識出錯）→ 丟掉錄音。 */
    private fun dropCloudRecording() {
        cloudSamples = null
        cloudKey = null
        cloudProvider = null
        if (cloudRecorder.isActive) cloudRecorder.cancel()
    }

    /**
     * 系統結果到了：先取走這次的雲端錄音（只取一次，onResults 可能晚到）。
     * 有錄音就先問雲端，成功用雲端文字、失敗／逾時用系統原文；兩邊都走同一條輸出流程。
     */
    private fun deliverWithCloud(raw: String, onNothing: () -> Unit = {}) {
        val samples = cloudSamples
        val key = cloudKey
        val provider = cloudProvider
        cloudSamples = null; cloudKey = null; cloudProvider = null
        if (samples == null || samples.isEmpty() || key.isNullOrEmpty() || provider == null || translateTarget != null) {
            if (raw.isNotEmpty()) deliver(raw) else onNothing()
            return
        }
        if (cloudAsrRunning) { if (raw.isNotEmpty()) deliver(raw) else onNothing(); return }
        cloudAsrRunning = true
        keyboard?.setHint(getString(R.string.hint_cloud_listening), error = false)
        val hotwords = VocabularyPacks.biasing(this)
        val app = applicationContext
        val generation = inputGeneration
        cloudWorker.execute {
            val text = CloudASR.transcribe(samples, CLOUD_LANGUAGE, hotwords, provider, key,
                log = CloudASR.defaultLog(app), guard = { value, language, _ ->
                    // 雲端回來的中文可能是簡體；繁中要轉回來（與 iOS TranscriptGuard.clean 同一個理由）。
                    val converted = if (language.startsWith("zh-TW") || language.startsWith("zh-Hant")
                        || language.startsWith("zh-HK")) toTraditional(value) else value
                    CloudASR.trimGuard(converted, language, 0.0)
                })
            keyboard?.post {
                cloudAsrRunning = false
                // 使用者在等雲端的期間換了輸入框或收起鍵盤：不能貼到新的欄位去。
                if (generation != inputGeneration) return@post
                // 兩邊都沒東西就不要貼一個空字串出去（系統出錯時會走這裡）。
                if (text != null) deliver(text) else if (raw.isNotEmpty()) deliver(raw) else onNothing()
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

    /** 系統或雲端拿到的逐字稿走同一條輸出流程（整理 → 貼上 → 背景智慧整理）。 */
    private fun deliver(raw: String) {
        // 說出要怎麼改：raw 是指示，不是要貼上的內容。改寫完取代選取。
        if (mode is KeyboardMode.Edit) { deliverEdit(raw); return }
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
            fitField(SpeechPunctuation.restore(Dictation.clean(this, raw), field), tone, inputType)
        }
            .getOrElse { Log.e(TAG, "normalize failed, inserting raw transcript", it); raw }
        val target = translateTarget
        translateTarget = null
        mode = KeyboardMode.Dictate
        if (target == null) {
            currentInputConnection?.commitText(cleaned, 1)
            HistoryStore.append(this, raw, cleaned)
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
                val output = fitField(translated.trim(), tone, inputType)
                currentInputConnection?.commitText(output, 1)
                HistoryStore.append(this, raw, output)
            }.onFailure {
                Log.w(TAG, "translate to ${target.code} failed", it)
                keyboard?.setHint(getString(R.string.assistant_translate_failed, AssistantErrors.detail(it)), error = true)
                currentInputConnection?.commitText(cleaned, 1)
                HistoryStore.append(this, raw, cleaned)
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
            updateMode()
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
                    updateMode()
                    keyboard?.setHint(getString(R.string.assistant_selection_gone), error = true)
                    return@onSuccess
                }
                currentInputConnection?.commitText(rewritten, 1)
                HistoryStore.append(this, instruction, rewritten)
                refreshContext()
            }.onFailure {
                Log.w(TAG, "edit failed", it)
                updateMode()
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

    /** 智慧整理：背景送出剛貼上的這段，回來時游標前還是原文才換（使用者動過就不換）。 */
    private fun refine(inserted: String, raw: String, context: SmartCleanup.CleanupContext = SmartCleanup.CleanupContext(),
                       tone: FieldToneHint.Kind = FieldToneHint.infer(currentInputEditorInfo),
                       inputType: Int? = currentInputEditorInfo?.inputType) {
        if (!SmartCleanup.isEnabled(this)) return
        val id = chain.add(inserted)
        refining++
        keyboard?.setHint(getString(R.string.hint_refining), error = false)
        SmartCleanup.clean(this, raw, { result ->
            refining--
            val corrected = result?.let { fitField(it, tone, inputType) }
            var swapped = false
            val ic = currentInputConnection
            if (corrected != null && corrected != inserted && ic != null && chain.swap(ic, id, corrected)) {
                learner.dictationInserted(corrected)
                swapped = true
            }
            if (!listening && refining == 0) {
                keyboard?.setHint(getString(if (swapped) R.string.hint_refined else R.string.hint_idle), error = false)
            }
        }, context = context, validationSource = inserted)
    }

    private val listener = object : RecognitionListener {
        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
            lastPartial = text
            keyboard?.showTranscript(text)      // 只預覽，不動輸入框
        }

        override fun onResults(results: Bundle?) {
            listening = false
            keyboard?.setListening(false)
            // 有些情況最終結果是空的、字只在即時結果裡（音訊檔來源實測），這時用最後一次即時結果，不讓講的話消失。
            val final = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty().trim()
            val raw = final.ifEmpty { lastPartial.trim() }
            lastPartial = ""
            keyboard?.showTranscript("")
            keyboard?.setHint(getString(R.string.hint_idle), error = false)
            if (raw.isEmpty()) { dropCloudRecording(); return }
            deliverWithCloud(raw)
        }

        override fun onError(error: Int) {
            Log.w(TAG, "recognition error $error")
            listening = false
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
            mode = KeyboardMode.Dictate
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
