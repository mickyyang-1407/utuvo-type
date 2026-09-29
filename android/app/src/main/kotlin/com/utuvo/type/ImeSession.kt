package com.utuvo.type

import android.content.Context
import com.utuvo.type.core.PhraseAssociations
import com.utuvo.type.core.PinyinCandidate
import com.utuvo.type.core.PinyinEngine
import com.utuvo.type.core.PinyinLexicon
import com.utuvo.type.core.ZhuyinCandidate
import com.utuvo.type.core.ZhuyinEngine
import com.utuvo.type.core.ZhuyinLexicon
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * 詞庫：APK 裡以不壓縮方式打包的 .dat，直接 mmap（頁面按需載入、可被系統回收），不整包讀進記憶體。
 * 三份都第一次用到才開；開不起來回 null，鍵盤退回「原樣送出」。
 */
object Lexicons {
    @Volatile private var zhuyin: ZhuyinLexicon? = null
    @Volatile private var pinyin: PinyinLexicon? = null
    @Volatile private var pinyinHant: PinyinLexicon? = null
    @Volatile private var assocHans: PhraseAssociations? = null
    @Volatile private var assocHant: PhraseAssociations? = null

    private fun map(context: Context, name: String): ByteBuffer? = runCatching {
        context.assets.openFd(name).use { fd ->
            FileInputStream(fd.fileDescriptor).channel.use { ch ->
                ch.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
            }
        }
    }.getOrNull()

    @Synchronized fun zhuyin(c: Context) = zhuyin ?: map(c, "zhuyin.dat")?.let(ZhuyinLexicon::of).also { zhuyin = it }
    @Synchronized fun pinyin(c: Context) = pinyin ?: map(c, "pinyin.dat")?.let(PinyinLexicon::of).also { pinyin = it }
    @Synchronized fun pinyinHant(c: Context) = pinyinHant ?: map(c, "pinyin-hant.dat")?.let(PinyinLexicon::of).also { pinyinHant = it }
    @Synchronized fun assocHans(c: Context) = assocHans ?: map(c, "assoc-hans.dat")?.let(PhraseAssociations::of).also { assocHans = it }
    @Synchronized fun assocHant(c: Context) = assocHant ?: map(c, "assoc-hant.dat")?.let(PhraseAssociations::of).also { assocHant = it }
}

/**
 * 中文輸入工作階段（移植自 iOS `ios/Keyboard/ImeSession.swift`）：注音、簡體拼音、繁體拼音同一個介面。
 * 詞庫打不開就退回「原樣送出」，至少打得出字。
 */
class ImeSession(context: Context, val kind: Kind) {
    enum class Kind { ZHUYIN, PINYIN, PINYIN_HANT }

    /**
     * 候選列放的格數（同 iOS `ImeSession.keyboardCandidateLimit`）。
     * 注音簡拼時打 ㄋㄏ 會對到幾百個詞，八格不夠放到常用詞（你好 在 ㄋㄏ 排第十幾）；
     * 二十格仍只解碼看得到附近的候選，要看全部用 [allCandidates] 展開整頁。
     */
    val keyboardCandidateLimit = 20

    private val zhuyin: ZhuyinEngine? =
        if (kind == Kind.ZHUYIN) Lexicons.zhuyin(context)?.let(::ZhuyinEngine) else null
    private val pinyin: PinyinEngine? = when (kind) {
        Kind.PINYIN -> Lexicons.pinyin(context)?.let(::PinyinEngine)
        Kind.PINYIN_HANT -> Lexicons.pinyinHant(context)?.let(::PinyinEngine)
        Kind.ZHUYIN -> null
    }
    /** 選字／送出後可以接什麼（你好 → 嗎）。注音與繁體拼音用小麥注音的聯想詞表，簡體拼音用 rime 推導的同規則表。 */
    private val associations: PhraseAssociations? = when (kind) {
        Kind.PINYIN -> Lexicons.assocHans(context)
        else -> Lexicons.assocHant(context)
    }
    private val fallback = StringBuilder()
    private var shownZhuyin: List<ZhuyinCandidate> = emptyList()
    private var shownPinyin: List<PinyinCandidate> = emptyList()

