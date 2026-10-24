package com.utuvo.type

import com.utuvo.type.core.EditScope
import com.utuvo.type.core.VoiceMode
import com.utuvo.type.core.VoiceModes

/**
 * 一次語音**按下光球那一刻**定下來的走向（mobile-keyboard-1）：結果晚到（雲端還在跑）時照**這一次**的走。
 *
 * 服務上的 mode／voiceMode／translateTarget／pendingScope／整理上下文是「現在」的狀態：
 * 下一次語音開始、下一次被 ✕ 取消（回到聽寫）、中途切換模式都會改它們。上一次還在等雲端的結果
 * 如果交付時才去讀，「幫我寫一封請假信」這種指示就會被當成聽寫原樣貼出去（verify r2 PROBE1/2）。
 */
internal data class TurnSnapshot(
    val mode: KeyboardMode,
    val voiceMode: VoiceMode,
    /** 改寫（沒有選取）時選好的「這一段／全部文字」。 */
    val scope: EditScope? = null,
    /** 智慧整理用的 app／欄位上下文（開始錄音時讀的）。 */
    val context: SmartCleanup.CleanupContext = SmartCleanup.CleanupContext(),
) {
    /** 長按弧選了語言＝翻譯（[KeyboardMode.decide] 裡翻譯優先，跟服務上的 translateTarget 同一件事）。 */
    val translateTarget: Translation.Target? get() = (mode as? KeyboardMode.Translate)?.target

    /** 一般聽寫（不是改寫、也不是幫我寫／改寫／問問題）：雲端退回裝置端文字時才講一聲。 */
    val dictating: Boolean get() = mode !is KeyboardMode.Edit && voiceMode == VoiceMode.DICTATE
}

/**
 * 一次語音（按光球開始 → 結果貼出）的狀態與身分證（mobile-keyboard-1）。純邏輯，JVM 測得到。
 *
 * 取消只作廢**這一次**：每次開始錄音拿一個新的 id，非同步結果（系統辨識器、雲端重辨識、翻譯、改寫）
 * 回來時先問 [isLive]。不能拿 inputGeneration 來作廢——那會連上一段還在背景跑的整理一起丟掉。
 *
 * ✕ 鍵在錄音中與整理中（按停之後、結果貼出之前）都要能按：[cancellable]。
 *
 * 每一次自己的東西（開始時的走向 [snapshot]、按停時算好的秒數 [seconds]）也記在這裡：
 * 一次的取消或收尾只動那一次自己的，不拆掉另一次還活著的流程。
 */
internal class VoiceTurns {
    enum class Phase { IDLE, RECORDING, PROCESSING }

    private var nextId = 0
    /** 最近一次開始的那一次（0＝還沒開始過）。 */
    var current = 0
        private set
    var phase = Phase.IDLE
        private set
    /** 被取消的 id（只留最近幾個；更早的結果早就回來了）。 */
    private val cancelled = ArrayDeque<Int>()
    /** 每一次開始時的走向與按停時的秒數（只留最近 [MAX_KEPT] 次）。 */
    private val snapshots = HashMap<Int, TurnSnapshot>()
    private val frozenSeconds = HashMap<Int, Int>()

    /** 開始錄音：新的一次。[snapshot]＝這一次的走向（交付時照它走，不讀服務上「現在」的模式）。 */
    fun start(snapshot: TurnSnapshot? = null): Int {
        current = ++nextId
        phase = Phase.RECORDING
        if (snapshot != null) snapshots[current] = snapshot
        val oldest = current - MAX_KEPT
        snapshots.keys.removeAll { it <= oldest }
        frozenSeconds.keys.removeAll { it <= oldest }
        return current
    }

    /**
     * 按停：錄音結束、等結果（✕ 還在）。只認 [id] 是現在這一次——
     * 上一次的辨識器晚到的收尾不能把新的一次從「錄音中」改成「整理中」。
     */
    fun stopped(id: Int = current) {
        if (id == current && phase == Phase.RECORDING) phase = Phase.PROCESSING
    }

    /** [id] 是不是最近開始的那一次（之後沒有新的一次開始）。 */
    fun isLatest(id: Int): Boolean = id == current

    /**
     * 辨識器回呼要不要處理：被取消的不要；已經有新的一次開始了也不要——
     * 舊辨識器晚到的結果會被併進新的一次的 session、把新的一次的錄音收掉。
     */
    fun accepts(id: Int): Boolean = isLatest(id) && isLive(id)

    /** 這一次開始時的走向（太舊或沒記就 null）。 */
    fun snapshot(id: Int): TurnSnapshot? = snapshots[id]

    /** 按停時算好的秒數（只記 > 0 的；之後別次的開始或取消不會改到它）。 */
    fun freezeSeconds(id: Int, seconds: Int) {
        if (seconds > 0 && id > current - MAX_KEPT) frozenSeconds[id] = seconds
    }

    fun seconds(id: Int): Int? = frozenSeconds[id]

    /** 這一次已經有結果（貼出、出錯、沒聽到）：✕ 收起來。舊的 id 不影響現在這一次。 */
    fun finish(id: Int) {
        if (id == current) phase = Phase.IDLE
    }

    /** 使用者按 ✕：作廢現在這一次；沒有在錄音或整理就回 null。 */
    fun cancel(): Int? {
        if (phase == Phase.IDLE) return null
        cancelled.addLast(current)
        while (cancelled.size > MAX_CANCELLED) cancelled.removeFirst()
        phase = Phase.IDLE
        return current
    }

    /** 這一次的結果還能不能用（沒被取消）。 */
    fun isLive(id: Int): Boolean = id !in cancelled

