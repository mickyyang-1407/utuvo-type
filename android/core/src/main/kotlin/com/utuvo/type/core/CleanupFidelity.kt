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

    /** 有停頓的改口詞（「，不對，」「，不是，」「，更正，」…），後面可以接「是／為」。同 Swift `correctionMarker`。 */
    private const val CORRECTION_MARKER = """[，,;；]\s*(?:啊[，,、\s]*)?(?:不對|不是|更正|講錯了|說錯了|no|I mean|sorry)[，,;；]\s*(?:是|為)?\s*"""

    /**
     * 負號（FX-3 ①）：數字前面的減號，前一個字不是英數字（「A-1」「COVID-19」）、也不是「數字＋空白」（「3 -5」）。
     * 數字中間的連字號（電話 0912-345-678、日期 2026-10-22、區間 3-5）不是負號。
     * 響度、電平單位後面緊接的減號照樣是負號（「LUFS-14」＝-14，不是「A-1」那種編號）。
     * 減號跟數字中間隔了空白也是負號（FX-7 M4：「目標響度是− 14 LUFS」＝-14）：「−」「－」都算；ASCII「-」前面要緊接
     * 非空白的字——行首的「- 14」是項目符號、「3 - 5」是減法，不算。同 Swift `minusSign`。
     */
    private const val MINUS_SIGN = """(?:(?<![A-Za-z0-9])|(?<=(?<![A-Za-z])(?i:lufs|lkfs|dbfs|dbtp|db)))(?<![0-9][ \t])(?:[-−－](?=[0-9])|[−－](?=[ \t]+[0-9])|(?<=[^\t\n\u000B\f\r\u0085\p{Zs}\u2028\u2029])-(?=[ \t]+[0-9]))"""
    private val levelUnits = setOf("lufs", "lkfs", "dbfs", "dbtp", "db")

    /**
     * 同一次把關裡 introducesNumberValues、reordersNumberValues、invertsContrast、swapsAroundSharedMiddle 會對同一段原文
     * 重複轉數字寫法、套改口、找數值、斷詞，兩千字的段落一次要好幾毫秒。這些都是純函式：
     * 記住最近 8 次的結果，省掉重算（FX-3 第四輪起短句也記：一次把關會把同一句轉好幾次數字寫法）。同 Swift `RecentResults`。
     */
    private class RecentResults<V>(private val transform: (String) -> V) {
        private val entries = ArrayDeque<Pair<String, V>>()

        operator fun invoke(key: String): V {
            synchronized(entries) { entries.lastOrNull { it.first == key }?.let { return it.second } }
            val value = transform(key)
            synchronized(entries) {
                entries.addLast(key to value)
                while (entries.size > 8) entries.removeFirst()
            }
            return value
        }
    }

    private val numberForms = RecentResults { Normalizer.normalizeNumbers(it) }
    private val correctedForms = RecentResults { Normalizer.correctionMarkers(it) }
    private val numberValueScans = RecentResults { scanNumberValues(it) }
    /** 掉值那條規則用的掃描（清單編號的判斷不同，見 dropsLineOrdinal）。同 Swift。 */
    private val dropsNumberValueScans = RecentResults { scanNumberValues(it, true) }
    private val meaningTokenLists = RecentResults { tokenizeMeaning(it) }

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
    // 「恩」是語音辨識把「嗯」寫錯的字，但也是實詞（恩人），後面一定要有停頓才算贅詞（同 Swift）。
    private val leadingFillers = Regex(
        """(?m)(?:^|(?<=[，,、。！？!?;；\n]))((?:(?:嗯嗯|嗯|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是|然後|然后)[，,、\s]*|恩恩?[，,、\s]+)+)(?=[\p{L}\p{N}])"""
    )
    private val pausedFillers = Regex(
        """[，,、;；](嗯嗯|嗯|恩恩|恩|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是)[，,、;；]"""
    )
    private val hesitatedDemonstrative = Regex(
        """(?:我覺得|我觉得|我想|我認為|我认为)(那個|那个)(?=[，,、;；](?:就是說|就是说|就是|我|你|我們|我们|大家|今天|明天|後天|昨天))"""
    )
    // 沒有標點的「我覺得那個就是這個 low end」：後面緊接另一個「這個／那個」時，前面那串只是在想詞（同 Swift）。
    private val hesitatedDemonstrativeChain = Regex(
        """(?:我覺得|我觉得|我想|我認為|我认为)((?:那個|那个)[，,、;；\s]*(?:(?:嗯|呃|恩)[，,、;；\s]*)?(?:就是說|就是说|就是)[，,、;；\s]*)(?=這個|这个|那個|那个)"""
    )
    private val sentenceInitialThen = Regex("""(?m)(?:^|(?<=[。！？!?;；\n]))(然後|然后)""")
    private val repeatedPronoun = Regex("""(?=([我你妳您他她它])([，,、\s]*)(\1)(?=[\u3400-\u9FFF]))""")
    private val repeatedHanWord = Regex(
        """(?=([\u3400-\u9FFF]{2,4})(\1)(?=[\u3400-\u9FFF]|[，,、\s。！？!?;；]|$))"""
    )
    private val numericCorrectionWithTail = Regex(
        """((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?)([\u3400-\u9FFF]{2,6})""" + CORRECTION_MARKER +
            """((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)""",
        RegexOption.IGNORE_CASE
    )
    private val supersededCorrection = Regex(
        """(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|[\u3400-\u9FFF]{2}(?:(?:跟|和|與|与)[\u3400-\u9FFF]{2,4})*|(?:[A-Za-z]+\s+)?[A-Za-z]+[0-9]*|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)""" +
            CORRECTION_MARKER,
        RegexOption.IGNORE_CASE
    )
    private val correctionMarkerRegex = Regex(CORRECTION_MARKER, RegexOption.IGNORE_CASE)
    // 改口詞前後補逗號，交給 Normalizer 既有的改口對齊；「不是」只在後面接「是」時才算改口（同 Swift）。
    private val unpunctuatedNotRightMarker = Regex("""[，,、\s]*(?:[啊呃喔哦噢欸][，,、\s]*)?(?<![對对])(?:不對[，,、\s]*)+""")
    private val unpunctuatedNotIsMarker = Regex("""[，,、\s]*(?:不是[，,、\s]*)+(?=是)""")
    private val unpunctuatedIMeanMarker = Regex("""[，,、\s]*我是說[，,、\s]*""")
    // 「星期三不是是星期四」「星期三不是，是星期四」：「不是」後面要接「是」才是改口（FX-3 ④）。
    // 單獨的「星期三不是星期四」是對比（前面那個才對），刪掉「星期三不是」會把意思整個反過來。同 Swift。
    // 「不是」前後都沒停頓（「星期三不是是星期四」）也不算改口（FX-3 第四輪 G3，同 FX-1 的改口規則），只刪有停頓的。
    private val unpunctuatedWeekdayCorrection = Regex(
        """(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+))(?:\s+不是[，,、\s]*|不是[，,、\s]+)是\s*"""
    )
    // 行首的「-」後面直接接數字是負號（「-14 LUFS」），不是項目符號（FX-3 ①）。同 Swift。
    // 編號後面直接接數字的是數值，不是清單編號（FX-9）：「3.5元」「1.1 ms」是小數，「三、一百」「五、三萬就好」是一串數字；
    // 後面隔空白或接其他字的照舊是清單編號（「1. 報告」「1. 3點開會」「二、報告」）。同 Swift。
    private val listPrefix = Regex("""(?m)^\s*(?:\d+[.、)](?![0-9])|[一二三四五六七八九十百]+[.、)](?![0-9零〇一二兩两三四五六七八九十百千萬万億亿])|[•*]|-(?![0-9]))\s*""")
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
        hesitatedDemonstrativeChain to 1,
        sentenceInitialThen to 1,
        repeatedPronoun to 3,
        repeatedHanWord to 2
    )

    fun preservesContent(original: String, cleaned: String, readings: CjkReadingLookup? = null): Boolean =
        rejectionReason(original, cleaned, readings) == null

    /**
     * 人稱不能被翻轉（同 Swift `CleanupFidelity.keepsPerson`，原本只在 iOS）：原文有「你」整理後全沒了、
     * 或原文沒有「我」整理後冒出來＝在改寫成自己的話或替對方回答；「我們」被縮成「我」也不行。
     * FX-3 ⑤：誰對誰也不能對調（「我寄給他」→「他寄給我」、「You send me」→「I send you」）：
     * 輸出的人稱要照原文的先後出現——可以省略，不能多出來或換位置。英文用 and／or 並列的人稱（「Me and him」→「He and I」）
     * 前後對調不算，那是文法修正。同一個人稱出現兩次時，光看先後擋不住對調（「我請他幫我訂」→「他請我訂」），
     * 所以再看位置：輸出的人稱緊鄰的字（前一個或後一個，兩邊分開看）原本緊鄰的是「另一個人」、而原文同一個人從沒緊鄰過它
     * ＝搶了別人的位置；兩個人互相搶了對方的位置才算對調（只有一邊——刪掉贅詞後剛好緊鄰同一個字——不算）。
     * 受詞不能被升成主詞（FX-3 第四輪 G2）：輸出裡在子句開頭的人稱，原文裡也要有一處可以當主詞
     *（「請他幫我訂票」→「他請我訂票」擋；「我想說他會打給我」→「我想他會打給我」過）。同 Swift。
     */
    fun keepsPerson(original: String, cleaned: String): Boolean {
        val second = setOf('你', '妳', '您')
        val hadSecond = original.any { it in second }
        val hasSecond = cleaned.any { it in second }
        if (hadSecond && !hasSecond) return false
        if (!original.contains("我") && cleaned.contains("我")) return false
        if (original.contains("我們") && !cleaned.contains("我們") && cleaned.contains("我")) return false   // 同 Swift：只擋縮成「我」
        val source = personMentions(original)
        val output = personMentions(cleaned)
        if (!isSubsequence(coordinatedOrder(output), coordinatedOrder(source))) return false
        val taken = HashSet<String>()
        for (mention in output) {
            if (mention.coordinated) continue
            for (side in listOf<(PersonMention) -> String>({ it.before }, { it.after })) {
                val word = side(mention)
                if (word == "|") continue
                if (source.any { it.person == mention.person && side(it) == word }) continue
                for (other in source) if (other.person != mention.person && side(other) == word) taken += mention.person + ">" + other.person
            }
        }
        if (taken.any { reversedPair(it) in taken }) return false
        // 誰當主詞（FX-3 第四輪 G2，取代第三輪的「主詞後面還有誰」比對——那條要靠子句切法，整理時拿掉「說」「that」就誤擋）：
        // 輸出裡在子句開頭（當主詞）的人稱，原文裡也要有一處可以當主詞。省掉主詞的祈使句最常見，受詞不能被升成主詞
        //（「請他幫我訂票」→「他請我訂票」、「Tell him to send me the stems」→「He told me to send the stems」）。同 Swift。
        if (output.any { mention -> mention.initial && source.none { it.person == mention.person && it.capable } }) return false
        return true
    }

    private fun reversedPair(pair: String): String {
        val people = pair.split(">")
        return people[1] + ">" + people[0]
    }

    /** 中文人稱前面緊接這些字＝它是受詞（請他、叫我、給你、跟他、把他、告訴我、拜託他、麻煩他…），不是主詞。同 Swift。 */
    private val objectMarkers: Set<String> = ("請请叫讓让要託托求逼派幫帮給给訴诉知醒問问找帶带教罵骂打寄傳传交跟和對对向替把被陪等見见" +
        "愛爱歡欢謝谢恨怪欠還还借送約约喊催拉推抱看聽听由為为與与同顧顾管騙骗誇夸嫌怕念想煩烦").map { it.toString() }.toSet()
    /** 英文主格：在哪裡都可以當主詞。受格（me／him…）只有在子句開頭才算（「Me and him will fix it」）。同 Swift。 */
    private val englishNominative = setOf("i", "we", "he", "she", "they")
    private val englishObjectCase = setOf(
        "me", "us", "him", "her", "them", "myself", "ourselves", "himself", "herself", "themselves", "yourself", "yourselves"
    )
    /** you／my／his 這類前面緊接這些字＝受詞或所有格跟著動詞、介系詞（tell you、send your file），不是主詞。同 Swift。 */
    private val englishGovernors = setOf(
        "tell", "told", "ask", "asked", "remind", "reminded", "call", "called", "send", "sent", "give", "gave", "email", "emailed",
        "text", "texted", "message", "messaged", "let", "help", "helped", "thank", "thanked", "show", "showed", "teach", "taught",
        "pay", "paid", "owe", "owed", "bring", "brought", "invite", "invited", "meet", "met", "see", "saw", "want", "wanted",
        "need", "needed", "get", "got", "ping", "pinged", "notify", "notified", "warn", "warned",
        "to", "for", "with", "at", "from", "by", "about", "of", "like", "than"
    )
    /** 子句開頭：文字開頭、標點後面，或這些連接詞、引出子句的動詞後面（略過前面的贅詞與時間詞）。同 Swift。 */
    private val clauseStops: Set<Char> = "，。！？,!?、；;：:.\n\r（(「『\"“".toSet()
    private val clauseConnectors = listOf(
        "說", "说", "講", "讲", "覺得", "觉得", "認為", "认为", "以為", "以为", "知道", "發現", "发现", "希望", "聽說", "听说",
        "然後", "然后", "所以", "但是", "可是", "不過", "不过", "因為", "因为", "結果", "结果", "如果", "而且", "或是", "或者",
        "還是", "还是", "後來", "后来", "接著", "接着", "雖然", "虽然",
        "and", "or", "but", "so", "because", "then", "if", "when", "while", "since", "although", "though", "that",
        "think", "thought", "said", "say", "says", "believe", "guess", "hope", "know", "knew", "feel", "felt"
    )
    // `timeBigrams` 宣告在後面，object 的屬性照順序初始化，所以要 lazy。
    private val clauseLeadIns: List<String> by lazy {
        listOf(
            "嗯嗯", "嗯", "呃", "欸", "喔", "啊", "那個", "那个", "這個", "这个", "就是說", "就是说", "就是", "umm", "um", "uhh", "uh", "erm",
            "today", "tomorrow", "yesterday", "tonight"
        ) + timeBigrams.sorted()
    }

    /** 一個人稱出現的地方：哪一類人稱、緊鄰的前一個與後一個詞（標點或頭尾＝「|」）、是否跟鄰近人稱用英文 and／or 並列。同 Swift。 */
    private class PersonMention(val person: String, val before: String, val after: String) {
        var coordinated = false
        var group = 0
        /** 在子句開頭（`isClauseInitial`）＝當主詞。 */
        var initial = false
        /**
         * 這一處可以當主詞：在子句開頭；或中文前面不是 `objectMarkers`（「說的對」「講得對」的對不算）；
         * 英文是主格（I／he…），或不是受格、前面也不是 `englishGovernors`。
         */
        var capable = false
    }

    /** `location` 在子句開頭：往前略過空白、贅詞、時間詞後，碰到文字開頭、標點或 `clauseConnectors`。同 Swift。 */
    private fun isClauseInitial(text: String, location: Int): Boolean {
        val spaces = setOf(' ', '\t', '　', '\u00A0')
        var end = location
        while (true) {
            while (end > 0 && text[end - 1] in spaces) end--
            if (end <= 0) return true
            if (text[end - 1] in clauseStops) return true
            val window = text.substring(maxOf(0, end - 10), end).lowercase()
            val endsWithWord: (String) -> Boolean = endsWith@{ word ->
                if (!window.endsWith(word)) return@endsWith false
                if (word.first().code >= 128) return@endsWith true
                val wordStart = end - word.length
                if (wordStart <= 0) return@endsWith true
                val unit = text[wordStart - 1]
                !(unit in 'A'..'Z' || unit in 'a'..'z')
            }
            val leadIn = clauseLeadIns.firstOrNull(endsWithWord)
            if (leadIn != null) {
                end -= leadIn.length
                continue
            }
            return clauseConnectors.any(endsWithWord)
        }
    }

    private fun personMentions(text: String): List<PersonMention> {
        val mentions = mutableListOf<PersonMention>()
        var previousEnd = -1
        for (match in personReference.findAll(text)) {
            val person = personClass(match.value) ?: continue
            val mention = PersonMention(person, neighborWord(text, match.range.first, false), neighborWord(text, match.range.last + 1, true))
            mention.group = mentions.size
            mention.initial = isClauseInitial(text, match.range.first)
            if (match.value.first().code < 128) {
                val lower = match.value.lowercase()
                mention.capable = lower in englishNominative || mention.initial ||
                    (lower !in englishObjectCase && mention.before !in englishGovernors)
            } else {
                val lead = text.substring(maxOf(0, match.range.first - 2), match.range.first)
                val adjectiveRight = lead in setOf("的對", "得對", "的对", "得对")
                mention.capable = mention.initial || mention.before !in objectMarkers || adjectiveRight
            }
            if (previousEnd >= 0 && mentions.isNotEmpty()) {
                val last = mentions.last()
                val gap = text.substring(previousEnd, match.range.first)
                val between = gap.trim(' ', '\t', '　', ' ').lowercase()
                if (between == "and" || between == "or") {
                    last.coordinated = true
                    mention.coordinated = true
                    mention.group = last.group
                }
            }
            mentions += mention
            previousEnd = match.range.last + 1
        }
        return mentions
    }

    /** 人稱的先後；並列的一組（英文 and／or）組內不分先後。同 Swift。 */
    private fun coordinatedOrder(mentions: List<PersonMention>): List<String> {
        val out = mutableListOf<String>()
        var index = 0
        while (index < mentions.size) {
            var end = index + 1
            while (end < mentions.size && mentions[end].group == mentions[index].group) end++
            out += mentions.subList(index, end).map { it.person }.sorted()
            index = end
        }
        return out
    }

    /**
     * `location` 前（或後）緊鄰的詞：略過空白；英文字母取整個單字（小寫）、阿拉伯數字取整串、其他文字取一個 UTF-16 單位；
     * 碰到標點或頭尾回「|」。同 Swift（NSString 的 UTF-16 單位）。
     */
    private fun neighborWord(text: String, location: Int, forward: Boolean): String {
        val skipped = setOf(' ', '\t', '　', ' ')
        var index = if (forward) location else location - 1
        while (index >= 0 && index < text.length && text[index] in skipped) index += if (forward) 1 else -1
        if (index < 0 || index >= text.length) return "|"
        fun isAsciiLetter(c: Char) = c in 'A'..'Z' || c in 'a'..'z'
        fun isAsciiDigit(c: Char) = c in '0'..'9'
        val unit = text[index]
        if (isAsciiLetter(unit) || isAsciiDigit(unit)) {
            val same: (Char) -> Boolean = if (isAsciiLetter(unit)) ::isAsciiLetter else ::isAsciiDigit
            var start = index
            var end = index + 1
            while (start > 0 && same(text[start - 1])) start--
            while (end < text.length && same(text[end])) end++
            return text.substring(start, end).lowercase()
        }
        return when (Character.getType(unit).toByte()) {
            Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
            Character.MODIFIER_LETTER, Character.OTHER_LETTER -> unit.toString()
            else -> "|"
        }
    }

    // 人稱：中文（加「們」＝複數）與英文代名詞，依出現順序。其他／其它／吉他／迷你／自我不是人稱（「來自我們」的我們照算）。同 Swift。
    private val personReference = Regex(
        """其他|其它|吉他|迷你|自我(?![們们])|[我你妳您他她它牠祂咱][們们]?|(?<![A-Za-z])[A-Za-z]+(?![A-Za-z])"""
    )
    private val englishPersons = mapOf(
        "me" to "1", "my" to "1", "mine" to "1", "myself" to "1",
        "we" to "1p", "us" to "1p", "our" to "1p", "ours" to "1p", "ourselves" to "1p",
        "you" to "2", "your" to "2", "yours" to "2", "yourself" to "2", "yourselves" to "2p",
        "he" to "3m", "him" to "3m", "his" to "3m", "himself" to "3m",
        "she" to "3f", "her" to "3f", "hers" to "3f", "herself" to "3f",
        "they" to "3p", "them" to "3p", "their" to "3p", "theirs" to "3p", "themselves" to "3p"
    )

    /**
     * 依出現順序列出人稱：1／1p＝我／我們，2／2p＝你／你們，3／3p＝他她它／他們。
     * 中文的他／她／它同音（ASR 常寫錯、整理時改對），算同一個；英文 he＝3m、she＝3f。「I」要大寫，全大寫的縮寫（US）不算。同 Swift。
     */
    internal fun personReferences(text: String): List<String> =
        personReference.findAll(text).mapNotNull { personClass(it.value) }.toList()

    private fun personClass(word: String): String? {
        val first = word.firstOrNull() ?: return null
        return if (first.code < 128) {
            when {
                word == "I" -> "1"
                word.length >= 2 && word == word.uppercase() -> null
                else -> englishPersons[word.lowercase()]
            }
        } else {
            val plural = word.length == 2 && (word.endsWith("們") || word.endsWith("们"))
            when (first) {
                '我' -> if (plural) "1p" else "1"
                '咱' -> "1p"
                '你', '妳', '您' -> if (plural) "2p" else "2"
                '他', '她', '它', '牠', '祂' -> if (plural) "3p" else "3"
                else -> null   // 其他、其它、吉他、迷你、自我
            }
        }
    }

    private fun isSubsequence(part: List<String>, whole: List<String>): Boolean {
        var next = 0
        for (item in part) {
            val found = (next until whole.size).firstOrNull { whole[it] == item } ?: return false
            next = found + 1
        }
        return true
    }

    private val lineOrdinal = Regex("""(?m)^[ \t]*[0-9]+[.、)](?![0-9])[ \t]*""")
    /**
     * 掉值那條規則用的清單編號：數字後面接中文數字時，那個數字是值不是編號（「100、一百」兩個值），
     * 其他照舊是編號（「1. 報告」「1. 3點開會」）。只有掉值這條路徑用這個，其他規則照舊（FX-13 修復 R5）。同 Swift。
     */
    private val dropsLineOrdinal = Regex("""(?m)^[ \t]*[0-9]+[.、)](?![0-9零〇一二兩两三四五六七八九十百千萬万億亿])[ \t]*""")
    /** 同一行裡的清單編號（「部分： 1. 前期… 2. 實際…」，換行被拿掉的條列）：前面是開頭、空白或冒號，後面接空白。同 Swift。 */
    private val inlineOrdinal = Regex("""(?:^|(?<=[\s：:]))([0-9]{1,2})\.[ \t]+(?=\S)""")
    /** 英文拼出來的數字（FX-3 第四輪 G4：「minus fourteen」＝-14）。單獨的「one」常是代名詞（the one、no one），不轉。同 Swift。 */
    private val spelledNumber = Regex(
        """(?<![A-Za-z'’-])(?i:(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[- ](one|two|three|four|five|six|seven|eight|nine)(?![A-Za-z'’-]))?|zero|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)(?![A-Za-z'’-])"""
    )
    private val spelledValues = mapOf(
        "zero" to 0, "one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5, "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9,
        "ten" to 10, "eleven" to 11, "twelve" to 12, "thirteen" to 13, "fourteen" to 14, "fifteen" to 15, "sixteen" to 16,
        "seventeen" to 17, "eighteen" to 18, "nineteen" to 19, "twenty" to 20, "thirty" to 30, "forty" to 40, "fifty" to 50,
        "sixty" to 60, "seventy" to 70, "eighty" to 80, "ninety" to 90
    )

    /** 英文拼出來的數字換成阿拉伯數字（twenty-one→21、fourteen→14），其他字不動。寬鬆把關的兩邊都先轉，數值才比得起來。同 Swift。 */
    fun spelledNumbers(text: String): String {
        if (text.none { it.code < 128 && it.isLetter() }) return text
        val matches = spelledNumber.findAll(text).toList()
        if (matches.isEmpty()) return text
        val out = StringBuilder()
        var cursor = 0
        for (match in matches) {
            val tens = match.groups[1]
            val value = if (tens == null) {
                spelledValues[match.value.lowercase()] ?: 0
            } else {
                (spelledValues[tens.value.lowercase()] ?: 0) + (match.groups[2]?.let { spelledValues[it.value.lowercase()] } ?: 0)
            }
            out.append(text, cursor, match.range.first).append(value)
            cursor = match.range.last + 1
        }
        return out.append(text, cursor, text.length).toString()
    }

    /** 拿掉同一行裡依序 1., 2., 3.… 的清單編號（至少兩個才算清單）。同 Swift。 */
    private fun removingInlineOrdinals(text: String): String {
        if (!text.contains(". ") && !text.contains(".\t")) return text
        val kept = mutableListOf<IntRange>()
        var expected = 1
        for (match in inlineOrdinal.findAll(text)) {
            if (match.groupValues[1].toIntOrNull() != expected) continue
            kept += match.range
            expected++
        }
        if (kept.size < 2) return text
        val out = StringBuilder(text)
        for (range in kept.asReversed()) out.delete(range.first, range.last + 1)
        return out.toString()
    }
    private val numberSign = Regex(MINUS_SIGN)
    /**
     * 一個數值：負號（減號、「負」「負的」「零下」、英文 minus／negative，後面可以有空白）＋阿拉伯數字（千分位、小數點、連字號分段、
     * 時刻「3:00」）或一串中文數字。同 Swift。
     */
    private val numberValueRun = Regex(
        "(?:" + MINUS_SIGN + """[ \t]*|(?:負的?|负的?|零下)[ \t]*|(?<![A-Za-z])(?i:minus|negative)[ \t]+)?(?:[0-9]+(?:(?:,[0-9]{3})+(?:\.[0-9]+)?|(?:-[0-9]+)+|\.[0-9]+|:[0-9]{2}(?![0-9]))?|[零〇一二兩两三四五六七八九十百千萬万億亿]+)"""
    )
    /** 單獨的「一」後面接量詞＝數量（「一杯拿鐵跟兩杯美式」），要跟其他數值比先後（FX-3 ②）。「一點」「一下」「一起」不在此列。同 Swift。 */
    private val quantityClassifiers = listOf(
        "杯", "張", "张", "個", "个", "位", "名", "本", "台", "臺", "支", "隻", "件", "份", "瓶", "碗", "盤", "盘", "間", "间",
        "家", "條", "条", "塊", "块", "元", "次", "天", "年", "歲", "岁", "首", "篇", "題", "题", "頁", "页", "樓", "楼",
        "輛", "辆", "箱", "盒", "包", "袋", "顆", "颗", "雙", "双", "套", "組", "组", "場", "场", "堂", "節", "节", "週", "周",
        "小時", "小时", "分鐘", "分钟", "秒", "公斤", "公里", "公尺", "公分", "人", "部", "層", "层", "號", "号", "晚"
    )
    private val englishMonths = setOf(
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    )
    /** 數值後面的單位寫法不同但同一種（改口要搬去取代同一種單位的值）。同 Swift。 */
    private val unitAliases = mapOf("点" to "點", "時" to "點", "时" to "點", "号" to "日", "號" to "日", "块" to "元", "塊" to "元", "楼" to "樓")
    private val chineseDigits = mapOf('零' to '0', '〇' to '0', '一' to '1', '二' to '2', '兩' to '2', '两' to '2', '三' to '3',
        '四' to '4', '五' to '5', '六' to '6', '七' to '7', '八' to '8', '九' to '9')

    /**
     * 一個數字出現的地方：整串的值（含負號、小數），以及連字號拆開後每一段的值（電話「0912-345-678」、區間「2-3」）。
     * `stutter`：中文數字裡相鄰重複的字併掉之後的值（ASR 結巴「十十月」＝十月），只在原文那一側採計。
     * `digits`：沒有負號、小數點的阿拉伯數字原樣（含前導零），接電話號碼用。`fraction`：可以當小數部分的一串個位數字。
     * `ordered`：輸出那一側要比先後——阿拉伯數字、帶負號的、兩個字以上的中文數字、單獨的二～九、後面接量詞的「一」；
     * 單獨的「一」「十」「百」「千」「萬」「零」常是一般詞（一起、十分、萬一），只比數值、不比先後。
     * `alternate`：原文那一側的另一種讀法（「減三dB」可以是 3 也可以寫成 -3、「10 minus 3」的 3 可以寫成 -3）。
     * `unit`：數值後面緊接的單位（一個中文字或一個英文字，小寫；同義寫法併成一種），沒有就是空字串。
     * `label`：單位加後面緊接的兩個中文字（`valueLabel`：「杯拿鐵」「樓開會」）。「B1」（地下一樓）的另一種讀法是 -1。同 Swift。
     */
    private class NumberValue(
        val whole: String?,
        val parts: List<String> = emptyList(),
        val stutter: String? = null,
        val range: IntRange = IntRange.EMPTY,
        val digits: String? = null,
        val fraction: String? = null,
        val ordered: Boolean = true,
        val alternate: String? = null,
        val unit: String = "",
        val label: String = ""
    )

    private fun canonical(digits: String): String = digits.trimStart('0').ifEmpty { "0" }

    /** 小數的值：整數部分去前導零、小數部分去尾端零（「1.50」＝「1.5」、「1.0」＝「1」）。 */
    private fun decimalValue(integer: String, fraction: String): String {
        val trimmed = fraction.trimEnd('0')
        return if (trimmed.isEmpty()) canonical(integer) else canonical(integer) + "." + trimmed
    }

    private fun numberValues(text: String, dropsOnly: Boolean = false): Pair<String, List<NumberValue>> =
        if (dropsOnly) dropsNumberValueScans(text) else numberValueScans(text)

    private fun scanNumberValues(text: String, dropsOnly: Boolean = false): Pair<String, List<NumberValue>> {
        val body = removingInlineOrdinals(if (dropsOnly) dropsLineOrdinal.replace(text, "") else lineOrdinal.replace(text, ""))
        val values = numberValueRun.findAll(body).map { match ->
            var token = match.value
            // 前後只看附近幾個字（UTF-16 單位）就夠判斷符號與單位。同 Swift。
            val before = body.substring(maxOf(0, match.range.first - 16), match.range.first).trim(' ', '\t')
            var sign = false
            var subtraction = false
            val prefix = listOf("零下", "負的", "负的", "負", "负", "-", "−", "－").firstOrNull { token.startsWith(it) }
            if (prefix != null) {
                token = token.substring(prefix.length)
                sign = true
            } else {
                val word = listOf("minus", "negative").firstOrNull { token.lowercase().startsWith(it) }
                if (word != null) {
                    token = token.substring(word.length)
                    // 「10 minus 3」是減法：3 照樣是 3，寫成「10 - 3」「10-3」都對。
                    subtraction = before.lastOrNull()?.let { it in '0'..'9' } ?: false
                    sign = !subtraction
                }
            }
            token = token.trim(' ', '\t')
            // 「減三dB」：減是動詞，3 跟 -3 兩種寫法都算對。
            val reduced = subtraction || before.endsWith("減") || before.endsWith("减")
            fun signed(value: String?): String? = if (value == null || !sign || value == "0") value else "-$value"
            fun negated(value: String?): String? = if (value == null || !reduced || value == "0") null else "-$value"
            val restStart = match.range.last + 1
            val rest = body.substring(restStart, minOf(body.length, restStart + 24))
            val unit = valueUnit(before, rest)
            val label = valueLabel(unit, rest)
            if (token.first() !in '0'..'9') {
                // 只有單位字（「萬」）時 chineseToInt 回 0，那不是一個數值。
                fun value(run: String): String? =
                    Normalizer.chineseToInt(run)?.takeUnless { it == 0L && run.none { c -> c == '零' || c == '〇' } }?.toString()
                val collapsed = buildString { for (c in token) if (isEmpty() || last() != c) append(c) }
                val digitsOnly = !sign && token.all { it in chineseDigits }
                val quantity = token == "一" && quantityClassifiers.any { rest.startsWith(it) }
                NumberValue(
                    signed(value(token)), stutter = if (collapsed == token) null else signed(value(collapsed)), range = match.range,
                    fraction = if (digitsOnly) token.map { chineseDigits.getValue(it) }.joinToString("") else null,
                    ordered = sign || quantity || token.length >= 2 || "二兩两三四五六七八九".contains(token),
                    alternate = negated(value(token)), unit = unit, label = label
                )
            } else {
                val plain = token.replace(",", "")
                val colon = plain.indexOf(':')
                val dot = plain.indexOf('.')
                if (colon >= 0) {
                    // 時刻是一個值（FX-3 第四輪 G1）：「3:00開會」是 3 點（單位「點」、標籤「點開會」），不是 3 跟 00 兩個數；
                    // 拆開的話 00 會帶走「開會」，改口的值就能搶到 3 的位置。整點就是那個鐘點，其他寫成「3:30」。同 Swift。
                    val hour = canonical(plain.substring(0, colon))
                    val minute = plain.substring(colon + 1)
                    val following = rest.trimStart(' ', '\t').takeWhile { it.isLetter() && it.code >= 128 }.take(2)
                    NumberValue(signed(if (minute == "00") hour else "$hour:$minute"), range = match.range, unit = "點", label = "點$following")
                } else if (dot >= 0) {
                    // FX-7 V1：版本號、點分的編號（版本2.10、7.10.4、V2.10）每一段照字串比，「2.10」≠「2.1」。同 Swift。
                    if (isVersionNumber(body, match.range, before, rest)) {
                        NumberValue(signed(plain), range = match.range, alternate = negated(plain), unit = unit, label = label)
                    } else {
                        // 一般的數值尾端的 0 可以省略（3.50元＝3.5元）；原樣的寫法當另一種讀法，對得上原文的版本號（版本2.10→「2.10 版」）。
                        val value = decimalValue(plain.substring(0, dot), plain.substring(dot + 1))
                        NumberValue(
                            signed(value), range = match.range,
                            alternate = negated(value) ?: (if (plain == value) null else signed(plain)), unit = unit, label = label
                        )
                    }
                } else {
                    val groups = plain.split("-").map(::canonical)
                    val digits = plain.replace("-", "")
                    // 「B1」「B2」：樓層前面的 B 是地下（「負一樓」→「B1」）。B 前面不能還有英文字母（「AB1」不算）。同 Swift。
                    val basement = !sign && groups.size == 1 && before.endsWith("B") &&
                        !(before.dropLast(1).lastOrNull()?.let { it.code < 128 && it.isLetter() } ?: false)
                    NumberValue(
                        signed(canonical(digits)), if (groups.size > 1) groups else emptyList(), range = match.range,
                        digits = if (!sign) digits else null,
                        fraction = if (!sign && groups.size == 1 && plain == token) plain else null,
                        alternate = if (groups.size > 1) null
                            else if (basement && canonical(digits) != "0") "-" + canonical(digits) else negated(canonical(digits)),
                        unit = unit, label = label
                    )
                }
            }
        }.toList()
        return body to values
    }

    /**
     * 數值後面緊接的單位：略過空白，英文取整個單字（小寫），其他文字取一個字（同義寫法併成一種）；沒有就是空字串。
     * 「3:00」的 3 是幾點；英文月份後面的數字是幾號（「October 22」＝22 日）。同 Swift。
     */
    private fun valueUnit(before: String, rest: String): String {
        val previousWord = before.takeLastWhile { it.code < 128 && it.isLetter() }
        if (previousWord.lowercase() in englishMonths) return "日"
        val trimmed = rest.trimStart(' ', '\t')
        if (trimmed.isEmpty()) return ""
        val first = trimmed[0]
        if ((first == ':' || first == '：') && trimmed.length > 1 && trimmed[1] in '0'..'9') return "點"
        if (first.code < 128 && first.isLetter()) return trimmed.takeWhile { it.code < 128 && it.isLetter() }.lowercase()
        val codePoint = trimmed.codePointAt(0)
        if (!Character.isLetter(codePoint)) return ""
        val character = String(Character.toChars(codePoint))
        return unitAliases[character] ?: character
    }

    /**
     * 單位加後面緊接的兩個中文字（「一杯拿鐵」→「杯拿鐵」、「3樓開會」→「樓開會」）：數量還綁著同一樣東西，
     * 換位置不算換主人（「兩杯拿鐵，一杯美式」→「一杯美式，兩杯拿鐵」）。英文的單位已經是整個字（apples），就是它。同 Swift。
     */
    private fun valueLabel(unit: String, rest: String): String {
        if (unit.isEmpty() || unit[0].code < 128) return unit
        val trimmed = rest.trimStart(' ', '\t')
        if (trimmed.isEmpty()) return unit
        val out = StringBuilder(unit)
        var index = Character.charCount(trimmed.codePointAt(0))
        var taken = 0
        while (index < trimmed.length && taken < 2) {
            val codePoint = trimmed.codePointAt(index)
            if (codePoint < 128 || !Character.isLetter(codePoint)) break
            out.appendCodePoint(codePoint)
            index += Character.charCount(codePoint)
            taken++
        }
        return out.toString()
    }

    /** 版本號前面緊接的英文字（FX-7 V1）：V、version、ver、iOS、macOS、Android、build（不分大小寫、整個字）；中文是「版本」「版」。同 Swift。 */
    private val versionLeads = setOf("v", "ver", "version", "ios", "macos", "android", "build")
    /** 同一個子句裡前面講過這些詞，後面的小數也是版本號（「把版本從2.9升到2.10」）；英文要是整個字。同 Swift。 */
    private val versionClauseWords = setOf("version", "ios", "macos", "android", "build")
    /** 數字後面接這些＝數量、價錢、倍數，不是版本號（「這個版本要3.50元」「新版本快1.50倍」）。同 Swift。 */
    private val measureWords = quantityClassifiers + listOf("倍", "%", "％", "度", "克", "米", "毫", "成")
    private val nonAsciiLetters = Regex("[^A-Za-z]+")

    /**
     * 帶小數點的數字是版本號或點分的編號（FX-7 V1）：點分的一串裡的一段（7.10.4、192.168.1.10）、前面緊接「版本」「版」或
     * `versionLeads`（中間可以隔空白、是、為、號、冒號）、後面緊接「版」，或同一個子句前面講過「版本」或 `versionClauseWords`、
     * 後面也不是 `measureWords`。這種數字每一段照字串比；一般的數值（3.50元、1.50倍）尾端的 0 照樣可以省略。同 Swift。
     */
    private fun isVersionNumber(body: String, range: IntRange, before: String, rest: String): Boolean {
        fun isDigit(index: Int) = index in body.indices && body[index] in '0'..'9'
        val end = range.last + 1
        if (range.first >= 2 && body[range.first - 1] == '.' && isDigit(range.first - 2)) return true
        if (end < body.length && body[end] == '.' && isDigit(end + 1)) return true
        val following = rest.trimStart(' ', '\t')
        if (following.startsWith("版")) return true
        fun isAsciiLetter(c: Char) = c in 'a'..'z' || c in 'A'..'Z'
        val lead = before.trimEnd { it in " \t是為为號号：:" }
        if (lead.endsWith("版本") || lead.endsWith("版")) return true
        if (lead.takeLastWhile(::isAsciiLetter).lowercase() in versionLeads) return true
        if (measureWords.any { following.startsWith(it) }) return false
        val clause = before.takeLastWhile { it !in "，。！？,!?、；;\n" }
        return clause.contains("版本") || clause.split(nonAsciiLetters).any { it.lowercase() in versionClauseWords }
    }

    /** 數值附近同一個子句的範圍到這些字為止（「3:00」的冒號不算）。同 Swift。 */
    private val valueContextStops: Set<Char> = "，。！？,!?、；;\n".toSet()

    private val joinableDigitGap = Regex("""[\s\u3000\-－–—~～到至,，、]{1,3}""")

    /**
     * 原文的數值依出現順序排成一格一格（連字號分段的數字每段一格）；`spans` 是可以合起來對上一個輸出數值的連續幾格：
     * 連字號分段的整串、相鄰的阿拉伯數字（中間只隔空白、連字號、「到」或逗號）接起來至少 7 位（電話重新分段；「3到5天」不算 35）、
     * 整數後面接「點」與一串個位數字＝小數（「一點五」＝1.5）。`replacements`：緊接在改口詞（「，不對，」）後面的數值在第幾格。同 Swift。
     */
    private class SourceNumbers(
        val cells: List<Set<String>>,
        val spans: List<Triple<Int, Int, String>>,
        val replacements: List<Int>,
        /** 每一格數值後面的單位（`NumberValue.unit`），改口要搬去取代同一種單位的值。同 Swift。 */
        val units: List<String>,
        /** 每一格的 `NumberValue.label`（單位＋後面兩個字）。 */
        val labels: List<String>,
        /** 每一格數值前後同一個子句裡的字（各最多 8 個 UTF-16 單位），改口時找「開會是四點」說的是哪一個值。 */
        val contexts: List<String>,
        /** 每一格數值前面緊接的詞（`ownerWord`：「預算100元」的「預算」），補回重複的值時看是不是同一個主人（FX-7 R2）。 */
        val owners: List<String>,
        /** 改口詞跟那個數值中間的字（「，不對，開會是四點」的「開會是」）；緊接在改口詞後面就沒有。 */
        val preambles: Map<Int, String>
    ) {
        /**
         * 輸出裡補回的重複值，前面緊接的詞 `owner` 是第 `cell` 格的主人（FX-7 R2）：說到第 `cell` 格的那個子句裡有這個詞，
         * 而且它不是別的值的主人（「預算100元，訂金200元」→「…訂金100元」的訂金是 200 的主人，不是 100 的）。同 Swift。
         */
        fun restates(owner: String, cell: Int): Boolean =
            contexts[cell].lowercase().contains(owner) && owners.indices.none { it != cell && owners[it] == owner }

        /** `value` 從第 `cursor` 格起最早在哪裡結束：對上一格，或一段合起來的格子。對不上回 null。 */
        fun earliestEnd(value: String, cursor: Int): Int? {
            var best = (cursor until cells.size).firstOrNull { value in cells[it] }?.let { it + 1 }
            for ((start, end, spanValue) in spans) {
                if (start >= cursor && spanValue == value) best = minOf(best ?: Int.MAX_VALUE, end)
            }
            return best
        }

        /**
         * 輸出的一個數值從第 `cursor` 格起最早在哪裡對上：整個值（或另一種讀法：「B1」＝-1）對上，
         * 或連字號各段依序對上（「2到3天」→「2-3 天」）。
         */
        fun earliestEnd(number: NumberValue, cursor: Int): Int? {
            val whole = number.whole ?: return cursor
            var best = earliestEnd(whole, cursor)
            number.alternate?.let { alternate -> earliestEnd(alternate, cursor)?.let { best = minOf(best ?: Int.MAX_VALUE, it) } }
            if (number.parts.isNotEmpty()) {
                var position: Int? = cursor
                for (part in number.parts) position = position?.let { earliestEnd(part, it) }
                if (position != null) best = minOf(best ?: Int.MAX_VALUE, position)
            }
            return best
        }

        /** 改口後的值搬到它取代的那一格（原本那格的值拿掉）：「約3點開會，地點在5樓，不對，4點」→ 4、5。 */
        fun moving(from: Int, target: Int): SourceNumbers {
            val moved = cells.toMutableList()
            moved[target] = cells[from]
            moved.removeAt(from)
            val movedUnits = units.toMutableList()
            movedUnits[target] = units[from]
            movedUnits.removeAt(from)
            val movedLabels = labels.toMutableList().apply { removeAt(from) }
            val movedContexts = contexts.toMutableList().apply { removeAt(from) }
            val movedOwners = owners.toMutableList().apply { removeAt(from) }
            val kept = spans.mapNotNull { span ->
                val (start, end, value) = span
                when {
                    target in start until end || from in start until end -> null
                    start > from -> Triple(start - 1, end - 1, value)
                    else -> span
                }
            }
            return SourceNumbers(moved, kept, emptyList(), movedUnits, movedLabels, movedContexts, movedOwners, emptyMap())
        }
    }

    private fun sourceNumbers(text: String, dropsOnly: Boolean = false): SourceNumbers {
        val (body, values) = numberValues(text, dropsOnly)
        val cells = mutableListOf<Set<String>>()
        val units = mutableListOf<String>()
        val labels = mutableListOf<String>()
        val contexts = mutableListOf<String>()
        val owners = mutableListOf<String>()
        val spans = mutableListOf<Triple<Int, Int, String>>()
        val bounds = mutableListOf<IntRange>()
        for (value in values) {
            val start = cells.size
            if (value.parts.isEmpty()) {
                cells += listOfNotNull(value.whole, value.stutter, value.alternate).toSet()
            } else {
                value.parts.forEach { cells += setOf(it) }
                value.whole?.let { spans += Triple(start, cells.size, it) }
            }
            repeat(cells.size - start) { units += value.unit }
            repeat(cells.size - start) { labels += value.label }
            var from = value.range.first
            var to = value.range.last + 1
            while (from > 0 && value.range.first - from < 8 && body[from - 1] !in valueContextStops) from--
            while (to < body.length && to - (value.range.last + 1) < 8 && body[to] !in valueContextStops) to++
            val context = body.substring(from, to)
            repeat(cells.size - start) { contexts += context }
            val owner = ownerWord(body, value.range.first)
            repeat(cells.size - start) { owners += owner }
            bounds += start until cells.size
        }
        fun gap(left: Int, right: Int): String = body.substring(values[left].range.last + 1, values[right].range.first)
        val chain = mutableListOf<Int>()
        fun flush() {
            for ((offset, start) in chain.withIndex()) {
                val digits = StringBuilder(values[start].digits ?: "")
                for (next in chain.drop(offset + 1)) {
                    digits.append(values[next].digits ?: "")
                    if (digits.length >= 7) spans += Triple(bounds[start].first, bounds[next].last + 1, canonical(digits.toString()))
                }
            }
            chain.clear()
        }
        for (index in values.indices) {
            if (values[index].digits == null) { flush(); continue }
            if (chain.isNotEmpty() && !joinableDigitGap.matches(gap(chain.last(), index))) flush()
            chain += index
        }
        flush()
        for (index in 0 until values.size - 1) {
            val whole = values[index].whole ?: continue
            val fraction = values[index + 1].fraction ?: continue
            if (values[index].parts.isNotEmpty() || whole.contains('.') || gap(index, index + 1) !in setOf("點", "点")) continue
            val value = if (whole.startsWith("-")) "-" + decimalValue(whole.drop(1), fraction) else decimalValue(whole, fraction)
            // FX-7 V1：說出來的版本號（「版本二點一零」，或連著三段以上的「七點一零點四」）每一段照字串比，只認原樣「2.10」；
            // 一般的小數兩種寫法都算（「一點五零」＝1.5＝1.50）。同 Swift。
            val dotted = (index > 0 && values[index].fraction != null && gap(index - 1, index) in setOf("點", "点")) ||
                (index + 2 < values.size && values[index + 2].fraction != null && gap(index + 1, index + 2) in setOf("點", "点"))
            val start = values[index].range.first
            val end = values[index + 1].range.last + 1
            val before = body.substring(maxOf(0, start - 16), start).trim(' ', '\t')
            val rest = body.substring(end, minOf(body.length, end + 24))
            val version = dotted || isVersionNumber(body, start until end, before, rest)
            val exact = "$whole.$fraction"
            if (!version) spans += Triple(bounds[index].first, bounds[index + 1].last + 1, value)
            if (version || exact != value) spans += Triple(bounds[index].first, bounds[index + 1].last + 1, exact)
        }
        // 改口詞後面同一個子句的第一個數值：緊接著（「，不對，4點」），或先重提是哪一個（「，不對，開會是四點」，最多 8 個字）。同 Swift。
        val replacements = mutableListOf<Int>()
        val preambles = HashMap<Int, String>()
        for (marker in correctionMarkerRegex.findAll(body)) {
            val end = marker.range.last + 1
            val index = values.indices.firstOrNull { values[it].range.first >= end } ?: continue
            if (values[index].parts.isNotEmpty() || values[index].range.first - end > 8) continue
            val preamble = body.substring(end, values[index].range.first)
            if (preamble.any { it in valueContextStops }) continue
            replacements += bounds[index].first
            if (preamble.isNotEmpty()) preambles[bounds[index].first] = preamble
        }
        return SourceNumbers(cells, spans, replacements, units, labels, contexts, owners, preambles)
    }

    /**
     * 輸出出現原文沒有的「數值」＝把數字改錯了（「1,250」→「12,500」、「3:30」→「3:00」）。同 Swift
     * `introducesNumberValues`：兩邊要先轉成同一種數字寫法；行首清單編號不算；阿拉伯與中文數字的值互通；
     * 原文結巴重複的中文數字（「十十月」）也認得併掉後的值；電話號碼重新分段（「0912到 345678」→「0912-345-678」）照樣放行。
     * 負號與小數點是數值的一部分（FX-3 ①）：「-14」≠「14」、「1.5」≠「5.1」；「負14」「零下5」＝「-14」「-5」。
     */
    fun introducesNumberValues(original: String, cleaned: String): Boolean {
        val source = sourceNumbers(original)
        return numberValues(cleaned).second.any { value ->
            val whole = value.whole ?: return@any false
            if (source.earliestEnd(whole, 0) != null) return@any false
            if (value.alternate != null && source.earliestEnd(value.alternate, 0) != null) return@any false
            value.parts.isEmpty() || !value.parts.all { source.earliestEnd(it, 0) != null }
        }
    }

    /**
     * 數值換了主人（FX-3 ②）：「預算是100元，訂金是200元」→「預算是200元，訂金是100元」、或把 100 抄到 200 的位置。
     * 輸出的數值要照原文的先後出現、次數不能變多（可以省略）。改口照樣放行：原文的幾種讀法任何一種對得上就好；
     * 有停頓的改口詞後面的值，也可以搬去取代前面最近一個同單位的值（「約3點開會，地點在5樓，不對，4點」→「約4點開會，地點在5樓」）；
     * 沒有同單位的就取代緊鄰的前一個值。不能隨便挑一個（「預算100元，訂金200元，不對，300元」的 300 是訂金，不是預算）。
     * 單位不同的數值可以互換位置（日期與時間重排），同一種單位的照原文先後。兩邊要先轉成同一種數字寫法。同 Swift。
     */
    fun reordersNumberValues(original: String, cleaned: String): Boolean {
        val scanned = numberValues(cleaned)
        val output = scanned.second.filter { it.ordered && it.whole != null }
        if (output.isEmpty()) return false
        // 不同單位的數值可以換位置（「明天下午三點，十月二十三號」→「10月23日（明天）下午3點」）：每個數值都還帶著原本的單位、
        // 同一種單位的數值照原文先後，就沒有換主人。數量還綁著同一樣東西（單位＋後面兩個字：「兩杯拿鐵，一杯美式」→
        // 「一杯美式，兩杯拿鐵」）也一樣。單位被改掉或沒有單位的，照整串的先後比。同 Swift。
        fun keepsOrder(source: SourceNumbers, key: (NumberValue) -> String, sourceKeys: List<String>): Boolean {
            if (!output.all { key(it).isNotEmpty() && it.parts.isEmpty() }) return false
            val cursors = HashMap<String, Int>()
            for (value in output) {
                val whole = value.whole ?: return false
                val found = ((cursors[key(value)] ?: 0) until source.cells.size).firstOrNull {
                    sourceKeys[it] == key(value) && whole in source.cells[it]
                } ?: return false
                cursors[key(value)] = found + 1
            }
            return true
        }
        // 輸出把同一個值緊接著說了兩次（本機版把「不是星期四，星期四我要出差」的兩個併成一個，整理模型照原話補回來）：
        // 拿掉緊接重複的值之後，跟原文的數值一個不少、順序一樣才放行。
        // 補回來的只能是同一個主人再說一次（FX-7 R2）：一個值最多補成兩個，兩個前面緊接的詞都要是空的、或是原文那一格的主人
        //（「不是4點我有會」→「不是4點；4點我有會」放行；「預算100元，訂金200元」→「預算100元，訂金100元，合計200元」擋）。同 Swift。
        val deduplicated = mutableListOf<NumberValue>()
        val runs = mutableListOf<IntRange>()
        for ((index, value) in output.withIndex()) {
            if (deduplicated.isNotEmpty() && deduplicated.last().whole == value.whole) {
                runs[runs.size - 1] = runs.last().first..index
            } else {
                deduplicated += value
                runs += index..index
            }
        }
        fun restoresRepeat(source: SourceNumbers): Boolean {
            if (!(deduplicated.size < output.size && deduplicated.size == source.cells.size &&
                    deduplicated.zip(source.cells).all { (value, cell) -> value.whole?.let { it in cell } ?: false })) return false
            return runs.indices.all { cell ->
                val run = runs[cell]
                val count = run.last - run.first + 1
                count == 1 || (count == 2 && run.all { index ->
                    val owner = ownerWord(scanned.first, output[index].range.first)
                    owner.isEmpty() || source.restates(owner, cell)
                })
            }
        }
        // 單位不同的值可以換位置，但兩個值互相換走對方後面的詞＝換了主人（FX-3 第四輪：「三樓開會，五點吃飯」→「5點開會，3樓吃飯」；
        // 時刻「5:00」以前被拆成兩個數、單位對不上才擋到，現在是一個值，要明著比）。同 Swift。
        fun swapsFollowers(source: SourceNumbers): Boolean {
            fun follower(label: String, unit: String) = if (label.startsWith(unit)) label.substring(unit.length) else ""
            fun sourceFollower(value: NumberValue): String? {
                val whole = value.whole ?: return null
                val index = source.cells.indices.firstOrNull { source.units[it] == value.unit && whole in source.cells[it] } ?: return null
                return follower(source.labels[index], source.units[index])
            }
            for ((index, value) in output.withIndex()) {
                val after = follower(value.label, value.unit)
                if (after.isEmpty()) continue
                val before = sourceFollower(value)
                if (before.isNullOrEmpty() || before == after) continue
                if (output.subList(index + 1, output.size).any { follower(it.label, it.unit) == before && sourceFollower(it) == after }) return true
            }
            return false
        }
        fun keepsOwners(source: SourceNumbers): Boolean {
            var cursor = 0
            for (value in output) {
                cursor = source.earliestEnd(value, cursor)
                    ?: return (keepsOrder(source, { it.unit }, source.units) && !swapsFollowers(source)) ||
                        keepsOrder(source, { it.label }, source.labels) || restoresRepeat(source)
            }
            return true
        }
        // 原文的幾種讀法依序比，任何一種沒有換主人就放行（一種一種算，前面的讀法對上了就不必再找後面的數值）。同 Swift。
        if (prepareSource(original, false, false, emptyList()).any { keepsOwners(sourceNumbers(it)) }) return false
        val separated = sourceNumbers(separatingCorrectionMarkers(listPrefix.replace(numberForms(normalizeFullwidthDigits(original)), "")))
        for (from in separated.replacements) {
            if (from <= 0) continue
            val unit = separated.units[from]
            var target = if (unit.isEmpty()) from - 1 else (0 until from).lastOrNull { separated.units[it] == unit } ?: (from - 1)
            // 改口先重提是哪一個（「三點開會，五點吃飯，不對，開會是四點」）：取代前面同單位、附近也說到「開會」的那個值；
            // 前面沒有一個值附近說到同一個詞，就不當改口。同 Swift。
            val preamble = separated.preambles[from]
            if (preamble != null) {
                target = (0 until from).lastOrNull {
                    (unit.isEmpty() || separated.units[it] == unit) && sharesWord(separated.contexts[it], preamble)
                } ?: continue
            }
            if (keepsOwners(separated.moving(from, target))) return false
        }
        return true
    }

    /**
     * FX-13 G1：數字句裡的一個值在輸出不見了（「100，200」→「100」）＝使用者無聲地少掉一個數字。
     * 換一種寫法不算掉（「一萬二」→「12,000」、「100，200」→「100、200」），而且要看「有幾個」不是「有沒有」——
     * 「100，100」→「100」就是掉了一個。唯一的例外是講者明講改口：被拿掉的值後面直接接著改口詞，
     * 而且改口後的那個值還留在輸出裡。
     * 只管整句除了數字（連單位字、贅詞、改口詞、標點）沒有別的東西的句子；有實詞的（預算、運費、我要…）照原判定。
     * 同 Swift `dropsNumberValues`。
     */
    fun dropsNumberValues(original: String, cleaned: String): Boolean {
        val sourceText = numberForms(original)
        val cleanedText = numberForms(cleaned)
        // 掉值這條路徑用專屬的掃描（清單編號的判斷不同，見 dropsLineOrdinal）：原文、輸出、改口
        // 都要用同一套掃描，格位才對得起來。同 Swift。
        if (!isNumberOnlyText(sourceText, true)) return false
        val source = sourceNumbers(sourceText, true)
        if (source.cells.isEmpty()) return false
        val output = numberValues(cleanedText, true).second
        // 輸出的每一個數值＝一個名額（`OutputSlot`）：整串與另一種讀法是同一個名額的兩種讀法，
        // 連字號的值要嘛當整串、要嘛當它每一段，不能兩種都來（FX-13 修復 R2：名額是獨佔的）。同 Swift。
        val slots = output.map { OutputSlot(it) }.toMutableList()
        val kept = BooleanArray(source.cells.size)
        // 沒有值的一格不是掉值：單獨的「萬」（「三 萬 塊」裡的萬）本來就沒有值，
        // `scanNumberValues` 刻意不把它算成 0，這種空的一格不配對、也不算掉（FX-13 修復 R4）。同 Swift。
        for (index in source.cells.indices) if (source.cells[index].isEmpty()) kept[index] = true
        // 原文有幾格可以合起來對上同一個輸出值（連字號分段、重新接起來的電話、「一點五」），它們只佔一個輸出值。
        for ((start, end, value) in source.spans) {
            if ((start until end).any { kept[it] }) continue
            val position = slots.indices.firstOrNull { slots[it].matchesWhole(value) } ?: continue
            slots[position].useWhole()
            for (cell in start until end) kept[cell] = true
        }
        // 每一格原文的值都要在輸出裡找得到。輸出的連字號分段可以各自配一格：
        // 「100～200」→「100-200」兩個值都還在，不算掉值（FX-13 修復 R1）。同 Swift。
        for (index in source.cells.indices) {
            if (kept[index]) continue
            val cell = source.cells[index]
            val whole = slots.indices.firstOrNull { slots[it].matchesCell(cell) }
            if (whole != null) {
                slots[whole].useWhole()
                kept[index] = true
                continue
            }
            // 輸出的連字號分段可以各自配一格：「100～200」→「100-200」兩個值都還在，不算掉值（FX-13 修復 R1）。
            // 但同一個輸出不能又當整串又當其中一段（FX-13 修復 R2）。同 Swift。
            val part = slots.indices.firstOrNull { slots[it].matchesPart(cell) }
            if (part != null) {
                slots[part].usePart(cell)
                kept[index] = true
            }
        }
        val dropped = kept.indices.filter { !kept[it] }
        if (dropped.isEmpty()) return false
        val corrections = corrections(sourceText, output = output.map { numberReadings(it) }, dropsOnly = true)
        // 改口後面的那一格是被併進改口後那個值的（「12,000，我是說，一萬二」→「12,000」本來就只留一個），不算掉值；
        // 改口詞前面那一格則是明講改掉了，只要新值有留就免掉。同 Swift。
        val lost = dropped.filter { it !in corrections.second }
        if (lost.isEmpty()) return false
        return lost.any { it !in corrections.first }
    }

    /** 一個輸出數值能讀成的樣子：整串、另一種讀法（「B1」＝-1）、連字號的每一段。同 Swift。 */
    private fun numberReadings(value: NumberValue): Set<String> =
        (listOfNotNull(value.whole, value.alternate) + value.parts).toSet()

    /**
     * 輸出的一个數值能提供的一個名額（FX-13 修復 R2：名額是獨佔的，不是「整串＋分段」兩份）。同 Swift。
     * - 整串（`100200`）與另一種讀法（`B1`＝-1）是同一個名額的兩種讀法：用掉一種，另一種也不能再用。
     * - 連字號的值（`100-200`）可以當整串用，也可以當它每一段用，但不能兩種都來：
     *   用掉整串＝分段全部失效；先用掉一段＝整串失效，其他段還在。
     */
    private class OutputSlot(value: NumberValue) {
        private val whole = value.whole
        private val alternate = value.alternate
        private var parts = value.parts.toMutableList()
        private var wholeUsed = false
        private var partsUsed = false

        /** 這個名額還能當整串（或另一種讀法）用嗎？ */
        private val wholeAvailable: Boolean get() = !wholeUsed && !partsUsed
        /** 這個名額還能當連字號的一段用嗎？ */
        private val partsAvailable: Boolean get() = !wholeUsed

        /** 原文合起來的一個值對不對得上這個名額的整串或另一種讀法。 */
        fun matchesWhole(value: String): Boolean {
            if (!wholeAvailable) return false
            return whole == value || alternate == value
        }

        /** 原文的一格對不對得上這個名額的整串或另一種讀法。 */
        fun matchesCell(cell: Set<String>): Boolean {
            if (!wholeAvailable) return false
            if (whole != null && whole in cell) return true
            if (alternate != null && alternate in cell) return true
            return false
        }

        /** 原文的一格對不對得上這個名額的某一段。 */
        fun matchesPart(cell: Set<String>): Boolean {
            if (!partsAvailable) return false
            return parts.any { it in cell }
        }

        /** 用掉整串（另一種讀法一起沒了），分段全部失效。 */
        fun useWhole() { wholeUsed = true; parts.clear() }

        /**
         * 用掉其中一段：整串失效，其他段還在。只吃掉配對的那一段——同樣的值出現兩次（`100-100`）
         * 也只配掉一段，另一段還在（FX-13 修復 R3）。同 Swift。
         */
        fun usePart(cell: Set<String>) {
            partsUsed = true
            val offset = parts.indexOfFirst { it in cell }
            if (offset >= 0) parts.removeAt(offset)
        }
    }

    /**
     * 數字句裡可以出現的單位（完整的單位詞，不是單一個字）：只認真正表示「量」的單位詞。
     * 單一個字分開看會把實詞拆開（「條件」＝條＋件），那種句子照原判定，不歸這條規則管（FX-13 修復 R2）。同 Swift。
     */
    private val numberOnlyUnits: Set<String> = setOf(
        "年", "月", "日", "時", "时", "分", "分鐘", "分钟", "秒",
        "圓", "元", "塊", "块", "點", "点", "樓", "楼", "週", "周", "歲", "岁", "個", "个",
        "次", "款", "支", "瓶", "杯", "張", "张", "條", "条", "件", "份", "組", "组", "雙", "双",
        "套", "場", "场", "節", "节", "課", "课", "頁", "页", "題", "题", "篇", "輛", "辆",
        "箱", "盒", "包", "袋", "顆", "颗", "堂", "晚", "厘", "毫", "公", "尺", "里", "斤",
        "公尺", "公分", "毫米", "公里", "公斤", "度", "成", "钟", "鐘",
        "小時", "小时", "個小時", "个小时", "毫秒"
    )
    /** 數字句裡可以出現的贅詞與改口詞（多字，先長的換掉）。 */
    private val numberOnlyFillers = listOf(
        "就是說", "就是说", "就是", "那個", "那个", "這個", "这个", "首先", "第",
        "嗯嗯", "嗯", "恩恩", "恩", "呃", "欸", "喔", "哦", "噢", "啊",
        "對對", "对对", "對啊", "对啊", "然後", "然后",
        "不對", "不对", "不是", "更正", "應該是", "应该", "講錯了", "讲错", "說錯了", "说错",
        "我是說", "我是说"
    )
    /** 英文的數量單位（保守清單）：只看整個詞。 */
    private val englishNumberUnits: Set<String> = setOf(
        "kg", "g", "mg", "ml", "l", "cm", "mm", "m", "km", "ms", "s", "min", "sec", "hr", "hrs",
        "hz", "khz", "mhz", "mb", "gb", "kb", "tb", "yuan", "rmb", "usd", "nt", "dollar", "dollars",
        "year", "years", "month", "months", "day", "days", "hour", "hours", "minute", "minutes",
        "second", "seconds", "percent", "pct"
    )
    /**
     * 整句除了數字（連必要的單位詞、贅詞、改口詞、標點）沒有別的東西＝`dropsNumberValues` 的適用範圍。
     * 數字的位置先當分隔符，剩下的字詞群（連續的字母）每一群要嘛是完整的單位詞（而且挨著數字）、
     * 要嘛是贅詞／改口詞，要嘛是英文的單位詞（挨著數字）；有別的字就是有實詞（預算、運費、條件…）。同 Swift。
     */
    private fun isNumberOnlyText(text: String, dropsOnly: Boolean = false): Boolean {
        val (body, values) = numberValues(text, dropsOnly)
        val isNumber = BooleanArray(body.length)
        for (value in values) for (index in value.range) isNumber[index] = true
        fun isSpace(char: Char) = char == ' ' || char == '\t' || char == '\n' || char == '\r' || char == '　'
        /** 這群字挨著數字嗎（單位詞要在數字的旁邊才算數字的一部分）。 */
        fun nextToNumber(start: Int, end: Int): Boolean {
            var before = start - 1
            while (before >= 0 && isSpace(body[before])) before--
            if (before >= 0 && isNumber[before]) return true
            var after = end
            while (after < body.length && isSpace(body[after])) after++
            return after < body.length && isNumber[after]
        }
        var index = 0
        while (index < body.length) {
            // 數值本身（阿拉伯數字與中文數字）不算字詞群的一部分：中文數字也是字母，不擋掉的話會跟單位黏成一群。同 Swift。
            if (isNumber[index] || !body[index].isLetter()) { index++; continue }
            val start = index
            while (index < body.length && !isNumber[index] && body[index].isLetter()) index++
            val run = body.substring(start, index)
            if (run in numberOnlyUnits || run.lowercase() in englishNumberUnits) {
                if (!nextToNumber(start, index)) return false
                continue
            }
            // 贅詞與改口詞把這群字切開（「點不對應該是點」＝「點」＋「點」）：切出來的每一段都要嘛是單位詞。同 Swift。
            var segments = listOf(run)
            for (filler in numberOnlyFillers) {
                segments = segments.flatMap { segment ->
                    if (segment.contains(filler)) segment.split(filler) else listOf(segment)
                }
            }
            val pieces = segments.filter { it.isNotEmpty() }
            if (pieces.isEmpty()) continue
            if (!pieces.all { it in numberOnlyUnits || it.lowercase() in englishNumberUnits }) return false
            if (!nextToNumber(start, index)) return false
        }
        return true
    }

    /**
     * 原文裡「某個值後面直接接著改口詞」的那幾格：`first`（`corrected`）是被明講改掉的舊值（輸出沒有它不算掉值），
     * `second`（`absorbed`）是改口後面那個新值所在的格（它就是留下來的那一個，不用再另外配一個輸出值）。
     * 只有新值還在輸出裡才算數——「100，不對，200」改成「100」連新值都沒留，不放行。同 Swift。
     */
    private val valueBeforeCorrection = Regex(
        "(?:[0-9]+(?:,[0-9]{3})*(?:\\.[0-9]+)?(?::[0-9]{1,2})?|[零〇一二兩两三四五六七八九十百千萬万億亿]+)" +
            "[點点時时日號号樓楼元塊块個个]?[，,、;；\\s]*(?:[啊呃喔哦噢欸][，,、\\s]*)*" +
            "(?:不對|不对|不是|更正|應該是|应该|講錯了|讲错|說錯了|说错|我是說|我是说|[iI] ?[Mm]ean|sorry)" +
            "[，,、;；\\s]*(?:是|為|为)?",
        RegexOption.IGNORE_CASE
    )

    /** 回傳（被改掉的舊格, 被併進新值的格）。 */
    private fun corrections(text: String, output: List<Set<String>>, dropsOnly: Boolean = false): Pair<Set<Int>, Set<Int>> {
        val (body, values) = numberValues(text, dropsOnly)
        // 每一個數值從第幾格開始（連字號分段每段一格）。
        val start = mutableListOf<Int>()
        var cell = 0
        for (value in values) {
            val count = maxOf(1, value.parts.size)
            repeat(count) { start += cell }
            cell += count
        }
        val corrected = mutableSetOf<Int>()
        val absorbed = mutableSetOf<Int>()
        for (marker in valueBeforeCorrection.findAll(body)) {
            val index = values.indices.lastOrNull {
                values[it].range.first >= marker.range.first && values[it].range.last + 1 <= marker.range.last + 1
            } ?: continue
            if (index >= start.size) continue
            val end = marker.range.last + 1
            // 改口詞後面同一個子句的第一個數值（緊接著，或先重提是哪一個，最多 8 個字）還在輸出裡。
            val next = values.indexOfFirst { it.range.first >= end && it.range.first - end <= 8 }
            if (next < 0) continue
            val gap = body.substring(end, values[next].range.first)
            if (gap.any { it in valueContextStops }) continue
            val readings = numberReadings(values[next])
            if (output.any { kept -> kept.any { value -> value in readings } }) {
                corrected += start[index]
                if (next < start.size) absorbed += start[next]
            }
        }
        return corrected to absorbed
    }

    /** 數值前面緊接、屬於數值自己的字（星期四、下午三點、10月23號）：不是主人，略過再往前找（FX-7 R2）。同 Swift。 */
    private val valuePrefixes = listOf("星期", "禮拜", "礼拜", "上午", "下午", "早上", "晚上", "中午", "凌晨", "傍晚", "週", "周", "月")

    /** `location` 前面緊接的詞（略過空白與 `valuePrefixes`）：一個英文字（小寫），或最多兩個中文字；前面是標點、數字或開頭就是空字串。同 Swift。 */
    private fun ownerWord(body: String, location: Int): String {
        var end = location
        while (end > 0 && (body[end - 1] == ' ' || body[end - 1] == '\t')) end--
        valuePrefixes.firstOrNull { end >= it.length && body.regionMatches(end - it.length, it, 0, it.length) }?.let { prefix ->
            end -= prefix.length
            while (end > 0 && (body[end - 1] == ' ' || body[end - 1] == '\t')) end--
        }
        val lead = SwiftText.graphemes(body.substring(maxOf(0, end - 16), end))
        val last = lead.lastOrNull() ?: return ""
        if (!SwiftText.isLetter(last)) return ""
        fun isAscii(g: String) = g.length == 1 && g[0].code < 128
        if (isAscii(last)) return lead.takeLastWhile { isAscii(it) && SwiftText.isLetter(it) }.joinToString("").lowercase()
        return lead.takeLastWhile { SwiftText.isLetter(it) && !isAscii(it) }.takeLast(2).joinToString("")
    }

    /** 兩段字有同一個詞：兩個中文字、或一個 4 個字母以上的英文字（改口重提「開會」對上前面的「3:00開會」）。同 Swift。 */
    private fun sharesWord(context: String, preamble: String): Boolean {
        val characters = preamble.codePoints().toArray()
        fun isWide(codePoint: Int) = codePoint >= 128 && Character.isLetter(codePoint)
        for (index in 0 until characters.size - 1) {
            if (isWide(characters[index]) && isWide(characters[index + 1]) &&
                context.contains(String(characters, index, 2))) return true
        }
        fun words(text: String) = text.lowercase().split(Regex("[^a-z]+")).filter { it.isNotEmpty() }
        val contextWords = words(context).toSet()
        return words(preamble).any { it.length >= 4 && it in contextWords }
    }

    /**
     * 一組對比：原文說 A（對的那個）不是 B。`bCore`：B 去掉開頭的介系詞、冠詞（on Thursday→thursday、在星期四→星期四），跟 B 一樣就沒有。
     * `context`：A 前面緊接的兩個詞（同一個子句裡）；`narrow`：A 是明確的一個詞。同 Swift。
     */
    /** `bare`：沒有「是」、逗號、同形狀可以認 A 的「A不是B」：只擋 A 不見了、B 變成肯定。同 Swift。 */
    private class ContrastPair(
        val a: List<String>, val b: List<String>, val bCore: List<String>?, val context: List<String>?, val narrow: Boolean,
        val bare: Boolean = false
    )

    /** 英文否定詞前面只有這些＝子句只有主詞（和助動詞），A 在前一個子句（「It's Wednesday, it's not Thursday」）。同 Swift。 */
    private val englishSubjectWords = setOf(
        "i", "i'm", "we", "we're", "you", "you're", "he", "he's", "she", "she's", "it", "it's", "they", "they're",
        "that", "that's", "this", "there", "there's", "is", "are", "was", "were", "am", "do", "does", "did",
        "will", "would", "should", "can", "could"
    )

    private val contrastStopsAfterChinese = setOf("嗎", "吗", "嘛", "吧", "呢", "啊", "不", "很", "太", "只", "都", "每")
    private val contrastStopsAfterEnglish = setOf("only", "just", "even", "sure", "yet", "really", "always", "necessarily", "too", "very", "so")
    /** 否定詞跟 B 中間可以隔一個的介系詞、冠詞（not on Thursday、不是在星期四）。同 Swift。 */
    private val contrastFunctionWords = setOf("on", "at", "in", "the", "a", "an", "to", "for", "by", "在")
    /** 本機版會把「第二版不是第三版」排成清單、在「不是」後面換行；換行不是停頓，接回去才認得出對比。同 Swift。 */
    private val lineBreakAfterNegation = Regex("""(不是|而非|並非|并非|(?<![A-Za-z])(?i:not))[ \t]*\n+[ \t]*""")

    /**
     * 對比句「是 A 不是 B」「A，不是 B」「星期三不是星期四」被整理成 B 才是對的＝意思整個反過來（「我要的是三點不是四點」→「我要的是四點。」）。
     * 改口要有「不是，是 B」「不是是 B」這種形狀，不在此列；英文的「A, not B」「Wednesday not Thursday」也照算。
     * 英文的 isn't／don't 跟 not 一樣；「A, it's not B」「A, don't B」否定詞前面只有主詞的，跟「A, not B」一樣 A 在前一個子句。
     * 沒有「是」也沒有逗號的「X不是Y」前後是同一種東西時（星期三／星期四、三點／四點、A版／B版）照下面三條看；
     * 其他的（「我要喝拿鐵不是美式」「Alice and not Bob」）看不準 A 是哪幾個詞，只擋「A 變少了、B 變成肯定」（FX-3 第四輪 G3）——
     * 「這不是問題」這類一般否定、留著 A 的改寫都不受影響。每一組對比各自看（FX-3 ③），任何一條成立就是翻轉：
     * 1. 輸出裡沒被否定的 B 比原文多（B 只能留在「不是／not」後面）；
     * 2. B 坐上了 A 的位置：B 前面緊接的兩個詞跟原文 A 前面的一樣（「預定的是台北不是台南，台南那家…」→「預定的是台南，那家…」）；
     * 3. A 是明確的一個詞時，A 變少了、B 還在——輸出還留著整組「A 不是 B」（後面省掉重提的 A）不算。
     * 「A 而非／並非 B」「A instead of／rather than B」同樣是 A 對；「不是 B 而是 A」「不是 B，是 A」「not B but A」是後面那個 A 對。
     * 1. 的例外：本機版把「不是星期四，星期四我要出差」的兩個 B 併成一個、整理模型照原話補回來（「不是 B」後面緊接一樣的 B、
     * 再接原文同一個字）不算。
     * 別處還有「不是」、或 A／B 在別處出現，都不能拿來抵；連 B 都拿掉了不算翻轉。禮拜／星期、台／臺這類換說法照樣認得。同 Swift。
     */
    fun invertsContrast(original: String, cleaned: String): Boolean {
        // 沒有否定詞就不可能有對比，省掉兩千字長段落的斷詞（每次把關都會先走這裡）。
        if (!original.contains("不") && !original.contains("非") && !original.contains("not", ignoreCase = true) &&
            !original.contains("n't", ignoreCase = true) && !original.contains("n’t", ignoreCase = true) &&
            !original.contains("instead", ignoreCase = true) && !original.contains("rather", ignoreCase = true)) return false
        val tokens = meaningTokens(lineBreakAfterNegation.replace(original, "$1"))
        val pairs = contrastPairs(tokens)
        if (pairs.isEmpty()) return false
        val source = IndexedWords(tokens.filter { it != "|" })
        val output = IndexedWords(meaningTokens(cleaned).filter { it != "|" })
        for (pair in pairs) {
            val alternatives = mutableListOf(pair.b)
            val head = pair.b.take(maxOf(2, pair.a.size))
            if (head.size < pair.b.size) alternatives += head
            pair.bCore?.let { alternatives += it }
            val assertsB = alternatives.any { assertedCount(it, output) - restoredRepeats(it, output, source) > assertedCount(it, source) }
            if (pair.bare) {
                if (assertsB && assertedCount(pair.a, output) < assertedCount(pair.a, source)) return true
                continue
            }
            if (assertsB) return true
            val context = pair.context
            if (context != null && occurrences(context + pair.b, output) > occurrences(context + pair.b, source)) return true
            if (pair.narrow && assertedCount(pair.a, output) < assertedCount(pair.a, source) && assertedCount(pair.b, output) > 0 &&
                !keepsContrast(pair, output.list)) return true
        }
        return false
    }

    /** 原文裡的每一組對比（`tokens` 是 `meaningTokens`，含子句分隔「|」）。同 Swift。 */
    private fun contrastPairs(tokens: List<String>): List<ContrastPair> {
        fun clauseStart(end: Int): Int {
            var start = end
            while (start > 0 && tokens[start - 1] != "|") start--
            return start
        }
        fun clauseEnd(start: Int): Int {
            var end = start
            while (end < tokens.size && tokens[end] != "|") end++
            return end
        }
        val pairs = mutableListOf<ContrastPair>()
        for (marker in tokens.indices) {
            val following = if (marker + 1 < tokens.size) tokens[marker + 1] else ""
            val length: Int
            val chinese: Boolean
            when {
                tokens[marker] == "不" && following == "是" -> { length = 2; chinese = true }
                tokens[marker] == "非" && marker > 0 && tokens[marker - 1] in setOf("而", "並", "并") -> { length = 1; chinese = true }
                tokens[marker] == "not" -> { length = 1; chinese = false }
                (tokens[marker] == "instead" && following == "of") || (tokens[marker] == "rather" && following == "than") -> {
                    length = 2; chinese = false
                }
                // isn't／don't／won't（FX-3 第四輪 G3：「It's Wednesday, it isn't Thursday」「…, don't use the 96k version」）。同 Swift。
                tokens[marker].endsWith("n't") || tokens[marker].endsWith("n’t") -> { length = 1; chinese = false }
                else -> continue
            }
            val after = marker + length
            val yEnd = clauseEnd(after)
            val y = tokens.subList(after, minOf(yEnd, after + 15)).toList()
            // 改口（不是，是…）、反問（不是嗎）、口吃（不是不是）、程度（不是很）、not only 之類都不是對比。
            var next = after
            while (next < tokens.size && tokens[next] == "|") next++
            if (chinese && next < tokens.size && tokens[next] == "是") continue
            val first = y.firstOrNull() ?: continue
            if (first in (if (chinese) contrastStopsAfterChinese else contrastStopsAfterEnglish)) continue
            // 「不是 B 而是 A」「不是 B，是 A」「not B but A」：後面那個 A 才對。
            val turned = turnedContrast(tokens, after, yEnd, chinese, ::clauseEnd)
            if (turned != null) {
                pairs += turned
                continue
            }
            val adverbs = if (chinese) setOf("而", "並", "并", "也") else setOf("and", "but")
            var start = clauseStart(marker)
            var baseEnd = marker
            fun strip() { while (baseEnd > start && tokens[baseEnd - 1] in adverbs) baseEnd-- }
            strip()
            // 英文否定詞前面只有主詞（和助動詞）＝「A, it's not B」「A, we don't B」：跟「A, not B」一樣，A 在前一個子句；
            // 沒有前一個子句（「I don't know」）就不是對比。同 Swift。
            val subjectOnly = !chinese && baseEnd > start &&
                tokens.subList(start, baseEnd).all { it.replace("’", "'") in englishSubjectWords }
            if (subjectOnly && start == 0) continue
            // 「A，不是 B」：A 在前一個子句。
            val comma = (baseEnd == start || subjectOnly) && start > 0
            if (comma) {
                baseEnd = start - 1
                start = clauseStart(baseEnd)
                strip()
            }
            val x = tokens.subList(start, baseEnd).toList()
            // 「是不是」是在問，不是對比。
            if (x.isEmpty() || (chinese && x.last() == "是")) continue
            val copulas = if (chinese) setOf("是") else setOf("is", "are", "was", "were")
            var base = x
            var copula = false
            val copulaIndex = x.indexOfLast { it in copulas }
            if (copulaIndex >= 0 && copulaIndex < x.size - 1) {
                base = x.subList(copulaIndex + 1, x.size).toList()
                copula = true
            }
            val shape = sameShape(base, y)
            val a: List<String>
            val b: List<String>
            val narrow: Boolean
            var bare = false
            if (shape != null) {
                a = base.takeLast(shape.first); b = y.take(shape.second); narrow = true
            } else if (copula) {
                a = base.takeLast(15); b = y; narrow = a.size <= 6
            } else if (comma) {
                a = base.takeLast(maxOf(2, minOf(y.size, 6))); b = y; narrow = false
            } else {
                // 沒有「是」、沒有逗號、前後也不是同一種東西的「A不是B」「A and not B」（FX-3 第四輪 G3：「我要喝拿鐵不是美式」）：
                // A 是否定詞前面緊接的幾個詞，看不準是哪幾個，所以只擋「A 不見了、B 變成肯定」這一種。同 Swift。
                a = base.takeLast(maxOf(2, minOf(y.size, 6))); b = y; narrow = false
                bare = true
            }
            if (a == b) continue
            val aStart = baseEnd - a.size
            var context: List<String>? = null
            if (!bare && aStart - 2 >= start) {
                val candidate = tokens.subList(aStart - 2, aStart).toList()
                if (candidate != listOf("不", "是") && candidate.last() != "not") context = candidate
            }
            pairs += ContrastPair(a, b, contrastCore(b), context, narrow, bare)
        }
        return pairs
    }

    /**
     * 「不是 B 而是 A」「不是 B，（而）是 A」「not B but A」：B 在否定詞後面，A 在同一個子句的「而是／but」後面、
     * 或下一個子句開頭的「是／而是／but」後面。英文的 A 最多 4 個詞、不含人稱（「not going, but my sister is」是兩件事）。同 Swift。
     */
    private fun turnedContrast(tokens: List<String>, after: Int, yEnd: Int, chinese: Boolean, clauseEnd: (Int) -> Int): ContrastPair? {
        var b: List<String> = emptyList()
        var aStart: Int? = null
        var index = after + 1
        while (index < yEnd) {
            val turn = if (chinese) tokens[index] == "而" && index + 1 < yEnd && tokens[index + 1] == "是" else tokens[index] == "but"
            if (turn) {
                b = tokens.subList(after, index).toList()
                aStart = index + if (chinese) 2 else 1
                break
            }
            index++
        }
        if (aStart == null) {
            var next = yEnd
            while (next < tokens.size && tokens[next] == "|") next++
            if (next > yEnd && next < tokens.size) {
                val following = if (next + 1 < tokens.size) tokens[next + 1] else ""
                if (chinese && tokens[next] == "是" && !(following == "不" && next + 2 < tokens.size && tokens[next + 2] == "是")) {
                    aStart = next + 1
                } else if (chinese && tokens[next] == "而" && following == "是") {
                    aStart = next + 2
                } else if (!chinese && tokens[next] == "but") {
                    aStart = next + 1
                }
                if (aStart != null) b = tokens.subList(after, yEnd).toList()
            }
        }
        val start = aStart ?: return null
        if (b.isEmpty() || start >= tokens.size) return null
        val a = tokens.subList(start, minOf(clauseEnd(start), start + 15)).toList()
        b = b.take(15)
        if (a.isEmpty() || a == b) return null
        if (!chinese && (a.size > 4 || a.any { englishPersons[it] != null || it == "i" })) return null
        return ContrastPair(a, b, contrastCore(b), null, a.size <= 6)
    }

    private fun contrastCore(b: List<String>): List<String>? {
        val core = b.dropWhile { it in contrastFunctionWords }
        return if (core.isEmpty() || core.size == b.size) null else core
    }

    /**
     * A（`base` 的結尾）和 B（`y` 的開頭）是同一種東西的兩個選項時，回傳 A、B 各取幾個詞：
     * 結尾一樣（三點／四點、A版／B版）、開頭一樣（星期三／星期四、台北／台南、小王／小李），
     * 或是兩個數字、兩個同字尾（至少三個字母）的英文字（wednesday／thursday）。同 Swift。
     */
    private fun sameShape(base: List<String>, y: List<String>): Pair<Int, Int>? {
        for (shared in minOf(4, base.size - 1) downTo 1) {
            if (y.size - shared < 1) continue
            val ending = base.takeLast(shared)
            for (offset in 1..minOf(3, y.size - shared)) {
                if (y.subList(offset, offset + shared) == ending) return (minOf(offset, base.size - shared) + shared) to (offset + shared)
            }
        }
        for (shared in minOf(4, y.size - 1) downTo 1) {
            if (base.size - shared < 1) continue
            val beginning = y.take(shared)
            for (extra in 1..minOf(3, base.size - shared)) {
                if (base.takeLast(shared + extra).take(shared) == beginning) return (shared + extra) to minOf(shared + extra, y.size)
            }
        }
        val last = base.lastOrNull() ?: return null
        val first = y.firstOrNull() ?: return null
        if (last == first || last.isEmpty() || first.isEmpty()) return null
        if (last[0] in '0'..'9' && first[0] in '0'..'9') return 1 to 1
        fun isWord(token: String) = token.length >= 4 && token.all { it in 'a'..'z' }
        if (isWord(last) && isWord(first)) {
            val shared = last.reversed().zip(first.reversed()).takeWhile { it.first == it.second }.size
            if (shared >= 3) return 1 to 1
        }
        return null
    }

    /** `words[index...]` 開頭的否定詞（不是、而非／並非、非、not、isn't 這類、instead of、rather than）結束在哪裡；不是否定詞回 null。同 Swift。 */
    private fun negationEnd(words: List<String>, index: Int): Int? {
        if (index >= words.size) return null
        val word = words[index]
        val following = if (index + 1 < words.size) words[index + 1] else ""
        if ((word == "不" && following == "是") || (word in setOf("而", "並", "并") && following == "非") ||
            (word == "instead" && following == "of") || (word == "rather" && following == "than")) return index + 2
        if (word == "非" || word == "not" || word.endsWith("n't") || word.endsWith("n’t")) return index + 1
        return null
    }

    /** `words[..<end]` 結尾是否定詞。同 Swift。 */
    private fun endsWithNegation(words: List<String>, end: Int): Boolean {
        if (end < 1) return false
        val last = words[end - 1]
        if (last == "非" || last == "not" || last.endsWith("n't") || last.endsWith("n’t")) return true
        if (end < 2) return false
        val previous = words[end - 2]
        return (previous == "不" && last == "是") || (previous == "instead" && last == "of") || (previous == "rather" && last == "than")
    }

    /** 第 `index` 個詞被否定：前面緊接否定詞，或中間只隔一個介系詞、冠詞（not on Thursday、不是在星期四）。同 Swift。 */
    private fun isNegated(words: List<String>, index: Int): Boolean =
        endsWithNegation(words, index) ||
            (index >= 1 && words[index - 1] in contrastFunctionWords && endsWithNegation(words, index - 1))

    /** 一串詞，加上每個詞出現在哪些位置：每一組對比只從 needle 第一個詞出現的地方比，兩千字的段落不必每組都整串掃一遍。同 Swift。 */
    private class IndexedWords(val list: List<String>) {
        private val positions = HashMap<String, MutableList<Int>>().also { map ->
            for ((index, word) in list.withIndex()) map.getOrPut(word) { mutableListOf() } += index
        }

        fun starts(needle: List<String>, index: Int): Boolean =
            index >= 0 && index + needle.size <= list.size && list.subList(index, index + needle.size) == needle

        /** `needle` 開頭的每一個位置（可以重疊），由前往後。 */
        fun matches(needle: List<String>): List<Int> {
            val first = needle.firstOrNull() ?: return emptyList()
            return positions[first]?.filter { starts(needle, it) } ?: emptyList()
        }
    }

    /** `needle` 在 `words` 裡出現、但沒被否定（`isNegated`）的次數（不重疊地數）。同 Swift。 */
    private fun assertedCount(needle: List<String>, words: IndexedWords): Int {
        var count = 0
        var next = 0
        for (index in words.matches(needle)) {
            if (index < next) continue
            if (!isNegated(words.list, index)) count++
            next = index + needle.size
        }
        return count
    }

    /**
     * 輸出裡「不是 B」後面緊接著又一個 B、再接原文「不是 B」後面那個字的次數（「不是星期四；星期四我要出差」對原文
     * 「不是星期四我要出差」）：本機版把重複的 B 併掉了，整理模型照原話補回來，第二個 B 不算新的肯定。同 Swift。
     */
    private fun restoredRepeats(needle: List<String>, output: IndexedWords, source: IndexedWords): Int {
        val length = needle.size
        if (length == 0) return 0
        fun follower(words: List<String>, index: Int) = if (index < words.size) words[index] else ""
        val continuations = HashSet<String>()
        for (index in source.matches(needle)) if (isNegated(source.list, index)) continuations += follower(source.list, index + length)
        if (continuations.isEmpty()) return 0
        var count = 0
        for (index in output.matches(needle)) {
            if (output.starts(needle, index - length) && isNegated(output.list, index - length) &&
                follower(output.list, index + length) in continuations) count++
        }
        return count
    }

    /** 輸出還留著這組對比：「A（而／並）不是 B」或「不是 B（而）是 A」「not B but A」（B 可以去掉開頭的介系詞、冠詞）。同 Swift。 */
    private fun keepsContrast(pair: ContrastPair, words: List<String>): Boolean {
        val options = listOf(pair.b) + listOfNotNull(pair.bCore)
        fun starts(needle: List<String>, index: Int) =
            index >= 0 && index + needle.size <= words.size && words.subList(index, index + needle.size) == needle
        fun startsWithB(index: Int): Int? {
            for (option in options) if (starts(option, index)) return index + option.size
            if (index < words.size && words[index] in contrastFunctionWords) {
                for (option in options) if (starts(option, index + 1)) return index + 1 + option.size
            }
            return null
        }
        val links = setOf("而", "並", "并", "也", "and", "but", "是")
        for (index in words.indices) {
            if (starts(pair.a, index)) {
                var cursor = index + pair.a.size
                if (negationEnd(words, cursor) == null && cursor < words.size && words[cursor] in links) cursor++
                val end = negationEnd(words, cursor)
                if (end != null && startsWithB(end) != null) return true
            }
            val end = negationEnd(words, index) ?: continue
            var cursor = startsWithB(end) ?: continue
            repeat(2) { if (cursor < words.size && words[cursor] in links) cursor++ }
            if (starts(pair.a, cursor)) return true
        }
        return false
    }

    /** `needle` 在 `words` 裡出現的次數（不重疊地數）。同 Swift。 */
    private fun occurrences(needle: List<String>, words: IndexedWords): Int {
        var count = 0
        var next = 0
        for (index in words.matches(needle)) {
            if (index < next) continue
            count++
            next = index + needle.size
        }
        return count
    }

    /**
     * 兩段內容繞著中間不動的一段對調了＝誰對誰被換掉（FX-3 ⑤：「王經理要把合約寄給李律師」→「李律師要把合約寄給王經理」、
     * 「小明欠小華五百元」→「小華欠小明500元」、「Alice owes Bob」→「Bob owes Alice」）。
     * M 是兩邊都恰好出現一次的詞：原文在 M 前面的某個詞跑到了 M 後面、同時原文在 M 後面的某個詞跑到了 M 前面。
     * 搬動的詞可以是重複的詞，兩邊次數一樣時第 k 次對第 k 次（FX-7 R3：「王經理…李律師，王經理明天休假」的王經理）。
     * 只把一段話挪個位置（「明天我去」→「我明天去」、把原因子句搬到後面）不會兩邊同時越過 M，照樣放行；
     * 英文 and／or 不當 M（「Me and him」→「He and I」是文法修正）；一段全是時間、另一段完全沒有時間＝挪時間副詞，照樣放行
     * （「at 3 pm on October 22 we meet」→「We meet on October 22 at 3 pm」）。改口照樣放行：原文的幾種讀法任何一種沒有對調就好。
     * 兩段還要互相坐上對方原本的位置（前一個或後一個詞跟對方原本的一樣）才算——「如果明天下雨我們就…」→「我們明天如果下雨就…」
     * 只是把「我們」挪到前面，「如果」沒有坐上「我們」的位置。「跟／和」後面接數量時也不當 M（「一杯咖啡跟一個蛋糕」是清單）。
     * 兩邊要先轉成同一種數字寫法。同 Swift。
     */
    fun swapsAroundSharedMiddle(original: String, cleaned: String): Boolean {
        val output = meaningTokens(cleaned).filter { it != "|" }
        return prepareSource(original, false, false, emptyList()).all { swapsAroundSharedMiddle(meaningTokens(it).filter { t -> t != "|" }, output) }
    }

    private class Anchor(val token: String, val index: Int, val position: Int, val time: Boolean, val unique: Boolean)

    private val swapCoordinators = setOf("跟", "和", "與", "与", "及", "或")

    private fun swapsAroundSharedMiddle(source: List<String>, output: List<String>): Boolean {
        val sourceCount = HashMap<String, Int>()
        val outputPositions = HashMap<String, MutableList<Int>>()
        for (token in source) sourceCount[token] = (sourceCount[token] ?: 0) + 1
        for ((position, token) in output.withIndex()) outputPositions.getOrPut(token) { mutableListOf() } += position
        val time = timeMask(source)
        // 兩邊出現次數一樣的詞，第 k 次對第 k 次；重複的詞也可以是被搬動的那段（FX-7 R3：「王經理…王經理明天休假」），
        // 中間不動的 M 還是只用兩邊都恰好出現一次的詞（`unique`）。同 Swift。
        val seen = HashMap<String, Int>()
        val anchors = source.indices.mapNotNull { index ->
            val token = source[index]
            val occurrence = seen[token] ?: 0
            seen[token] = occurrence + 1
            val positions = outputPositions[token]
            if (positions != null && positions.size == sourceCount[token]) {
                Anchor(token, index, positions[occurrence], time[index], positions.size == 1)
            } else {
                null
            }
        }
        fun neighbor(words: List<String>, index: Int, step: Int): String =
            if (index + step in words.indices) words[index + step] else if (step < 0) "^" else "$"
        fun isNumber(token: String) = token.isNotEmpty() && (token[0] in '0'..'9' || (token[0] == '-' && token.length > 1))
        if (anchors.size < 3) return false
        val laterMinimum = IntArray(anchors.size + 1) { Int.MAX_VALUE }
        for (index in anchors.indices.reversed()) laterMinimum[index] = minOf(laterMinimum[index + 1], anchors[index].position)
        var earlierMaximum = Int.MIN_VALUE
        for ((index, anchor) in anchors.withIndex()) {
            val crossing = anchor.unique && anchor.token != "and" && anchor.token != "or" &&
                !(anchor.token in swapCoordinators && isNumber(neighbor(source, anchor.index, 1))) &&
                earlierMaximum > anchor.position && laterMinimum[index + 1] < anchor.position
            earlierMaximum = maxOf(earlierMaximum, anchor.position)
            if (!crossing) continue
            val back = anchors.subList(0, index).filter { it.position > anchor.position }
            val forward = anchors.subList(index + 1, anchors.size).filter { it.position < anchor.position }
            val movedBack = back.map { it.time }
            val movedForward = forward.map { it.time }
            val onlyTimeBack = false !in movedBack
            val onlyTimeForward = false !in movedForward
            val noTimeBack = true !in movedBack
            val noTimeForward = true !in movedForward
            if ((onlyTimeBack && noTimeForward) || (onlyTimeForward && noTimeBack)) continue
            // 搬過去的那段，前一個或後一個詞跟另一段原本的一樣＝坐上了對方的位置；兩段都坐上了才是對調。同 Swift。
            fun takes(movers: List<Anchor>, owners: List<Anchor>): Boolean = movers.any { mover ->
                owners.any { owner ->
                    neighbor(output, mover.position, -1) == neighbor(source, owner.index, -1) ||
                        neighbor(output, mover.position, 1) == neighbor(source, owner.index, 1)
                }
            }
            if (takes(back, forward) && takes(forward, back)) return true
        }
        return false
    }

    private val timeBigrams = setOf(
        "今天", "明天", "昨天", "後天", "后天", "前天", "今年", "明年", "去年", "前年", "早上", "上午", "中午", "下午", "晚上",
        "凌晨", "清晨", "傍晚", "半夜", "午夜", "今晚", "明晚", "昨晚", "月底", "月初", "年底", "年初"
    )
    /** 接在數字後面就是時間的字：3點、10月、23號、2026年、3 pm、22nd。同 Swift。 */
    private val timeUnitsAfterNumber = setOf(
        "點", "点", "分", "秒", "半", "刻", "月", "日", "號", "号", "年", "時", "时", "am", "pm", "o'clock", "st", "nd", "rd", "th"
    )
    private val englishTimeWords = setOf(
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "yesterday", "tonight",
        "noon", "midnight", "morning", "afternoon", "evening", "night", "week", "weekend", "month", "year"
    )
    /** 後面接著時間才算時間的英文字（「at 3 pm」「on the 22nd」「next week」）。同 Swift。 */
    private val englishTimeLeads = setOf(
        "at", "on", "in", "by", "before", "after", "until", "till", "around", "from", "since", "the", "this", "next", "last", "every"
    )
    private val numberTimeLeads = setOf("at", "by", "around", "until", "till", "before", "after", "since")

    /**
     * 每個詞是不是時間的一部分（`meaningTokens` 的詞）：今天、下午、星期三、3點、10月23號、3:30、at 3 pm、on October 22、next week。
     * 單看一個字不算（「小明」的明、「樓上」的上不是時間）。同 Swift。
     */
    private fun timeMask(tokens: List<String>): BooleanArray {
        val mask = BooleanArray(tokens.size)
        fun isNumber(index: Int): Boolean {
            if (index < 0 || index >= tokens.size) return false
            val token = tokens[index]
            if (token.isEmpty()) return false
            return token[0] in '0'..'9' || (token[0] == '-' && SwiftText.count(token) > 1)
        }
        for (index in tokens.indices) {
            val token = tokens[index]
            if (index + 1 < tokens.size && (token + tokens[index + 1]) in timeBigrams) { mask[index] = true; mask[index + 1] = true }
            if (token == "星" && index + 1 < tokens.size && tokens[index + 1] == "期") {
                mask[index] = true; mask[index + 1] = true
                if (index + 2 < tokens.size && (isNumber(index + 2) || tokens[index + 2] in setOf("日", "天", "末"))) mask[index + 2] = true
            }
            if (token in englishTimeWords || token in englishMonths) mask[index] = true
            if (isNumber(index)) {
                if (token.contains(':')) mask[index] = true
                if (index + 1 < tokens.size && tokens[index + 1] in timeUnitsAfterNumber) { mask[index] = true; mask[index + 1] = true }
                if (index > 0 && (tokens[index - 1] in englishMonths || tokens[index - 1] in numberTimeLeads)) mask[index] = true
            }
            if (token == "半" && index > 0 && mask[index - 1]) mask[index] = true
        }
        for (index in tokens.indices.reversed()) {
            if (tokens[index] in englishTimeLeads && index + 1 < tokens.size && mask[index + 1]) mask[index] = true
        }
        return mask
    }

    private val meaningFolds = listOf("禮拜" to "星期", "礼拜" to "星期", "週" to "星期", "周" to "星期", "星期天" to "星期日", "臺" to "台")
    private const val CHINESE_NUMERALS = "零〇一二兩两三四五六七八九十百千萬万億亿"
    private const val CLAUSE_SEPARATORS = "，。！？,!?、；;：:."

    /**
     * 比對意思用的詞（對比、調換）：中文一字一詞、英文一個單字一詞（小寫，含 isn't 的撇號）、數字一串一詞
     * （中文數字換成阿拉伯數字、千分位拿掉，小數點與時間的冒號留著），子句之間的標點換成「|」，空白與其他符號略過。
     * 同一個東西的不同寫法先換成一種：禮拜／週／周→星期、星期天→星期日、臺→台。同 Swift（逐字形叢集）。
     */
    internal fun meaningTokens(text: String): List<String> = meaningTokenLists(text)

    private fun tokenizeMeaning(text: String): List<String> {
        var folded = normalizeFullwidthDigits(text)
        for ((from, to) in meaningFolds) folded = folded.replace(from, to)
        val characters = SwiftText.graphemes(folded)
        fun isDigit(index: Int) = index < characters.size && characters[index].length == 1 && characters[index][0] in '0'..'9'
        fun isLatin(index: Int) = index < characters.size && characters[index].length == 1 &&
            (characters[index][0] in 'a'..'z' || characters[index][0] in 'A'..'Z')
        fun isChineseNumeral(index: Int) = index < characters.size && characters[index].length == 1 && characters[index][0] in CHINESE_NUMERALS
        fun isNumeral(index: Int) = isDigit(index) || isChineseNumeral(index)
        fun afterSpaces(index: Int): Int {
            var next = index
            while (next < characters.size && (characters[next] == " " || characters[next] == "\t")) next++
            return next
        }
        // 「LUFS-14」：減號前面的英文字是響度、電平單位，減號就是負號（同 `MINUS_SIGN`）。
        fun afterLevelUnit(index: Int): Boolean {
            var start = index
            while (start > 0 && isLatin(start - 1)) start--
            return characters.subList(start, index).joinToString("").lowercase() in levelUnits
        }
        val tokens = mutableListOf<String>()
        var index = 0
        // 負號跟著數字走（「-5」「負五」「零下五」≠「5」），規則同 `numberValueRun`：數字中間的連字號不是負號。
        var negative = false
        fun appendNumber(value: String) {
            tokens += if (negative && value != "0") "-$value" else value
            negative = false
        }
        while (index < characters.size) {
            val character = characters[index]
            // 負號跟數字中間隔空白也算（FX-7 M4，同 `MINUS_SIGN`）：「−」「－」都算，ASCII「-」前面要緊接非空白的字。同 Swift。
            val spacedSign = character == "−" || character == "－" ||
                (character == "-" && index > 0 && !SwiftText.isWhitespace(characters[index - 1]))
            if ((character == "-" || character == "−" || character == "－") &&
                (isDigit(index + 1) || (spacedSign && afterSpaces(index + 1) > index + 1 && isDigit(afterSpaces(index + 1)))) &&
                !(index > 0 && (isDigit(index - 1) || (isLatin(index - 1) && !afterLevelUnit(index)))) &&
                !(index > 1 && (characters[index - 1] == " " || characters[index - 1] == "\t") && isDigit(index - 2))
            ) {
                negative = true
                index++
                continue
            }
            val signWord = character == "負" || character == "负" || (character == "零" && index + 1 < characters.size && characters[index + 1] == "下")
            // 「負的三」也是負號（FX-3 第四輪 G4）。同 Swift。
            val signLength = if (character == "零") 2 else if (index + 1 < characters.size && characters[index + 1] == "的") 2 else 1
            if (signWord && isNumeral(afterSpaces(index + signLength))) {
                negative = true
                index = afterSpaces(index + signLength)
                continue
            }
            if (isDigit(index)) {
                val run = StringBuilder()
                while (index < characters.size) {
                    if (isDigit(index)) {
                        run.append(characters[index]); index++
                    } else if ((characters[index] == "." || characters[index] == ":") && isDigit(index + 1)) {
                        run.append(characters[index]); index++
                    } else if (characters[index] == "," && isDigit(index + 1) && isDigit(index + 2) && isDigit(index + 3) && !isDigit(index + 4)) {
                        index++
                    } else {
                        break
                    }
                }
                appendNumber(run.toString())
            } else if (isChineseNumeral(index)) {
                val run = StringBuilder()
                while (isChineseNumeral(index)) { run.append(characters[index]); index++ }
                val value = Normalizer.chineseToInt(run.toString())
                if (value != null) {
                    appendNumber(value.toString())
                } else {
                    negative = false
                    run.forEach { tokens += it.toString() }
                }
            } else if (isLatin(index)) {
                val run = StringBuilder()
                while (index < characters.size) {
                    if (isLatin(index)) {
                        run.append(characters[index]); index++
                    } else if ((characters[index] == "'" || characters[index] == "’") && isLatin(index + 1) && run.isNotEmpty()) {
                        run.append(characters[index]); index++
                    } else {
                        break
                    }
                }
                tokens += run.toString().lowercase()
            } else {
                if (SwiftText.isNewline(character) || (character.length == 1 && character[0] in CLAUSE_SEPARATORS)) {
                    if (tokens.isNotEmpty() && tokens.last() != "|") tokens += "|"
                } else if (SwiftText.isLetter(character)) {
                    tokens += character
                }
                index++
            }
        }
        return tokens
    }

    /** Short diagnostic for rejected cleanup output, including the source text that was lost. */
    fun rejectionReason(original: String, cleaned: String, readings: CjkReadingLookup? = null): String? {
        // FX-3 ④：對比句被翻成相反的意思，來源怎麼讀都不放行（「星期三不是星期四」→「星期四」）。同 Swift。
        if (invertsContrast(original, cleaned)) return "對比句被改成相反的意思"
        val listItems = numberedListItems(cleaned)
        val allowListFormatting = listItems.size >= 2 && hasListContext(original, listItems.size)
        val sources = prepareSource(original, allowListFormatting, listIntroCopula.containsMatchIn(cleaned), listItems)
        val output = listPrefix.replace(Normalizer.normalizeNumbers(normalizeFullwidthDigits(cleaned)), "")
        val outputTokens = tokens(output, optionalFillerRanges(output))
        val readingsMemo = ReadingMemo(readings)
        // 來源有幾種合理讀法：刪掉被改口取代的片段（舊做法）、原樣保留、或照改口改好；輸出對得上任何一種就放行。
        var sourceTokens = emptyList<Token>()
        sources.forEachIndexed { index, candidate ->
            val candidateTokens = tokens(candidate, optionalFillerRanges(candidate))
            if (index == 0) sourceTokens = candidateTokens
            if (matches(candidateTokens, outputTokens, readingsMemo, homophoneBudget(candidate))) return null
        }

        val missing = missingSourceTokens(sourceTokens, outputTokens).joinToString(separator = "", transform = ::displayValue)
        return if (missing.isNotEmpty()) {
            "來源實詞未保留：「" + missing.take(32) + "」"
        } else {
            "輸出新增或調動了實詞"
        }
    }

    /**
     * 來源的幾種讀法，第一個是主讀法（拒絕原因以它為準）：刪掉被改口取代的片段（舊做法）、
     * 原樣保留、改口詞前後補逗號後用 Normalizer 的改口對齊改好（對不齊就沒有這一種）。同 Swift。
     */
    private fun prepareSource(
        original: String,
        allowListFormatting: Boolean,
        outputKeepsListIntroCopula: Boolean,
        listItems: List<String>
    ): List<String> {
        var source = listPrefix.replace(numberForms(normalizeFullwidthDigits(original)), "")
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
        var superseded = numericCorrectionWithTail.replace(source, "$3$2")
        superseded = supersededCorrection.replace(superseded, "")
        superseded = unpunctuatedWeekdayCorrection.replace(superseded, "")
        val candidates = mutableListOf(numberForms(normalizeFullwidthDigits(superseded)))
        fun add(candidate: String) {
            val value = numberForms(normalizeFullwidthDigits(candidate))
            if (value !in candidates) candidates += value
        }
        if (superseded != source) add(source)
        val separated = separatingCorrectionMarkers(source)
        val corrected = correctedForms(separated)
        if (corrected != separated) add(corrected)
        return candidates
    }

    /** 「不對」類改口詞一律變成「，不對，」；「不是」只在後面接「是」時變成「，不是，」；「我是說」前面補逗號（同 Swift）。 */
    internal fun separatingCorrectionMarkers(value: String): String {
        var out = unpunctuatedNotRightMarker.replace(value, "，不對，")
        out = unpunctuatedNotIsMarker.replace(out, "，不是，")
        out = unpunctuatedIMeanMarker.replace(out, "，我是說")
        return out
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
        // 負號是數值的一部分（FX-3 ①：「-14」≠「14」）；規則同 `numberValueRun`。同 Swift。
        val signs = numberSign.findAll(text).map { it.range.first }.toSet()
        var index = 0
        while (index < text.length) {
            if (index in signs) {
                // 負號後面可以隔空白（FX-7 M4：「− 14」）。同 Swift。
                var digitStart = index + 1
                while (digitStart < text.length && (text[digitStart] == ' ' || text[digitStart] == '\t')) digitStart++
                val match = number.find(text, digitStart)
                if (match?.range?.first == digitStart) {
                    result += Token("n:-" + match.value.replace(",", ""), false)
                    index = match.range.last + 1
                    continue
                }
            }
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
