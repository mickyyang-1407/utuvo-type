package com.utuvo.type.core

/**
 * 單字讀音（不計聲調的拼音）。core 是純函式層、拿不到 ICU 的 Han-Latin，
 * 所以由 app 注入（android 用 `CorrectionLearner.pinyin`）。回 null = 不知道讀音，
 * 該字一律不視為可替換（fail-closed）。
 */
fun interface CjkReadingLookup {
    fun readingOf(character: Char): String?
}

/** Pure, conservative guard: formatting and number presentation may change, substantive text may not. */
object CleanupFidelity {
    /**
     * 同音替換上限：一次 cleanup 最多能換掉來源這麼多比例的實詞。
     * 語音辨識錯字修正（除值→儲值）通常只換一兩個字；整句被換成另一句同音的話不是修正。
     */
    const val HOMOPHONE_SUBSTITUTION_PERCENT = 25

    /**
     * 語意關鍵字：讀音再像也不能換——否定、數字（含數量級）、人稱代名詞、反義同音字。
     * 否定詞互換＝語意翻轉；億→意＝數值差一個數量級；買→賣＝原意相反。
     */
    private val neverSubstituted = setOf(
        '不', '沒', '没', '別', '别', '未', '無', '无', '勿',
        '零', '〇', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
        '百', '千', '萬', '万', '億', '亿', '兆', '拾', '佰', '仟', '兩', '两',
        '我', '你', '妳', '您', '他', '她', '它', '牠', '祂', '咱',
        '買', '买', '賣', '卖'
    )

    fun isCJK(char: Char): Boolean = char.code in 0x3400..0x9FFF || char.code in 0xF900..0xFAFF

    // These ranges mark source words the model may keep or remove. The model still decides whether
    // they are fillers; this gate only makes their removal safe when the context is unambiguous.
    private val leadingFillers = Regex(
        """(?m)(?:^|(?<=[，,、。！？!?;；\n]))((?:(?:嗯嗯|嗯|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是|然後|然后)[，,、\s]*)+)(?=[\p{L}\p{N}])"""
    )
    private val pausedFillers = Regex(
        """[，,、;；](嗯嗯|嗯|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是)[，,、;；]"""
    )
    private val hesitatedDemonstrative = Regex(
        """(?:我覺得|我觉得|我想|我認為|我认为)(那個|那个)(?=[，,、;；](?:就是說|就是说|就是|我|你|我們|我们|大家|今天|明天|後天|昨天))"""
    )
    private val sentenceInitialThen = Regex("""(?m)(?:^|(?<=[。！？!?;；\n]))(然後|然后)""")
    private val repeatedPronoun = Regex("""(?=([我你妳您他她它])([，,、\s]*)(\1)(?=[\u3400-\u9FFF]))""")
    private val repeatedHanWord = Regex(
        """(?=([\u3400-\u9FFF]{2,4})(\1)(?=[\u3400-\u9FFF]|[，,、\s。！？!?;；]|$))"""
    )
    private val numericCorrectionWithTail = Regex(
        """((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?)([\u3400-\u9FFF]{2,6})[，,;；]\s*(?:啊[，,、\s]*)?(?:不對|不是|更正|講錯了|說錯了|no|I mean|sorry)[，,;；]\s*(?:是|為)?\s*((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)""",
        RegexOption.IGNORE_CASE
    )
    private val supersededCorrection = Regex(
        """(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|[\u3400-\u9FFF]{2}(?:(?:跟|和|與|与)[\u3400-\u9FFF]{2,4})*|(?:[A-Za-z]+\s+)?[A-Za-z]+[0-9]*|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)[，,;；]\s*(?:啊[，,、\s]*)?(?:不對|不是|更正|講錯了|說錯了|no|I mean|sorry)[，,;；]\s*(?:是|為)?\s*""",
        RegexOption.IGNORE_CASE
    )
    private val unpunctuatedWeekdayCorrection = Regex(
        """(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+))\s*不是\s*"""
    )
    private val listPrefix = Regex("""(?m)^\s*(?:\d+[.、)]|[一二三四五六七八九十百]+[.、)]|[•*\-])\s*""")
    private val spokenListMarker = Regex("""(?m)(?:^|(?<=[，,、：:]))第[一二三四五六七八九十百]+(?:是|[，,、：:])""")
    private val firstlyListMarker = Regex("""(?m)(?:^|(?<=[，,、：:\n]))首先[，,、：:]""")
    private val listCue = Regex("""(?:清單|清单|(?:幾|几|[一二兩两三四五六七八九十0-9]+)(?:件事|個重點|个重点|樣東西|样东西|項|项|樣|样))""")
    private val numberedListItem = Regex("""(?m)^[ \t]*\d+[.、)][ \t]*(\S.*?)[ \t]*$""")
    private val listIntroCopula = Regex("""(?:清單|清单)是(?=[，,、：:\n]|$)""")
    private val listConnector = Regex("""還有|以及|和|跟""")
    private val listSeparator = Regex("""[，,、。！？!?;；：:\n]""")
    private val number = Regex("""[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?(?::[0-9]{1,2})*""")
    private val fillerTokens = listOf(
        "就是說", "就是说", "對對", "对对", "對啊", "对啊", "然後", "然后", "嗯嗯",
        "那個", "那个", "這個", "这个", "就是", "呃", "欸", "喔", "啊", "嗯"
    )
    private val fillerTokensByInitial = fillerTokens.groupBy { it.first() }

