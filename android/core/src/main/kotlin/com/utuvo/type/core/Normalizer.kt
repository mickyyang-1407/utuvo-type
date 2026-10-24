package com.utuvo.type.core

import kotlin.math.pow

/**
 * UTUVO Type 的 deterministic 文字整理（移植自 Swift `UTUVOTypeCore/Normalizer.swift`）。
 *
 * 純函式：沒有 IO、沒有 SDK。行為以 Swift 版為準，由
 * `core/src/test/resources/golden/normalizer.json`（Swift 匯出的標準答案）逐條把關；
 * 兩邊要改規則就一起改，再重匯標準答案。
 */
data class NormalizedText(val original: String, val cleaned: String, val appliedSteps: List<String>)

data class NormalizerOptions(
    val dictionary: Map<String, String> = emptyMap(),
    val fillerSet: Set<String> = DEFAULT_FILLERS,
    val localeIdentifier: String = "zh_TW",
    /** 使用者自己的英文專名（個人字典＋開著的詞庫包）；給 LatinNameFixer 當比對目標。 */
    val latinTerms: List<String> = emptyList(),
    /**
     * 序數／明講數量的列舉改成「1. 」編號清單（同 Swift，2026-10-22 W2-6）。輸入框放不下換行（單行框）時關掉：
     * 接成一行的「1. 2.」比原本的逗號句難讀，照舊只切 list cue 的行（2026-10-22 修正）。
     */
    val numberedLists: Boolean = true,
) {
    companion object {
        /** 常見中文口述贅詞。刻意保持精簡——只有真的會被誤投進句子的。 */
        val DEFAULT_FILLERS: Set<String> = setOf(
            "嗯", "嗯嗯", "啊", "啊啊", "呃", "呃呃",
            "那個", "那個那個", "這個", "這個這個",
            "就是說", "就是說說", "然後那個", "對", "欸",
            // 「恩」是語音辨識把「嗯」寫錯的字；也是實詞（感恩、恩人），兩側都要是邊界才算（同 Swift）。
            "恩", "恩恩",
            // 簡體（規則與繁體相同）
            "那个", "那个那个", "这个", "这个这个", "就是说", "然后那个", "对",
        )
    }
}

class Normalizer(val options: NormalizerOptions = NormalizerOptions()) {

    fun normalize(text: String): NormalizedText = normalize(text, stopBefore = null)

    /** 測試用：跑到 `stopBefore` 這一關之前就回傳（同 Swift `normalize(_:stoppingBefore:)`）。 */
    internal fun normalize(text: String, stopBefore: String?): NormalizedText {
        var working = text
        val steps = mutableListOf<String>()
        fun stage(name: String, transform: (String) -> String) {
            working = transform(working)
            if (steps.lastOrNull() != name) steps.add(name)
        }

        stage("trim") { SwiftText.trim(foldSmallFormPunctuation(it)) }   // 同 Swift：小型標點先換成一般全形

        // 選取改寫的指令區塊要原樣交給 editor，不能當成一般聽寫的自我修正。
        if (InputFeatures.hasSelectedBlock(working)) {
            steps.add("selection-preserved")
            return NormalizedText(text, working, steps)
        }
        stage("spelled-letters") { joinSpelledLetters(it) }
        if (options.latinTerms.isNotEmpty()) stage("latin-names") {
            LatinNameFixer.fix(it, options.latinTerms, LatinNameFixer.TextSource.SPEECH, dictionaryRuleKeys(options.dictionary))
        }
        if (options.dictionary.isNotEmpty()) stage("dictionary") { applyDictionary(it, options.dictionary) }
        stage("filler") { removeFillers(it, options.fillerSet) }
        // 疊字收掉之後可能才露出完整的贅詞，再掃一次（同 Swift，2026-10-22 修正：normalize 要冪等）。
        // 連說兩次的改口詞（不對不對）在這裡被壓成一個，下一關要知道它原本連說過，先留一個看不見的記號（同 Swift）。
        stage("repeat") { input -> collapseRepeats(flaggingDoubledCorrections(input)).let { if (it == input) it else removeFillers(it, options.fillerSet) } }
        stage("self-correction") { applySelfCorrection(it) }
        stage("number-date-amount") { normalizeNumbers(it) }
        if (stopBefore == "list") return NormalizedText(text, working, steps)
        // 編號清單（同 Swift，2026-10-22 W2-6；第三輪改成保守規則）：符合條列規則的序數串 →「1. 」；明講數量的頓號列舉 → 編號清單。
        // 單行框（numberedLists = false）與已經分好段（有空行）的文字只切行、不編號。
        stage("list") {
            if (InputFeatures.hasMarkdown(it)) it
            else {
                val numbered = options.numberedLists && !it.contains("\n\n")
                val lined = normalizeListCues(it, numbered)
                if (numbered) numberCountedEnumerations(lined) else lined
            }
        }
        stage("punctuation") { normalizePunctuation(it) }
        stage("particles") { reattachParticles(it) }
        stage("mood") { SentenceMood.apply(it) }   // 同 Swift：問句「？」、感嘆「！」；最後句號由送出前拿掉
        stage("collapse-whitespace") { collapseWhitespace(it) }
        if (stopBefore == "paragraph") return NormalizedText(text, working, steps)
        // 有換行（清單／分段）的結果不會再經過 SentenceMood.finish 拿掉句尾吊著的「，」「、」，這裡收掉（同 Swift）。
        stage("paragraph") { dropDanglingEndOfLines(paragraphize(it)) }
        return NormalizedText(text, working, steps)
    }

    /** 用這個 normalizer 自己的字典與英文專名，只跑那兩關（同 Swift `applyVocabulary(_:)`）。 */
    fun applyVocabulary(text: String): String = applyVocabulary(text, options.dictionary, options.latinTerms)