    val isEmpty: Boolean get() = zhuyin?.isEmpty ?: pinyin?.isEmpty ?: fallback.isEmpty()

    /** 還有打到一半、沒標聲調的音（注音用；拼音沒有聲調，空白一律送出最佳轉換）。 */
    val hasComposing: Boolean
        get() = zhuyin?.let { it.composing.isNotEmpty() } ?: if (pinyin != null) false else fallback.isNotEmpty()

    val preedit: String get() = zhuyin?.preedit ?: pinyin?.preedit ?: fallback.toString()

    /** 整串送出時的文字（候選列第 0 格）。注音簡拼時輸入框顯示打的符號（preedit），送出的是轉換結果。 */
    val conversion: String get() = zhuyin?.conversion ?: pinyin?.preedit ?: fallback.toString()

    /** 剛送出 `text` 之後可以接的聯想詞（只回要接著插入的部分）。 */
    fun associationsAfter(text: String): List<String> =
        associations?.continuations(text, keyboardCandidateLimit) ?: emptyList()

    /** 句首候選；候選列第 0 格之後照這個順序。 */
    val candidates: List<String>
        get() {
            val n = keyboardCandidateLimit
            zhuyin?.let { shownZhuyin = if (it.isEmpty) emptyList() else it.candidates(n); return shownZhuyin.map { c -> c.text } }
            pinyin?.let { shownPinyin = if (it.isEmpty) emptyList() else it.candidates(n); return shownPinyin.map { c -> c.text } }
            return emptyList()
        }

    /**
     * 展開整頁候選字用的完整清單（引擎上限 60）。會換掉目前的候選對照表，
     * 之後 [select] 的索引以這份為準（同 iOS `allCandidates()`）。
     */
    fun allCandidates(): List<String> {
        zhuyin?.let {
            shownZhuyin = if (it.isEmpty) emptyList() else it.candidates(ZhuyinEngine.CANDIDATE_LIMIT)
            return shownZhuyin.map { c -> c.text }
        }
        pinyin?.let {
            shownPinyin = if (it.isEmpty) emptyList() else it.candidates(PinyinEngine.CANDIDATE_LIMIT)
            return shownPinyin.map { c -> c.text }
        }
        return emptyList()
    }

    /** 把引擎與 wrapper 的暫存全部清掉（已組好的音節、組到一半的字符、cached 候選）。 */
    fun reset() {
        zhuyin?.reset()
        pinyin?.reset()
        fallback.setLength(0)
        shownZhuyin = emptyList()
        shownPinyin = emptyList()
    }

    fun type(key: Char) {
        zhuyin?.let { it.type(key); return }
        pinyin?.let { it.type(key); return }
        fallback.append(key)
    }

    /**
     * 注音專屬：空白＝以一聲收尾正在組的音節。回 false（簡拼、沒打聲調、只有聲母）時
     * 呼叫端改成整串送出。拼音走 [commitAll]，不走這條。
     */
    fun space(): Boolean = zhuyin?.space() ?: false

    fun backspace(): Boolean {
        zhuyin?.let { return it.backspace() }
        pinyin?.let { return it.backspace() }
        if (fallback.isEmpty()) return false
        fallback.setLength(fallback.length - 1)
        return true
    }

    fun select(index: Int): String {
        zhuyin?.let { z -> shownZhuyin.getOrNull(index)?.let { return z.select(it) } }
        pinyin?.let { p -> shownPinyin.getOrNull(index)?.let { return p.select(it) } }
        return commitAll()
    }

    fun commitAll(): String {
        zhuyin?.let { return it.commitAll() }
        pinyin?.let { return it.commitAll() }
        return fallback.toString().also { fallback.setLength(0) }
    }
}