    private data class Token(val value: String, val optional: Boolean)
    private val optionalRangePatterns = listOf(
        leadingFillers to 1,
        pausedFillers to 1,
        hesitatedDemonstrative to 1,
        sentenceInitialThen to 1,
        repeatedPronoun to 3,
        repeatedHanWord to 2
    )

    fun preservesContent(original: String, cleaned: String, readings: CjkReadingLookup? = null): Boolean =
        rejectionReason(original, cleaned, readings) == null

    /** Short diagnostic for rejected cleanup output, including the source text that was lost. */
    fun rejectionReason(original: String, cleaned: String, readings: CjkReadingLookup? = null): String? {
        val listItems = numberedListItems(cleaned)
        val allowListFormatting = listItems.size >= 2 && hasListContext(original, listItems.size)
        val source = prepareSource(original, allowListFormatting, listIntroCopula.containsMatchIn(cleaned), listItems)
        val output = listPrefix.replace(Normalizer.normalizeNumbers(normalizeFullwidthDigits(cleaned)), "")
        val sourceTokens = tokens(source, optionalFillerRanges(source))
        val outputTokens = tokens(output, optionalFillerRanges(output))
        val readingsMemo = ReadingMemo(readings)
        if (matches(sourceTokens, outputTokens, readingsMemo, homophoneBudget(source))) return null

        val missing = missingSourceTokens(sourceTokens, outputTokens).joinToString(separator = "", transform = ::displayValue)
        return if (missing.isNotEmpty()) {
            "來源實詞未保留：「" + missing.take(32) + "」"
        } else {
            "輸出新增或調動了實詞"
        }
    }

    private fun prepareSource(
        original: String,
        allowListFormatting: Boolean,
        outputKeepsListIntroCopula: Boolean,
        listItems: List<String>
    ): String {
        var source = listPrefix.replace(Normalizer.normalizeNumbers(normalizeFullwidthDigits(original)), "")
        if (allowListFormatting) {
            source = spokenListMarker.replace(source, "")
            source = firstlyListMarker.replace(source, "")
            if (!outputKeepsListIntroCopula) {
                source = listIntroCopula.replace(source) { it.value.dropLast(1) }
            }
            source = removingListConnectors(source, listItems)
        }
        // Corrections and repeated words are represented as optional source tokens below. Keeping
        // the words here lets the gate accept either a cleaned result or an unchanged transcript.
        source = numericCorrectionWithTail.replace(source, "$3$2")
        source = supersededCorrection.replace(source, "")
        source = unpunctuatedWeekdayCorrection.replace(source, "")
        return Normalizer.normalizeNumbers(normalizeFullwidthDigits(source))
    }

    private fun numberedListItems(value: String): List<String> =
        numberedListItem.findAll(value).mapNotNull { it.groups[1]?.value }.toList()

