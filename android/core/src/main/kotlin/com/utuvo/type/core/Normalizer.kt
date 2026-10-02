package com.utuvo.type.core

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
) {
    companion object {
        /** 常見中文口述贅詞。刻意保持精簡——只有真的會被誤投進句子的。 */
        val DEFAULT_FILLERS: Set<String> = setOf(
            "嗯", "嗯嗯", "啊", "啊啊", "呃", "呃呃",
            "那個", "那個那個", "這個", "這個這個",
            "就是說", "就是說說", "然後那個", "對", "欸",
            // 簡體（規則與繁體相同）
            "那个", "那个那个", "这个", "这个这个", "就是说", "然后那个", "对",
        )
    }
}

class Normalizer(val options: NormalizerOptions = NormalizerOptions()) {

    fun normalize(text: String): NormalizedText {
        var working = text
        val steps = mutableListOf<String>()
        fun stage(name: String, transform: (String) -> String) {
            working = transform(working)
            if (steps.lastOrNull() != name) steps.add(name)
        }

        stage("trim") { SwiftText.trim(it) }

        // 選取改寫的指令區塊要原樣交給 editor，不能當成一般聽寫的自我修正。
        if (InputFeatures.hasSelectedBlock(working)) {
            steps.add("selection-preserved")
            return NormalizedText(text, working, steps)
        }
        stage("spelled-letters") { joinSpelledLetters(it) }
        if (options.latinTerms.isNotEmpty()) stage("latin-names") { LatinNameFixer.fix(it, options.latinTerms) }
        if (options.dictionary.isNotEmpty()) stage("dictionary") { applyDictionary(it, options.dictionary) }
        stage("filler") { removeFillers(it, options.fillerSet) }
        stage("repeat") { collapseRepeats(it) }
        stage("self-correction") { applySelfCorrection(it) }
        stage("number-date-amount") { normalizeNumbers(it) }
        stage("list") { if (InputFeatures.hasMarkdown(it)) it else normalizeListCues(it) }
        stage("punctuation") { normalizePunctuation(it) }
        stage("particles") { reattachParticles(it) }
        stage("mood") { SentenceMood.apply(it) }   // 同 Swift：問句「？」、感嘆「！」；最後句號由送出前拿掉
        stage("collapse-whitespace") { collapseWhitespace(it) }
        stage("paragraph") { paragraphize(it) }
        return NormalizedText(text, working, steps)
    }

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

        fun applyDictionary(text: String, dict: Map<String, String>): String {
            if (dict.isEmpty()) return text
            var out = text
            for (key in dict.keys.sortedWith(longestFirst)) {
                val value = dict[key]
                if (value.isNullOrEmpty()) continue
                out = replaceDictionaryTerm(out, key, value)
            }
            return out
        }