    /** ✕ 該不該出現。 */
    val cancellable: Boolean get() = phase != Phase.IDLE

    private companion object {
        const val MAX_CANCELLED = 16
        const val MAX_KEPT = 16
    }
}

/**
 * 一次性的復原：剛插入或剛改寫掉的文字。只留一次，再動一次就作廢。
 *
 * [insertEnd] 是插入／改寫**當下**的游標絕對位置（也就是剛寫的那段的結尾）。
 * 復原前要確認游標還停在這裡（[VoiceModes.undoStillApplies]），否則使用者自己動過位置，刪掉的就不是我們寫的那一段。
 */
internal data class VoiceUndo(
    val rewritten: String,
    val original: String,
    val insertEnd: Int,
    /** 一般聽寫：這段在 CorrectionChain 的 id（背景整理換字時跟著更新）；其他來源為 null。 */
    val chainId: Long? = null,
    /** 一般聽寫接在上一段後面時先補的前綴（[DictationJoin.prefix]：空白、「，」「、」；W2-7 起不補「。」）：復原要一起刪掉，換字時留在前面。 */
    val prefix: String = "",
    /** 這段插入之前記的上一段（文字＋拿掉的標點）：復原之後還原，下一段的接續判斷才對得上。 */
    val previousDictation: DictationJoin.Previous? = null,
    /** true＝語音區頂列的「復原」小鈕（一般聽寫、翻譯）；false＝幫我寫／改寫的復原卡。 */
    val chip: Boolean = false,
)

/** 一鍵復原要記什麼（delivery-learning-5、modes-5）。純邏輯，JVM 測得到。 */
internal object VoiceUndoPlan {
    /**
     * 一般聽寫插入之後：復原要刪的是「接續的前綴＋這段」，不然會留下一個多出來的空白／「，」「、」。
     * 什麼都沒插就不給復原。宿主報不出游標位置（[insertEnd] < 0，getExtractedText 回 null）也不給：
     * 那個「復原」小鈕按了永遠是「已無法復原」，不如不要出現。
     */
    fun forDictation(prefix: String, inserted: String, insertEnd: Int, chainId: Long?, previousDictation: DictationJoin.Previous?): VoiceUndo? {
        if (inserted.isEmpty() || insertEnd < 0) return null
        return VoiceUndo(prefix + inserted, "", insertEnd, chainId, prefix, previousDictation, chip = true)
    }

    /** 翻譯插入之後：有選取時翻譯取代了它，復原要把原本選取的文字放回去。報不出游標位置就不給（同 [forDictation]）。 */
    fun forTranslation(output: String, replacedSelection: String, insertEnd: Int): VoiceUndo? {
        if (output.isEmpty() || insertEnd < 0) return null
        return VoiceUndo(output, replacedSelection, insertEnd, chip = true)
    }

    /**
     * 按「復原」時能不能動手：沒有選取（[selectionStart] == [selectionEnd]，游標就停在插入結尾），
     * 而且前文就是剛寫的那段（[VoiceModes.undoStillApplies]）。
     *
     * 使用者插入之後又選了一段——就算選取剛好從插入結尾開始——就不復原：
     * deleteSurroundingText 刪的是選取**前面**的字，接著放回原文的 commitText 會把他新選的那段蓋掉。
     * [beforeText] 是選取起點前 [VoiceUndo.rewritten] 長度的字；位置都是整份文件的絕對 UTF-16 偏移（讀不到給 -1）。
     */
    fun canUndo(record: VoiceUndo, beforeText: String, selectionStart: Int, selectionEnd: Int): Boolean =
        selectionStart == selectionEnd &&
            VoiceModes.undoStillApplies(beforeText, selectionStart, record.insertEnd, record.rewritten)

    /**
     * 選取改寫（說出要怎麼改）回來時，選取還是原本那一段才取代——規則跟「問問題」取代選取的同一條
     * （[VoiceModes.canReplace]）。[currentRaw] 是宿主當下的選取原樣（可能帶前後空白），
     * [original] 是開始錄音時存的 trim 過的選取。
     */
    fun selectionUnchanged(original: String, currentRaw: String?): Boolean =
        VoiceModes.canReplace(original, currentRaw?.trim().orEmpty())

    /** 選取改寫取代之後：復原刪掉改寫結果、放回**原樣**的選取（含前後空白，一字不少）。 */
    fun forSelectionEdit(rewritten: String, replacedSelection: String, insertEnd: Int): VoiceUndo? {
        if (rewritten.isEmpty() || replacedSelection.isEmpty()) return null
        return VoiceUndo(rewritten, replacedSelection, insertEnd)
    }

    /**
     * 背景智慧整理把第 [swappedId] 段換成 [corrected] 之後，復原記錄要跟著更新，不然復原時對不上、按了沒作用。
     *  - 記的就是被換掉的那段 → 文字換成「接續的前綴＋更正版」、結尾位置換成換字後的游標。
     *  - 記的是後面那段（前面那段換字，後面的位置跟著移動）→ 只更新結尾位置。
     *  - 其他（不是聽寫的復原、或記的是更早的那段）→ 不動。
     * [newInsertEnd] 讀不到（null）就把位置設成未知，復原會被擋下，不會刪錯字。
     */
    fun afterRefine(record: VoiceUndo?, swappedId: Long, corrected: String, newInsertEnd: Int?): VoiceUndo? {
        val id = record?.chainId ?: return record
        if (id < swappedId) return record
        val end = newInsertEnd ?: -1
        return if (id == swappedId) record.copy(rewritten = record.prefix + corrected, insertEnd = end)
        else record.copy(insertEnd = end)
    }
}