    private fun hasListContext(value: String, numberedItemCount: Int): Boolean {
        if (listCue.containsMatchIn(value)) return true
        if (spokenListMarker.findAll(value).count() >= 2) return true
        val separatorCount = value.count { it in "，,、" }
        if (separatorCount >= 2) return true
        return numberedItemCount >= 3 && separatorCount >= 1 && listConnector.containsMatchIn(value)
    }

    /** Drop a conjunction only when it separates adjacent items present on numbered output lines. */
    private fun removingListConnectors(source: String, listItems: List<String>): String {
        if (listItems.size < 2) return source
        val separators = listSeparator.findAll(source).map { it.range }.toList()
        val cues = listCue.findAll(source).map { it.range }.toList()
        val outputTokens = listItems.map { tokens(it).map(Token::value) }
        val removableRanges = listConnector.findAll(source).mapNotNull { match ->
            val connector = match.range
            if (cues.isNotEmpty()) {
                val cue = cues.lastOrNull { it.last + 1 <= connector.first } ?: return@mapNotNull null
                if (separators.none { it.first >= cue.last + 1 && it.first < connector.first }) return@mapNotNull null
            }
            val previousSeparators = separators.filter { it.first < connector.first }
            val previousSeparator = previousSeparators.lastOrNull() ?: return@mapNotNull null
            val nextSeparator = separators.firstOrNull { it.first >= connector.last + 1 }

            var leftStart = previousSeparator.last + 1
            var leftEnd = connector.first
            var left = source.substring(leftStart, leftEnd).trim()
            if (left.isEmpty() && previousSeparators.size >= 2) {
                val earlierSeparator = previousSeparators[previousSeparators.lastIndex - 1]
                leftStart = earlierSeparator.last + 1
                leftEnd = previousSeparator.first
                left = source.substring(leftStart, leftEnd).trim()
            }
            val rightEnd = nextSeparator?.first ?: source.length
            val right = source.substring(connector.last + 1, rightEnd).trim()
            val leftTokens = tokens(left).map(Token::value)
            val rightTokens = tokens(right).map(Token::value)
            if (leftTokens.isEmpty() || rightTokens.isEmpty()) return@mapNotNull null

            val separatesNumberedItems = (0 until outputTokens.lastIndex).any { index ->
                hasSuffix(outputTokens[index], leftTokens) && hasPrefix(outputTokens[index + 1], rightTokens)
            }
            connector.takeIf { separatesNumberedItems }
        }.toList()
        if (removableRanges.isEmpty()) return source
        var result = source
        for (range in removableRanges.sortedByDescending { it.first }) {
            result = result.removeRange(range.first, range.last + 1)
        }
        return result
    }

    private fun hasPrefix(whole: List<String>, part: List<String>): Boolean =
        part.size <= whole.size && whole.take(part.size) == part

    private fun hasSuffix(whole: List<String>, part: List<String>): Boolean =
        part.size <= whole.size && whole.takeLast(part.size) == part

    private fun optionalFillerRanges(text: String): List<IntRange> =
        optionalRangePatterns.flatMap { (regex, group) ->
            regex.findAll(text).mapNotNull { match ->
                match.groups[group]?.range?.takeUnless { it.isEmpty() }
            }.toList()
        }

    private fun tokens(text: String, optionalRanges: List<IntRange> = emptyList()): List<Token> {
        val result = mutableListOf<Token>()
        val optionalPrefix = optionalPrefixCounts(text.length, optionalRanges)
        var index = 0
        while (index < text.length) {
            val filler = fillerTokensByInitial[text[index]]?.firstOrNull { text.startsWith(it, index) }
            if (filler != null) {
                val optional = isOptional(optionalPrefix, index, filler.length)
                result += Token("f:$filler", optional)
                index += filler.length
                continue
            }

            val codePoint = Character.codePointAt(text, index)
            if (codePoint in '0'.code..'9'.code) {
                val match = number.find(text, index)
                if (match?.range?.first == index) {
                    result += Token("n:" + match.value.replace(",", ""), false)
                    index = match.range.last + 1
                    continue
                }
                result += Token("n:" + String(Character.toChars(codePoint)), false)
            } else if (Character.isDigit(codePoint)) {
                result += Token("n:" + String(Character.toChars(codePoint)), false)
            } else if (Character.isLetter(codePoint)) {
                val charLength = Character.charCount(codePoint)
                val optional = isOptional(optionalPrefix, index, charLength)
                result += Token("l:" + String(Character.toChars(codePoint)).lowercase(), optional)
            }
            index += Character.charCount(codePoint)
        }
        return result
    }