        /**
         * 字典詞左側可以緊接中文（「我去台藝大」），右側若仍是文字＝更長詞的一部分，保留原文。
         * 例外是拼音文字詞（pik）：語音辨識常把英文黏在中文前後（「用pik播放器」），
         * 這時只有同樣是拼音文字的字元才算「更長的詞」（pika、apik），中文是邊界。
         */
        internal fun replaceDictionaryTerm(text: String, target: String, replacement: String): String {
            val chars = SwiftText.graphemes(text)
            val t = SwiftText.graphemes(target)
            if (t.isEmpty()) return text
            val latinStart = isAlphabeticWordChar(t.first())
            val latinEnd = isAlphabeticWordChar(t.last())
            val sb = StringBuilder(text.length)
            var i = 0
            while (i < chars.size) {
                val end = i + t.size
                if (end <= chars.size && chars.subList(i, end) == t) {
                    val leftBoundary = !latinStart || i == 0 || !isAlphabeticWordChar(chars[i - 1])
                    val rightBoundary = end == chars.size ||
                        !(if (latinEnd) isAlphabeticWordChar(chars[end]) else isTokenChar(chars[end]))
                    if (leftBoundary && rightBoundary) {
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
        internal val bothSidesFillers = setOf("對", "這個", "对", "这个")
        /** 兼作實詞、至少一側要是「硬邊界」（句首句尾或標點，空白不算）才算贅詞。 */
        internal val hardSideFillers = setOf("那個", "這個這個", "那個那個", "然後那個", "那个", "这个这个", "那个那个", "然后那个")
        /**
         * 兼作句尾語氣詞、只有左邊是邊界（句首、標點、空白）才算贅詞（2026-09-25 Micky 實機：「當然啊」被刪成「當然」）。
         * 「啊，我忘了」「欸，你看」刪；「當然啊」「好啊」「不錯啊」「好欸」黏在字後面是語氣，留。
         */
        internal val leadingOnlyFillers = setOf("啊", "啊啊", "欸")

        private fun isHardBoundary(g: String) = SwiftText.isPunctuation(g) || SwiftText.isNewline(g)

        fun removeFillers(text: String, fillers: Set<String>): String {
            if (fillers.isEmpty()) return text
            val chars = SwiftText.graphemes(text).toMutableList()
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
                    val isFiller = when (filler) {
                        in bothSidesFillers -> leftBoundary && rightBoundary
                        in hardSideFillers -> leftHard || rightHard
                        in leadingOnlyFillers -> leftBoundary
                        else -> leftBoundary || rightBoundary
                    }
                    if (isFiller) {
                        repeat(target.size) { chars.removeAt(index) }
                        // 不留孤兒標點：「對，明天見」→「明天見」、「好，對，就這樣」→「好，就這樣」。
                        if (index < chars.size && SwiftText.isPunctuation(chars[index]) &&
                            (index == 0 || SwiftText.isPunctuation(chars[index - 1]))
                        ) {
                            chars.removeAt(index)
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
            working = applyRegex(working, "([我你他它這那是不就要很請等])(?:[、，,\\s]+\\1)+(?=[\\u4E00-\\u9FFF]|[、，,\\s]|$)") { it[1] }
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
                if (j - i >= 2 && chars[i] in repeatableCharacters) {
                    sb.append(chars[i]); i = j
                } else {
                    sb.append(chars[i]); i++
                }
            }
            return sb.toString()
        }

        private const val SEG = "[^，。！？,!?\\s]{1,30}"
        /** 「X不是A，是B」刪掉 A 後還需要「是」的主詞／指示詞（同 Swift copulaSubjects）。 */
        private const val COPULA_SUBJECTS = "這些|那些|這個|那個|我們|你們|他們|她們|它們|這|那|它|他|她|我|你|您"

        private val selfCorrections = listOf(
            icu("($COPULA_SUBJECTS)不是($SEG)[，,。是]?是($SEG)") to "$1是$3",
            icu("不是($SEG)[，,。是]?是($SEG)") to "$2",
            icu("($SEG)不對[，,]?是($SEG)") to "$2",
            icu("($SEG)不對($SEG)") to "$2",
            icu("改成($SEG)") to "$1",
            icu("應該是($SEG)") to "$1",
        )

        /** 「不是 A，是 B」→ B；「A 不對，是 B」→ B；「A 不對 B」→ B；「改成 B」→ B。 */
        /** 停頓後「應該說／我是說／我的意思是」＝前一小句作廢（同 Swift correctionMarkers）。 */
        private val correctionMarkerWords = listOf("我的意思是", "應該說", "我是說", "应该说")

        internal fun correctionMarkers(text: String): String {
            var out = text
            repeat(5) {
                val hit = findCorrection(out) ?: return out
                val (clauseStart, comma, afterMarker) = hit
                val old = out.substring(clauseStart, comma)
                val rest = out.substring(afterMarker).trimStart('，', ',', ' ')
                var keep = ""
                for (n in listOf(2, 1)) {
                    val anchor = SwiftText.graphemes(rest).take(n).joinToString("")
                    if (SwiftText.count(anchor) == n) { val r = old.lastIndexOf(anchor); if (r >= 0) { keep = old.substring(0, r); break } }
                }
                out = out.substring(0, clauseStart) + keep + rest
            }
            return out
        }

        private val standaloneCorrections = listOf("喔不對", "哦不對", "噢不對", "不對不對", "不對", "不是不是", "不是", "說錯了", "講錯了", "说错了")

        private fun findCorrection(s: String): Triple<Int, Int, Int>? {
            val breakers = setOf('，', ',', '。', '！', '？', '!', '?', '\n')
            for (marker in standaloneCorrections) {
                var from = 0
                while (true) {
                    val r = s.indexOf(marker, from)
                    if (r < 0) break
                    val end = r + marker.length
                    val before = r > 0 && (s[r - 1] == '，' || s[r - 1] == ',')
                    val after = end < s.length && (s[end] == '，' || s[end] == ',')
                    if (before && after) {
                        val comma = r - 1
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
                    if (p > 0 && s[p - 1] == ' ') p--
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
            text = applyRegex(text, "(?<![\\d.:])(\\d{1,2})([:.])([1-5])0([一二三四五六七八九])") { g -> "${g[1]}${g[2]}${g[3]}${chineseDigit[g[4]] ?: 0}" }
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

        fun applySelfCorrection(text: String): String {
            var out = repairAfterFiller(correctionMarkers(text))
            for ((re, template) in selfCorrections) out = re.replace(out, template)
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
            out = applyRegex(
                out,
                "([\\d零〇一二三四五六七八九十兩]{1,3})點(半|十五分|三十分|四十五分|([\\d零〇一二三四五六七八九十]{1,3})分|(?=[開出到交會鐘]))",
            ) { g ->
                val h = toArabic(g[1])
                when (val suffix = g[2]) {
                    "" -> "$h:00"
                    "半" -> "$h:30"
                    "十五分" -> "$h:15"
                    "三十分" -> "$h:30"
                    "四十五分" -> "$h:45"
                    else -> "$h:" + String.format("%02d", chineseToInt(suffix.dropLast(1)) ?: 0)
                }
            }
            out = applyRegex(out, "([\\d零〇一二三四五六七八九十百千萬億兩]{1,15})(元|塊|圓| dollars?)") { g ->
                chineseToInt(colloquial(g[1]))?.let { formatThousands(it) + g[2] } ?: (g[1] + g[2])
            }
            // 2026-09-24 實機回報（Fast 模式講數字不轉）：以下規則都在金額之後，避免金額規則重讀已轉好的「35,000」。
            val digit = "零〇一二三四五六七八九"
            val numeral = "零〇一二三四五六七八九十百千萬億兩"
            // 前面是這些＝不是一個確定的數（幾十個、好幾百、上百人、十多）；不轉。
            val vague = "\\d幾好數多上來餘"

            // 百分比：「百分之二十」「百分之三點五」
            out = applyRegex(out, "百分之([$numeral]{1,5})(?:點([$digit]{1,3}))?") { g ->
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
            // 小數＋單位：「三點五公斤」（「三點五分」是時間，上面已處理）
            out = applyRegex(out, "(?<![$numeral\\d])([$numeral]{1,5})點([$digit]{1,3})(公斤|公里|公尺|公分|公升|倍|度|秒|個百分點|吋|寸|歲|小時|個小時|萬|億|G|GB|TB|K|kHz|Hz|dB)") { g ->
                val whole = chineseToInt(g[1]) ?: return@applyRegex g[0]
                val frac = g[2].mapNotNull { chineseToInt(it.toString())?.toString() }.joinToString("")
                "$whole.$frac${g[3]}"
            }
            // 千以上的數字（含口語「三萬五」「兩千五」）：「預算大概三萬五」→「35,000」。必須以數字開頭：「千萬不要」不轉。
            out = applyRegex(out, "(?<![$numeral$vague])([一二兩三四五六七八九十][$numeral]*[千萬億][$numeral]*)(?![$numeral\\d])") { g ->
                val v = chineseToInt(colloquial(g[1]))
                if (v != null && v >= 1000) formatThousands(v) else g[0]
            }
            // 數字＋單位，數值 ≥ 10：「十五分鐘」→「15分鐘」；「三個問題」「一下」「十分好」不動。
            out = applyRegex(out, "(?<![$numeral${vague}第])([$numeral]{1,6})(分鐘|秒鐘|秒|小時|個小時|天|週|個禮拜|個星期|個月|年|歲|公斤|公里|公尺|公分|公升|度|人|次|張|頁|首|軌|個|位|本|台|支|件|題|篇|集|樓)") { g ->
                // 「三四五個人」＝概數：沒有十／百／千這類位值字的逐位數字不轉。
                val v = chineseToInt(colloquial(g[1]))
                if (g[1].any { it in "十百千萬億" } && v != null && v >= 10) "$v${g[2]}" else g[0]
            }
            // 逐位念的數字（至少 3 位）：「一二三四五」「零九一二…」→ 阿拉伯數字；「一五一十」這種成語中間有十不會整段成立。
            out = applyRegex(out, "(?<![$numeral\\d])([$digit]{3,})(十)?(?![$numeral\\d個人天次位年歲種隻本件])") { g ->
                val run = g[1]
                if (g[2].isNotEmpty() && run.last() != '九') return@applyRegex g[0]
                val digits = run.mapNotNull { chineseToInt(it.toString())?.toString() }.joinToString("")
                digits + if (g[2].isEmpty()) "" else "10"
            }
            return out
        }

        /** 口語省略單位：「兩千五」＝2500、「三萬五」＝35000、「一百二」＝120（最後一個數字跟在單位後面、中間沒有零）。 */
        internal fun colloquial(s: String): String {
            val chars = s.toCharArray()
            if (chars.size < 3 || chars.last() !in "一二兩三四五六七八九") return s
            return when (chars[chars.size - 2]) {
                '百' -> s + "十"
                '千' -> s + "百"
                '萬' -> s + "千"
                '億' -> s + "千萬"
                else -> s
            }
        }

        /** 由後往前替換；沒參與的群組給空字串（同 Swift 版 NSNotFound → ""）。 */
        internal fun applyRegex(text: String, pattern: String, transform: (List<String>) -> String): String {
            val matches = icu(pattern).findAll(text).toList()
            if (matches.isEmpty()) return text
            val sb = StringBuilder(text)
            for (m in matches.asReversed()) {
                val groups = m.groups.map { it?.value ?: "" }
                sb.replace(m.range.first, m.range.last + 1, transform(groups))
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

        private val numberedCues = listOf("第一", "第二", "第三", "第四", "第五", "第六", "第七", "第八", "第九", "第十")
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
        fun joinSpelledLetters(text: String): String =
            applyRegex(text, "(?<![A-Za-z])[A-Za-z](?: [A-Za-z])+(?![A-Za-z])") { g -> g[0].replace(" ", "") }

        /** 條列：以句為單位，一句裡有兩種以上不同的 cue 才換行；cue 後面緊接「的」不算（同 Swift，2026-09-19）。 */
        fun normalizeListCues(text: String): String = splitSentences(text).joinToString("") { listifySentence(it) }

        internal fun listifySentence(sentence: String): String {
            fun distinct(cues: List<String>) = cues.count { cue ->
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
            val numbered = distinct(numberedCues)
            val verbal = distinct(verbalCues)
            if (numbered < 2 && verbal < 2) return sentence
            var out = sentence
            if (numbered >= 2) out = applyRegex(out, "(第一|第二|第三|第四|第五|第六|第七|第八|第九|第十)(?!的)([^第]{1,40}?)(?=第|[。！？!?]|$)") { g -> "\n${g[1]}${g[2]}" }
            if (verbal >= 2) out = applyRegex(out, "(首先|其次|再次|然後|接下來|最後)(?!的)(.{1,40}?)(?=首先|其次|再次|然後|接下來|最後|[。！？!?]|$)") { g -> "\n${g[1]}${g[2]}" }
            return out
        }

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

        private val paragraphOpeners = listOf("另外", "還有", "再來", "再者", "接下來", "此外", "至於", "關於", "對了", "順便", "最後",
            "總之", "總而言之", "整體來說", "整體而言", "總結", "結論是", "首先", "其次", "第二", "第三", "第四", "第五",
            "Also", "Another", "Finally", "By the way", "Anyway", "Overall", "In summary")
        private val paragraphClosers = listOf("謝謝", "感謝", "麻煩", "不好意思", "辛苦了", "Thanks", "Thank you")
        private val paragraphWeakOpeners = listOf("不過", "但是", "可是", "然而", "However", "But")
        private val greetingRegex = Regex("^[^，,。！？]{0,10}(你好|您好|哈囉|嗨|早安|午安|晚安)[，,]")

        /** 只修空白與 tab（Swift .whitespaces，不含換行）。 */
        private fun trimSpaces(t: String) = t.trim(' ', '\t')

        /** 長文分段（同 Swift paragraphize，規則說明見 Swift 註解）。 */
        fun paragraphize(text: String): String {
            if (text.contains("\n")) return text
            val sentences = splitSentences(text).toMutableList()
            if (sentences.size < 3 || SwiftText.count(text) < 100) return text

            var greeting: String? = null
            greetingRegex.find(sentences[0])?.let { m ->
                greeting = trimSpaces(m.value)
                val rest = trimSpaces(sentences[0].substring(m.range.last + 1))
                if (rest.isEmpty()) sentences.removeAt(0) else sentences[0] = rest
            }
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

            val paragraphs = mutableListOf<String>()
            var current = ""
            for (sentence in sentences) {
                val length = SwiftText.count(trimSpaces(current))
                val breakHere = length > 0 && (
                    (starts(sentence, paragraphOpeners) && length >= 20)
                        || (starts(sentence, paragraphClosers) && length >= 20)
                        || (starts(sentence, paragraphWeakOpeners) && length >= 40)
                        || length >= 120)
                if (breakHere) {
                    paragraphs += trimSpaces(current)
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
            for ((from, to) in punctuationPairs) {
                out = applyRegex(out, "([\\u4E00-\\u9FFF])(" + Regex.escape(from) + ")") { g -> g[1] + to }
            }
            return out
        }

        /** 多個空白壓成一個，保留換行，頭尾修剪。 */
        fun collapseWhitespace(text: String): String {
            val sb = StringBuilder(text.length)
            var lastWasSpace = false
            var lastWasNewline = false
            for (g in SwiftText.graphemes(text)) {
                when (g) {
                    " ", "\t" -> {
                        if (!lastWasSpace && !lastWasNewline) sb.append(' ')
                        lastWasSpace = true
                    }
                    "\n" -> {
                        if (!lastWasNewline) sb.append('\n')
                        lastWasSpace = false
                        lastWasNewline = true
                    }
                    else -> {
                        sb.append(g)
                        lastWasSpace = false
                        lastWasNewline = false
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