    companion object {
        /**
         * Swift 的 NSRegularExpression 是 ICU：\\d、\\s 是 Unicode 語意。
         * - 電腦上的 JVM（java.util.regex）預設只有 ASCII，要加 (?U) 才一樣；
         * - Android 的 java.util.regex 底層就是 ICU（本來就是 Unicode 語意），而且**不認得 (?U)**，
         *   加了會 PatternSyntaxException（Pixel 7／Android 17 實測：辨識完整理文字就閃退）。
         * 所以執行時試一次：認得就加，不認得就不加。
         */
        private val unicodeFlag: String = runCatching { Regex("(?U)\\d"); "(?U)" }.getOrDefault("")

        internal fun icu(pattern: String) = Regex(unicodeFlag + pattern)

        /** 長度長的優先；同長度照字典序（Swift 版同長度的順序不固定，這裡固定下來）。 */
        private val longestFirst = compareByDescending<String> { SwiftText.count(it) }.thenBy { it }

        fun applyDictionary(text: String, dict: Map<String, String>): String = applyDictionary(text, dict, keepingExistingValues = false)

        /** `keepingExistingValues`：命中的位置本來就是完整字典值就跳過（同 Swift；給 applyVocabulary 用，一般 normalize 照舊）。 */
        internal fun applyDictionary(text: String, dict: Map<String, String>, keepingExistingValues: Boolean): String {
            if (dict.isEmpty()) return text
            var out = text
            for (key in dict.keys.sortedWith(longestFirst)) {
                val value = dict[key]
                if (value.isNullOrEmpty()) continue
                out = replaceDictionaryTerm(out, key, value, keepingExistingValues)
            }
            return out
        }

        /**
         * 只跑「英文專名＋個人字典」兩關（同 Swift applyVocabulary，asr-vocab-2）：給智慧整理回來的文字補套使用者的詞，
         * 不重跑贅詞、改口、數字、條列、分段。冪等：命中的地方已經是完整字典值就跳過。
         */
        fun applyVocabulary(text: String, dictionary: Map<String, String>, latinTerms: List<String>): String {
            var out = text
            // 英文專名用 CLEANUP 規則（同 Swift，W2-1 verifier）：模型寫對的英文不准被拉成個人詞或改大小寫。
            if (latinTerms.isNotEmpty()) {
                out = LatinNameFixer.fix(out, latinTerms, LatinNameFixer.TextSource.CLEANUP, dictionaryRuleKeys(dictionary))
            }
            return applyDictionary(out, dictionary, keepingExistingValues = true)
        }

        /**
         * 個人字典裡真的會換字的規則（輸出不是空字串、也不等於自己）的 key（同 Swift `dictionaryRuleKeys`）：
         * 英文專名修正原樣留給字典那一關，明確規則先於模糊比對。
         */
        internal fun dictionaryRuleKeys(dictionary: Map<String, String>): Set<String> =
            dictionary.filter { (k, v) -> v.isNotEmpty() && k != v }.keys

        /**
         * 智慧整理回來的文字要補套的英文專名目標（同 Swift `latinTermsForCleanedText`，asr-vocab-2 接線）：
         * 個人字典的寫法全部保留，詞庫包的詞只留多字詞（Pro Tools、Claude Code）。單字的包內詞已經在整理提示詞裡給過模型，
         * 而且太短、加權距離會撞到一般英文（模型寫對的 glad、cloud 會被改成 Claude）。
         */
        fun latinTermsForCleanedText(personal: List<String>, packTerms: List<String>): List<String> =
            (personal + packTerms.filter { it.contains(' ') }).filter { it.isNotEmpty() }.distinct()

        /**
         * 字典詞左側可以緊接中文（「我去台藝大」），右側若仍是文字＝更長詞的一部分，保留原文。
         * 例外是拼音文字詞（pik）：語音辨識常把英文黏在中文前後（「用pik播放器」），
         * 這時只有同樣是拼音文字的字元才算「更長的詞」（pika、apik），中文是邊界。
         */
        internal fun replaceDictionaryTerm(text: String, target: String, replacement: String): String =
            replaceDictionaryTerm(text, target, replacement, keepingExistingValue = false)

        internal fun replaceDictionaryTerm(text: String, target: String, replacement: String, keepingExistingValue: Boolean): String {
            val chars = SwiftText.graphemes(text)
            val t = SwiftText.graphemes(target)
            if (t.isEmpty()) return text
            val latinStart = isAlphabeticWordChar(t.first())
            val latinEnd = isAlphabeticWordChar(t.last())
            val v = SwiftText.graphemes(replacement)
            // key 在 value 裡出現的位置：命中時往回對，看完整的 value 是不是已經在那裡。
            val offsetsInValue = if (keepingExistingValue && v.size >= t.size) {
                (0..(v.size - t.size)).filter { v.subList(it, it + t.size) == t }
            } else {
                emptyList()
            }
            val sb = StringBuilder(text.length)
            var i = 0
            while (i < chars.size) {
                val end = i + t.size
                if (end <= chars.size && chars.subList(i, end) == t) {
                    val leftBoundary = !latinStart || i == 0 || !isAlphabeticWordChar(chars[i - 1])
                    val rightBoundary = end == chars.size ||
                        !(if (latinEnd) isAlphabeticWordChar(chars[end]) else isTokenChar(chars[end]))
                    val valueAlreadyThere = offsetsInValue.any { offset ->
                        val start = i - offset
                        start >= 0 && start + v.size <= chars.size && chars.subList(start, start + v.size) == v
                    }
                    if (leftBoundary && rightBoundary && !valueAlreadyThere) {
                        sb.append(replacement)
                        i = end
                        continue
                    }
                }
                sb.append(chars[i])
                i++
            }
            return sb.toString()
        }

        /** 把 CJK 文字、英數字、底線當 token 字元；標點／空白不算。 */
        internal fun isTokenChar(g: String): Boolean {
            if (SwiftText.isLetter(g) || SwiftText.isNumber(g) || g == "_") return true
            return isCJKChar(g)
        }

        /** 拼音文字（拉丁等）的詞字元：token 字元裡扣掉 CJK／假名／諺文。 */
        internal fun isAlphabeticWordChar(g: String): Boolean = isTokenChar(g) && !isCJKChar(g)

        internal fun isCJKChar(g: String): Boolean {
            if (g.isEmpty()) return false
            val v = g.codePointAt(0)
            return v in 0x4E00..0x9FFF || v in 0x3400..0x4DBF || v in 0x3040..0x30FF || v in 0xAC00..0xD7AF
        }

        /** 兼作實詞、兩側都要是邊界才算贅詞。 */
        internal val bothSidesFillers = setOf("對", "這個", "对", "这个", "恩", "恩恩")
        /** 兼作實詞、至少一側要是「硬邊界」（句首句尾或標點，空白不算）才算贅詞。 */
        internal val hardSideFillers = setOf("那個", "這個這個", "那個那個", "然後那個", "那个", "这个这个", "那个那个", "然后那个")
        /**
         * 兼作句尾語氣詞、只有左邊是邊界（句首、標點、空白）才算贅詞（2026-09-25 Micky 實機：「當然啊」被刪成「當然」）。
         * 「啊，我忘了」「欸，你看」刪；「當然啊」「好啊」「不錯啊」「好欸」黏在字後面是語氣，留。
         */
        internal val leadingOnlyFillers = setOf("啊", "啊啊", "欸")

        private fun isHardBoundary(g: String) = SwiftText.isPunctuation(g) || SwiftText.isNewline(g)

        /** 同一行裡的空白（不含換行）：孤兒標點與限定詞判斷都跳過這些（同 Swift isInlineSpace）。 */
        internal fun isInlineSpace(g: String): Boolean = g == " " || g == "\t" || g == "\u3000" || g == "\u00A0"

        /** 英文字母或數字（半形、全形）：限定詞判斷用（同 Swift isLatinOrDigit）。 */
        internal fun isLatinOrDigit(g: String): Boolean {
            if (g.isEmpty()) return false
            val v = g.codePointAt(0)
            return v in 0x41..0x5A || v in 0x61..0x7A || v in 0x30..0x39 ||
                v in 0xFF10..0xFF19 || v in 0xFF21..0xFF3A || v in 0xFF41..0xFF5A
        }

        /** 結尾是「這個／那個」的贅詞，後面（跳過空白）接英文或數字＝限定詞（同 Swift isDeterminer）。 */
        internal fun isDeterminer(filler: String, chars: List<String>, index: Int): Boolean {
            if (listOf("這個", "那個", "这个", "那个").none { filler.endsWith(it) }) return false
            var next = index
            while (next < chars.size && isInlineSpace(chars[next])) next++
            return next < chars.size && isLatinOrDigit(chars[next])
        }

        /**
         * 句首的贅詞串（「嗯嗯，然後就是說，」「然後然後，呃，」）：只在串裡有純猶豫詞（嗯／呃／恩）或「就是說」、
         * 或「然後」後面緊接逗號時才拿掉；「然後就是這樣。」不動。同 Swift stripLeadingFillerChains。
         */
        private val leadingChainTokens = listOf("就是說", "就是说", "嗯嗯", "呃呃", "恩恩", "然後", "然后", "就是", "那個", "那个", "嗯", "呃", "恩")
        private val leadingChainHesitations = setOf("就是說", "就是说", "嗯嗯", "呃呃", "恩恩", "嗯", "呃", "恩")

        private fun isChainSeparator(g: String) = g == "，" || g == "," || g == "、" || isInlineSpace(g)

        internal fun stripLeadingFillerChains(chars: List<String>): MutableList<String> {
            val out = ArrayList<String>(chars.size)
            var index = 0
            var atSentenceStart = true
            while (index < chars.size) {
                if (atSentenceStart) {
                    if (isInlineSpace(chars[index])) {
                        out.add(chars[index])
                        index++
                        continue
                    }
                    atSentenceStart = false
                    val end = leadingChainEnd(chars, index)
                    if (end != null) {
                        index = end
                        continue
                    }
                }
                out.add(chars[index])
                if (chars[index] in setOf("。", "！", "？", "!", "?") || SwiftText.isNewline(chars[index])) atSentenceStart = true
                index++
            }
            return out
        }

        private class ChainItem(val token: String, val tokenEnd: Int, val separatorEnd: Int)

        /** 句首贅詞串要拿掉的結尾位置；不該拿就回 null。 */
        private fun leadingChainEnd(chars: List<String>, start: Int): Int? {
            val items = mutableListOf<ChainItem>()
            var position = start
            while (position < chars.size) {
                val token = leadingChainTokens.firstOrNull { token ->
                    val t = SwiftText.graphemes(token)
                    position + t.size <= chars.size && chars.subList(position, position + t.size) == t
                } ?: break
                val tokenEnd = position + SwiftText.count(token)
                var separatorEnd = tokenEnd
                while (separatorEnd < chars.size && isChainSeparator(chars[separatorEnd])) separatorEnd++
                items += ChainItem(token, tokenEnd, separatorEnd)
                position = separatorEnd
            }
            // 後面要接著實際內容（字或數字），整句都是贅詞的交給逐詞規則。
            if (position >= chars.size || !(SwiftText.isLetter(chars[position]) || SwiftText.isNumber(chars[position]))) return null
            val last = items.indexOfLast { item ->
                // 「恩」黏著下一個字可能是實詞（恩人），後面要有停頓才算猶豫詞。
                when {
                    item.token == "恩" || item.token == "恩恩" -> item.separatorEnd > item.tokenEnd
                    item.token in leadingChainHesitations -> true
                    else -> (item.token == "然後" || item.token == "然后") &&
                        item.tokenEnd < chars.size && (chars[item.tokenEnd] == "，" || chars[item.tokenEnd] == ",")
                }
            }
            if (last < 0) return null
            var end = last
            while (end + 1 < items.size) {
                val next = items[end + 1]
                if (next.separatorEnd <= next.tokenEnd || isDeterminer(next.token, chars, next.tokenEnd)) break
                end++
            }
            return items[end].separatorEnd
        }

        fun removeFillers(text: String, fillers: Set<String>): String {
            if (fillers.isEmpty()) return text
            val chars = stripLeadingFillerChains(SwiftText.graphemes(text))
            for (filler in fillers.sortedWith(longestFirst)) {
                val target = SwiftText.graphemes(filler)
                if (target.isEmpty()) continue
                var index = 0
                while (index + target.size <= chars.size) {
                    if (chars.subList(index, index + target.size) != target) {
                        index++
                        continue
                    }
                    val rightIndex = index + target.size
                    val leftBoundary = index == 0 || !isTokenChar(chars[index - 1])
                    val rightBoundary = rightIndex == chars.size || !isTokenChar(chars[rightIndex])
                    val leftHard = index == 0 || isHardBoundary(chars[index - 1])
                    val rightHard = rightIndex == chars.size || isHardBoundary(chars[rightIndex])
                    val isFiller = when {
                        // 「這個 delay」「那個 compressor」：後面接英文或數字＝限定詞，不是贅詞（同 Swift）。
                        isDeterminer(filler, chars, rightIndex) -> false
                        filler in bothSidesFillers -> leftBoundary && rightBoundary
                        filler in hardSideFillers -> leftHard || rightHard
                        filler in leadingOnlyFillers -> leftBoundary
                        else -> leftBoundary || rightBoundary
                    }
                    if (isFiller) {
                        repeat(target.size) { chars.removeAt(index) }
                        // 不留孤兒標點：「對，明天見」→「明天見」、「好，對，就這樣」→「好，就這樣」。
                        // 中間隔著空白也算（「嗯 ，我覺得」以前會剩「，我覺得」）。同 Swift。
                        var next = index
                        while (next < chars.size && isInlineSpace(chars[next])) next++
                        var previous = index - 1
                        while (previous >= 0 && isInlineSpace(chars[previous])) previous--
                        if (next < chars.size && SwiftText.isPunctuation(chars[next]) &&
                            (previous < 0 || SwiftText.isPunctuation(chars[previous]))
                        ) {
                            chars.removeAt(next)
                        }
                        continue
                    }
                    index++
                }
            }
            return chars.joinToString("")
        }

        private val phraseRepeat = icu("([\\u4E00-\\u9FFF]{2,8})\\1")
        private val pausedPhraseRepeat = icu("([\\u4E00-\\u9FFF]{3,8})[、，,\\s]+\\1")
        private val repeatableCharacters = setOf("我", "你", "他", "它", "這", "那", "是", "不", "就", "要", "很", "請", "等")

        /** 「我我覺得」→「我覺得」、「這樣這樣」→「這樣」；「看看」「今天天氣」保留。 */
        fun collapseRepeats(text: String): String {
            var working = text
            while (true) {
                val m = pausedPhraseRepeat.find(working) ?: break
                working = working.replaceRange(m.range, m.groupValues[1])
            }
            // 「不是,是」是明確改口，不要把「不是」末尾的「是」和後面的「是」當口吃合併。
            working = applyRegex(working, "(?<!不)([我你他它這那是不就要很請等])(?:[、，,\\s]+\\1)+(?=[\\u4E00-\\u9FFF]|[、，,\\s]|$)") { it[1] }
            while (true) {
                val m = phraseRepeat.find(working) ?: break
                working = working.replaceRange(m.range, m.groupValues[1])
            }
            val chars = SwiftText.graphemes(working)
            val sb = StringBuilder(working.length)
            var i = 0
            while (i < chars.size) {
                var j = i + 1
                while (j < chars.size && chars[j] == chars[i]) j++
                val negatedCopula = chars[i] == "是" && i > 0 && chars[i - 1] == "不"
                if (j - i >= 2 && chars[i] in repeatableCharacters && !negatedCopula) {
                    sb.append(chars[i]); i = j
                } else {
                    sb.append(chars[i]); i++
                }
            }
            return sb.toString()
        }

        private val correctionMarkerWords = listOf("我的意思是", "應該說", "我是說", "应该说")
        private val standaloneCorrections = listOf("啊不對", "喔不對", "哦不對", "噢不對", "不對不對", "不對", "不是不是", "不是", "說錯了", "講錯了", "说错了")
        private val copulaSubjects = listOf("這些", "那些", "這個", "那個", "我們", "你們", "他們", "她們", "它們", "這", "那", "它", "他", "她", "我", "你", "您")
        private val weekdayModifiers = listOf(
            "大後天的", "明天的", "昨天的", "後天的",
            "大後天", "明天", "昨天", "後天", "下個", "這個", "上個", "下", "這", "上",
        )

        private fun isCorrectionWhitespace(ch: Char): Boolean =
            ch in '\t'..'\r' || ch == ' ' || ch == '\u0085' || ch == '\u00A0' || ch == '\u1680' ||
                ch in '\u2000'..'\u200A' || ch == '\u2028' || ch == '\u2029' || ch == '\u202F' ||
                ch == '\u205F' || ch == '\u3000'

        private fun trimCorrectionWhitespace(text: String): String {
            var start = 0
            var end = text.length
            while (start < end && isCorrectionWhitespace(text[start])) start++
            while (end > start && isCorrectionWhitespace(text[end - 1])) end--
            return text.substring(start, end)
        }

        /**
         * 把關（CleanupFidelity.prepareSource）用：它先把每個改口詞都補上逗號，看不出原本有沒有停頓，
         * 所以「不對」類與「我是說」都照沒訊號的規則（C2，只認值換值）。第一次貼上走 valueOnly = false（同 Swift）。
         */
        internal fun correctionMarkers(text: String): String = correctionMarkers(text, valueOnly = true)

        internal fun correctionMarkers(text: String, valueOnly: Boolean): String {
            var out = text
            repeat(5) {
                val hit = findCorrection(out) ?: return out
                val (clauseStart, comma, afterMarker) = hit
                val old = out.substring(clauseStart, comma)
                val rawRest = out.substring(afterMarker).dropWhile { it == '，' || it == ',' || isCorrectionWhitespace(it) }
                // 只有「不對」類與「我是說」照 C2；「不是」與其他改口詞照原本的規則。
                if (valueOnly) {
                    val marker = trimCorrectionWhitespace(out.substring(comma + 1, afterMarker))
                    if ((marker.contains("不對") || marker == "我是說") && !isValueForValueCorrection(old, rawRest)) return out
                }
                val rest = stripCorrectionLead(rawRest)
                val (replacement, suffix) = splitCorrectionPayload(rest) ?: return out
                val corrected = alignCorrection(old, replacement) ?: return out
                out = out.substring(0, clauseStart) + corrected + suffix
            }
            return out
        }

        private fun stripCorrectionLead(text: String): String {
            var value = trimCorrectionWhitespace(text)
            val leads = listOf("就是啊", "就是", "是", "啊", "欸", "诶")
            repeat(3) {
                val lead = leads.firstOrNull { value.startsWith(it) } ?: return trimCorrectionWhitespace(value)
                value = value.removePrefix(lead)
            }
            return trimCorrectionWhitespace(value)
        }

        private fun splitCorrectionPayload(text: String): Pair<String, String>? {
            val boundaries = setOf('，', ',', '。', '！', '？', '!', '?', '\r', '\n')
            val boundary = text.indexOfFirst { it in boundaries }
            if (boundary < 0) {
                val value = trimCorrectionWhitespace(text)
                return if (value.isEmpty()) null else value to ""
            }
            val value = trimCorrectionWhitespace(text.substring(0, boundary))
            return if (value.isEmpty()) null else value to text.substring(boundary)
        }

        /** Replace only a confidently aligned value in the old clause; keep surrounding words intact. */
        private fun alignCorrection(old: String, replacement: String): String? {
            val relativeDays = listOf("大後天", "前天", "後天", "昨天", "今天", "明天")
            for (newDay in relativeDays.filter { replacement.startsWith(it) }) {
                for (oldDay in relativeDays.filter { it != newDay }) {
                    val at = old.lastIndexOf(oldDay)
                    if (at < 0) continue
                    val newSuffix = replacement.substring(newDay.length)
                    replaceAlignedToken(old, at until at + oldDay.length, newDay, newSuffix)?.let { return it }
                }
            }

            // Stable weekday prefix and one-character value: 星期三 → 星期四, 禮拜三 → 禮拜四.
            val weekday = Regex("(星期|禮拜|週|周)([一二三四五六日天])")
            val oldDays = weekday.findAll(old).toList()
            val newDays = weekday.findAll(replacement).toList()
            for (newDay in newDays) {
                val newPrefix = newDay.groups[1]?.value ?: continue
                val newLead = replacement.substring(0, newDay.range.first)
                val newModifier = weekdayModifiers.firstOrNull { newLead.endsWith(it) } ?: ""
                for (oldDay in oldDays.asReversed()) {
                    if (oldDay.groups[1]?.value != newPrefix) continue
                    val oldModifier = if (newModifier.isEmpty()) {
                        ""
                    } else {
                        weekdayModifiers.firstOrNull { old.substring(0, oldDay.range.first).endsWith(it) } ?: ""
                    }
                    val oldExpressionRange = (oldDay.range.first - oldModifier.length)..oldDay.range.last
                    val newSuffix = replacement.substring(newDay.range.last + 1)
                    replaceAlignedToken(old, oldExpressionRange, newModifier + newDay.value, newSuffix)?.let { return it }
                }
            }

            // Numeric and version tokens align when their non-numeric shape matches (48K → 96K, V3 → V4).
            // 小數是一整個值（C3，同 Swift）：44.1K → 48K、1.5倍 → 2倍、1.2 → 1.3。
            // 鐘點「3:30」也是一整個值（同 Swift，FX-6 T2）；緊貼「數字:」的數字不單獨當一個值。
            // 小數＋位值也是一整個值（同 Swift，FX-8 D2／D4）：「一點五萬」「三點五千」「兩點八百」不拆成「一點」＋「五萬」，
            // 形狀「#點#」只跟小數對齊；小數對整數（兩萬）或整點（四點）對不上＝整句照講的留著。
            val token = Regex("""(?<![A-Za-z0-9_])(?<![0-9][:：])(?:[0-9]{1,2}[:：][0-9]{2}|[零〇一二三四五六七八九十兩两]+[點点][零〇一二三四五六七八九]{1,3}[百千萬万億亿](?![0-9零〇一二三四五六七八九十百千萬万億亿兩两])|[A-Za-z_]*[0-9]+(?:\.[0-9]+)*[A-Za-z0-9_]*|[0-9零〇一二三四五六七八九十百千萬万億亿兩两]+(?:點|点|樓|楼|層|层|號|号|塊|块|元|K|k)?)(?![A-Za-z0-9_])(?![:：][0-9])""")
            val numberRun = Regex("""[0-9]+(?:\.[0-9]+)+|[0-9零〇一二三四五六七八九十百千萬万億亿兩两]+""")
            val oldTokens = token.findAll(old).toList()
            val newTokens = token.findAll(replacement).toList()
            for (newMatch in newTokens) {
                if (startsWithWeekdayDigit(replacement, newMatch.range)) continue
                val newToken = newMatch.value
                val newShape = newToken.replace(numberRun, "#").lowercase()
                for (oldMatch in oldTokens.asReversed()) {
                    // FX-8 D1（同 Swift）：「禮拜五三點」的值是「三點」，星期幾那個字留在值外面。
                    // FX-12 C1（同 Swift）：第N 後接鐘點時，序數的一～九也留在值外面；第十N／第二十照舊。
                    val hasOrdinalClock = startsWithOrdinalClockDigit(old, oldMatch.range)
                    val oldRange = if (startsWithWeekdayDigit(old, oldMatch.range) || hasOrdinalClock)
                        (oldMatch.range.first + 1)..oldMatch.range.last else oldMatch.range
                    val oldToken = old.substring(oldRange.first, oldRange.last + 1)
                    val oldShape = oldToken.replace(numberRun, "#").lowercase()
                    val sameNumberWithAddedUnit = newToken.startsWith(oldToken) && newToken.length > oldToken.length
                    if (oldShape != newShape && !sameNumberWithAddedUnit) continue
                    val newSuffix = replacement.substring(newMatch.range.last + 1)
                    clockHourCorrection(old, oldRange, newToken, newSuffix)?.let { return it.result }
                    replaceAlignedToken(old, oldRange, newToken, newSuffix)?.let {
                        // C1（同 Swift）：鐘點先獨立讀完，避免序數又被數字關併入鐘點。
                        if (hasOrdinalClock) {
                            val prefix = old.substring(0, oldRange.first)
                            return prefix + normalizeNumbers(it.substring(prefix.length))
                        }
                        return it
                    }
                }
            }

            // Shared opening phrase aligns short edits such as 小雅跟小博 → 小雅跟小潘.
            val newCharacters = SwiftText.graphemes(replacement)
            if (newCharacters.size < 2) return null
            for (length in newCharacters.size downTo 2) {
                val anchor = newCharacters.take(length).joinToString("")
                val at = old.lastIndexOf(anchor)
                if (at < 0) continue
                val oldTail = old.substring(at + anchor.length)
                val newTail = newCharacters.drop(length).joinToString("")
                // A longer unmatched tail may be context, so decline instead of deleting it.
                if (SwiftText.count(oldTail) > SwiftText.count(newTail) + 1 || newTail.isEmpty()) continue
                return old.substring(0, at) + anchor + newTail
            }
            // A one-grapheme shared opening also anchors a correction: 剛上去 → 剛出門.
            // 單字錨點只認虛詞／副詞（同 Swift singleCharAnchors）。
            val anchor = newCharacters.firstOrNull() ?: return null
            if (anchor !in SINGLE_CHAR_ANCHORS) return null
            val at = old.lastIndexOf(anchor)
            if (at < 0) return null
            val oldTail = old.substring(at + anchor.length)
            val newTail = newCharacters.drop(1).joinToString("")
            if (SwiftText.count(oldTail) > SwiftText.count(newTail) + 1 || newTail.isEmpty()) return null
            return old.substring(0, at) + anchor + newTail
        }

        private val SINGLE_CHAR_ANCHORS = setOf("剛", "在", "去", "到", "要", "是", "給", "跟", "把", "從", "往", "用", "叫", "先", "再", "就", "還", "也", "都", "會", "想", "和", "對")

        /**
         * FX-8 D1（同 Swift startsWithWeekdayDigit）：值的第一個字是緊跟在「星期／禮拜／礼拜／週／周」後面的星期幾（一～六）、
         * 後面還接數字、而且是「N點」（鐘點或小數）＝那個字是星期幾，不是鐘點的一部分。不帶「點」的（每週三十個）照舊。
         */
        /** FX-12 C1（同 Swift）：只有第＋一個一～九＋鐘點才拆序數，非鐘點與第十N照舊。 */
        private fun startsWithOrdinalClockDigit(text: String, range: IntRange): Boolean {
            val value = text.substring(range.first, range.last + 1)
            return value.any { it == '點' || it == '点' } && ordinalMerges(value, text.substring(0, range.first))
        }

        private fun startsWithWeekdayDigit(text: String, range: IntRange): Boolean {
            if (range.last - range.first < 1) return false
            val value = text.substring(range.first, range.last + 1)
            if (value[0] !in "一二三四五六" || value[1] !in "零〇一二三四五六七八九十兩两" || value.none { it == '點' || it == '点' }) return false
            // FX-12 C2（同 Swift）：十位小數＋明確數量單位是每週的數量，不拆星期幾。
            val tail = text.substring(range.last + 1)
            if (value[1] == '十' && (value.last() == '點' || value.last() == '点') &&
                Regex("^[零〇一二三四五六七八九]{1,3}(?:個?小時|公里|公斤|分鐘)").containsMatchIn(tail)) return false
            val before = text.substring(0, range.first)
            return listOf("星期", "禮拜", "礼拜", "週", "周").any { before.endsWith(it) }
        }

        /** Keep an existing tail when it agrees with the replacement; decline mismatched tails. */
        private fun replaceAlignedToken(old: String, range: IntRange, token: String, suffix: String): String? =
            joinAligned(old.substring(0, range.first), token, old.substring(range.last + 1), suffix)

        private fun joinAligned(prefix: String, token: String, oldSuffix: String, suffix: String): String? {
            if (suffix.isEmpty() || oldSuffix.contains(suffix)) return prefix + token + oldSuffix
            if (oldSuffix.isEmpty() || suffix.endsWith(oldSuffix)) return prefix + token + suffix
            return null
        }

        /** 鐘點的分鐘（同 Swift clockMinutes，FX-6 T1）：半、一刻／三刻、N分（不是「分鐘」）、不帶「分」的十五／四十／零五。 */
        private val clockMinutes = Regex("""\A(?:半|[一三]刻|[0-9]{1,2}分(?!鐘)|[零〇一二三四五六七八九十]{1,3}分(?!鐘)|(?:[二三四五]?十[一二三四五六七八九]?|[零〇][一二三四五六七八九])(?![零〇一二三四五六七八九十百千萬万億亿兩两0-9.分秒個个位人塊块元倍度]))""")

        /** 是「舊值有分鐘、新值只有整點」這種形狀時的結果；result = null＝讀不出鐘點或對不齊，整句照講的留著。 */
        private class ClockCorrection(val result: String?)

        /**
         * FX-6 T1（同 Swift clockHourCorrection）：舊值「N點＋分鐘」、新值只有整點 → 整個舊時間換成「H:00」。
         * 不是這種形狀回 null，照原本的對齊。
         */
        private fun clockHourCorrection(old: String, oldRange: IntRange, newToken: String, newSuffix: String): ClockCorrection? {
            fun isPoint(c: Char) = c == '點' || c == '点'
            var oldHour = old.substring(oldRange.first, oldRange.last + 1)
            var oldRest = old.substring(oldRange.last + 1)
            when {
                oldHour.isNotEmpty() && isPoint(oldHour.last()) -> oldHour = oldHour.dropLast(1)
                oldRest.isNotEmpty() && isPoint(oldRest.first()) -> oldRest = oldRest.drop(1)
                else -> return null
            }
            var newHour = newToken
            var newRest = newSuffix
            when {
                newHour.isNotEmpty() && isPoint(newHour.last()) -> newHour = newHour.dropLast(1)
                newRest.isNotEmpty() && isPoint(newRest.first()) -> newRest = newRest.drop(1)
                else -> return null
            }
            val minutes = clockMinutes.find(oldRest)?.value ?: return null
            if (clockMinutes.find(newRest) != null) return null
            val oh = chineseToInt(oldHour)
            val nh = chineseToInt(newHour)
            if (oh == null || oh !in 0..24 || nh == null || nh !in 0..24) return ClockCorrection(null)
            return ClockCorrection(joinAligned(old.substring(0, oldRange.first), "$nh:00", oldRest.substring(minutes.length), newRest))
        }

        private fun findCorrection(s: String): Triple<Int, Int, Int>? {
            val breakers = setOf('，', ',', '。', '！', '？', '!', '?', '\r', '\n')
            for (marker in standaloneCorrections) {
                var from = 0
                while (true) {
                    val r = s.indexOf(marker, from)
                    if (r < 0) break
                    val end = r + marker.length
                    var beforeMarker = r
                    while (beforeMarker > 0 && isCorrectionWhitespace(s[beforeMarker - 1])) beforeMarker--
                    var afterMarker = end
                    while (afterMarker < s.length && isCorrectionWhitespace(s[afterMarker])) afterMarker++
                    val before = beforeMarker > 0 && (s[beforeMarker - 1] == '，' || s[beforeMarker - 1] == ',')
                    val after = afterMarker < s.length && (s[afterMarker] == '，' || s[afterMarker] == ',')
                    if (before && after) {
                        val comma = beforeMarker - 1
                        var start = comma
                        while (start > 0 && s[start - 1] !in breakers) start--
                        if (start < comma) return Triple(start, comma, end)
                    }
                    from = end
                }
            }
            for (marker in correctionMarkerWords) {
                var from = 0
                while (true) {
                    val r = s.indexOf(marker, from)
                    if (r < 0) break
                    var p = r
                    while (p > 0 && isCorrectionWhitespace(s[p - 1])) p--
                    if (p > 0 && (s[p - 1] == '，' || s[p - 1] == ',')) {
                        val comma = p - 1
                        var start = comma
                        while (start > 0 && s[start - 1] !in breakers) start--
                        if (start < comma) return Triple(start, comma, r + marker.length)
                    }
                    from = r + marker.length
                }
            }
            return null
        }

        private val repairFillers = setOf("哦", "噢", "呃")
        private val pronounStarts = setOf("我", "你", "妳", "您", "他", "她", "它")

        /** 「剛上去哦剛出門」→「剛出門」（同 Swift repairAfterFiller）。 */
        internal fun repairAfterFiller(text: String): String {
            val chars = SwiftText.graphemes(text).toMutableList()
            var i = 1
            while (i < chars.size - 1) {
                val next = chars[i + 1]
                if (chars[i] in repairFillers && isHanChar(next) && next !in pronounStarts) {
                    var j = i - 1
                    var found = -1
                    while (j >= 0 && i - j <= 4 && isHanChar(chars[j])) {
                        if (chars[j] == next) { found = j; break }
                        j--
                    }
                    if (found >= 0 && i - found >= 2) {
                        for (k in i downTo found) chars.removeAt(k)
                        i = found
                        continue
                    }
                }
                i++
            }
            return chars.joinToString("")
        }

        private fun isHanChar(g: String) = g.isNotEmpty() && isCJKChar(g)

        private val timeShape = "(?<![\\d.])([01]?\\d|2[0-3])\\.([0-5]\\d)(?![\\d.])"
        private val timeAfter = listOf("的時候", "的时候", "時", "左右", "前", "後", "那班", "出門", "開始", "到", "準時", "整")
        private val timeBefore = listOf("早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "大概", "約")

        /** 「5.49的時候」→「5:49」，同段一模一樣的數字一起改（同 Swift decimalTimes）。 */
        private val chineseDigit = mapOf("一" to 1, "二" to 2, "三" to 3, "四" to 4, "五" to 5, "六" to 6, "七" to 7, "八" to 8, "九" to 9)

        internal fun decimalTimes(input: String): String {
            // 辨識器把「四十二」拆開：「7:4。12」、「7.40二」→ 先接回（同 Swift）。
            var text = applyRegex(input, "(?<![\\d.:])(\\d{1,2})[:.]([1-5])[，。、\\s]*1([0-9])(?![\\d.])") { g -> "${g[1]}:${g[2]}${g[3]}" }
            // 「40二」只在那個中文數字後面就收尾（結尾、標點、或 timeAfter 的時間字、後面不再接數字）才接回（同 Swift，FX-6 T3）：
            // 整理過的「11:30二萬」「3:30一分鐘」「1:30八 ms」「3:30一起去」再整理一次不會被讀成別的數。「一」不接。
            val closers = timeAfter.joinToString("|")
            text = applyRegex(text, "(?<![\\d.:])(\\d{1,2})([:.])([1-5])0([二三四五六七八九])(?=$|[，。、,!?！？；;]|(?:$closers)(?![零〇一二三四五六七八九十百千萬億兩\\d]))") { g -> "${g[1]}${g[2]}${g[3]}${chineseDigit[g[4]] ?: 0}" }
            val re = icu(timeShape)
            val times = mutableSetOf<String>()
            for (m in re.findAll(text)) {
                val tail = text.substring(m.range.last + 1).trimStart(' ', '\t')
                val head = text.substring(maxOf(0, m.range.first - 4), m.range.first)
                if (timeAfter.any { tail.startsWith(it) } || timeBefore.any { head.contains(it) }) times += m.value
            }
            if (times.isEmpty()) return text
            return applyRegex(text, timeShape) { g -> if (g[0] in times) "${g[1]}:${g[2]}" else g[0] }
        }

        fun applySelfCorrection(text: String): String =
            applyExplicitNotCorrection(repairAfterFiller(correctionMarkers(unpunctuatedCorrections(text), valueOnly = false)))

        /**
         * 改口詞後面沒停頓（「48k，不對是96k」）：借把關的補逗號規則，對得齊、改得掉才採用；否則原樣。同 Swift。
         * 不能當改口的改口詞（C1 描述詞、沒訊號又不是值換值，見 maskingUnresolvableMarkers）先遮起來。
         */
        internal fun unpunctuatedCorrections(flagged: String): String {
            // 連說記號（repeat 關留下的）只在判斷訊號時用，之後一律拿掉。
            val text = if (flagged.contains(DOUBLED_FLAG)) flagged.replace(DOUBLED_FLAG.toString(), "") else flagged
            val masked = maskingUnresolvableMarkers(flagged) ?: return text
            val separated = CleanupFidelity.separatingCorrectionMarkers(masked)
            if (separated == masked) return text
            val corrected = correctionMarkers(separated, valueOnly = false)
            if (corrected == separated) return text
            for (marker in listOf("，不對，", "，不是，", "，我是說")) {
                if (corrected.split(marker).size > text.split(marker).size) return text
            }
            return if (masked == text) corrected else corrected.replace(MARKER_MASK.toString(), "")
        }

        // ---- 沒訊號的改口詞（FX-1 v2，2026-10-22，同 Swift）----
        // C1 「不對」後面直接接 齊應勁稱外盤焦等頭味題口＝描述詞（不對齊、不對應、不對勁…），永遠不是改口詞。
        // C2 改口詞（不對／我是說／啊不對）前後緊貼著停頓（，,、。；;：:！!？? 或空白）或連說兩次（不對不對）＝有訊號，
        //    照原本的規則。沒訊號的只有前後緊鄰的是同一種值、而且新值後面到下一個標點最多 2 個中文字才改，其他照講的留著。
        //    「不是」維持原本的規則（單獨的「我住三樓不是四樓」是對比，本來就不動）。

        private const val NOT_RIGHT_WORD_FOLLOWERS = "齊應勁稱外盤焦等頭味題口"
        private const val CORRECTION_INTERJECTIONS = "啊呃喔哦噢欸"
        private const val CORRECTION_PAUSE_PUNCTUATION = "，,、。；;：:！!？?"
        /** 遮改口詞用的字（WORD JOINER），同 Swift markerMask。 */
        internal const val MARKER_MASK = '\u2060'
        /** 連說記號（INVISIBLE SEPARATOR），同 Swift doubledFlag。 */
        internal const val DOUBLED_FLAG = '\u2063'
        private val doubledCorrection = Regex("(不對|不是|我是說)\\1+")

        /** 直接連說的改口詞壓成一個並留下連說記號；原文本來就有記號字元就不動（同 Swift）。 */
        internal fun flaggingDoubledCorrections(text: String): String {
            if (text.contains(DOUBLED_FLAG)) return text
            return doubledCorrection.replace(text) { it.groupValues[1] + DOUBLED_FLAG }
        }

        private enum class CorrectionMarkerKind { NOT_RIGHT, NOT_IS, I_MEAN }

        private class CorrectionMarkerSpan(
            val start: Int, val end: Int, val positions: List<Int>, val kind: CorrectionMarkerKind,
            val signalled: Boolean, val descriptive: Boolean,
        )

        /** 跟 CleanupFidelity.separatingCorrectionMarkers 對到的是同一批位置（同 Swift correctionMarkerSpans）。 */
        private fun correctionMarkerSpans(s: String): List<CorrectionMarkerSpan> {
            fun at(i: Int, word: String) = i >= 0 && s.startsWith(word, i)
            fun isSeparator(i: Int) = s[i] == '，' || s[i] == ',' || s[i] == '、' || isCorrectionWhitespace(s[i])
            fun isPause(i: Int) = i >= 0 && i < s.length && (s[i] in CORRECTION_PAUSE_PUNCTUATION || isCorrectionWhitespace(s[i]))
            data class Run(val positions: List<Int>, val end: Int, val next: Int, val doubled: Boolean)
            fun run(first: Int, word: String): Run {
                val positions = mutableListOf(first)
                var end = first + 2
                var doubled = false
                while (true) {
                    if (end < s.length && s[end] == DOUBLED_FLAG) { doubled = true; end++ }
                    var j = end
                    while (j < s.length && isSeparator(j)) j++
                    if (!at(j, word)) return Run(positions, end, j, doubled || positions.size > 1)
                    positions.add(j)
                    end = j + 2
                }
            }
            val spans = mutableListOf<CorrectionMarkerSpan>()
            var i = 0
            while (i < s.length) {
                if (at(i, "不對")) {
                    if (i > 0 && (s[i - 1] == '對' || s[i - 1] == '对')) { i += 2; continue }
                    val r = run(i, "不對")
                    var start = i
                    var k = i
                    while (k > 0 && isSeparator(k - 1)) k--
                    var gapped = false
                    if (k > 0 && s[k - 1] in CORRECTION_INTERJECTIONS) { start = k - 1; gapped = k < i }
                    val descriptive = r.end < s.length && s[r.end] in NOT_RIGHT_WORD_FOLLOWERS
                    val signalled = r.doubled || gapped || isPause(start - 1) || isPause(r.end)
                    spans += CorrectionMarkerSpan(start, r.end, r.positions, CorrectionMarkerKind.NOT_RIGHT, signalled, descriptive)
                    i = r.end
                } else if (at(i, "不是")) {
                    val r = run(i, "不是")
                    if (r.next < s.length && s[r.next] == '是') {
                        val signalled = r.doubled || isPause(i - 1) || isPause(r.end)
                        spans += CorrectionMarkerSpan(i, r.end, r.positions, CorrectionMarkerKind.NOT_IS, signalled, false)
                    }
                    i = r.end
                } else if (at(i, "我是說")) {
                    var end = i + 3
                    val doubled = end < s.length && s[end] == DOUBLED_FLAG
                    if (doubled) end++
                    spans += CorrectionMarkerSpan(i, end, listOf(i), CorrectionMarkerKind.I_MEAN,
                        doubled || isPause(i - 1) || isPause(end), false)
                    i = end
                } else {
                    i++
                }
            }
            return spans
        }

        /** 把不能當改口的改口詞遮起來；回傳一律拿掉連說記號；原文本來就有遮字用的字元回 null（同 Swift）。 */
        internal fun maskingUnresolvableMarkers(text: String): String? {
            val spans = correctionMarkerSpans(text)
            val masks = mutableSetOf<Int>()
            for ((index, span) in spans.withIndex()) {
                if (span.descriptive) { masks += span.positions; continue }
                // 「不是」照原本的規則：補逗號只碰後面接「是」的，單獨的「三樓不是四樓」本來就不動。
                if (span.signalled || span.kind == CorrectionMarkerKind.NOT_IS) continue
                // 新值後面的字數算到下一個改口詞為止（「三點不對四點不對五點」）。
                val limit = spans.drop(index + 1).firstOrNull { !it.descriptive }?.start ?: text.length
                if (!isValueForValueCorrection(text.substring(0, span.start), text.substring(span.end, limit))) {
                    masks += span.positions
                }
            }
            if (masks.isNotEmpty() && text.contains(MARKER_MASK)) return null
            val out = StringBuilder(text.length + masks.size)
            for ((index, ch) in text.withIndex()) {
                if (ch == DOUBLED_FLAG) continue
                out.append(ch)
                if (index in masks) out.append(MARKER_MASK)
            }
            return out.toString()
        }

        private enum class CorrectionValueKind { RELATIVE_DAY, WEEKDAY, VERSION, ARABIC, CHINESE }

        /** 量詞（中文數字後面一定要有，或數字本身帶十百千萬億）；「點」後面可以接「半」「十五分」（同 Swift）。 */
        private const val CORRECTION_MEASURE = "(?:[點点](?:半|[0-9零〇一二三四五六七八九十]+分?)?|[號号樓楼層层塊块元倍個个位人次年月日天週周歲岁分秒度張张台臺軌轨頁页章集期版杯份本件間间條条種种堂節节班萬万千百億亿])"
        private const val CORRECTION_NUMERALS = "零〇一二三四五六七八九十百千萬万億亿兩两"
        private const val CORRECTION_DAY_PERIOD = "(?:上午|下午|中午|晚上|早上|傍晚|凌晨|半夜)?"
        private val correctionValuePatterns = listOf(
            // 「禮拜五下午」「明天晚上」整個算一個值（不然「禮拜三不對禮拜五下午見」的「下午見」會被算成三個字的後文）。同 Swift。
            CorrectionValueKind.RELATIVE_DAY to "(?:大後天|大前天|後天|后天|前天|昨天|今天|明天)$CORRECTION_DAY_PERIOD",
            CorrectionValueKind.WEEKDAY to "(?:下個|這個|上個|下|這|上)?(?:星期|禮拜|礼拜|週|周)[一二三四五六日天]$CORRECTION_DAY_PERIOD",
            CorrectionValueKind.VERSION to "(?<![A-Za-z])[Vv](?>[0-9]+(?:\\.[0-9]+)*)",
            // 時間「3:30」不算（對齊規則會把它拆壞）。
            CorrectionValueKind.ARABIC to "(?<![A-Za-z0-9_.:：])(?>[0-9]+(?:\\.[0-9]+)*)(?![:：])(?:[A-Za-z%]+|$CORRECTION_MEASURE)?",
            CorrectionValueKind.CHINESE to "(?<![$CORRECTION_NUMERALS])(?>[$CORRECTION_NUMERALS]+)$CORRECTION_MEASURE?",
        )
        private val correctionValueAtEnd = correctionValuePatterns.map { (kind, p) -> kind to Regex("$p\\z") }
        private val correctionValueAtStart = correctionValuePatterns.map { (kind, p) -> kind to Regex("\\A$p") }

        /** 中文數字要帶量詞，或本身有十百千萬億（「兩萬」）；光一個「三」不算值。 */
        private fun isCorrectionValue(kind: CorrectionValueKind, value: String): Boolean {
            if (kind != CorrectionValueKind.CHINESE) return true
            val last = value.lastOrNull() ?: return false
            return last !in CORRECTION_NUMERALS || value.any { it in "十百千萬万億亿" }
        }

        private fun correctionValue(text: String, patterns: List<Pair<CorrectionValueKind, Regex>>): Pair<CorrectionValueKind, IntRange>? {
            for ((kind, regex) in patterns) {
                val match = regex.find(text) ?: continue
                if (isCorrectionValue(kind, match.value)) return kind to match.range
            }
            return null
        }

        /** C2：改口詞前面緊鄰的值跟後面緊鄰的值是同一種，而且新值後面到下一個標點最多 2 個中文字（同 Swift）。 */
        internal fun isValueForValueCorrection(before: String, after: String): Boolean {
            val (oldKind, _) = correctionValue(trimCorrectionWhitespace(before), correctionValueAtEnd) ?: return false
            val rest = stripCorrectionLead(after)
            val (newKind, range) = correctionValue(rest, correctionValueAtStart) ?: return false
            if (newKind != oldKind) return false
            var hanCount = 0
            for (ch in rest.substring(range.last + 1)) {
                if (ch in CORRECTION_PAUSE_PUNCTUATION || ch == '\n' || ch == '\r') break
                if (isCJKChar(ch.toString())) hanCount++
            }
            return hanCount <= 2
        }

        private fun applyExplicitNotCorrection(text: String): String {
            val pattern = Regex("""([^，。！？,!?\s　]{0,30})不是([^，。！？,!?\s　]{1,30})([，,。]?)是(?!不是|對不對|要不要)([^，。！？,!?\s　]{1,30})""")
            var out = text
            repeat(5) {
                val match = pattern.find(out) ?: return out
                val prefix = match.groups[1]?.value ?: return out
                val separator = match.groups[3]?.value ?: return out
                if (separator.isEmpty() && prefix.endsWith("是")) return out
                // 「不是星期四而是星期三」是對比（後面那個對），不是改口；當成改口會切出「星期三而」（FX-3 第四輪 G3）。照原話留著。同 Swift。
                if (separator.isEmpty() && (match.groups[2]?.value ?: return out).endsWith("而")) return out
                val old = prefix + (match.groups[2]?.value ?: return out)
                val replacement = match.groups[4]?.value ?: return out
                val corrected = alignCorrection(old, replacement)
                    ?: copulaSubjects.firstOrNull { prefix.endsWith(it) }?.let { prefix + "是" + replacement }
                    ?: return out
                out = out.replaceRange(match.range, corrected)
            }
            return out
        }

        private const val NUM = "[\\d零〇一二三四五六七八九十百千兩]"

        /** 數字／日期／金額／時間：只動常見形狀。 */
        fun normalizeNumbers(text: String): String {
            var out = decimalTimes(text)
            fun toArabic(s: String) = chineseToInt(s)?.toString() ?: s
            out = applyRegex(out, "($NUM{1,10})年($NUM{1,5})月($NUM{1,5})日") { g ->
                "${toArabic(g[1])} 年 ${toArabic(g[2])} 月 ${toArabic(g[3])} 日"
            }
            out = applyRegex(out, "($NUM{1,10})年($NUM{1,5})月(?!日)") { g -> "${toArabic(g[1])} 年 ${toArabic(g[2])} 月" }
            out = applyRegex(out, "($NUM{1,5})月($NUM{1,5})日") { g -> "${toArabic(g[1])} 月 ${toArabic(g[2])} 日" }
            // 星期幾的數字不跟後面的鐘點黏在一起（同 Swift 規則 4，FX-2 v2 N3）：「禮拜五三點半」＝禮拜五＋3:30。
            out = applyRegex(
                out,
                "([\\d零〇一二三四五六七八九十兩]{1,3})點(半|十五分|三十分|四十五分|([\\d零〇一二三四五六七八九十]{1,3})分|(?=[開出到交會鐘]))",
            ) { g, before, after ->
                var hourRun = g[1]
                var lead = ""
                // 序數「第N」的那個數字也不併進鐘點（同 Swift，FX-11 E4）：「第一三點開會」＝第一＋3:00，不是「第13:00」。
                if (weekdayMerges(hourRun, before) || ordinalMerges(hourRun, before)) {
                    // 拆掉星期幾後不是 0～24 點、或「星期三十一點二分鐘」＝整段照講的留著。
                    val rest = hourRun.substring(1)
                    val hour = chineseToInt(rest)
                    if ((g[3].isNotEmpty() && after.startsWith("鐘")) || hour == null || hour !in 0..24) return@applyRegex g[0]
                    lead = hourRun.substring(0, 1)
                    hourRun = rest
                }
                val h = lead + toArabic(hourRun)
                when (val suffix = g[2]) {
                    "" -> "$h:00"
                    "半" -> "$h:30"
                    "十五分" -> "$h:15"
                    "三十分" -> "$h:30"
                    "四十五分" -> "$h:45"
                    else -> "$h:" + String.format("%02d", chineseToInt(suffix.dropLast(1)) ?: 0)
                }
            }
            // 前面已經是數字／千分位逗號／小數點＝在數字中間：「12,000塊」原本只抓到「000塊」→「12,0塊」。同 Swift。
            // 數字和 塊／元 中間可以有一個空白或不換行空白（不認換行），原本的空白照留。同 Swift（2026-10-22 nd02）。
            // 概數、單獨的萬／億、星期幾、共用位值的範圍＝整段照講的留著（leavesSpoken，同 Swift，FX-2 v2）。
            out = applyRegex(out, "(?<![\\d,，.])([\\d零〇一二三四五六七八九十百千萬億兩]{1,15})(?:([ \\u00A0]?)(元|塊|圓)|( dollars?))") { g, before, after ->
                val unit = g[2] + g[3] + g[4]
                if (leavesSpoken(g[1], before, unit + after)) return@applyRegex g[0]
                // 小數＋萬／億＋單位（同 Swift，FX-11）：「一點五萬塊」的「五萬」是小數的一部分，交給小數規則整段讀（15,000塊）。
                if (isDecimalWanYiTail(g[1], before, unit + after)) return@applyRegex g[0]
                chineseToInt(colloquial(g[1]))?.let { formatThousands(it) + unit } ?: (g[1] + unit)
            }
            // 2026-09-24 實機回報（Fast 模式講數字不轉）：以下規則都在金額之後，避免金額規則重讀已轉好的「35,000」。
            val digit = "零〇一二三四五六七八九"
            val numeral = "零〇一二三四五六七八九十百千萬億兩"
            val technicalNumeral = "零〇一二三四五六七八九十百千兩"
            val technicalUnits = "kHz|Hz|kbps|Kbps|Mbps|K|k|bits|bit|dBFS|dBTP|dB|LUFS|LKFS|LU|ms|fps|MB|GB|TB|%"
            // 前面是這些＝不是一個確定的數（幾十個、好幾百、上百人、十多）；不轉。
            val vague = "\\d幾好數多上來餘"

            // 百分比：「百分之二十」「百分之三點五」
            // 概數的百分比（百分之十幾、二十來、五十多、十餘）整段照講的留著（同 Swift，FX-6 T5）。
            out = applyRegex(out, "百分之([$numeral]{1,5})(?:點([$digit]{1,3}))?") { g, _, after ->
                if (after.isNotEmpty() && after[0] in VAGUE_PERCENT_FOLLOWERS) return@applyRegex g[0]
                val v = chineseToInt(g[1]) ?: return@applyRegex g[0]
                val frac = if (g[2].isEmpty()) "" else "." + (chineseToInt(g[2])?.let { String.format("%0${g[2].length}d", it) } ?: "")
                "$v$frac%"
            }
            // 月日（口語「號」）：「九月二十四號」
            out = applyRegex(out, "(?<![$numeral\\d])([$numeral]{1,3})月([$numeral]{1,3})(號|号)") { g ->
                val m = chineseToInt(g[1])
                val d = chineseToInt(g[2])
                if (m != null && d != null && m in 1..12 && d in 1..31) "$m 月 $d ${g[3]}" else g[0]
            }
            // 整點：「下午三點」「三點見」。「有兩點要說」「快一點」不轉：要前面有時段詞，或後面接見／左右／之前…
            out = applyRegex(out, "(早上|上午|中午|下午|晚上|凌晨|傍晚|半夜|今天|明天|後天|昨天|禮拜[一二三四五六天日]|星期[一二三四五六天日])([$numeral]{1,3})點(?![點半$numeral\\d])") { g ->
                val h = chineseToInt(g[2])
                if (h != null && h in 0..24) "${g[1]}${h}點" else g[0]
            }
            out = applyRegex(out, "(?<![$numeral${vague}有差快慢早晚多少好])([二兩三四五六七八九十]{1,3})點(?=見|左右|之前|以前|前|之後|以後|後|到|至|整|鐘)") { g ->
                val h = chineseToInt(g[1])
                if (h != null && h in 1..24) "${h}點" else g[0]
            }
            // 8c. 對比／替代的另一個整點跟著同一句已經轉好的寫法（同 Swift，2026-10-22 W2-6：「我們約三點開會，不是四點」）。
            out = alignContrastedHours(out, text)
            // 小數＋單位：「三點五公斤」（「三點五分」是時間，上面已處理）
            out = applyRegex(out, "(?<![$numeral\\d])([$numeral]{1,5})點([$digit]{1,3})(公斤|公里|公尺|公分|公升|倍|度|秒|個百分點|吋|寸|歲|小時|個小時|萬|億|G|GB|TB|K|kHz|Hz|dB)") { g, before, after ->
                if (leavesSpoken(g[1], before, "點" + g[2] + g[3] + after)) return@applyRegex g[0]
                val whole = chineseToInt(g[1]) ?: return@applyRegex g[0]
                val frac = g[2].mapNotNull { chineseToInt(it.toString())?.toString() }.joinToString("")
                "$whole.$frac${g[3]}"
            }
            // 中文數字＋技術單位、負數：「九十六 kHz」→「96 kHz」、「負十四 LUFS」→「-14 LUFS」（同 Swift 規則 9b）。
            out = applyRegex(out, "(?<![${numeral}0-9])(負)?([$technicalNumeral]{2,}|[零〇二三四五六七八九十百千兩]|(?<=負)一|(?<![\\u4E00-\\u9FFF])一|一(?=點))(?:點([$digit]+))?( ?)($technicalUnits)(?![A-Za-z])") { g, before, after ->
                val run = g[2]
                val fractionDigits = g[3]
                val tail = (if (fractionDigits.isEmpty()) "" else "點$fractionDigits") + g[4] + g[5] + after
                if (leavesSpoken(run, before + g[1], tail)) return@applyRegex g[0]
                val spoken = if (fractionDigits.isEmpty()) colloquial(run) else run
                // 「一百二點五」這種口語省略＋小數講法不確定是多少，不猜。
                if (fractionDigits.isNotEmpty() && spoken != colloquial(run)) return@applyRegex g[0]
                val whole = chineseToInt(spoken) ?: return@applyRegex g[0]
                val fraction = fractionDigits.mapNotNull { chineseToInt(it.toString())?.toString() }.joinToString("")
                (if (g[1].isEmpty()) "" else "-") + "$whole" + (if (fraction.isEmpty()) "" else ".$fraction") + g[4] + g[5]
            }
            // 阿拉伯數字＋萬／億：「30萬」→「300,000」、「10萬5」→「105,000」（同 Swift 規則 9c）。
            // 「11:32萬」的 32 是鐘點的分鐘，不從那裡開始讀（同 Swift，FX-6 T3）。
            out = applyRegex(out, "(?<![0-9.,萬億:：])([0-9]+)(?:\\.([0-9]+))? ?(萬|億)(?:([0-9]{1,4}) ?萬)?(?:([0-9]{1,4})(千)?)?(?![0-9$numeral]|[.,][0-9]| [0-9])") { g, before, after ->
                if (leavesSpoken(g[0], before, after)) return@applyRegex g[0]
                arabicWanYiValue(g[1], g[2], g[3], g[4], g[5], g[6].isNotEmpty())?.let { formatThousands(it) } ?: g[0]
            }
            // 千以上的數字（含口語「三萬五」「兩千五」）：「預算大概三萬五」→「35,000」。必須以數字開頭：「千萬不要」不轉。
            out = applyRegex(out, "(?<![$numeral$vague])([一二兩三四五六七八九十][$numeral]*[千萬億][$numeral]*)(?![$numeral\\d])") { g, before, after ->
                if (leavesSpoken(g[1], before, after)) return@applyRegex g[0]
                val v = chineseToInt(colloquial(g[1]))
                if (v != null && v >= 1000) formatThousands(v) else g[0]
            }
            // 數字＋單位，數值 ≥ 10：「十五分鐘」→「15分鐘」；「三個問題」「一下」「十分好」不動。
            out = applyRegex(out, "(?<![$numeral${vague}第])([$numeral]{1,6})(分鐘|秒鐘|秒|小時|個小時|天|週|個禮拜|個星期|個月|年|歲|公斤|公里|公尺|公分|公升|度|人|次|張|頁|首|軌|個|位|本|台|支|件|題|篇|集|樓)") { g, before, after ->
                // 「三四五個人」＝概數：沒有十／百／千這類位值字的逐位數字不轉。
                if (g[1].none { it in "十百千萬億" } || leavesSpoken(g[1], before, g[2] + after)) return@applyRegex g[0]
                val v = chineseToInt(colloquial(g[1]))
                if (v != null && v >= 10) "$v${g[2]}" else g[0]
            }
            // 逐位念的數字（至少 3 位）：「一二三四五」「零九一二…」→ 阿拉伯數字；「一五一十」這種成語中間有十不會整段成立。
            // 星期幾的數字不併進來（「禮拜五三四點」不是「禮拜534點」，同 Swift，FX-2 v2 N3）。
            out = applyRegex(out, "(?<![$numeral\\d])([$digit]{3,})(十)?(?![$numeral\\d個人天次位年歲種隻本件])") { g, before, _ ->
                val run = g[1]
                if (g[2].isNotEmpty() && run.last() != '九') return@applyRegex g[0]
                if (weekdayMerges(run, before)) return@applyRegex g[0]
                val digits = run.mapNotNull { chineseToInt(it.toString())?.toString() }.joinToString("")
                digits + if (g[2].isEmpty()) "" else "10"
            }
            // 台灣電話：手機「0912-345-678」、台北市話「02-2333-3333」；其他區碼不動（同 Swift 規則 13）。
            out = applyRegex(out, "(?<![0-9A-Za-z.\\-])(09[0-9]{2})[- ]?([0-9]{3})[- ]?([0-9]{3})(?![0-9A-Za-z\\-])") { g ->
                "${g[1]}-${g[2]}-${g[3]}"
            }
            out = applyRegex(out, "(?<![0-9A-Za-z.\\-])02[- ]?([0-9]{4})[- ]?([0-9]{4})(?![0-9A-Za-z\\-])") { g ->
                "02-${g[1]}-${g[2]}"
            }
            return out
        }

        /**
         * 規則 8c（同 Swift alignContrastedHours）：「不是／還是／或是／或者／而是／或」帶出來、收在子句結尾的中文整點，
         * 跟著同一句（句界同 splitSentences）裡最近一個這次由鐘點規則轉出來的寫法：「3:00」那邊 →「4:00」、「3點」那邊 →「4點」。
         * 這句沒有轉好的鐘點就不動；原文本來就寫好的數字（比數 3:05）不跟；對比的是「幾點（重點）」時不動
         * （同 Swift，2026-10-22 第二輪：對比詞前面最近的 N點要是這次轉出來的鐘點，沒轉的中文 N點＝數量；
         * 對比詞那一小段前面另有主詞（議程還是兩點、重點還是兩點）也不動）；單獨的「一點」不收。只改寫法、不碰改口與對比的判斷。
         */
        private const val contrastedHourPattern = "(不是|還是|或是|或者|而是|或)([一二兩三四五六七八九十]{1,3})點(?![點半分鐘零〇一二三四五六七八九十百千萬億兩\\d])(?=[，,。！？!?、；;\\s喔哦啦吧呢耶欸]|$)"
        private const val convertedHourPattern = "(?<![\\d:.,])\\d{1,2}(?::[0-5]\\d|點)(?!\\d)"
        private const val countedPointsPattern = "(?<![零〇一二兩三四五六七八九十]|不是|還是|或是|或者|而是|或)[零〇一二兩三四五六七八九十]+點"
        private const val pointNounPattern = "(?<!\\d)點"
        /** 對比詞前面這一小段裡可以有的字：時間詞與不帶主詞的副詞（同 Swift contrastClauseFillerPattern）。 */
        private const val contrastClauseFillerPattern = "今天|明天|後天|昨天|今晚|明晚|早上|上午|中午|下午|晚上|凌晨|傍晚|應該|可能|也許|或許|大概|還|也|就|都|那|是|[ \\t]"

        internal fun alignContrastedHours(text: String, original: String): String {
            if (!text.contains("點")) return text
            val candidate = icu(contrastedHourPattern)
            val converted = icu(convertedHourPattern)
            fun tally(s: String): Map<String, Int> = converted.findAll(s).groupingBy { it.value }.eachCount()
            val before = tally(original)
            val produced = tally(text).filter { (k, v) -> v > (before[k] ?: 0) }.keys
            if (produced.isEmpty()) return text
            val counted = icu(countedPointsPattern)
            val pointNoun = icu(pointNounPattern)
            val filler = icu(contrastClauseFillerPattern)
            val out = StringBuilder()
            for (sentence in splitSentences(text)) {
                val times = converted.findAll(sentence).map { it.range }.toList()
                if (times.none { sentence.substring(it.first, it.last + 1) in produced }) { out.append(sentence); continue }
                // 句子裡所有的「N點」：轉好的鐘點與沒轉的中文 N點（數量）。
                val points = times + counted.findAll(sentence).map { it.range }.toList()
                val result = StringBuilder(sentence)
                for (m in candidate.findAll(sentence).toList().asReversed()) {
                    val runGroup = m.groups[2] ?: continue
                    val run = runGroup.value
                    if (run == "一") continue
                    val hour = chineseToInt(run) ?: continue
                    if (hour !in 1..24) continue
                    val start = runGroup.range.first
                    val contrast = m.groups[1]?.range?.first ?: continue
                    // 對比的對象：對比詞前面最近的一個 N點；要是這次轉出來的鐘點才對齊。
                    val anchor = points.filter { it.last + 1 <= contrast }.maxByOrNull { it.first } ?: continue
                    val anchorText = sentence.substring(anchor.first, anchor.last + 1)
                    if (anchorText !in produced) continue
                    // 對比詞那一小段：直接開頭，或錨點就在這一小段裡；前面另有主詞＝在講那個東西。
                    val head = sentence.substring(0, contrast)
                    // 半形「:」不算子句分隔（3:00 裡面就有一個；同 Swift）。
                    val clauseStart = head.lastIndexOfAny(charArrayOf('，', ',', '、', '；', ';', '：')) + 1
                    val clause = head.substring(clauseStart)
                    if (anchor.first < clauseStart && filler.replace(clause, "").isNotEmpty()) continue
                    if (pointNoun.containsMatchIn(clause)) continue
                    result.replace(start, m.range.last + 1, if (anchorText.contains(":")) "$hour:00" else "${hour}點")
                }
                out.append(result)
            }
            return out.toString()
        }

        /** 「30萬」「10萬5」「1.5萬」「3億5000萬」「3萬2千」→ 數值；講法不確定就回 null，原文不動（同 Swift arabicWanYiValue）。 */
        internal fun arabicWanYiValue(
            integer: String, fraction: String, unit: String, wanSection: String, tail: String, thousand: Boolean,
        ): Long? {
            val unitValue = if (unit == "億") 100_000_000L else 10_000L
            if (unit == "萬" && wanSection.isNotEmpty()) return null
            if (fraction.isNotEmpty() && !(wanSection.isEmpty() && tail.isEmpty())) return null
            return try {
                val whole = integer.toLongOrNull() ?: return null
                var value = Math.multiplyExact(whole, unitValue)
                if (fraction.isNotEmpty()) {
                    if (fraction.length > 8) return null
                    val f = fraction.toLongOrNull() ?: return null
                    var scale = 1L
                    repeat(fraction.length) { scale *= 10 }
                    val scaled = f * unitValue
                    if (scaled % scale != 0L) return null
                    value = Math.addExact(value, scaled / scale)
                }
                var lastUnit = unitValue
                if (wanSection.isNotEmpty()) {
                    val w = wanSection.toLongOrNull() ?: return null
                    value = Math.addExact(value, w * 10_000L)
                    lastUnit = 10_000L
                }
                if (tail.isEmpty()) return value
                val t = tail.toLongOrNull() ?: return null
                val addition = when {
                    thousand -> if (tail.length == 1 && lastUnit == 10_000L) t * 1_000L else return null
                    tail.length == 1 -> t * (lastUnit / 10)
                    lastUnit == 10_000L -> t
                    else -> return null
                }
                Math.addExact(value, addition)
            } catch (overflow: ArithmeticException) {
                null
            }
        }

        // 整段照講的留著（同 Swift leavesSpoken，FX-2 v2，2026-10-22）：規則 5／9／9b／9c／10／11 共用。
        // 一段數字有兩種讀法、或根本不是一個確定的數，就整段照原文，不轉、也不轉一半。
        private const val SPOKEN_DIGITS = "一二兩三四五六七八九"
        private const val MAGNITUDES = "十百千萬億"
        private const val NUMERALS = "零〇一二三四五六七八九十百千萬億兩"
        private const val RANGE_RUN_CHARS = "零〇一二三四五六七八九十百千萬億兩0123456789.,"
        private const val RANGE_MARKS = "到至～~"
        /** 小數點後面念的數字（不含「兩」，同 Swift decimalDigitScalars，FX-6 T4）。 */
        private const val DECIMAL_DIGITS = "零〇一二三四五六七八九"
        /** 百分比後面接這些＝概數（同 Swift vaguePercentFollowers，FX-6 T5）。 */
        private const val VAGUE_PERCENT_FOLLOWERS = "幾几來来多餘余"

        /** `run` 是規則抓到的那段數字，`before`／`after` 是它緊鄰的前後文（同一步的輸入，各最多幾十個字）。 */
        internal fun leavesSpoken(run: String, before: String, after: String): Boolean {
            val first = run.firstOrNull() ?: return false
            // N1 前面沒有確定數字的萬／億：「幾萬塊」「數萬元」「萬元戶」（舊版讀成 0）。
            if (first == '萬' || first == '億') return true
            // N1 位值字開頭、前面（隔行內空白也算）是概數字或數字：「幾十」「數百」「上千」「一兩 百 ms」「3 千 塊」。
            if (first in MAGNITUDES) {
                var k = before.length
                while (k > 0 && (before[k - 1] == ' ' || before[k - 1] == '\u00A0' || before[k - 1] == '\u3000')) k--
                if (k > 0) {
                    val p = before[k - 1]
                    if (p == '幾' || p == '數' || (p == '上' && first != '十') || p in NUMERALS || p in '0'..'9') return true
                }
            }
            val hasMagnitude = run.any { it in MAGNITUDES }
            val b = before
            // N1「三、四十」：頓號前一個數字、後面帶位值＝兩個數一起講的概數（「第一、五千塊」是清單，不算）。
            if (hasMagnitude && b.length >= 2 && b[b.length - 1] == '、' && b[b.length - 2] in SPOKEN_DIGITS &&
                (b.length < 3 || b[b.length - 3] != '第')
            ) return true
            // N1「一兩萬」「三四十」「兩三百」：兩個數字連著講再接位值＝概數。
            if (hasMagnitude && run.zipWithNext().any { (x, y) -> x in SPOKEN_DIGITS && y in SPOKEN_DIGITS }) return true
            // N3 星期幾的數字不跟後面的數字黏在一起：「禮拜五十萬」「星期三十分鐘」「一週五十個小時」分不出來，不轉。
            if (weekdayMerges(run, before)) return true
            // N5 共用位值的範圍：「三到五萬」「一千到兩千萬」「三十到五十萬」只讀得出一半＝整段不讀。
            rangeNeighbour(before.reversed(), forward = false)?.let { if (sharesMagnitude(it.reversed(), run)) return true }
            rangeNeighbour(after, forward = true)?.let { if (sharesMagnitude(run, it)) return true }
            // T4（同 Swift，FX-6）小數＋千：前面緊接「數字＋點」、這段是「數字＋千…」（一點五千、三點五千）＝整段照講的留著。
            // 小數點後面不會念「兩」（三點兩千塊＝鐘點＋2,000），照舊轉。
            val m = run.indexOfFirst { it in MAGNITUDES }
            // 百也一樣（同 Swift，FX-8 D3）：「一點五百元」可以是 150 元，也可以是「一點」＋500 元；以前轉成一半「一點500元」。
            if (m > 0 && (run[m] == '千' || run[m] == '百') && run.substring(0, m).all { it in DECIMAL_DIGITS } && b.length >= 2 &&
                (b[b.length - 1] == '點' || b[b.length - 1] == '点') && (b[b.length - 2] in NUMERALS || b[b.length - 2] in '0'..'9')
            ) return true
            return false
        }

        /**
         * 這段數字的第一個字是緊跟在「禮拜／星期／週／周」後面的星期幾，而且後面還接著數字。
         * 後面接的是百／千／萬／億（「這週三千塊」「禮拜五千塊」）不算：那是一週 3,000、5,000。
         */
        internal fun weekdayMerges(run: String, before: String): Boolean {
            if (run.length < 2 || run[0] !in "一二三四五六" || run[1] !in "零〇一二三四五六七八九十兩") return false
            // 「礼拜」（簡體）也是星期（同 Swift，FX-8 D1）。
            return before.endsWith("禮拜") || before.endsWith("礼拜") || before.endsWith("星期") || before.endsWith("週") || before.endsWith("周")
        }

        /**
         * FX-11 E4（同 Swift ordinalMerges）：這段鐘點數字的第一個字緊跟在「第」後面＝那個字是序數，不是鐘點的一部分
         * （「第一三點開會」→「第一3:00開會」）。第二個字是「十」不算：「第二十點」多半就是 20 點，照舊。
         */
        internal fun ordinalMerges(run: String, before: String): Boolean {
            if (run.length < 2 || run[0] !in "一二三四五六七八九" || run[1] !in "零〇一二三四五六七八九兩") return false
            return before.endsWith("第")
        }

        /** 「N點」前面是這些＝那個「N點」是鐘點或序數（同 Swift decimalAmountClockContext）。 */
        private val decimalAmountClockContext = Regex("(?:早上|上午|中午|下午|晚上|凌晨|傍晚|半夜|深夜|午夜|清晨|週末|周末|早|晚|夜|(?:禮拜|礼拜|星期|週|周)[一二三四五六天日]?|第)$")
        /** 緊鄰數值前的有限金額詞尾，不在整句搜尋（同 Swift decimalAmountExplicitContext）。 */
        private val decimalAmountExplicitContext = Regex("(?:金額|預算|價格)(?:是|為)?$")
        /** 「一點」前面是這些＝「一點」可以是「一些」或「這一點」；「有」不單獨表示比較（同 Swift decimalAmountComparativeOne）。 */
        private const val DECIMAL_AMOUNT_COMPARATIVE_ONE = "差宜多少貴這这那給给早晚快慢好高低大小"
        /** 金額單位後緊接改口講整點；只越過限定標點／語助詞與「其實」，不跳過新主語（同 Swift decimalAmountHourCorrection）。 */
        private val decimalAmountHourCorrection = Regex("^[ \\u00A0]?(?:元|塊(?:錢)?|圓|dollars?)[，,、。.!！？?；;：: 啊呀喔哦吧啦呢\\u00A0\\r\\n\\t]*(?:(?:其實|其实)[，,、。.!！？?；;：: 啊呀喔哦吧啦呢\\u00A0\\r\\n\\t]*)?(?:不對|不对|不是|我是說|應該是|應該說)[，,、。.!！？?；;：: 啊呀喔哦吧啦呢\\u00A0\\r\\n\\t]*(?:[零〇一二兩三四五六七八九十]{1,3}點(?![點零〇一二三四五六七八九十百千萬億兩0-9])|[0-9]{1,2}(?::[0-9]{2}|點))")

        /**
         * FX-11（同 Swift isDecimalWanYiTail）：金額規則抓到的「五萬」「零五萬」是小數「一點五萬」「兩點零五萬」的後半段 → true，
         * 金額規則不動，小數規則整段讀（15,000塊／20,500塊）。小數點後只有一個「一」、前面是時段／星期／第、
         * 單獨的「一點」前面是比較／指示的字（「差不多」不算）、後面的改口講的是整點、整數部分兩個數字連著講（一兩點、三四點）、
         * 或小數規則讀不出來＝照舊（false）。
         */
        internal fun isDecimalWanYiTail(run: String, before: String, after: String): Boolean {
            if (run.length < 2 || run.length > 4 || (run.last() != '萬' && run.last() != '億')) return false
            val fraction = run.dropLast(1)
            if (!fraction.all { it in DECIMAL_DIGITS } || fraction == "一") return false
            if (before.isEmpty() || before.last() != '點') return false
            var k = before.length - 1
            while (k > 0 && before[k - 1] in NUMERALS) k--
            val whole = before.substring(k, before.length - 1)
            if (whole.isEmpty() || whole.length > 5) return false
            if (k > 0 && before[k - 1] in '0'..'9') return false
            // 整數部分兩個數字連著講（一兩點、三四點）＝概數或兩個鐘點，不是一個數。
            if (whole.zipWithNext().any { (x, y) -> x in SPOKEN_DIGITS && y in SPOKEN_DIGITS }) return false
            val head = before.substring(0, k)
            if (decimalAmountClockContext.containsMatchIn(head)) return false
            if (whole == "一" && head.isNotEmpty() && head.last() in DECIMAL_AMOUNT_COMPARATIVE_ONE && !head.endsWith("差不多")) return false
            // 前導零／〇或緊鄰金額詞是明確小數證據，後句整點不能把它拆回鐘點＋金額（同 Swift）。
            val hasDecimalAmountEvidence = fraction.first() in "零〇" || decimalAmountExplicitContext.containsMatchIn(head)
            if (!hasDecimalAmountEvidence && decimalAmountHourCorrection.containsMatchIn(after)) return false
            // 小數規則讀得出來才讓：整數讀得出、不是概數／範圍那些整段照講的。
            if (chineseToInt(whole) == null) return false
            return !leavesSpoken(whole, head, "點" + run + after)
        }

        /** 從數字旁邊往外讀：空白、「到／至／～」、空白，再接一段數字 → 那段數字（由近到遠）。往前讀時呼叫端先把前文倒過來。 */
        private fun rangeNeighbour(s: CharSequence, forward: Boolean): String? {
            var i = 0
            while (i < s.length && s[i] == ' ') i++
            if (i >= s.length || s[i] !in RANGE_MARKS) return null
            i++
            while (i < s.length && s[i] == ' ') i++
            var j = i
            while (j < s.length && s[j] in RANGE_RUN_CHARS) j++
            if (forward && j > i && j + 1 < s.length && s[j] == ' ' && (s[j + 1] == '萬' || s[j + 1] == '億') && s[j - 1].code < 128) j += 2
            return s.subSequence(i, j).toString().trim('.', ',').ifEmpty { null }
        }

        /** 「三」到「五萬」、「一千」到「兩千萬」：起點比終點的係數小＝共用終點的位值（「五千到一萬」不是）。起點自己有萬／億也不是。 */
        private fun sharesMagnitude(start: String, end: String): Boolean {
            val last = end.lastOrNull() ?: return false
            if (last !in MAGNITUDES || '萬' in start || '億' in start) return false
            val a = rangeValue(start) ?: return false
            val c = rangeValue(end.dropLast(1).trimEnd(' ')) ?: return false
            return a > 0 && a < c
        }

        /** 阿拉伯數字（可有千分位、一個小數點）或中文數字的值；兩種混在一起或讀不出來＝null（同 Swift rangeValue）。 */
        private fun rangeValue(s: String): Double? {
            val t = s.filter { it != ',' }
            if (t.isEmpty()) return null
            if (t.all { it.code < 128 }) {
                val parts = t.split('.')
                if (parts.size > 2 || parts.any { p -> p.length > 15 || !p.all { it in '0'..'9' } }) return null
                if (parts[0].isEmpty() && (parts.size == 1 || parts[1].isEmpty())) return null
                val whole = (parts[0].toLongOrNull() ?: 0L).toDouble()
                if (parts.size != 2 || parts[1].isEmpty()) return whole
                val f = parts[1].toLongOrNull() ?: return whole
                return whole + f.toDouble() / 10.0.pow(parts[1].length)
            }
            if (t.any { it.code < 128 }) return null
            return chineseToInt(colloquial(t))?.toDouble()
        }

        /**
         * 口語省略單位：「兩千五」＝2500、「三萬五」＝35000、「一百二」＝120（最後一個數字跟在單位後面、中間沒有零）。
         * 「千六」「百五」（前面沒講一）也是：1,600、150（同 Swift，FX-2 v2 N4；舊版讀成 1,006）。
         */
        internal fun colloquial(s: String): String {
            val chars = s.toCharArray()
            val abbreviated = chars.size == 2 && (chars[0] == '千' || chars[0] == '百')
            if ((chars.size < 3 && !abbreviated) || chars.last() !in "一二兩三四五六七八九") return s
            return when (chars[chars.size - 2]) {
                '百' -> s + "十"
                '千' -> s + "百"
                '萬' -> s + "千"
                '億' -> s + "千萬"
                else -> s
            }
        }

        internal fun applyRegex(text: String, pattern: String, transform: (List<String>) -> String): String =
            replaceMatches(text, pattern) { groups, _ -> transform(groups) }

        /** 前後文各給這麼多個 UTF-16 單位（同 Swift regexContextWindow）。 */
        private const val REGEX_CONTEXT_WINDOW = 24

        /** 同 applyRegex，另外把這一段緊鄰的前文、後文（同一步的輸入、各最多 REGEX_CONTEXT_WINDOW 個字元）交給 transform。 */
        internal fun applyRegex(text: String, pattern: String, transform: (List<String>, String, String) -> String): String =
            replaceMatches(text, pattern) { groups, range ->
                val start = range.first
                val end = range.last + 1
                val before = text.substring(maxOf(0, start - REGEX_CONTEXT_WINDOW), start)
                val after = text.substring(end, minOf(text.length, end + REGEX_CONTEXT_WINDOW))
                transform(groups, before, after)
            }

        /** 由後往前替換；沒參與的群組給空字串（同 Swift 版 NSNotFound → ""）。 */
        private fun replaceMatches(text: String, pattern: String, transform: (List<String>, IntRange) -> String): String {
            val matches = icu(pattern).findAll(text).toList()
            if (matches.isEmpty()) return text
            val sb = StringBuilder(text)
            for (m in matches.asReversed()) {
                val groups = m.groups.map { it?.value ?: "" }
                sb.replace(m.range.first, m.range.last + 1, transform(groups, m.range))
            }
            return sb.toString()
        }

        private val digitMap = mapOf(
            '零' to 0, '〇' to 0, '一' to 1, '二' to 2, '兩' to 2, '三' to 3, '四' to 4,
            '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9,
        )
        private val asciiInteger = Regex("[+-]?[0-9]+")
        private val sectionWeights = mapOf('十' to 10L, '百' to 100L, '千' to 1000L, '萬' to 10_000L, '億' to 100_000_000L)

        /** 中文數字轉整數（0～99,999,999,999 常用組合）；Swift 的 Int 是 64 位元，這裡用 Long。 */
        fun chineseToInt(s: String): Long? {
            // Swift 的 Int(s) 只收 ASCII 數字（可帶正負號）；Java 的 toLongOrNull 連全形數字都收，要擋掉。
            if (asciiInteger.matches(s)) s.toLongOrNull()?.let { return it }
            if (s.isEmpty()) return null
            if (s.all { it in digitMap }) return s.map { digitMap.getValue(it) }.joinToString("").toLongOrNull()
            var total = 0L
            var section = 0L
            var current = 0L
            var sawAny = false
            for (ch in s) {
                val d = digitMap[ch]
                if (d != null) { current = d.toLong(); sawAny = true; continue }
                val w = sectionWeights[ch] ?: return null
                if (w >= 10_000) {
                    section = (section + current) * w
                    total += section
                    section = 0
                } else {
                    section += (if (current == 0L) 1 else current) * w
                }
                current = 0
                sawAny = true
            }
            total += section + current
            return if (sawAny) total else null
        }

        /** 千分位（不依賴 locale）。 */
        fun formatThousands(n: Long): String {
            val s = n.toString()
            if (s.length <= 3) return s
            val sb = StringBuilder()
            s.reversed().forEachIndexed { i, ch ->
                if (i > 0 && i % 3 == 0) sb.append(',')
                sb.append(ch)
            }
            return sb.reverse().toString()
        }

        private val verbalCues = listOf("首先", "其次", "再次", "然後", "接下來", "最後")

        private const val sentenceParticles = "了啦喔哦吧呢嗎吗呀啊囉嘛耶欸哈"

        /** 單獨的句尾語助詞被標點切開 → 黏回前一句（同 Swift reattachParticles）。 */
        fun reattachParticles(text: String): String {
            val interjection = applyRegex(text, "[。．.]\\s*(哎|唉|欸|哇|嗯|哈|喔|哎呀|唉呀)([。！!．.]?)$") { g ->
                "，${g[1]}${g[2].ifEmpty { "。" }}"
            }
            return applyRegex(interjection, "([，,、。．.！!？?])\\s*([$sentenceParticles])(?=[，,、。．.！!？?\\s]|$)") { g ->
                if (g[1] in listOf("，", ",", "、")) g[2] else g[2] + g[1]
            }
        }

        /** 逐字母念的縮寫合回一個字（「K C F S」→「KCFS」，同 Swift joinSpelledLetters）。 */
        /** 小型標點（U+FE50–FE57）→ 一般寫法；﹒ 交給後面的中文句號規則。同 Swift。 */
        val smallFormPunctuation: Map<Char, String> = mapOf(
            '\uFE50' to "，", '\uFE51' to "、", '\uFE52' to ".", '\uFE54' to "；",
            '\uFE55' to "：", '\uFE56' to "？", '\uFE57' to "！"
        )
        fun foldSmallFormPunctuation(text: String): String {
            if (text.none { smallFormPunctuation.containsKey(it) }) return text
            val sb = StringBuilder(text.length)
            for (c in text) sb.append(smallFormPunctuation[c] ?: c.toString())
            return sb.toString()
        }

        fun joinSpelledLetters(text: String): String =
            applyRegex(text, "(?<![A-Za-z])[A-Za-z](?: [A-Za-z])+(?![A-Za-z])") { g -> g[0].replace(" ", "") }

        /**
         * 條列：以句為單位，一句裡有兩種以上不同的 cue 才換行；cue 後面緊接「的」不算（同 Swift，2026-09-19）。
         * 序數串（第一…第N）只有整串符合條列規則（ordinalList）才動（同 Swift，2026-10-22 W2-6 第三輪）：numbered 時改成「1. 」編號清單
         * （引言結尾改「：」、清單後面的句子另起一行），否則只在每個「第N」前面換行；不符合就整句原樣——不編號也不切行。
         */
        fun normalizeListCues(text: String, numbered: Boolean = false): String {
            val out = StringBuilder()
            var previous: String? = null
            var afterList = false
            for (sentence in splitSentences(text)) {
                var body = sentence
                val newline = if (endsWithNewline(body)) "\n" else ""
                if (newline.isNotEmpty()) body = body.dropLast(1)
                if (afterList && out.isNotEmpty() && !endsWithNewline(out)) {
                    out.append('\n')
                    body = body.trimStart(' ', '\t')
                }
                afterList = false
                val list = ordinalList(body, previous)
                if (list == null) {
                    out.append(listifyVerbalCues(body)).append(newline)
                } else if (numbered) {
                    val lines = mutableListOf<String>()
                    if (SwiftText.graphemes(list.prefix).any { SwiftText.isLetter(it) || SwiftText.isNumber(it) }) {
                        lines += listIntro(list.prefix)
                    } else if (out.isNotEmpty() && !endsWithNewline(out)) {
                        out.append('\n')
                    }
                    list.bodies.forEachIndexed { k, item -> lines += "${k + 1}. " + trimListItem(item) }
                    out.append(lines.joinToString("\n")).append(newline)
                    afterList = true
                } else {
                    val piece = StringBuilder(list.prefix)
                    for (segment in list.segments) {
                        val joined = out.toString() + piece
                        if (joined.isNotEmpty() && !endsWithNewline(joined)) piece.append('\n')
                        piece.append(segment)
                    }
                    out.append(piece).append(newline)
                }
                previous = sentence
            }
            return out.toString()
        }

        /** 最後一個字（Swift Character）是「\n」：「\r\n」在 Swift 是一個字，不算（同 Swift `last == "\n"`）。 */
        private fun endsWithNewline(s: CharSequence) = s.endsWith("\n") && !s.endsWith("\r\n")

        internal fun listifyVerbalCues(sentence: String): String {
            val distinct = verbalCues.count { cue ->
                var from = 0
                var found = false
                while (true) {
                    val i = sentence.indexOf(cue, from)
                    if (i < 0) break
                    val end = i + cue.length
                    if (end >= sentence.length || !sentence.startsWith("的", end)) { found = true; break }
                    from = end
                }
                found
            }
            if (distinct < 2) return sentence
            return applyRegex(sentence, "(首先|其次|再次|然後|接下來|最後)(?!的)(.{1,40}?)(?=首先|其次|再次|然後|接下來|最後|[。！？!?]|$)") { g -> "\n${g[1]}${g[2]}" }
        }

        /** 序數：「第」＋中文數字（同 Swift ordinalCuePattern）。 */
        private const val ordinalCuePattern = "第[一二三四五六七八九十]{1,3}"
        /** 「第N」後面緊接這些（或空白）＝明確的序號（同 Swift ordinalSeparators）。 */
        private val ordinalSeparators = setOf("，", ",", "、", "：", ":")
        /** 「第N」後面接這些＝明確的序號，一起拿掉（同 Swift ordinalCopulas）。 */
        private val ordinalCopulas = listOf("個是", "个是", "點是", "点是", "項是", "项是", "步是", "件是", "就是")
        /** 「是」開頭的詞（FX-7 L5）：「第一是非題」「第一個是否要延期」的「是」是詞的一部分，不是繫詞，留著（同 Swift ordinalShiWords）。 */
        private val ordinalShiWords = listOf("是非", "是否", "是不是")
        /** 「是」開頭的詞（`ordinalShiWords`）；「是非常…」的「是」還是繫詞（同 Swift startsWithShiWord）。 */
        private fun startsWithShiWord(text: String) = ordinalShiWords.any { text.startsWith(it) } && !text.startsWith("是非常")
        /** 「第N」後面接量詞＝序數名詞片語，不是條列（同 Swift ordinalMeasureWords，一組固定的字）。 */
        private val ordinalMeasureWords: List<String> = listOf("小節", "小节", "聲道", "声道", "回合") + SwiftText.graphemes(
            "軌轨台遍支個个次首張张件項项點点步章節节段位名天週周年輪轮場场集拍層层樓楼號号種种款顆颗則则筆笔趟口套組组隻條条把本部版" +
                "月日期屆届頁页代季批類类級级階阶篇份題题道句行排列局盤盘課课站棒線线任世的手波家間间塊块封堂班棟栋輛辆杯碗秒分時时人印關关圈冊册卷幕案例招式型"
        )
        /** 引言講的數量（同 Swift ordinalCountPattern）。 */
        private const val ordinalCountPattern = "(?<![第0-9一二三四五六七八九十兩百])(?:([兩二三四五六七八九十]|10|[2-9])(?:件事情|件事|樣東西|樣|項|個步驟|個重點)|([兩二三四五六七八九十])點)"
        private val ordinalIntroWords = listOf("以下", "如下", "清單")
        /**
         * (B) 「第N」後面直接接內容時，這一項要用這些動作動詞開頭才算條列（同 Swift ordinalListVerbs，2026-10-22 W2-6 第四輪封閉詞類）。
         * 跟 Swift 是同一份：GoldenTest 逐字比對 golden/ordinal-list-verbs.json（Swift 匯出）。量詞表優先（第三排／第一關不算動作）。
         */
        val ordinalListVerbs: List<String> = listOf(
            "買", "回", "寫", "交", "做", "改", "加", "刪", "寄", "送", "帶", "排", "繳", "洗", "煮", "倒", "拿", "找", "問", "練", "讀", "修",
            "開", "關", "去", "收", "錄", "準備", "更新", "匯出", "匯入", "確認", "檢查", "整理", "補錄", "重錄", "重做", "重開", "重新",
            "上傳", "下載", "安裝", "測試", "聯絡", "通知", "預約", "處理", "安排", "提醒", "規劃", "設定", "備份",
            // 簡體
            "买", "写", "删", "带", "缴", "问", "练", "读", "开", "关", "录", "准备", "汇出", "汇入", "确认", "检查", "补录", "重录", "重开",
            "上传", "下载", "安装", "测试", "联络", "预约", "处理", "规划", "备份",
        )
        /** 用表上的動詞開頭、其實是名詞的詞（同 Swift ordinalListVerbNouns）；動詞後面緊接「的」也不算動作。 */
        val ordinalListVerbNouns: List<String> = listOf("交響", "交响", "錄音室", "录音室", "練習曲", "练习曲", "做法", "寫法", "写法", "加法", "修正案")
        /** (A) 「第N」前面要是子句開頭：句首、這些分隔（含空白、換行），或清單引言本身（同 Swift ordinalClauseDelimiters）。 */
        private const val ordinalClauseDelimiters = "，,、：:；;。 \t\n\r"
        /** (A) 緊接在第一個「第N」前面的清單引言（同 Swift ordinalIntroEndPattern）。 */
        private const val ordinalIntroEndPattern = "(?:清單是|清单是|清單|清单|以下|如下|$ordinalCountPattern)$"
        /** 清單項目結尾一律拿掉的標點（同 Swift listItemTrailers）。 */
        private const val listItemTrailers = "，,、；;：:。 \t"

        internal class OrdinalList(val prefix: String, val segments: List<String>, val bodies: List<String>)

        /**
         * 一句裡的序數串是不是條列（同 Swift ordinalList，2026-10-22 W2-6 第三輪保守規則＋第四輪 A／B／C）：所有的「第N」依序是 1…k（k ≥ 2）、
         * 每一項都有內容，而且每一項都：(A) 在子句開頭（句首、分隔或清單引言後面）；(B) 後面緊接分隔／空白／「是」類，或直接接
         * ordinalListVerbs 的動作（這種串還要有講數量＝項數或「以下／如下／清單」的引言）；(C) 不接量詞。不符合回 null（整句原樣）。
         */
        internal fun ordinalList(sentence: String, previous: String?): OrdinalList? {
            if (!sentence.contains("第")) return null
            val cues = icu(ordinalCuePattern).findAll(sentence).map { it.range }.toList()
            if (cues.size < 2) return null
            val segments = mutableListOf<String>()
            val items = mutableListOf<Triple<Int, String?, Boolean>>()
            for ((index, cue) in cues.withIndex()) {
                val end = if (index + 1 < cues.size) cues[index + 1].first else sentence.length
                val segment = sentence.substring(cue.first, end)
                val item = parseOrdinalLine(segment) ?: return null
                if (item.first != index + 1 || item.second == null) return null
                // (A) 第二項起：前一項的最後一個字要是分隔。
                if (index > 0 && segments[index - 1].last() !in ordinalClauseDelimiters) return null
                segments += segment
                items += item
            }
            val prefix = sentence.substring(0, cues[0].first)
            // (A) 第一項：句首、分隔，或緊接在清單引言後面。
            if (prefix.isNotEmpty() && prefix.last() !in ordinalClauseDelimiters &&
                !icu(ordinalIntroEndPattern).containsMatchIn(prefix)) return null
            if (items.any { it.third }) {
                val intro = if (SwiftText.graphemes(prefix).any { SwiftText.isLetter(it) || SwiftText.isNumber(it) }) prefix else (previous ?: "")
                val count = ordinalListIntroCount(intro) ?: return null
                if (count != 0 && count != cues.size) return null
                if (!items.all { !it.third || isVerbLedItem(it.second ?: "") }) return null
            }
            return OrdinalList(prefix, segments, items.map { it.second ?: "" })
        }

        /**
         * 一項的序數與拿掉序數後的內容；不是「第N」開頭回 null，後面接量詞時內容是 null（同 Swift parseOrdinalLine）。
         * third＝「第N」後面直接接內容（沒有分隔、空白，也不是「是」），要過 (B) 的關。
         */
        internal fun parseOrdinalLine(line: String): Triple<Int, String?, Boolean>? {
            val g = SwiftText.graphemes(line)
            var k = 0
            while (k < g.size && (g[k] == " " || g[k] == "\t")) k++
            if (k >= g.size || g[k] != "第") return null
            k++
            val numeralStart = k
            while (k < g.size && g[k] in chineseOrdinalDigits) k++
            val numeral = g.subList(numeralStart, k).joinToString("")
            if (numeral.isEmpty() || k - numeralStart > 3) return null
            val value = chineseToInt(numeral)?.toInt() ?: return null
            if (value < 1) return null
            val spaced = g.getOrNull(k) == " " || g.getOrNull(k) == "\t"
            while (k < g.size && (g[k] == " " || g[k] == "\t")) k++
            val rest = g.subList(k, g.size).joinToString("")
            var direct = false
            val copula = ordinalCopulas.firstOrNull { rest.startsWith(it) }
            var body = when {
                // 「個是／點是／就是…」後面接「是非／是否／是不是」時只拿掉「個／點／就…」；「第一是是非題」只拿掉一個「是」。同 Swift。
                copula != null -> rest.substring(copula.length - 1).let { shi ->
                    if (startsWithShiWord(shi)) shi else rest.substring(copula.length)
                }
                rest.startsWith("是") -> if (!startsWithShiWord(rest)) rest.substring(1) else rest
                g.getOrNull(k) in ordinalSeparators -> rest
                ordinalMeasureWords.any { rest.startsWith(it) } -> return Triple(value, null, false)
                else -> { if (!spaced) direct = true; rest }
            }
            body = body.trimStart('，', ',', '、', '：', ':', ' ', '\t')
            body = body.trimEnd('，', ',', '、', '；', ';', '：', ':', ' ', '\t')
            return Triple(value, if (trimListItem(body).isEmpty()) null else body, direct)
        }

        /** 引言最後一個子句講的數量；只講「以下／如下／清單」回 0；都沒有回 null（同 Swift ordinalListIntroCount）。 */
        internal fun ordinalListIntroCount(intro: String): Int? {
            var clause = intro.trim { it in " \t\n，,、：:；;。！？!?" }
            val cut = clause.indexOfLast { it in "，,、；;：:" }
            if (cut >= 0) clause = clause.substring(cut + 1)
            val m = icu(ordinalCountPattern).findAll(clause).lastOrNull()
            if (m != null) return enumerationCounts[m.groups[1]?.value ?: m.groups[2]?.value ?: return null]
            return if (ordinalIntroWords.any { clause.contains(it) }) 0 else null
        }

        /** 「第N」後面直接接的內容是不是一個動作：用 ordinalListVerbs 的動詞開頭（取最長的），不是 ordinalListVerbNouns，動詞後面不是「的」（同 Swift isVerbLedItem）。 */
        internal fun isVerbLedItem(body: String): Boolean {
            if (ordinalListVerbNouns.any { body.startsWith(it) }) return false
            val verb = ordinalListVerbs.filter { body.startsWith(it) }.maxByOrNull { it.length } ?: return false
            return !body.startsWith("的", verb.length)
        }

        /** 清單一項：結尾的「，、；：。」與空白拿掉（同 Swift trimListItem）。 */
        internal fun trimListItem(item: String): String = item.trimEnd { it in listItemTrailers }

        private val chineseOrdinalDigits = setOf("一", "二", "三", "四", "五", "六", "七", "八", "九", "十")

        /** 清單前面那一行（引言）：結尾逗號／頓號／冒號換成「：」，沒有標點就補「：」；收在句號問號等就原樣（同 Swift listIntro）。 */
        internal fun listIntro(line: String): String {
            val body = line.trimEnd(' ', '\t')
            if (body.isEmpty()) return line
            val last = body.last()
            if (last in "，,、：:") {
                val without = body.dropLast(1)
                return if (without.isEmpty()) line else "$without："
            }
            if (last in "。！？!?；;」』”\"）)….") return line
            return "$body："
        }

        /**
         * 明講數量的頓號列舉 → 編號清單（同 Swift numberCountedEnumerations，2026-10-22 W2-6 ls03；同日修正誤判與吃字）。
         * 數量（兩／二…十、2…10）＋樣／件／個／點／項（可接 東西／事情／事／重點）緊接逗號或冒號，後面頓號列舉的項數剛好等於數量、
         * 每項 ≤ 12 字、列舉講完這句就結束才動；序數／指稱（第、這、那、每、哪）、人名代名詞、鐘點、最後一項接著講事情、
         * 只有兩項卻沒明講在列的，都不動；最後一項只拿掉「還有／以及」。已經有編號清單的文字不動。
         * 2026-10-22 第二輪（同 Swift）：「N點」要緊接列重點的動詞（有／注意／講／提／列…）；最後一項比最長那項長兩個單位以上、
         * 或只長一個單位但帶著講事情的字＝列舉後面接著講話，不動（單位見 itemUnits）。
         */
        private const val countedEnumerationPattern = "^(.*?(?<![零〇一二三四五六七八九十百千萬億兩0-9第這这那每哪])(兩|二|三|四|五|六|七|八|九|十|10|[2-9])(樣|件|個|點|項)(東西|事情|事|重點)?)[ \\t]*[，,：:][ \\t]*([^，,。！？!?：:；;\\n]+)$"
        private val enumerationCounts = mapOf("兩" to 2, "二" to 2, "三" to 3, "四" to 4, "五" to 5, "六" to 6, "七" to 7, "八" to 8, "九" to 9, "十" to 10,
            "2" to 2, "3" to 3, "4" to 4, "5" to 5, "6" to 6, "7" to 7, "8" to 8, "9" to 9, "10" to 10)
        private val enumerationLastLeads = listOf("還有", "以及")
        private val enumerationPeople = setOf("你", "妳", "您", "我", "他", "她", "它", "你們", "妳們", "我們", "他們", "她們", "大家", "自己")
        private val enumerationClockContext = listOf("今天", "明天", "後天", "昨天", "今晚", "早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "約", "到", "說")
        private val enumerationPredicates = listOf("都", "各", "再", "也", "就", "你們", "我們", "他們", "負責", "去", "來", "要", "會", "一起", "記得")
        private val explicitListUnits = setOf("樣東西", "件事", "件事情", "項", "點", "個重點")
        private val explicitListVerbs = listOf("有", "注意", "準備", "買", "帶", "講", "需要")
        /** 「N點」前面要是這些（可再接「了」）才是在數重點（同 Swift pointListVerbs）。 */
        private val pointListVerbs = listOf("有", "注意", "講", "提", "列", "補充", "強調", "分享", "說明", "歸納", "整理", "包括", "包含", "分成", "分為", "以下", "需要")
        /** 最後一項只多一個單位時，結尾是這些＝接著在講事情（同 Swift enumerationRunOnEnds）。 */
        private val enumerationRunOnEnds = setOf("好", "讚", "棒", "對", "錯", "行", "來", "去", "走", "到", "了", "吧", "啊", "喔", "呢", "嗎", "啦", "耶", "欸", "嘛", "囉")

        /** 列舉一項的長度（單位）：中文等一個字一個，英文字母／數字連成一串算一個，空白不算（同 Swift itemUnits，逐 scalar 算）。 */
        internal fun itemUnits(item: String): Int {
            var units = 0
            var inWord = false
            var i = 0
            while (i < item.length) {
                val v = item.codePointAt(i)
                i += Character.charCount(v)
                val word = v in 0x30..0x39 || v in 0x41..0x5A || v in 0x61..0x7A
                if (word) {
                    if (!inWord) units++
                    inWord = true
                    continue
                }
                inWord = false
                if (v == 0x20 || v == 0x09 || v == 0x3000) continue
                units++
            }
            return units
        }
        private val numberedLine = Regex("^[ \t]*[0-9]+\\. ")

        internal fun numberCountedEnumerations(text: String): String {
            if (!text.contains("、") || hasNumberedLine(text)) return text
            val sentences = splitSentences(text)
            var changed = false
            val out = StringBuilder()
            for ((index, sentence) in sentences.withIndex()) {
                val list = countedEnumerationList(sentence)
                if (list == null) { out.append(sentence); continue }
                changed = true
                out.append(list)
                if (index != sentences.size - 1) out.append('\n')
            }
            return if (changed) out.toString() else text
        }

        internal fun countedEnumerationList(sentence: String): String? {
            if (!sentence.contains("、")) return null
            var end = sentence.length
            while (end > 0 && (sentence[end - 1] in "，,、。." || sentence[end - 1].isWhitespace())) end--
            val s = sentence.substring(0, end)
            val m = icu(countedEnumerationPattern).find(s) ?: return null
            val countGroup = m.groups[2] ?: return null
            val count = countGroup.value
            val n = enumerationCounts[count] ?: return null
            val unit = m.groups[3]?.value ?: return null
            val unitPhrase = unit + (m.groups[4]?.value ?: "")
            val beforeCount = s.substring(0, countGroup.range.first)
            val items = (m.groups[5]?.value ?: return null).split("、").map { trimSpaces(it) }.toMutableList()
            if (items.size != n) return null
            enumerationLastLeads.firstOrNull { items[n - 1].startsWith(it) }?.let { lead ->
                items[n - 1] = trimSpaces(items[n - 1].substring(lead.length))
            }
            for (k in items.indices) items[k] = trimListItem(items[k])
            if (!items.all { it.isNotEmpty() && SwiftText.count(it) <= 12 }) return null
            if (items.any { it in enumerationPeople }) return null
            if (unit == "點") {
                if (count[0].code < 128) return null
                val near = SwiftText.graphemes(beforeCount).takeLast(4).joinToString("")
                if (enumerationClockContext.any { near.contains(it) }) return null
                val verb = beforeCount.removeSuffix("了")
                if (unitPhrase != "點重點" && pointListVerbs.none { verb.endsWith(it) }) return null
            }
            val last = items[n - 1]
            val longest = items.dropLast(1).maxOfOrNull { itemUnits(it) } ?: 0
            val lastUnits = itemUnits(last)
            if (lastUnits >= longest + 2) return null
            if (lastUnits == longest + 1 &&
                (enumerationPredicates.any { last.contains(it) } || SwiftText.graphemes(last).lastOrNull() in enumerationRunOnEnds)) return null
            if (n < 3) {
                val verb = beforeCount.removeSuffix("了")
                if (unitPhrase !in explicitListUnits || explicitListVerbs.none { verb.endsWith(it) }) return null
            }
            return (m.groups[1]?.value ?: return null) + "：" + items.mapIndexed { k, item -> "\n${k + 1}. $item" }.joinToString("")
        }

        /** 有一行是「1. 」這種編號開頭。 */
        internal fun hasNumberedLine(text: String): Boolean = text.split("\n").any { numberedLine.containsMatchIn(it) }

        private val sentenceTerminators = setOf("。", "！", "？", "!", "?", "\n")
        private val sentenceClosers = setOf("」", "』", "”", "\"", "）", ")")

        /** 切句，保留句尾標點與空白（同 Swift splitSentences）。 */
        internal fun splitSentences(text: String): List<String> {
            val g = SwiftText.graphemes(text)
            val out = mutableListOf<String>()
            val cur = StringBuilder()
            var i = 0
            while (i < g.size) {
                val ch = g[i]
                cur.append(ch)
                val englishStop = ch == "." && i + 1 < g.size && g[i + 1] == " "
                if (ch in sentenceTerminators || englishStop) {
                    var j = i + 1
                    while (j < g.size && ((g[j] in sentenceTerminators && g[j] != "\n") || g[j] in sentenceClosers)) { cur.append(g[j]); j++ }
                    out += cur.toString(); cur.setLength(0)
                    i = j
                    continue
                }
                i++
            }
            if (cur.isNotEmpty()) out += cur.toString()
            return out
        }

        internal val paragraphOpeners = listOf("另外", "還有", "再來", "再者", "接下來", "接著", "此外", "至於", "關於", "對了", "順便", "最後",
            "總之", "總而言之", "整體來說", "整體而言", "總結", "結論是", "首先", "其次", "第二", "第三", "第四", "第五",
            "Also", "Another", "Finally", "By the way", "Anyway", "Overall", "In summary")
        internal val paragraphClosers = listOf("謝謝", "感謝", "麻煩", "不好意思", "辛苦了", "Thanks", "Thank you")
        internal val paragraphWeakOpeners = listOf("不過", "但是", "可是", "然而", "However", "But")
        private val greetingRegex = Regex("^[^，,。！？]{0,10}(你好|您好|哈囉|嗨|早安|午安|晚安)[，,]")

        /** 只修空白與 tab（Swift .whitespaces，不含換行）。 */
        private fun trimSpaces(t: String) = t.trim(' ', '\t')

        /**
         * 句中的段落轉折詞（同 Swift clauseOpenerPattern，2026-10-22 W2-6）：前面是逗號、後面不是「的」。
         * 當限定詞／形容用的不算（同 Swift，2026-10-22 修正）：另外一個／另外兩個／另外半、最後一天／最後半小時／最後面／最後還是、對了一半；
         * 後面接指示詞／幾也一樣（第二輪）：另外那個版本、最後這段、最後那段、最後幾個音。
         * 「接著」（第三輪，同 Swift）：「緊接著」「我接著說」前面不是逗號，不切。
         */
        private const val clauseOpenerPattern = "(?<=[，,])(?:首先|接著|另外(?![一兩二三四五六七八九十個个半這这那哪幾几些])|對了(?![嗎吗吧呢]|一半)|總之|最後(?![一兩二三四五六七八九十半面個个\\d這这那哪幾几些]|還是|还是)|第[一二三四五六七八九十]{1,3}個?部分)(?!的)"
        /**
         * 轉述別人的話（老師一直強調，首先…／他在信裡面寫，首先…／老闆告訴我們，另外…）：逗號後面到這句結束都是引文，
         * 裡面的轉折詞一個都不切（同 Swift reportedSpeechVerbs，2026-10-22 第二輪）。動詞後面可以再接一個人。
         */
        private val reportedSpeechVerbs = listOf("強調", "說", "講", "寫", "問", "提到", "提過", "表示", "提醒", "交代", "告訴", "建議", "要求",
            "認為", "覺得", "回答", "回覆", "指出", "規定")
        private val reportedSpeechListeners = listOf("我們", "你們", "他們", "她們", "大家", "我", "你", "妳", "他", "她")

        /** 逗號前面這段是不是收在轉述動詞（可再接一個人；同 Swift endsWithReportedSpeech）。 */
        internal fun endsWithReportedSpeech(clause: String): Boolean {
            var t = clause.trim(' ', '\t')
            val who = reportedSpeechListeners.firstOrNull { t.endsWith(it) }
            if (who != null) {
                val without = t.dropLast(who.length)
                if (reportedSpeechVerbs.any { without.endsWith(it) }) t = without
            }
            return reportedSpeechVerbs.any { t.endsWith(it) }
        }
        /** 開始列舉的轉折：前面那句是開場白，短短一句也自成一段（同 Swift sequenceOpeners）。 */
        private val sequenceOpeners = listOf("首先", "第一個部分", "第一部分")

        /** 一句在句中轉折詞前面切開（逗號留在前一段）；沒有就整句一個（同 Swift splitAtClauseOpeners）。 */
        internal fun splitAtClauseOpeners(sentence: String): List<String> {
            val parts = mutableListOf<String>()
            var start = 0
            for (m in icu(clauseOpenerPattern).findAll(sentence)) {
                if (m.range.first <= start) continue
                val beforeComma = sentence.substring(start, m.range.first - 1)
                if (endsWithReportedSpeech(beforeComma)) break
                parts += sentence.substring(start, m.range.first)
                start = m.range.first
            }
            parts += sentence.substring(start)
            return parts
        }

        /**
         * 段落收在句中逗號 → 逗號改句號，這一句再照句尾語氣調一次（同 Swift closeParagraph）。
         * 逗號前面是英文字母或數字 → 用英文句點「.」（同 Swift，2026-10-22 修正）。
         */
        internal fun closeParagraph(paragraph: String): String {
            val t = trimSpaces(paragraph)
            if (t.isEmpty() || (t.last() != '，' && t.last() != ',')) return t
            val body = t.dropLast(1)
            val end = trimSpaces(body).lastOrNull()
            val stop = if (end != null && end.code < 128 && end.isLetterOrDigit()) "." else "。"
            val sentences = splitSentences(body + stop)
            if (sentences.isEmpty()) return t
            return sentences.dropLast(1).joinToString("") + SentenceMood.retune(sentences.last())
        }

        /** 有換行的結果（編號清單、分段）：最後吊著的「，」「、」拿掉（同 Swift dropDanglingEndOfLines）。 */
        internal fun dropDanglingEndOfLines(text: String): String {
            if (!text.contains("\n")) return text
            var end = text.length
            while (end > 0 && text[end - 1].isWhitespace()) end--
            if (end == 0 || text[end - 1] !in "，、") return text
            val without = text.substring(0, end - 1)
            if (SwiftText.graphemes(without).none { SwiftText.isLetter(it) || SwiftText.isNumber(it) }) return text
            return without + text.substring(end)
        }

        /** 英文字數（連續的 ASCII 字母算一個字；同 Swift latinWordCount）。 */
        internal fun latinWordCount(text: String): Int {
            var words = 0
            var inWord = false
            for (c in text) {
                val letter = c in 'A'..'Z' || c in 'a'..'z'
                if (letter && !inWord) words++
                inWord = letter
            }
            return words
        }

        internal fun cjkCount(text: String): Int {
            var n = 0
            var i = 0
            while (i < text.length) {
                val cp = text.codePointAt(i)
                if (cp in 0x3400..0x9FFF) n++
                i += Character.charCount(cp)
            }
            return n
        }

        /** 英文為主的長文至少要這麼多字（英文字＋中文字）才分段（同 Swift latinParagraphMinimumWords）。 */
        private const val latinParagraphMinimumWords = 60

        /** 長文分段（同 Swift paragraphize，規則說明見 Swift 註解）。 */
        fun paragraphize(text: String): String {
            if (text.contains("\n")) return text
            val all = paragraphOpeners + paragraphClosers + paragraphWeakOpeners
            fun core(sentence: String): String {
                val t = trimSpaces(sentence)
                for (lead in listOf("然後", "那")) if (t.startsWith(lead)) {
                    val rest = t.substring(lead.length)
                    if (all.any { rest.startsWith(it) }) return rest
                }
                return t
            }
            fun starts(sentence: String, list: List<String>) = core(sentence).let { t -> list.any { t.startsWith(it) } }

            // 單位＝句子，句子裡再從句中轉折詞前面切開（soft）。
            val units = splitSentences(text).flatMap { sentence ->
                splitAtClauseOpeners(sentence).mapIndexed { index, part -> part to (index > 0) }
            }.toMutableList()
            val openers = units.drop(1).count { it.second || starts(it.first, paragraphOpeners) }
            val length = SwiftText.count(text)
            val latinWords = latinWordCount(text)
            val cjk = cjkCount(text)
            val long = if (latinWords > cjk) latinWords + cjk >= latinParagraphMinimumWords
                else length >= 100 || (length >= 80 && openers >= 2)
            if (units.size < 3 || !long) return text

            var greeting: String? = null
            greetingRegex.find(units[0].first)?.let { m ->
                greeting = trimSpaces(m.value)
                val rest = trimSpaces(units[0].first.substring(m.range.last + 1))
                if (rest.isEmpty()) units.removeAt(0) else units[0] = rest to units[0].second
            }

            val paragraphs = mutableListOf<String>()
            var current = ""
            var currentOpened = false
            for ((sentence, soft) in units) {
                val currentLength = SwiftText.count(trimSpaces(current))
                val opener = soft || starts(sentence, paragraphOpeners)
                val sequence = starts(sentence, sequenceOpeners)
                val breakHere = currentLength > 0 && (
                    (sequence && currentLength >= 6)
                        || (opener && currentLength >= (if (currentOpened) 10 else 20))
                        || (starts(sentence, paragraphClosers) && currentLength >= 20)
                        || (starts(sentence, paragraphWeakOpeners) && currentLength >= 40)
                        || currentLength >= 120)
                if (breakHere || currentLength == 0) currentOpened = opener || sequence
                if (breakHere) {
                    paragraphs += closeParagraph(current)
                    current = core(sentence)
                } else {
                    current += sentence
                }
            }
            val tail = trimSpaces(current)
            if (tail.isNotEmpty()) paragraphs += tail
            return (listOfNotNull(greeting) + paragraphs).joinToString("\n\n")
        }

        private val punctuationPairs = listOf("," to "，", "." to "。", ";" to "；", ":" to "：", "?" to "？", "!" to "！")

        /** 中文字後面的半形標點轉全形。 */
        fun normalizePunctuation(text: String): String {
            var out = applyRegex(text, "[ \\t]+([，。？！、：；])") { g -> g[1] }
            out = applyRegex(out, "([，。？！、：；])[ \\t]+") { g -> g[1] }
            // 中文後面的刪節號（... 或 …）→「……」；不先處理的話第一個點會被當句號變成「但是。..」（2026-10-20 Pixel）。同 Swift。
            out = applyRegex(out, "([\\u4E00-\\u9FFF])(?:\\.{2,}|…+)") { g -> g[1] + "……" }
            for ((from, to) in punctuationPairs) {
                out = applyRegex(out, "([\\u4E00-\\u9FFF])(" + Regex.escape(from) + ")") { g -> g[1] + to }
            }
            return latinPunctuationInChinese(out)
        }

        private val latinFullWidth = mapOf("," to "，", ";" to "；", "!" to "！", "?" to "？")

        /**
         * 英文字／數字後面的半形 , ; ! ? 在中文句子裡 → 全形（同 Swift latinPunctuationInChinese，2026-10-22）。
         * 後面接中文字就轉（空白一起拿掉）；有中文的行，行尾的 ? !、下一行之前的行尾 , 也轉。「.」「:」不碰。
         */
        internal fun latinPunctuationInChinese(text: String): String {
            val inline = applyRegex(text, "([A-Za-z0-9%)\\]])[ \\t]*([,;!?])[ \\t]*(?=[\\u4E00-\\u9FFF])") { g ->
                g[1] + (latinFullWidth[g[2]] ?: g[2])
            }
            val lines = inline.split("\n")
            return lines.mapIndexed { index, line ->
                if (line.none { it in '一'..'鿿' }) return@mapIndexed line
                var out = applyRegex(line, "([A-Za-z0-9])[ \\t]*([?!])[ \\t]*$") { g -> g[1] + (latinFullWidth[g[2]] ?: g[2]) }
                if (index < lines.size - 1) out = applyRegex(out, "([A-Za-z0-9])[ \\t]*,[ \\t]*$") { g -> g[1] + "，" }
                out
            }.joinToString("\n")
        }

        /** 多個空白壓成一個，保留換行，頭尾修剪。 */
        fun collapseWhitespace(text: String): String {
            // 連續換行最多留兩個（一個空行＝分段），分好段的結果再整理一次段落不會被併掉（同 Swift，2026-10-22 修正）。
            val sb = StringBuilder(text.length)
            var lastWasSpace = false
            var newlines = 0
            for (g in SwiftText.graphemes(text)) {
                when (g) {
                    " ", "\t" -> {
                        if (!lastWasSpace && newlines == 0) sb.append(' ')
                        lastWasSpace = true
                    }
                    "\n" -> {
                        if (newlines < 2) sb.append('\n')
                        lastWasSpace = false
                        newlines++
                    }
                    else -> {
                        sb.append(g)
                        lastWasSpace = false
                        newlines = 0
                    }
                }
            }
            return SwiftText.trim(sb.toString())
        }
    }
}

/** 輸入特徵（移植自 Swift `Routing.swift` 的 `InputFeatures`）。 */
object InputFeatures {
    fun hasListCues(text: String) = listOf(
        "第一", "第二", "第三", "第四", "第五", "首先", "其次", "再次", "接下來", "然後", "最後", "幫我記", "幫我列",
    ).any { text.contains(it) }

    fun hasSelfCorrection(text: String) =
        (text.contains("不是") && text.contains("是")) || text.contains("不對") || text.contains("改成") || text.contains("應該是")

    fun hasMarkdown(text: String) = listOf("# ", "## ", "- ", "* ", "```", "**", "__", "~~").any { text.contains(it) }

    fun hasSelectedBlock(text: String) = text.contains("<selected>") && text.contains("</selected>")
}