    private fun optionalPrefixCounts(textLength: Int, ranges: List<IntRange>): IntArray {
        val changes = IntArray(textLength + 1)
        ranges.forEach { range ->
            val start = range.first
            val end = range.last + 1
            if (start >= 0 && end <= textLength && start < end) {
                changes[start]++
                changes[end]--
            }
        }
        val prefix = IntArray(textLength + 1)
        var active = 0
        for (offset in 0 until textLength) {
            active += changes[offset]
            prefix[offset + 1] = prefix[offset] + if (active > 0) 1 else 0
        }
        return prefix
    }

    private fun isOptional(prefix: IntArray, start: Int, length: Int): Boolean {
        val end = start + length
        return start >= 0 && end < prefix.size && end - start == prefix[end] - prefix[start]
    }

    /** 單字讀音每次比對可能重複查（長文數千個位元），記一次就好。 */
    private class ReadingMemo(private val lookup: CjkReadingLookup?) {
        private val cache = HashMap<Char, String>()

        /** 讀音取不到＝不視為可替換；沒注入 lookup 時直接短路，不為每個位元留 cache entry。 */
        fun readingOf(character: Char): String? {
            if (lookup == null) return null
            cache[character]?.let { return it }
            val reading = lookup.readingOf(character)
            if (reading != null) cache[character] = reading
            return reading
        }
    }

    /**
     * 同音錯字修正的額度：整句被換成另一句同音的話就不是修正了。
     * 25% 的整數除法會讓 2–3 字短句直接歸零（2*25/100 = 0），「除值→儲值」這種一個字的
     * 修正就整個被擋掉。兩個字以上至少留一個名額；單字仍維持 0。
     */
    private fun homophoneBudget(source: String): Int {
        val cjkCount = source.count { isCJK(it) }
        if (cjkCount < 2) return 0
        return maxOf(1, cjkCount * HOMOPHONE_SUBSTITUTION_PERCENT / 100)
    }

    /**
     * 對齊成本：完全相同 0、同音替換 1、optional 略過 0、其他＝不可行。
     *
     * 取「同音替換總數最少、且不超過預算」的對齊（動態規劃），而不是靠貪婪順序：
     * 之前同音比對搶在 optional 前面，「研討研討陶器」→「研討陶器」會讓被刪的那個「討」
     * 先跟後面的「陶」同音配上，之後整條對齊就錯位。反過來一律先 optional，又會讓
     * 「悠悠卡→悠遊卡」被擋——兩種都不能靠順序取捨，只能回頭找最省的解。
     *
     * 權利→權力、期中→期終這類兩字詞同音**刻意不擋**：那正是語音辨識最常見的錯字，
     * 要交給模型判斷；擋掉會連真正的修正一起擋。攔截靠的是預算上限，不是字級清單。
     */
    private fun matches(
        source: List<Token>,
        output: List<Token>,
        readings: ReadingMemo,
        budget: Int
    ): Boolean {
        val width = output.size + 1
        // best[j] = 對齊 source[0..<i) 與 output[0..<j) 所需的最少同音替換；-1 = 走不到。
        // 成本只增不減，超過預算的格子直接當不可行，省掉後面所有不可能的分支。
        var best = IntArray(width) { -1 }
        best[0] = 0
        for (sourceToken in source) {
            // 本列最後一個移動：略過 optional 的輸出 token（不動用來源）。
            for (outputIndex in output.indices) {
                if (output[outputIndex].optional) merge(best[outputIndex], best, outputIndex + 1, budget)
            }
            val next = IntArray(width) { -1 }
            for (outputIndex in 0 until width) {
                val current = best[outputIndex]
                if (current < 0) continue
                if (sourceToken.optional) merge(current, next, outputIndex, budget)
                if (outputIndex >= output.size) continue
                val cost = alignmentCost(sourceToken.value, output[outputIndex].value, readings)
                if (cost >= 0) merge(current + cost, next, outputIndex + 1, budget)
            }
            if (next.none { it >= 0 }) return false
            best = next
        }
        for (outputIndex in output.indices) {
            if (output[outputIndex].optional) merge(best[outputIndex], best, outputIndex + 1, budget)
        }
        return best[output.size] >= 0
    }

    private fun merge(cost: Int, cells: IntArray, index: Int, limit: Int) {
        if (cost < 0 || cost > limit) return
        if (cells[index] < 0 || cost < cells[index]) cells[index] = cost
    }

    /**
     * 同位置的同音單字替換＝語音辨識錯字修正（除值→儲值、元山→圓山），視為保留。
     * 讀音取不到就回 -1（不可行），不猜。
     */
    private fun alignmentCost(sourceValue: String, outputValue: String, readings: ReadingMemo): Int {
        if (sourceValue == outputValue) return 0
        val sourceCharacter = singleCJKCharacter(sourceValue) ?: return -1
        val outputCharacter = singleCJKCharacter(outputValue) ?: return -1
        if (sourceCharacter == outputCharacter) return -1
        if (sourceCharacter in neverSubstituted || outputCharacter in neverSubstituted) return -1
        val sourceReading = readings.readingOf(sourceCharacter) ?: return -1
        if (sourceReading.isEmpty() || sourceReading != readings.readingOf(outputCharacter)) return -1
        return 1
    }

    private fun singleCJKCharacter(token: String): Char? {
        if (token.length != 3 || !token.startsWith("l:")) return null
        val character = token[2]
        return if (isCJK(character)) character else null
    }

    private fun missingSourceTokens(source: List<Token>, output: List<Token>): List<String> {
        val missing = mutableListOf<String>()
        val outputPositions = tokenPositions(output)
        val sourcePositions = tokenPositions(source)
        var sourceIndex = 0
        var outputIndex = 0
        while (sourceIndex < source.size && outputIndex < output.size) {
            if (source[sourceIndex].value == output[outputIndex].value) {
                sourceIndex++
                outputIndex++
            } else if (output[outputIndex].optional) {
                outputIndex++
            } else if (source[sourceIndex].optional) {
                sourceIndex++
            } else if (nextOccurrence(outputPositions, source[sourceIndex].value, outputIndex + 1) != null) {
                outputIndex++
            } else {
                val nextSource = nextOccurrence(sourcePositions, output[outputIndex].value, sourceIndex + 1)
                if (nextSource != null) {
                    missing += source.subList(sourceIndex, nextSource).filterNot { it.optional }.map { it.value }
                    sourceIndex = nextSource
                } else {
                    missing += source[sourceIndex].value
                    sourceIndex++
                    outputIndex++
                }
            }
        }
        if (sourceIndex < source.size) {
            missing += source.subList(sourceIndex, source.size).filterNot { it.optional }.map { it.value }
        }
        return missing
    }

    private fun tokenPositions(tokens: List<Token>): Map<String, List<Int>> {
        val positions = mutableMapOf<String, MutableList<Int>>()
        tokens.forEachIndexed { index, token -> positions.getOrPut(token.value) { mutableListOf() }.add(index) }
        return positions
    }

    private fun nextOccurrence(positions: Map<String, List<Int>>, value: String, start: Int): Int? {
        val indices = positions[value] ?: return null
        var low = 0
        var high = indices.size
        while (low < high) {
            val middle = low + (high - low) / 2
            if (indices[middle] < start) low = middle + 1 else high = middle
        }
        return indices.getOrNull(low)
    }

    private fun normalizeFullwidthDigits(value: String): String = buildString(value.length) {
        value.forEach { char ->
            append(if (char in '０'..'９') (char.code - 0xFEE0).toChar() else char)
        }
    }

    private fun displayValue(token: String): String =
        if (token.length > 2) token.drop(2) else token
}
