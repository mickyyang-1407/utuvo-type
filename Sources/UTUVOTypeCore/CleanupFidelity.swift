import Foundation

/// Conservative content check for smart cleanup. Formatting and number presentation may change,
/// while substantive text must stay in the same order.
public enum CleanupFidelity {
    /// 同音替換上限：一次 cleanup 最多能換掉來源這麼多比例的實詞。
    /// 語音辨識錯字修正（除值→儲值）通常只換一兩個字；整句被換成另一句同音的話不是修正。
    public static let homophoneSubstitutionPercent = 25

    // These ranges mark contextually recognized fillers as optional on both sides of the comparison.
    private static let leadingFillers = try! NSRegularExpression(
        // 「恩」是語音辨識把「嗯」寫錯的字，但也是實詞（恩人），後面一定要有停頓才算贅詞。
        pattern: #"(?m)(?:^|(?<=[，,、。！？!?;；\n]))((?:(?:嗯嗯|嗯|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是|然後|然后)[，,、\s]*|恩恩?[，,、\s]+)+)(?=[\p{L}\p{N}])"#
    )
    private static let pausedFillers = try! NSRegularExpression(
        pattern: #"[，,、;；](嗯嗯|嗯|恩恩|恩|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是)[，,、;；]"#
    )
    private static let hesitatedDemonstrative = try! NSRegularExpression(
        pattern: #"(?:我覺得|我觉得|我想|我認為|我认为)(那個|那个)(?=[，,、;；](?:就是說|就是说|就是|我|你|我們|我们|大家|今天|明天|後天|昨天))"#
    )
    // 沒有標點的「我覺得那個就是這個 low end」「我覺得那個嗯就是這個…」：後面緊接另一個「這個／那個」時，
    // 前面那串只是在想詞（2026-10-17 Groq s6 被擋「來源實詞未保留：「那個就是」」）。
    // 「我覺得那個就是重點」「那就是這個問題」不在此列（後面不是這個／那個、或前面沒有「我覺得」）。
    private static let hesitatedDemonstrativeChain = try! NSRegularExpression(
        pattern: #"(?:我覺得|我觉得|我想|我認為|我认为)((?:那個|那个)[，,、;；\s]*(?:(?:嗯|呃|恩)[，,、;；\s]*)?(?:就是說|就是说|就是)[，,、;；\s]*)(?=這個|这个|那個|那个)"#
    )
    private static let sentenceInitialThen = try! NSRegularExpression(
        pattern: #"(?m)(?:^|(?<=[。！？!?;；\n]))(然後|然后)"#
    )
    // Mark only the repeated copy as optional so retaining the original stutter remains valid too.
    private static let repeatedPronoun = try! NSRegularExpression(
        pattern: #"(?=([我你妳您他她它])([，,、\s]*)(\1)(?=[\u3400-\u9FFF]))"#
    )
    private static let repeatedHanWord = try! NSRegularExpression(
        pattern: #"(?=([\u3400-\u9FFF]{2,4})(\1)(?=[\u3400-\u9FFF]|[，,、\s。！？!?;；]|$))"#
    )
    /// 有停頓的改口詞（「，不對，」「，不是，」「，更正，」…），後面可以接「是／為」。
    private static let correctionMarker = #"[，,;；]\s*(?:啊[，,、\s]*)?(?:不對|不是|更正|講錯了|說錯了|no|I mean|sorry)[，,;；]\s*(?:是|為)?\s*"#
    private static let numericCorrectionWithTail = try! NSRegularExpression(
        pattern: #"((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?)([\u3400-\u9FFF]{2,6})"# + correctionMarker
            + #"((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)"#,
        options: [.caseInsensitive]
    )
    private static let supersededCorrection = try! NSRegularExpression(
        pattern: #"(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|[\u3400-\u9FFF]{2}(?:(?:跟|和|與|与)[\u3400-\u9FFF]{2,4})*|(?:[A-Za-z]+\s+)?[A-Za-z]+[0-9]*|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)"#
            + correctionMarker,
        options: [.caseInsensitive]
    )
    private static let correctionMarkerRegex = try! NSRegularExpression(pattern: correctionMarker, options: [.caseInsensitive])
    // 「星期三不是是星期四」「星期三不是，是星期四」：「不是」後面要接「是」才是改口（FX-3 ④）。
    // 單獨的「星期三不是星期四」是對比（前面那個才對），刪掉「星期三不是」會把意思整個反過來。
    // 「不是」前後都沒停頓（「星期三不是是星期四」）也不算改口（FX-3 第四輪 G3，同 FX-1 的改口規則），只刪有停頓的。
    private static let unpunctuatedWeekdayCorrection = try! NSRegularExpression(
        pattern: #"(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+))(?:\s+不是[，,、\s]*|不是[，,、\s]+)是\s*"#
    )
    // 改口詞前後補上逗號，交給 Normalizer 既有的改口對齊（alignCorrection）——沒標點的「48K不對是96K」
    // 「小雅跟小波不是，是小雅跟小潘」也能認出來。「不是」只在後面接「是」時才算改口；
    // 單獨的「三點不是四點」是對比，不碰（2026-10-22 cleanup-semantics-1）。
    private static let unpunctuatedNotRightMarker = try! NSRegularExpression(
        pattern: #"[，,、\s]*(?:[啊呃喔哦噢欸][，,、\s]*)?(?<![對对])(?:不對[，,、\s]*)+"#
    )
    private static let unpunctuatedNotIsMarker = try! NSRegularExpression(
        pattern: #"[，,、\s]*(?:不是[，,、\s]*)+(?=是)"#
    )
    private static let unpunctuatedIMeanMarker = try! NSRegularExpression(
        pattern: #"[，,、\s]*我是說[，,、\s]*"#
    )
    // 行首的「-」後面直接接數字是負號（「-14 LUFS」），不是項目符號（FX-3 ①）。
    // 編號後面直接接數字的是數值，不是清單編號（FX-9）：「3.5元」「1.1 ms」是小數，「三、一百」「五、三萬就好」是一串數字；
    // 拿掉的話忠實照抄被擋（原文剩「5元」、輸出還是「3.5元」），嚴格把關兩邊都剩「5元」反而放過「3.5元→4.5元」。
    // 後面隔空白或接其他字的照舊是清單編號（「1. 報告」「1. 3點開會」「二、報告」）。
    private static let listPrefix = try! NSRegularExpression(
        pattern: #"(?m)^\s*(?:\d+[.、)](?![0-9])|[一二三四五六七八九十百]+[.、)](?![0-9零〇一二兩两三四五六七八九十百千萬万億亿])|[•*]|-(?![0-9]))\s*"#
    )
    private static let spokenListMarker = try! NSRegularExpression(
        pattern: #"(?m)(?:^|(?<=[，,、：:]))第[一二三四五六七八九十百]+(?:是|[，,、：:])"#
    )
    private static let firstlyListMarker = try! NSRegularExpression(
        pattern: #"(?m)(?:^|(?<=[，,、：:\n]))首先[，,、：:]"#
    )
    private static let listCue = try! NSRegularExpression(
        pattern: #"(?:清單|清单|(?:幾|几|[一二兩两三四五六七八九十0-9]+)(?:件事|個重點|个重点|樣東西|样东西|項|项|樣|样))"#
    )
    private static let numberedListItem = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*\d+[.、)][ \t]*(\S.*?)[ \t]*$"#
    )
    private static let listIntroCopula = try! NSRegularExpression(
        pattern: #"((?:清單|清单))是(?=[，,、：:\n]|$)"#
    )
    private static let listConnector = try! NSRegularExpression(
        pattern: #"還有|以及|和|跟"#
    )
    private static let listSeparator = try! NSRegularExpression(
        pattern: #"[，,、。！？!?;；：:\n]"#
    )
    private static let number = try! NSRegularExpression(
        pattern: #"[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?(?::[0-9]{1,2})*"#
    )
    private static let fillerTokens = [
        "就是說", "就是说", "對對", "对对", "對啊", "对啊", "然後", "然后", "嗯嗯",
        "那個", "那个", "這個", "这个", "就是", "呃", "欸", "喔", "啊", "嗯"
    ]
    private static let fillerTokensByInitial = Dictionary(grouping: fillerTokens, by: { $0.first! })

    private struct Token {
        let value: String
        let optional: Bool
    }

    /// 單字讀音一次比對可能重複查（長文數千個位元），記一次就好——轉拼音不便宜。
    private struct ReadingMemo {
        private var cache: [Character: String] = [:]
        mutating func reading(of character: Character) -> String {
            if let cached = cache[character] { return cached }
            let reading = MandarinReading.pinyin(character)
            cache[character] = reading
            return reading
        }
    }

    /// 給守規矩的整理模型（Claude）用的寬鬆把關，iOS／Mac／Android 同一套數字（2026-10-17／18 量測）：
    /// 原文雙字詞至少留 35%、輸出新增的雙字詞不超過 60%（替使用者回答約 80%）、不能出現原文沒有的數字。
    /// 不鎖「每個實詞都要留著」——那條會擋掉正確的專名／改口修正（Dolbe Edmos→Dolby Atmos）。
    public static func passesRelaxed(original: String, cleaned: String) -> Bool {
        // 兩邊先轉成同一種數字寫法再比：Mac 的比對原文是「預算是三十萬」，Claude 回「300,000」，
        // 數字組成的雙字詞全被當成新增內容而擋掉（2026-10-19 真人錄音 sc02／nd05）。
        // 英文拼出來的數字也一樣（FX-3 第四輪 G4：「minus fourteen」→「-14」、拿掉 minus 的「fourteen」要擋）。
        let original = spelledNumbers(numberForms(original)), cleaned = spelledNumbers(numberForms(cleaned))
        return bigramRecall(cleaned, source: original) >= 0.35
            && novelBigramShare(cleaned, source: original) <= 0.6
            && !introducesDigits(original: original, cleaned: cleaned)
            && !introducesNumberValues(original: original, cleaned: cleaned)
            && !reordersNumberValues(original: original, cleaned: cleaned)
            && !dropsNumberValues(original: original, cleaned: cleaned)
            && !invertsContrast(original: original, cleaned: cleaned)
            && !swapsAroundSharedMiddle(original: original, cleaned: cleaned)
    }

    /// 人稱不能被翻轉（2026-09-24 Apple Intelligence 實測：「你今天晚上要吃什麼」→「我今天晚上想吃什麼」）：
    /// 原文有「你」整理後全沒了、或原文沒有「我」整理後冒出來＝在改寫成自己的話或替對方回答。
    /// 受詞不能被升成主詞（FX-3 第四輪 G2）：輸出裡在子句開頭的人稱，原文裡也要有一處可以當主詞
    ///（「請他幫我訂票」→「他請我訂票」擋；「我想說他會打給我」→「我想他會打給我」過）。
    /// （原本只在 iOS SmartCleanup；2026-10-22 搬進 core，Mac／Android 共用。）
    public static func keepsPerson(original: String, cleaned: String) -> Bool {
        let second: Set<Character> = ["你", "妳", "您"]
        let hadSecond = original.contains { second.contains($0) }, hasSecond = cleaned.contains { second.contains($0) }
        if hadSecond && !hasSecond { return false }
        if !original.contains("我") && cleaned.contains("我") { return false }
        // 「我們先去錄音室」→「我想明天去錄音室」：複數人稱被縮成自己（同日端到端實測）。
        // 只擋「縮成我」；整理成條列時把主詞省掉（「首先我們花了三個禮拜」→「1. 花了三個禮拜」）不算（2026-10-22 lp03）。
        if original.contains("我們") && !cleaned.contains("我們") && cleaned.contains("我") { return false }
        // FX-3 ⑤：誰對誰也不能對調（「我寄給他」→「他寄給我」、「You send me」→「I send you」）：
        // 輸出的人稱要照原文的先後出現——可以省略，不能多出來或換位置。英文用 and／or 並列的人稱（「Me and him」→「He and I」）
        // 前後對調不算，那是文法修正。
        let source = personMentions(in: original), output = personMentions(in: cleaned)
        guard isSubsequence(coordinatedOrder(output), of: coordinatedOrder(source)) else { return false }
        // 同一個人稱出現兩次時，光看先後擋不住對調（「我請他幫我訂」→「他請我訂」：[我,他,我] 裡挑得出 [他,我]）。
        // 所以再看位置：輸出的人稱緊鄰的字（前一個或後一個，兩邊分開看）原本緊鄰的是「另一個人」、而原文同一個人從沒緊鄰過它＝搶了別人的位置。
        // 兩個人互相搶了對方的位置才算對調；只有一邊（刪掉贅詞後剛好緊鄰同一個字：「我嗯要去，他要來」→「我要去，他要來」）不算。
        var taken = Set<String>()
        for mention in output where !mention.coordinated {
            for side in [\PersonMention.before, \PersonMention.after] where mention[keyPath: side] != "|" {
                let word = mention[keyPath: side]
                guard !source.contains(where: { $0.person == mention.person && $0[keyPath: side] == word }) else { continue }
                for other in source where other.person != mention.person && other[keyPath: side] == word {
                    taken.insert(mention.person + ">" + other.person)
                }
            }
        }
        if taken.contains(where: { taken.contains(reversedPair($0)) }) { return false }
        // 誰當主詞（FX-3 第四輪 G2，取代第三輪的「主詞後面還有誰」比對——那條要靠子句切法，整理時拿掉「說」「that」就誤擋）：
        // 輸出裡在子句開頭（當主詞）的人稱，原文裡也要有一處可以當主詞。省掉主詞的祈使句最常見，受詞不能被升成主詞
        //（「請他幫我訂票」→「他請我訂票」、「Tell him to send me the stems」→「He told me to send the stems」）。
        if output.contains(where: { mention in
            mention.initial && !source.contains { $0.person == mention.person && $0.capable }
        }) { return false }
        return true
    }

    private static func reversedPair(_ pair: String) -> String {
        let people = pair.split(separator: ">")
        return people[1] + ">" + people[0]
    }

    /// 中文人稱前面緊接這些字＝它是受詞（請他、叫我、給你、跟他、把他、告訴我、拜託他、麻煩他…），不是主詞。
    private static let objectMarkers: Set<String> = Set(("請请叫讓让要託托求逼派幫帮給给訴诉知醒問问找帶带教罵骂打寄傳传交跟和對对向替把被陪等見见"
        + "愛爱歡欢謝谢恨怪欠還还借送約约喊催拉推抱看聽听由為为與与同顧顾管騙骗誇夸嫌怕念想煩烦").map { String($0) })
    /// 英文主格：在哪裡都可以當主詞。受格（me／him…）只有在子句開頭才算（「Me and him will fix it」）。
    private static let englishNominative: Set<String> = ["i", "we", "he", "she", "they"]
    private static let englishObjectCase: Set<String> = [
        "me", "us", "him", "her", "them", "myself", "ourselves", "himself", "herself", "themselves", "yourself", "yourselves"
    ]
    /// you／my／his 這類前面緊接這些字＝受詞或所有格跟著動詞、介系詞（tell you、send your file），不是主詞。
    private static let englishGovernors: Set<String> = [
        "tell", "told", "ask", "asked", "remind", "reminded", "call", "called", "send", "sent", "give", "gave", "email", "emailed",
        "text", "texted", "message", "messaged", "let", "help", "helped", "thank", "thanked", "show", "showed", "teach", "taught",
        "pay", "paid", "owe", "owed", "bring", "brought", "invite", "invited", "meet", "met", "see", "saw", "want", "wanted",
        "need", "needed", "get", "got", "ping", "pinged", "notify", "notified", "warn", "warned",
        "to", "for", "with", "at", "from", "by", "about", "of", "like", "than"
    ]
    /// 子句開頭：文字開頭、標點後面，或這些連接詞、引出子句的動詞後面（略過前面的贅詞與時間詞）。
    private static let clauseStops: Set<unichar> = Set("，。！？,!?、；;：:.\n\r（(「『\"“".utf16)
    private static let clauseConnectors: [String] = [
        "說", "说", "講", "讲", "覺得", "觉得", "認為", "认为", "以為", "以为", "知道", "發現", "发现", "希望", "聽說", "听说",
        "然後", "然后", "所以", "但是", "可是", "不過", "不过", "因為", "因为", "結果", "结果", "如果", "而且", "或是", "或者",
        "還是", "还是", "後來", "后来", "接著", "接着", "雖然", "虽然",
        "and", "or", "but", "so", "because", "then", "if", "when", "while", "since", "although", "though", "that",
        "think", "thought", "said", "say", "says", "believe", "guess", "hope", "know", "knew", "feel", "felt"
    ]
    private static let clauseLeadIns: [String] = [
        "嗯嗯", "嗯", "呃", "欸", "喔", "啊", "那個", "那个", "這個", "这个", "就是說", "就是说", "就是", "umm", "um", "uhh", "uh", "erm",
        "today", "tomorrow", "yesterday", "tonight"
    ] + timeBigrams.sorted()

    /// 一個人稱出現的地方：哪一類人稱，以及緊鄰的前一個、後一個詞（中文一個字、英文一個單字小寫、數字一串；標點或頭尾＝「|」）。
    private struct PersonMention {
        let person: String
        let before: String
        let after: String
        /// 跟前一個或後一個人稱用 and／or 並列（只認英文；中文的「跟／和」也是介系詞——「我跟他說」≠「他跟我說」）。
        var coordinated = false
        var group = 0
        /// 在子句開頭（`isClauseInitial`）＝當主詞。
        var initial = false
        /// 這一處可以當主詞：在子句開頭；或中文前面不是 `objectMarkers`（「說的對」「講得對」的對不算）；
        /// 英文是主格（I／he…），或不是受格、前面也不是 `englishGovernors`。
        var capable = false
    }

    /// `location` 在子句開頭：往前略過空白、贅詞、時間詞後，碰到文字開頭、標點或 `clauseConnectors`。
    private static func isClauseInitial(_ ns: NSString, at location: Int) -> Bool {
        let spaces: Set<unichar> = [0x20, 0x09, 0x3000, 0xA0]
        var end = location
        while true {
            while end > 0 && spaces.contains(ns.character(at: end - 1)) { end -= 1 }
            guard end > 0 else { return true }
            if clauseStops.contains(ns.character(at: end - 1)) { return true }
            let windowStart = max(0, end - 10)
            let window = ns.substring(with: NSRange(location: windowStart, length: end - windowStart)).lowercased()
            func endsWithWord(_ word: String) -> Bool {
                guard window.hasSuffix(word) else { return false }
                guard word.unicodeScalars.first?.isASCII ?? false else { return true }
                let wordStart = end - word.utf16.count
                guard wordStart > 0 else { return true }
                let unit = ns.character(at: wordStart - 1)
                return !((65...90).contains(unit) || (97...122).contains(unit))
            }
            if let leadIn = clauseLeadIns.first(where: endsWithWord) {
                end -= leadIn.utf16.count
                continue
            }
            return clauseConnectors.contains(where: endsWithWord)
        }
    }

    private static func personMentions(in text: String) -> [PersonMention] {
        let ns = text as NSString
        var mentions: [PersonMention] = []
        var previousEnd = -1
        for match in personReference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let person = personClass(ns.substring(with: match.range)) else { continue }
            var mention = PersonMention(person: person, before: neighborWord(in: ns, from: match.range.location, forward: false),
                                        after: neighborWord(in: ns, from: NSMaxRange(match.range), forward: true))
            mention.group = mentions.count
            mention.initial = isClauseInitial(ns, at: match.range.location)
            let word = ns.substring(with: match.range)
            if word.first?.isASCII ?? false {
                let lower = word.lowercased()
                mention.capable = englishNominative.contains(lower) || mention.initial
                    || (!englishObjectCase.contains(lower) && !englishGovernors.contains(mention.before))
            } else {
                let lead = ns.substring(with: NSRange(location: max(0, match.range.location - 2), length: min(2, match.range.location)))
                let adjectiveRight = ["的對", "得對", "的对", "得对"].contains(lead)
                mention.capable = mention.initial || !objectMarkers.contains(mention.before) || adjectiveRight
            }
            if previousEnd >= 0, var last = mentions.popLast() {
                let gap = NSRange(location: previousEnd, length: match.range.location - previousEnd)
                let between = ns.substring(with: gap)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\u{3000}\u{00A0}")).lowercased()
                if between == "and" || between == "or" {
                    last.coordinated = true
                    mention.coordinated = true
                    mention.group = last.group
                }
                mentions.append(last)
            }
            mentions.append(mention)
            previousEnd = NSMaxRange(match.range)
        }
        return mentions
    }

    /// 人稱的先後；並列的一組（英文 and／or）組內不分先後。
    private static func coordinatedOrder(_ mentions: [PersonMention]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < mentions.count {
            var end = index + 1
            while end < mentions.count && mentions[end].group == mentions[index].group { end += 1 }
            out += mentions[index ..< end].map(\.person).sorted()
            index = end
        }
        return out
    }

    /// `location` 前（或後）緊鄰的詞：略過空白；英文字母取整個單字（小寫）、阿拉伯數字取整串、其他文字取一個字；碰到標點或頭尾回「|」。
    private static func neighborWord(in ns: NSString, from location: Int, forward: Bool) -> String {
        let skipped: Set<unichar> = [0x20, 0x09, 0x3000, 0xA0]
        var index = forward ? location : location - 1
        while index >= 0 && index < ns.length && skipped.contains(ns.character(at: index)) { index += forward ? 1 : -1 }
        guard index >= 0 && index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return "|" }
        func isASCIILetter(_ unit: unichar) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        func isASCIIDigit(_ unit: unichar) -> Bool { (48...57).contains(unit) }
        let unit = ns.character(at: index)
        if isASCIILetter(unit) || isASCIIDigit(unit) {
            let same = isASCIILetter(unit) ? isASCIILetter : isASCIIDigit
            var start = index, end = index + 1
            while start > 0 && same(ns.character(at: start - 1)) { start -= 1 }
            while end < ns.length && same(ns.character(at: end)) { end += 1 }
            return ns.substring(with: NSRange(location: start, length: end - start)).lowercased()
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return String(Character(scalar))
        default: return "|"
        }
    }

    // 人稱：中文（加「們」＝複數）與英文代名詞，依出現順序。其他／其它／吉他／迷你／自我不是人稱（「來自我們」的我們照算）。
    private static let personReference = try! NSRegularExpression(
        pattern: #"其他|其它|吉他|迷你|自我(?![們们])|[我你妳您他她它牠祂咱][們们]?|(?<![A-Za-z])[A-Za-z]+(?![A-Za-z])"#
    )
    private static let englishPersons: [String: String] = [
        "me": "1", "my": "1", "mine": "1", "myself": "1",
        "we": "1p", "us": "1p", "our": "1p", "ours": "1p", "ourselves": "1p",
        "you": "2", "your": "2", "yours": "2", "yourself": "2", "yourselves": "2p",
        "he": "3m", "him": "3m", "his": "3m", "himself": "3m",
        "she": "3f", "her": "3f", "hers": "3f", "herself": "3f",
        "they": "3p", "them": "3p", "their": "3p", "theirs": "3p", "themselves": "3p"
    ]

    /// 依出現順序列出人稱：1／1p＝我／我們，2／2p＝你／你們，3／3p＝他她它／他們。
    /// 中文的他／她／它同音（ASR 常寫錯、整理時改對），算同一個；英文 he＝3m、she＝3f。「I」要大寫，全大寫的縮寫（US）不算。
    static func personReferences(in text: String) -> [String] {
        let ns = text as NSString
        return personReference.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            personClass(ns.substring(with: match.range))
        }
    }

    private static func personClass(_ word: String) -> String? {
        guard let first = word.first else { return nil }
        if first.isASCII {
            if word == "I" { return "1" }
            if word.count >= 2 && word == word.uppercased() { return nil }
            return englishPersons[word.lowercased()]
        }
        let plural = word.count == 2 && (word.hasSuffix("們") || word.hasSuffix("们"))
        switch first {
        case "我": return plural ? "1p" : "1"
        case "咱": return "1p"
        case "你", "妳", "您": return plural ? "2p" : "2"
        case "他", "她", "它", "牠", "祂": return plural ? "3p" : "3"
        default: return nil   // 其他、其它、吉他、迷你、自我
        }
    }

    private static func isSubsequence(_ part: [String], of whole: [String]) -> Bool {
        var remaining = whole[...]
        for item in part {
            guard let found = remaining.firstIndex(of: item) else { return false }
            remaining = remaining[(found + 1)...]
        }
        return true
    }

    private static let lineOrdinal = try! NSRegularExpression(pattern: #"(?m)^[ \t]*[0-9]+[.、)](?![0-9])[ \t]*"#)
    /// 掉值那條規則用的清單編號：數字後面接中文數字時，那個數字是值不是編號（「100、一百」兩個值），
    /// 其他照舊是編號（「1. 報告」「1. 3點開會」）。只有掉值這條路徑用這個，其他規則照舊（FX-13 修復 R5）。
    private static let dropsLineOrdinal = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*[0-9]+[.、)](?![0-9零〇一二兩两三四五六七八九十百千萬万億亿])[ \t]*"#)
    /// 同一行裡的清單編號（「部分： 1. 前期… 2. 實際…」，換行被拿掉的條列）：前面是開頭、空白或冒號，後面接空白。
    private static let inlineOrdinal = try! NSRegularExpression(pattern: #"(?:^|(?<=[\s：:]))([0-9]{1,2})\.[ \t]+(?=\S)"#)
    /// 英文拼出來的數字（FX-3 第四輪 G4：「minus fourteen」＝-14）。單獨的「one」常是代名詞（the one、no one），不轉。
    private static let spelledNumber = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z'’-])(?i:(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[- ](one|two|three|four|five|six|seven|eight|nine)(?![A-Za-z'’-]))?|zero|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)(?![A-Za-z'’-])"#
    )
    private static let spelledValues: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// 英文拼出來的數字換成阿拉伯數字（twenty-one→21、fourteen→14），其他字不動。寬鬆把關的兩邊都先轉，數值才比得起來。
    public static func spelledNumbers(_ text: String) -> String {
        guard text.contains(where: { $0.isASCII && $0.isLetter }) else { return text }
        let ns = text as NSString
        let matches = spelledNumber.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = "", cursor = 0
        for match in matches {
            var value = 0
            for group in 1 ..< match.numberOfRanges where match.range(at: group).location != NSNotFound {
                value += spelledValues[ns.substring(with: match.range(at: group)).lowercased()] ?? 0
            }
            if match.range(at: 1).location == NSNotFound {
                value = spelledValues[ns.substring(with: match.range).lowercased()] ?? 0
            }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + String(value)
            cursor = NSMaxRange(match.range)
        }
        return out + ns.substring(from: cursor)
    }

    /// 拿掉同一行裡依序 1., 2., 3.… 的清單編號（至少兩個才算清單）。
    private static func removingInlineOrdinals(_ text: String) -> String {
        guard text.contains(". ") || text.contains(".\t") else { return text }
        let ns = text as NSString
        var kept: [NSRange] = [], expected = 1
        for match in inlineOrdinal.matches(in: text, range: NSRange(location: 0, length: ns.length))
        where Int(ns.substring(with: match.range(at: 1))) == expected {
            kept.append(match.range)
            expected += 1
        }
        guard kept.count >= 2 else { return text }
        let out = NSMutableString(string: text)
        for range in kept.reversed() { out.deleteCharacters(in: range) }
        return out as String
    }
    // 負號（FX-3 ①）：數字前面的減號，前一個字不是英數字（「A-1」「COVID-19」）、也不是「數字＋空白」（「3 -5」）。
    // 數字中間的連字號（電話 0912-345-678、日期 2026-10-22、區間 3-5）不是負號。
    // 響度、電平單位後面緊接的減號照樣是負號（「LUFS-14」＝-14，不是「A-1」那種編號）。
    // 減號跟數字中間隔了空白也是負號（FX-7 M4：「目標響度是− 14 LUFS」＝-14）：「−」「－」都算；ASCII「-」前面要緊接
    // 非空白的字——行首的「- 14」是項目符號、「3 - 5」是減法，不算。
    private static let minusSign = #"(?:(?<![A-Za-z0-9])|(?<=(?<![A-Za-z])(?i:lufs|lkfs|dbfs|dbtp|db)))(?<![0-9][ \t])(?:[-−－](?=[0-9])|[−－](?=[ \t]+[0-9])|(?<=[^\t\n\u000B\f\r\u0085\p{Zs}\u2028\u2029])-(?=[ \t]+[0-9]))"#
    private static let levelUnits: Set<String> = ["lufs", "lkfs", "dbfs", "dbtp", "db"]
    private static let numberSign = try! NSRegularExpression(pattern: minusSign)
    /// 一個數值：負號（減號、「負」「負的」「零下」、英文 minus／negative，後面可以有空白）＋阿拉伯數字（千分位、小數點、連字號分段、
    /// 時刻「3:00」）或一串中文數字。
    private static let numberValueRun = try! NSRegularExpression(
        pattern: "(?:" + minusSign + #"[ \t]*|(?:負的?|负的?|零下)[ \t]*|(?<![A-Za-z])(?i:minus|negative)[ \t]+)?(?:[0-9]+(?:(?:,[0-9]{3})+(?:\.[0-9]+)?|(?:-[0-9]+)+|\.[0-9]+|:[0-9]{2}(?![0-9]))?|[零〇一二兩两三四五六七八九十百千萬万億亿]+)"#
    )
    /// 單獨的「一」後面接量詞＝數量（「一杯拿鐵跟兩杯美式」），要跟其他數值比先後（FX-3 ②）。「一點」「一下」「一起」不在此列。
    private static let quantityClassifiers = [
        "杯", "張", "张", "個", "个", "位", "名", "本", "台", "臺", "支", "隻", "件", "份", "瓶", "碗", "盤", "盘", "間", "间",
        "家", "條", "条", "塊", "块", "元", "次", "天", "年", "歲", "岁", "首", "篇", "題", "题", "頁", "页", "樓", "楼",
        "輛", "辆", "箱", "盒", "包", "袋", "顆", "颗", "雙", "双", "套", "組", "组", "場", "场", "堂", "節", "节", "週", "周",
        "小時", "小时", "分鐘", "分钟", "秒", "公斤", "公里", "公尺", "公分", "人", "部", "層", "层", "號", "号", "晚"
    ]
    private static let englishMonths: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    ]
    /// 數值後面的單位寫法不同但同一種（改口要搬去取代同一種單位的值）。
    private static let unitAliases: [String: String] = ["点": "點", "時": "點", "时": "點", "号": "日", "號": "日", "块": "元", "塊": "元", "楼": "樓"]
    private static let chineseDigits: [Character: Character] = ["零": "0", "〇": "0", "一": "1", "二": "2", "兩": "2", "两": "2", "三": "3",
                                                                "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]

    /// 一個數字出現的地方：整串的值（含負號、小數），以及連字號拆開後每一段的值（電話「0912-345-678」、區間「2-3」）。
    private struct NumberValue {
        let whole: String?
        var parts: [String] = []
        /// 中文數字裡相鄰重複的字併掉之後的值（ASR 結巴「十十月」＝十月），只在原文那一側採計。
        var stutter: String? = nil
        var range = NSRange(location: 0, length: 0)
        /// 沒有負號、小數點的阿拉伯數字原樣（含前導零），接電話號碼用。
        var digits: String? = nil
        /// 可以當小數部分的一串個位數字（「一點五」的五、「1點5」的 5）。
        var fraction: String? = nil
        /// 輸出那一側要比先後：阿拉伯數字、帶負號的、兩個字以上的中文數字、單獨的二～九、後面接量詞的「一」。
        /// 單獨的「一」「十」「百」「千」「萬」「零」常是一般詞（一起、十分、萬一），只比數值、不比先後。
        var ordered = true
        /// 另一種讀法：「減三dB」可以是 3 也可以寫成 -3、「10 minus 3」的 3 可以寫成 -3、「B1」（地下一樓）＝「負一樓」。
        var alternate: String? = nil
        /// 數值後面緊接的單位（一個中文字或一個英文字，小寫；同義寫法併成一種）；沒有就是空字串。
        var unit = ""
        /// 單位加後面緊接的兩個中文字（`valueLabel`：「杯拿鐵」「樓開會」）。
        var label = ""
    }

    private static func canonical(_ digits: String) -> String {
        let trimmed = digits.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// 小數的值：整數部分去前導零、小數部分去尾端零（「1.50」＝「1.5」、「1.0」＝「1」）。
    private static func decimalValue(_ integer: String, _ fraction: Substring) -> String {
        let trimmed = fraction.reversed().drop(while: { $0 == "0" }).reversed()
        return trimmed.isEmpty ? canonical(integer) : canonical(integer) + "." + String(trimmed)
    }

    private static func numberValues(in text: String, dropsOnly: Bool = false) -> (body: NSString, values: [NumberValue]) {
        dropsOnly ? dropsNumberValueScans(text) : numberValueScans(text)
    }

    private static func scanNumberValues(in text: String, dropsOnly: Bool = false) -> (body: NSString, values: [NumberValue]) {
        let body = removingInlineOrdinals(replace(dropsOnly ? dropsLineOrdinal : lineOrdinal, in: text, with: "")) as NSString
        let values = numberValueRun.matches(in: body as String, range: NSRange(location: 0, length: body.length)).map { match -> NumberValue in
            var token = body.substring(with: match.range)
            // 前後只看附近幾個字（UTF-16 單位）就夠判斷符號與單位，長文不必每個數值都複製整段。
            let windowStart = max(0, match.range.location - 16)
            let before = body.substring(with: NSRange(location: windowStart, length: match.range.location - windowStart))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            var sign = false, subtraction = false
            if let prefix = ["零下", "負的", "负的", "負", "负", "-", "−", "－"].first(where: token.hasPrefix) {
                token.removeFirst(prefix.count)
                sign = true
            } else if let word = ["minus", "negative"].first(where: token.lowercased().hasPrefix) {
                token.removeFirst(word.count)
                // 「10 minus 3」是減法：3 照樣是 3，寫成「10 - 3」「10-3」都對。
                subtraction = before.last.map { $0.isASCII && $0.isNumber } ?? false
                sign = !subtraction
            }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            // 「減三dB」：減是動詞，3 跟 -3 兩種寫法都算對。
            let reduced = subtraction || before.hasSuffix("減") || before.hasSuffix("减")
            func signed(_ value: String?) -> String? {
                guard let value, sign, value != "0" else { return value }
                return "-" + value
            }
            func negated(_ value: String?) -> String? {
                guard let value, reduced, value != "0" else { return nil }
                return "-" + value
            }
            let rest = body.substring(with: NSRange(location: NSMaxRange(match.range), length: min(24, body.length - NSMaxRange(match.range))))
            let unit = valueUnit(before: before, after: rest), label = valueLabel(unit: unit, after: rest)
            guard let first = token.unicodeScalars.first, (48...57).contains(first.value) else {
                // 只有單位字（「萬」）時 chineseToInt 回 0，那不是一個數值。
                func value(of run: String) -> String? {
                    Normalizer.chineseToInt(run).flatMap { $0 == 0 && !run.contains(where: { "零〇".contains($0) }) ? nil : $0 }.map { String($0) }
                }
                var collapsed = ""
                for character in token where collapsed.last != character { collapsed.append(character) }
                let digitsOnly = !sign && token.allSatisfy { chineseDigits[$0] != nil }
                let quantity = token == "一" && quantityClassifiers.contains(where: rest.hasPrefix)
                return NumberValue(whole: signed(value(of: token)), stutter: collapsed == token ? nil : signed(value(of: collapsed)),
                                   range: match.range, fraction: digitsOnly ? String(token.compactMap { chineseDigits[$0] }) : nil,
                                   ordered: sign || quantity || token.count >= 2 || "二兩两三四五六七八九".contains(token),
                                   alternate: negated(value(of: token)), unit: unit, label: label)
            }
            let plain = token.replacingOccurrences(of: ",", with: "")
            if let colon = plain.firstIndex(of: ":") {
                // 時刻是一個值（FX-3 第四輪 G1）：「3:00開會」是 3 點（單位「點」、標籤「點開會」），不是 3 跟 00 兩個數；
                // 拆開的話 00 會帶走「開會」，改口的值就能搶到 3 的位置。整點就是那個鐘點，其他寫成「3:30」。
                let hour = canonical(String(plain[..<colon])), minute = String(plain[plain.index(after: colon)...])
                let following = rest.drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0.isLetter && !$0.isASCII }).prefix(2)
                return NumberValue(whole: signed(minute == "00" ? hour : hour + ":" + minute), range: match.range,
                                   unit: "點", label: "點" + following)
            }
            if let dot = plain.firstIndex(of: ".") {
                // FX-7 V1：版本號、點分的編號（版本2.10、7.10.4、V2.10）每一段照字串比，「2.10」≠「2.1」。
                if isVersionNumber(in: body, at: match.range, before: before, after: rest) {
                    return NumberValue(whole: signed(plain), range: match.range, alternate: negated(plain), unit: unit, label: label)
                }
                // 一般的數值尾端的 0 可以省略（3.50元＝3.5元）；原樣的寫法當另一種讀法，對得上原文的版本號（版本2.10→「2.10 版」）。
                let value = decimalValue(String(plain[..<dot]), plain[plain.index(after: dot)...])
                return NumberValue(whole: signed(value), range: match.range,
                                   alternate: negated(value) ?? (plain == value ? nil : signed(plain)), unit: unit, label: label)
            }
            let groups = plain.split(separator: "-").map { canonical(String($0)) }
            let digits = plain.replacingOccurrences(of: "-", with: "")
            // 「B1」「B2」：樓層前面的 B 是地下（「負一樓」→「B1」）。B 前面不能還有英文字母（「AB1」不算）。
            let basement = !sign && groups.count == 1 && before.hasSuffix("B")
                && !(before.dropLast().last.map { $0.isASCII && $0.isLetter } ?? false)
            return NumberValue(whole: signed(canonical(digits)), parts: groups.count > 1 ? groups : [], range: match.range,
                               digits: sign ? nil : digits,
                               fraction: !sign && groups.count == 1 && plain == token ? plain : nil,
                               alternate: groups.count > 1 ? nil : (basement && canonical(digits) != "0" ? "-" + canonical(digits) : negated(canonical(digits))),
                               unit: unit, label: label)
        }
        return (body, values)
    }

    /// 版本號前面緊接的英文字（FX-7 V1）：V、version、ver、iOS、macOS、Android、build（不分大小寫、整個字）；中文是「版本」「版」。
    private static let versionLeads: Set<String> = ["v", "ver", "version", "ios", "macos", "android", "build"]
    /// 同一個子句裡前面講過這些詞，後面的小數也是版本號（「把版本從2.9升到2.10」「iOS 從17.9升到17.10」）；英文要是整個字。
    private static let versionClauseWords: Set<String> = ["version", "ios", "macos", "android", "build"]
    /// 數字後面接這些＝數量、價錢、倍數，不是版本號（「這個版本要3.50元」「新版本快1.50倍」）。
    private static let measureWords = quantityClassifiers + ["倍", "%", "％", "度", "克", "米", "毫", "成"]

    /// 帶小數點的數字是版本號或點分的編號（FX-7 V1）：
    /// - 點分的一串裡的一段（7.10.4、192.168.1.10：前面緊接「數字.」或後面緊接「.數字」）；
    /// - 前面緊接「版本」「版」或 `versionLeads`（中間可以隔空白、是、為、號、冒號：「版本是2.10」「iOS 17.10」「V2.10」）；
    /// - 後面緊接「版」（2.10版）；
    /// - 同一個子句前面講過「版本」或 `versionClauseWords`，後面也不是 `measureWords`。
    /// 這種數字每一段照字串比；一般的數值（3.50元、1.50倍）尾端的 0 照樣可以省略。
    private static func isVersionNumber(in body: NSString, at range: NSRange, before: String, after rest: String) -> Bool {
        func isDigit(_ index: Int) -> Bool { index >= 0 && index < body.length && (48...57).contains(body.character(at: index)) }
        let dot: unichar = 0x2E, end = NSMaxRange(range)
        if range.location >= 2 && body.character(at: range.location - 1) == dot && isDigit(range.location - 2) { return true }
        if end < body.length && body.character(at: end) == dot && isDigit(end + 1) { return true }
        let following = rest.drop(while: { $0 == " " || $0 == "\t" })
        if following.first == "版" { return true }
        func isASCIILetter(_ character: Character) -> Bool { character.isASCII && character.isLetter }
        let lead = String(before.reversed().drop(while: { " \t是為为號号：:".contains($0) }).reversed())
        if lead.hasSuffix("版本") || lead.hasSuffix("版") { return true }
        if versionLeads.contains(String(lead.reversed().prefix(while: isASCIILetter).reversed()).lowercased()) { return true }
        guard !measureWords.contains(where: { following.hasPrefix($0) }) else { return false }
        let clause = String(before.reversed().prefix(while: { !"，。！？,!?、；;\n".contains($0) }).reversed())
        return clause.contains("版本")
            || clause.split(whereSeparator: { !isASCIILetter($0) }).contains { versionClauseWords.contains($0.lowercased()) }
    }

    /// 數值後面緊接的單位：略過空白，英文取整個單字（小寫），其他文字取一個字（同義寫法併成一種）；沒有就是空字串。
    /// 「3:00」的 3 是幾點（Normalizer 會把「三點開會」寫成「3:00開會」）；英文月份後面的數字是幾號（「October 22」＝22 日）。
    private static func valueUnit(before: String, after rest: String) -> String {
        let previousWord = before.reversed().prefix(while: { $0.isASCII && $0.isLetter }).reversed()
        if englishMonths.contains(String(previousWord).lowercased()) { return "日" }
        let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else { return "" }
        if first == ":" || first == "：", let next = trimmed.dropFirst().first, next.isASCII && next.isNumber { return "點" }
        if first.isASCII && first.isLetter {
            return String(trimmed.prefix(while: { $0.isASCII && $0.isLetter })).lowercased()
        }
        guard first.isLetter else { return "" }
        return unitAliases[String(first)] ?? String(first)
    }

    /// 單位加後面緊接的兩個中文字（「一杯拿鐵」→「杯拿鐵」、「3樓開會」→「樓開會」）：數量還綁著同一樣東西，
    /// 換位置不算換主人（「兩杯拿鐵，一杯美式」→「一杯美式，兩杯拿鐵」）。英文的單位已經是整個字（apples），就是它。
    private static func valueLabel(unit: String, after rest: String) -> String {
        guard let first = unit.first, !first.isASCII else { return unit }
        let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
        return unit + String(trimmed.dropFirst().prefix(while: { $0.isLetter && !$0.isASCII }).prefix(2))
    }

    private static let joinableDigitGap = try! NSRegularExpression(pattern: #"^[\s\u3000\-－–—~～到至,，、]{1,3}$"#)
    /// 數值附近同一個子句的範圍到這些字為止（「3:00」的冒號不算）。
    private static let valueContextStops: Set<unichar> = Set("，。！？,!?、；;\n".utf16)

    /// 原文的數值依出現順序排成一格一格（連字號分段的數字每段一格）；`spans` 是可以合起來對上一個輸出數值的連續幾格：
    /// - 連字號分段的整串（「2026-10-22」＝20261022）；
    /// - 相鄰的阿拉伯數字（中間只隔空白、連字號、「到」或逗號）接起來至少 7 位：電話「0912到 345678」整理成
    ///   「0912-345-678」或「0912345678」，數字順序沒變、只是分段不同（2026-10-22 replay real-claude s23）；「3到5天」不算 35；
    /// - 整數後面接「點」與一串個位數字＝小數（「一點五」＝1.5、「七點一點四」→「7.1.4」）。
    private struct SourceNumbers {
        var cells: [Set<String>] = []
        /// 每一格數值後面的單位（`NumberValue.unit`），改口要搬去取代同一種單位的值。
        var units: [String] = []
        /// 每一格的 `NumberValue.label`（單位＋後面兩個字）。
        var labels: [String] = []
        /// 每一格數值前後同一個子句裡的字（各最多 8 個 UTF-16 單位），改口時找「開會是四點」說的是哪一個值。
        var contexts: [String] = []
        /// 每一格數值前面緊接的詞（`ownerWord`：「預算100元」的「預算」），補回重複的值時看是不是同一個主人（FX-7 R2）。
        var owners: [String] = []
        var spans: [(start: Int, end: Int, value: String)] = []
        /// 改口詞（「，不對，」）後面同一個子句的第一個數值在第幾格：它可以取代前面某一個值（`moving`）。
        var replacements: [Int] = []
        /// 改口詞跟那個數值中間的字（「，不對，開會是四點」的「開會是」）；緊接在改口詞後面就沒有。
        var preambles: [Int: String] = [:]

        init(_ text: String, dropsOnly: Bool = false) {
            let (body, values) = CleanupFidelity.numberValues(in: text, dropsOnly: dropsOnly)
            var bounds: [Range<Int>] = []
            for value in values {
                let start = cells.count
                if value.parts.isEmpty {
                    cells.append(Set([value.whole, value.stutter, value.alternate].compactMap { $0 }))
                } else {
                    cells.append(contentsOf: value.parts.map { [$0] })
                    if let whole = value.whole { spans.append((start, cells.count, whole)) }
                }
                units += Array(repeating: value.unit, count: cells.count - start)
                labels += Array(repeating: value.label, count: cells.count - start)
                var from = value.range.location, to = NSMaxRange(value.range)
                while from > 0 && value.range.location - from < 8 && !CleanupFidelity.valueContextStops.contains(body.character(at: from - 1)) { from -= 1 }
                while to < body.length && to - NSMaxRange(value.range) < 8 && !CleanupFidelity.valueContextStops.contains(body.character(at: to)) { to += 1 }
                contexts += Array(repeating: body.substring(with: NSRange(location: from, length: to - from)), count: cells.count - start)
                owners += Array(repeating: CleanupFidelity.ownerWord(in: body, before: value.range.location), count: cells.count - start)
                bounds.append(start ..< cells.count)
            }
            func gap(_ left: Int, _ right: Int) -> String {
                let from = NSMaxRange(values[left].range)
                return body.substring(with: NSRange(location: from, length: values[right].range.location - from))
            }
            var chain: [Int] = []
            func flush() {
                for (offset, start) in chain.enumerated() {
                    var digits = values[start].digits ?? ""
                    for next in chain.dropFirst(offset + 1) {
                        digits += values[next].digits ?? ""
                        if digits.count >= 7 { spans.append((bounds[start].lowerBound, bounds[next].upperBound, CleanupFidelity.canonical(digits))) }
                    }
                }
                chain = []
            }
            for index in values.indices {
                guard values[index].digits != nil else { flush(); continue }
                if let last = chain.last {
                    let between = gap(last, index)
                    if CleanupFidelity.joinableDigitGap.firstMatch(in: between, range: NSRange(location: 0, length: (between as NSString).length)) == nil { flush() }
                }
                chain.append(index)
            }
            flush()
            for index in values.indices.dropLast() {
                guard values[index].parts.isEmpty, let whole = values[index].whole, !whole.contains("."),
                      let fraction = values[index + 1].fraction, ["點", "点"].contains(gap(index, index + 1)) else { continue }
                let value = whole.hasPrefix("-") ? "-" + decimalValue(String(whole.dropFirst()), fraction[...])
                                                 : decimalValue(whole, fraction[...])
                // FX-7 V1：說出來的版本號（「版本二點一零」，或連著三段以上的「七點一零點四」）每一段照字串比，只認原樣「2.10」；
                // 一般的小數兩種寫法都算（「一點五零」＝1.5＝1.50）。
                let dotted = (index > 0 && values[index].fraction != nil && ["點", "点"].contains(gap(index - 1, index)))
                    || (index + 2 < values.count && values[index + 2].fraction != nil && ["點", "点"].contains(gap(index + 1, index + 2)))
                let start = values[index].range.location, end = NSMaxRange(values[index + 1].range)
                let windowStart = max(0, start - 16)
                let before = body.substring(with: NSRange(location: windowStart, length: start - windowStart))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                let rest = body.substring(with: NSRange(location: end, length: min(24, body.length - end)))
                let version = dotted || CleanupFidelity.isVersionNumber(in: body, at: NSRange(location: start, length: end - start),
                                                                        before: before, after: rest)
                let exact = whole + "." + fraction
                if !version { spans.append((bounds[index].lowerBound, bounds[index + 1].upperBound, value)) }
                if version || exact != value { spans.append((bounds[index].lowerBound, bounds[index + 1].upperBound, exact)) }
            }
            // 改口詞後面同一個子句的第一個數值：緊接著（「，不對，4點」），或先重提是哪一個（「，不對，開會是四點」，最多 8 個字）。
            for marker in CleanupFidelity.correctionMarkerRegex.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                let end = NSMaxRange(marker.range)
                guard let index = values.indices.first(where: { values[$0].range.location >= end }), values[index].parts.isEmpty,
                      values[index].range.location - end <= 8 else { continue }
                let preamble = body.substring(with: NSRange(location: end, length: values[index].range.location - end))
                guard !preamble.utf16.contains(where: CleanupFidelity.valueContextStops.contains) else { continue }
                replacements.append(bounds[index].lowerBound)
                if !preamble.isEmpty { preambles[bounds[index].lowerBound] = preamble }
            }
        }

        /// 改口後的值搬到它取代的那一格（原本那格的值拿掉）：「約3點開會，地點在5樓，不對，4點」→ 4、5。
        func moving(_ from: Int, to target: Int) -> SourceNumbers {
            var copy = self
            copy.cells[target] = cells[from]
            copy.cells.remove(at: from)
            copy.units[target] = units[from]
            copy.units.remove(at: from)
            copy.labels.remove(at: from)
            copy.contexts.remove(at: from)
            copy.owners.remove(at: from)
            copy.spans = spans.compactMap { span in
                if (span.start ..< span.end).contains(target) || (span.start ..< span.end).contains(from) { return nil }
                return span.start > from ? (span.start - 1, span.end - 1, span.value) : span
            }
            copy.replacements = []
            copy.preambles = [:]
            return copy
        }

        /// 輸出裡補回的重複值，前面緊接的詞 `owner` 是第 `cell` 格的主人（FX-7 R2）：說到第 `cell` 格的那個子句裡有這個詞，
        /// 而且它不是別的值的主人（「預算100元，訂金200元」→「…訂金100元」的訂金是 200 的主人，不是 100 的）。
        func restates(_ owner: String, at cell: Int) -> Bool {
            contexts[cell].lowercased().contains(owner) && !owners.indices.contains { $0 != cell && owners[$0] == owner }
        }

        /// `value` 從第 `cursor` 格起最早在哪裡結束：對上一格，或一段合起來的格子。對不上回 nil。
        func earliestEnd(of value: String, from cursor: Int) -> Int? {
            var best = cells.indices.first(where: { $0 >= cursor && cells[$0].contains(value) }).map { $0 + 1 }
            for span in spans where span.start >= cursor && span.value == value { best = min(best ?? .max, span.end) }
            return best
        }

        /// 輸出的一個數值從第 `cursor` 格起最早在哪裡對上：整個值（或另一種讀法：「B1」＝-1）對上，
        /// 或連字號各段依序對上（「2到3天」→「2-3 天」）。
        func earliestEnd(of number: NumberValue, from cursor: Int) -> Int? {
            guard let whole = number.whole else { return cursor }
            var best = earliestEnd(of: whole, from: cursor)
            if let alternate = number.alternate, let end = earliestEnd(of: alternate, from: cursor) { best = min(best ?? .max, end) }
            if !number.parts.isEmpty {
                var position: Int? = cursor
                for part in number.parts { position = position.flatMap { earliestEnd(of: part, from: $0) } }
                if let position { best = min(best ?? .max, position) }
            }
            return best
        }
    }

    /// 輸出出現原文沒有的「數值」＝把數字改錯了（「1,250」→「12,500」、「3:30」→「3:00」、「30萬」→「100,000」）。
    /// `introducesDigits` 只比 0–9 各個數字，數值錯十倍看不出來（2026-10-19 phone-real-claude nd05）。
    /// 兩邊要先轉成同一種數字寫法（`passesRelaxed` 已經轉好）；行首清單編號「1. 」不算；
    /// 阿拉伯數字（千分位、連字號拆開或合起來都算）與中文數字（「一」「三十」）的值互通：「一小時」→「1 小時」照樣放行；
    /// 原文結巴重複的中文數字（「十十月」）也認得併掉後的值（10-19 真人錄音「十十月十三號」→「10 月 13 號」）；
    /// 電話號碼重新分段（「0912到 345678」→「0912-345-678」）也照樣放行。
    /// 負號與小數點是數值的一部分（FX-3 ①）：「-14」≠「14」、「1.5」≠「5.1」；「負14」「零下5」＝「-14」「-5」。
    public static func introducesNumberValues(original: String, cleaned: String) -> Bool {
        let source = SourceNumbers(original)
        return numberValues(in: cleaned).values.contains { value in
            guard let whole = value.whole, source.earliestEnd(of: whole, from: 0) == nil,
                  value.alternate.map({ source.earliestEnd(of: $0, from: 0) == nil }) ?? true else { return false }
            return value.parts.isEmpty || !value.parts.allSatisfy { source.earliestEnd(of: $0, from: 0) != nil }
        }
    }

    /// 數值換了主人（FX-3 ②）：「預算是100元，訂金是200元」→「預算是200元，訂金是100元」、或把 100 抄到 200 的位置。
    /// 輸出的數值要照原文的先後出現、次數不能變多（可以省略）。改口照樣放行：原文的幾種讀法
    /// （刪掉被改口取代的片段、照改口改好）任何一種對得上就好；有停頓的改口詞後面的值，
    /// 也可以搬去取代前面最近一個同單位的值（「約3點開會，地點在5樓，不對，4點」→「約4點開會，地點在5樓」）；
    /// 沒有同單位的就取代緊鄰的前一個值。不能隨便挑一個（「預算100元，訂金200元，不對，300元」的 300 是訂金，不是預算）。
    /// 單位不同的數值可以互換位置（日期與時間重排），同一種單位的照原文先後。
    /// 兩邊要先轉成同一種數字寫法（`passesRelaxed` 已經轉好）。
    public static func reordersNumberValues(original: String, cleaned: String) -> Bool {
        let scanned = numberValues(in: cleaned)
        let output = scanned.values.filter { $0.ordered && $0.whole != nil }
        guard !output.isEmpty else { return false }
        // 不同單位的數值可以換位置（「明天下午三點，十月二十三號」→「10月23日（明天）下午3點」）：每個數值都還帶著原本的單位、
        // 同一種單位的數值照原文先後，就沒有換主人。數量還綁著同一樣東西（單位＋後面兩個字：「兩杯拿鐵，一杯美式」→
        // 「一杯美式，兩杯拿鐵」）也一樣。單位被改掉或沒有單位的，照整串的先後比。
        func keepsOrder(_ source: SourceNumbers, by key: (NumberValue) -> String, _ sourceKeys: [String]) -> Bool {
            guard output.allSatisfy({ !key($0).isEmpty && $0.parts.isEmpty }) else { return false }
            var cursors: [String: Int] = [:]
            for value in output {
                guard let whole = value.whole,
                      let found = ((cursors[key(value)] ?? 0) ..< source.cells.count).first(where: {
                          sourceKeys[$0] == key(value) && source.cells[$0].contains(whole)
                      }) else { return false }
                cursors[key(value)] = found + 1
            }
            return true
        }
        // 輸出把同一個值緊接著說了兩次（本機版把「不是星期四，星期四我要出差」的兩個併成一個，整理模型照原話補回來）：
        // 拿掉緊接重複的值之後，跟原文的數值一個不少、順序一樣才放行（「100元…100元」抄到 200 的位置照樣擋）。
        // 補回來的只能是同一個主人再說一次（FX-7 R2）：一個值最多補成兩個，兩個前面緊接的詞都要是空的、或是原文那一格的主人
        //（「不是4點我有會」→「不是4點；4點我有會」放行；「預算100元，訂金200元」→「預算100元，訂金100元，合計200元」擋）。
        var deduplicated: [NumberValue] = [], runs: [Range<Int>] = []
        for (index, value) in output.enumerated() {
            if deduplicated.last?.whole == value.whole {
                runs[runs.count - 1] = runs[runs.count - 1].lowerBound ..< index + 1
            } else {
                deduplicated.append(value)
                runs.append(index ..< index + 1)
            }
        }
        func restoresRepeat(_ source: SourceNumbers) -> Bool {
            guard deduplicated.count < output.count && deduplicated.count == source.cells.count
                && zip(deduplicated, source.cells).allSatisfy({ value, cell in value.whole.map(cell.contains) ?? false }) else { return false }
            return runs.indices.allSatisfy { cell in
                runs[cell].count == 1 || (runs[cell].count == 2 && output[runs[cell]].allSatisfy { value in
                    let owner = ownerWord(in: scanned.body, before: value.range.location)
                    return owner.isEmpty || source.restates(owner, at: cell)
                })
            }
        }
        // 單位不同的值可以換位置，但兩個值互相換走對方後面的詞＝換了主人（FX-3 第四輪：「三樓開會，五點吃飯」→「5點開會，3樓吃飯」；
        // 時刻「5:00」以前被拆成兩個數、單位對不上才擋到，現在是一個值，要明著比）。
        func swapsFollowers(_ source: SourceNumbers) -> Bool {
            func follower(_ label: String, _ unit: String) -> String { label.hasPrefix(unit) ? String(label.dropFirst(unit.count)) : "" }
            func sourceFollower(_ value: NumberValue) -> String? {
                guard let whole = value.whole,
                      let index = source.cells.indices.first(where: { source.units[$0] == value.unit && source.cells[$0].contains(whole) })
                else { return nil }
                return follower(source.labels[index], source.units[index])
            }
            for (index, value) in output.enumerated() {
                let after = follower(value.label, value.unit)
                guard !after.isEmpty, let before = sourceFollower(value), !before.isEmpty, before != after else { continue }
                if output[(index + 1)...].contains(where: { follower($0.label, $0.unit) == before && sourceFollower($0) == after }) { return true }
            }
            return false
        }
        func keepsOwners(_ source: SourceNumbers) -> Bool {
            var cursor = 0
            for value in output {
                guard let end = source.earliestEnd(of: value, from: cursor) else {
                    return (keepsOrder(source, by: \.unit, source.units) && !swapsFollowers(source))
                        || keepsOrder(source, by: \.label, source.labels) || restoresRepeat(source)
                }
                cursor = end
            }
            return true
        }
        // 原文的幾種讀法依序比，任何一種沒有換主人就放行（一種一種算，前面的讀法對上了就不必再找後面的數值）。
        let bases = prepareSource(original, allowListFormatting: false, outputKeepsListIntroCopula: false, listItems: [])
        if bases.contains(where: { keepsOwners(SourceNumbers($0)) }) { return false }
        let separated = SourceNumbers(separatingCorrectionMarkers(in: replace(listPrefix, in: numberForms(normalizeFullwidthDigits(in: original)), with: "")))
        for from in separated.replacements where from > 0 {
            let unit = separated.units[from]
            var target = unit.isEmpty ? from - 1 : (0 ..< from).last(where: { separated.units[$0] == unit }) ?? from - 1
            // 改口先重提是哪一個（「三點開會，五點吃飯，不對，開會是四點」）：取代前面同單位、附近也說到「開會」的那個值；
            // 前面沒有一個值附近說到同一個詞，就不當改口。
            if let preamble = separated.preambles[from] {
                guard let named = (0 ..< from).last(where: {
                    (unit.isEmpty || separated.units[$0] == unit) && sharesWord(separated.contexts[$0], preamble)
                }) else { continue }
                target = named
            }
            if keepsOwners(separated.moving(from, to: target)) { return false }
        }
        return true
    }

    /// FX-13 G1：數字句裡的一個值在輸出不見了（`100，200` → `100`）＝使用者無聲地少掉一個數字。
    /// 換一種寫法不算掉（`一萬二` → `12,000`、`100，200` → `100、200`），而且要看「有幾個」不是「有沒有」——
    /// `100，100` → `100` 就是掉了一個。唯一的例外是講者明講改口：被拿掉的值後面直接接著改口詞，
    /// 而且改口後的那個值還留在輸出裡。
    /// 只管整句除了數字（連單位字、贅詞、改口詞、標點）沒有別的東西的句子；有實詞的（預算、運費、我要…）
    /// 照原判定，這條規則不動。
    public static func dropsNumberValues(original: String, cleaned: String) -> Bool {
        let sourceText = numberForms(original), cleanedText = numberForms(cleaned)
        guard isNumberOnlyText(sourceText, dropsOnly: true) else { return false }
        // 掉值這條路徑用專屬的掃描（清單編號的判斷不同，見 dropsLineOrdinal）：原文、輸出、改口
        // 都要用同一套掃描，格位才對得起來。
        let source = SourceNumbers(sourceText, dropsOnly: true)
        guard !source.cells.isEmpty else { return false }
        let output = numberValues(in: cleanedText, dropsOnly: true).values
        // 輸出的每一個數值＝一個名額（`OutputSlot`）：整串與另一種讀法是同一個名額的兩種讀法，
        // 連字號的值要嘛當整串、要嘛當它每一段，不能兩種都來（FX-13 修復 R2：名額是獨佔的）。
        var slots = output.map { OutputSlot($0) }
        var kept = [Bool](repeating: false, count: source.cells.count)
        // 沒有值的一格不是掉值：單獨的「萬」（「三 萬 塊」裡的萬）本來就沒有值，
        // `scanNumberValues` 刻意不把它算成 0，這種空的一格不配對、也不算掉（FX-13 修復 R4）。
        for (index, cell) in source.cells.enumerated() where cell.isEmpty { kept[index] = true }
        // 原文有幾格可以合起來對上同一個輸出值（連字號分段、重新接起來的電話、「一點五」），它們只佔一個輸出值。
        for span in source.spans where !(span.start ..< span.end).contains(where: { kept[$0] }) {
            guard let position = slots.indices.first(where: { slots[$0].matches(whole: span.value) }) else { continue }
            slots[position].useWhole()
            for cell in span.start ..< span.end { kept[cell] = true }
        }
        // 每一格原文的值都要在輸出裡找得到，而輸出的名額只能配一格。
        for (index, cell) in source.cells.enumerated() where !kept[index] {
            if let position = slots.indices.first(where: { slots[$0].matches(cell: cell) }) {
                slots[position].useWhole()
                kept[index] = true
                continue
            }
            // 輸出的連字號分段可以各自配一格：「100～200」→「100-200」兩個值都還在，不算掉值（FX-13 修復 R1）。
            // 但同一個輸出不能又當整串又當其中一段（FX-13 修復 R2）。
            if let position = slots.indices.first(where: { slots[$0].matchesPart(cell: cell) }) {
                slots[position].usePart(cell: cell)
                kept[index] = true
            }
        }
        let dropped = kept.indices.filter { !kept[$0] }
        guard !dropped.isEmpty else { return false }
        let corrections = corrections(in: sourceText, keptIn: output.map(numberReadings), dropsOnly: true)
        // 改口後面的那一格是被併進改口後那個值的（「12,000，我是說，一萬二」→「12,000」本來就只留一個），
        // 不算掉值；改口詞前面那一格則是明講改掉了，只要新值有留就免掉。
        // 改口例外只決定「算不算掉值」，不增減輸出的名額（FX-13 修復 R2）。
        let lost = dropped.filter { !corrections.absorbed.contains($0) }
        guard !lost.isEmpty else { return false }
        return !lost.allSatisfy { corrections.corrected.contains($0) }
    }

    /// 一個輸出數值能讀成的樣子：整串、另一種讀法（「B1」＝-1）、連字號的每一段。
    private static func numberReadings(_ value: NumberValue) -> Set<String> {
        var set = Set([value.whole, value.alternate].compactMap { $0 })
        set.formUnion(value.parts)
        return set
    }

    /// 輸出的一个數值能提供的一個名額（FX-13 修復 R2：名額是獨佔的，不是「整串＋分段」兩份）。
    /// - 整串（`100200`）與另一種讀法（`B1`＝-1）是同一個名額的兩種讀法：用掉一種，另一種也不能再用。
    /// - 連字號的值（`100-200`）可以當整串用，也可以當它每一段用，但不能兩種都來：
    ///   用掉整串＝分段全部失效；先用掉一段＝整串失效，其他段還在。
    private struct OutputSlot {
        private let whole: String?
        private let alternate: String?
        private var parts: [String]
        private var wholeUsed = false
        private var partsUsed = false

        init(_ value: NumberValue) {
            whole = value.whole
            alternate = value.alternate
            parts = value.parts
        }

        /// 這個名額還能當整串（或另一種讀法）用嗎？
        private var wholeAvailable: Bool { !wholeUsed && !partsUsed }
        /// 這個名額還能當連字號的一段用嗎？
        private var partsAvailable: Bool { !wholeUsed }

        /// 原文合起來的一個值對不對得上這個名額的整串或另一種讀法。
        func matches(whole value: String) -> Bool {
            guard wholeAvailable else { return false }
            return self.whole == value || self.alternate == value
        }

        /// 原文的一格對不對得上這個名額的整串或另一種讀法。
        func matches(cell: Set<String>) -> Bool {
            guard wholeAvailable else { return false }
            if let whole, cell.contains(whole) { return true }
            if let alternate, cell.contains(alternate) { return true }
            return false
        }

        /// 原文的一格對不對得上這個名額的某一段。
        func matchesPart(cell: Set<String>) -> Bool {
            guard partsAvailable else { return false }
            return parts.contains { cell.contains($0) }
        }

        /// 用掉整串（另一種讀法一起沒了），分段全部失效。
        mutating func useWhole() { wholeUsed = true; parts.removeAll() }

        /// 用掉其中一段：整串失效，其他段還在。只吃掉配對的那一段——同樣的值出現兩次（`100-100`）
        /// 也只配掉一段，另一段還在（FX-13 修復 R3）。
        mutating func usePart(cell: Set<String>) {
            partsUsed = true
            guard let index = parts.firstIndex(where: { cell.contains($0) }) else { return }
            parts.remove(at: index)
        }
    }

    /// 數字句裡可以出現的單位（完整的單位詞，不是單一個字）：沿用本來那份單位清單（每個單位字），
    /// 加上本來就當成一個單位的複合寫法（分鐘、公斤、公尺）。
    /// 單一個字分開看會把實詞拆開（「條件」＝條＋件、「周日」＝週＋日），那種句子照原判定，不歸這條規則管（FX-13 修復 R2）。
    private static let numberOnlyUnits: Set<String> = [
        "年", "月", "日", "時", "时", "分", "分鐘", "分钟", "秒",
        "圓", "元", "塊", "块", "點", "点", "樓", "楼", "週", "周", "歲", "岁", "個", "个",
        "次", "款", "支", "瓶", "杯", "張", "张", "條", "条", "件", "份", "組", "组", "雙", "双",
        "套", "場", "场", "節", "节", "課", "课", "頁", "页", "題", "题", "篇", "輛", "辆",
        "箱", "盒", "包", "袋", "顆", "颗", "堂", "晚", "厘", "毫", "公", "尺", "里", "斤",
        "公尺", "公分", "毫米", "公里", "公斤", "度", "成", "钟", "鐘",
        "小時", "小时", "個小時", "个小时", "毫秒"
    ]
    /// 數字句裡可以出現的贅詞與改口詞（多字，先長的换掉）。
    private static let numberOnlyFillers = [
        "就是說", "就是说", "就是", "那個", "那个", "這個", "这个", "首先", "第",
        "嗯嗯", "嗯", "恩恩", "恩", "呃", "欸", "喔", "哦", "噢", "啊",
        "對對", "对对", "對啊", "对啊", "然後", "然后",
        "不對", "不对", "不是", "更正", "應該是", "应该", "講錯了", "讲错", "說錯了", "说错",
        "我是說", "我是说"
    ]
    /// 英文的數量單位（保守清單）：只看整個詞。
    private static let englishNumberUnits: Set<String> = [
        "kg", "g", "mg", "ml", "l", "cm", "mm", "m", "km", "ms", "s", "min", "sec", "hr", "hrs",
        "hz", "khz", "mhz", "mb", "gb", "kb", "tb", "yuan", "rmb", "usd", "nt", "dollar", "dollars",
        "year", "years", "month", "months", "day", "days", "hour", "hours", "minute", "minutes",
        "second", "seconds", "percent", "pct"
    ]
    /// 整句除了數字（連必要的單位詞、贅詞、改口詞、標點）沒有別的東西＝`dropsNumberValues` 的適用範圍。
    /// 數字的位置先當分隔符，剩下的字詞群（連續的字母）每一群要嘛是完整的單位詞（而且挨著數字）、
    /// 要嘛是贅詞／改口詞，要嘛是英文的單位詞（挨著數字）；有別的字就是有實詞（預算、運費、條件…）。
    private static func isNumberOnlyText(_ text: String, dropsOnly: Bool = false) -> Bool {
        let (body, values) = numberValues(in: text, dropsOnly: dropsOnly)
        let units = Array((body as String).utf16)
        var isNumber = [Bool](repeating: false, count: units.count)
        for value in values {
            for index in value.range.location ..< NSMaxRange(value.range) { isNumber[index] = true }
        }
        func isLetter(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.letters.contains(scalar)
        }
        func isSpace(_ unit: unichar) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x3000
        }
        /// 這群字挨著數字嗎（單位詞要在數字的旁邊才算數字的一部分）。
        func nextToNumber(_ start: Int, _ end: Int) -> Bool {
            var before = start - 1
            while before >= 0 && isSpace(units[before]) { before -= 1 }
            if before >= 0 && isNumber[before] { return true }
            var after = end
            while after < units.count && isSpace(units[after]) { after += 1 }
            return after < units.count && isNumber[after]
        }
        var index = 0
        while index < units.count {
            // 數值本身（阿拉伯數字與中文數字）不算字詞群的一部分：中文數字也是字母，不擋掉的話會跟單位黏成一群。
            guard !isNumber[index], isLetter(units[index]) else { index += 1; continue }
            let start = index
            while index < units.count && !isNumber[index] && isLetter(units[index]) { index += 1 }
            var scalars = String.UnicodeScalarView()
            for position in start ..< index {
                if let scalar = UnicodeScalar(units[position]) { scalars.append(scalar) }
            }
            let run = String(scalars)
            if numberOnlyUnits.contains(run) || englishNumberUnits.contains(run.lowercased()) {
                guard nextToNumber(start, index) else { return false }
                continue
            }
            // 贅詞與改口詞把這群字切開（「點不對應該是點」＝「點」＋「點」）：切出來的每一段都要嘛是單位詞。
            var segments: [String] = [run]
            for filler in numberOnlyFillers {
                segments = segments.flatMap { segment in
                    segment.contains(filler) ? segment.components(separatedBy: filler) : [segment]
                }
            }
            let pieces = segments.filter { !$0.isEmpty }
            if pieces.isEmpty { continue }
            guard pieces.allSatisfy({ numberOnlyUnits.contains($0) || englishNumberUnits.contains($0.lowercased()) }) else { return false }
            guard nextToNumber(start, index) else { return false }
        }
        return true
    }

    /// 原文裡「某個值後面直接接著改口詞」的那幾格：`corrected` 是被明講改掉的舊值（輸出沒有它不算掉值），
    /// `absorbed` 是改口後面那個新值所在的格（它就是留下來的那一個，不用再另外配一個輸出值）。
    /// 只有新值還在輸出裡才算數——「100，不對，200」改成「100」連新值都沒留，不放行。
    private static let valueBeforeCorrection = try! NSRegularExpression(
        pattern: #"(?:[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?(?::[0-9]{1,2})?|[零〇一二兩两三四五六七八九十百千萬万億亿]+)[點点時时日號号樓楼元塊块個个]?[，,、;；\s]*(?:[啊呃喔哦噢欸][，,、\s]*)*(?i:(?:不對|不对|不是|更正|應該是|应该|講錯了|讲错|說錯了|说错|我是說|我是说|i mean|sorry))[，,、;；\s]*(?:是|為|为)?"#,
        options: [.caseInsensitive]
    )
    private static func corrections(in text: String, keptIn output: [Set<String>], dropsOnly: Bool = false) -> (corrected: Set<Int>, absorbed: Set<Int>) {
        let (body, values) = numberValues(in: text, dropsOnly: dropsOnly)
        // 每一個數值從第幾格開始（連字號分段每段一格）。
        var start: [Int] = [], cell = 0
        for value in values {
            start += Array(repeating: cell, count: max(1, value.parts.count))
            cell += max(1, value.parts.count)
        }
        let whole = NSRange(location: 0, length: body.length)
        var corrected: Set<Int> = [], absorbed: Set<Int> = []
        for marker in valueBeforeCorrection.matches(in: body as String, range: whole) {
            guard let index = values.indices.last(where: {
                values[$0].range.location >= marker.range.location
                    && NSMaxRange(values[$0].range) <= NSMaxRange(marker.range)
            }), index < start.count else { continue }
            let end = NSMaxRange(marker.range)
            // 改口詞後面同一個子句的第一個數值（緊接著，或先重提是哪一個，最多 8 個字）還在輸出裡。
            guard let next = values.firstIndex(where: { $0.range.location >= end && $0.range.location - end <= 8 }) else { continue }
            let gap = body.substring(with: NSRange(location: end, length: values[next].range.location - end))
            guard !gap.utf16.contains(where: valueContextStops.contains) else { continue }
            let readings = numberReadings(values[next])
            if output.contains(where: { !$0.isDisjoint(with: readings) }) {
                corrected.insert(start[index])
                if next < start.count { absorbed.insert(start[next]) }
            }
        }
        return (corrected, absorbed)
    }

    /// 數值前面緊接、屬於數值自己的字（星期四、下午三點、10月23號）：不是主人，略過再往前找（FX-7 R2）。
    private static let valuePrefixes = ["星期", "禮拜", "礼拜", "上午", "下午", "早上", "晚上", "中午", "凌晨", "傍晚", "週", "周", "月"]

    /// `location` 前面緊接的詞（略過空白與 `valuePrefixes`）：一個英文字（小寫），或最多兩個中文字；前面是標點、數字或開頭就是空字串。
    private static func ownerWord(in body: NSString, before location: Int) -> String {
        var end = location
        while end > 0 && [0x20, 0x09].contains(body.character(at: end - 1)) { end -= 1 }
        if let prefix = valuePrefixes.first(where: { (end >= ($0 as NSString).length)
            && body.substring(with: NSRange(location: end - ($0 as NSString).length, length: ($0 as NSString).length)) == $0 }) {
            end -= (prefix as NSString).length
            while end > 0 && [0x20, 0x09].contains(body.character(at: end - 1)) { end -= 1 }
        }
        let start = max(0, end - 16)
        let lead = Array(body.substring(with: NSRange(location: start, length: end - start)))
        guard let last = lead.last, last.isLetter else { return "" }
        if last.isASCII {
            return String(lead.reversed().prefix(while: { $0.isASCII && $0.isLetter }).reversed()).lowercased()
        }
        return String(lead.reversed().prefix(while: { $0.isLetter && !$0.isASCII }).prefix(2).reversed())
    }

    /// 兩段字有同一個詞：兩個中文字、或一個 4 個字母以上的英文字（改口重提「開會」對上前面的「3:00開會」）。
    private static func sharesWord(_ context: String, _ preamble: String) -> Bool {
        let characters = Array(preamble)
        for index in characters.indices.dropLast() where !characters[index].isASCII && characters[index].isLetter
            && !characters[index + 1].isASCII && characters[index + 1].isLetter {
            if context.contains(String(characters[index ... index + 1])) { return true }
        }
        let words = context.lowercased().split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map(String.init)
        return preamble.lowercased().split(whereSeparator: { !($0.isASCII && $0.isLetter) })
            .contains { $0.count >= 4 && words.contains(String($0)) }
    }

    /// 一組對比：原文說 A（對的那個）不是 B。
    private struct ContrastPair {
        let a: [String]
        let b: [String]
        /// B 去掉開頭的介系詞、冠詞（on Thursday→thursday、在星期四→星期四）；跟 B 一樣就沒有。
        let bCore: [String]?
        /// A 前面緊接的兩個詞（同一個子句裡）；不夠兩個就沒有。
        let context: [String]?
        /// A 是明確的一個詞：同形狀的一對（三點／四點），或「是」後面最多 6 個詞。
        let narrow: Bool
        /// 沒有「是」、逗號、同形狀可以認 A 的「A不是B」：只擋 A 不見了、B 變成肯定。
        var bare = false
    }

    /// 英文否定詞前面只有這些＝子句只有主詞（和助動詞），A 在前一個子句（「It's Wednesday, it's not Thursday」）。
    private static let englishSubjectWords: Set<String> = [
        "i", "i'm", "we", "we're", "you", "you're", "he", "he's", "she", "she's", "it", "it's", "they", "they're",
        "that", "that's", "this", "there", "there's", "is", "are", "was", "were", "am", "do", "does", "did",
        "will", "would", "should", "can", "could"
    ]

    private static let contrastStopsAfterChinese: Set<String> = ["嗎", "吗", "嘛", "吧", "呢", "啊", "不", "很", "太", "只", "都", "每"]
    private static let contrastStopsAfterEnglish: Set<String> = ["only", "just", "even", "sure", "yet", "really", "always", "necessarily", "too", "very", "so"]
    /// 否定詞跟 B 中間可以隔一個的介系詞、冠詞（not on Thursday、不是在星期四）。
    private static let contrastFunctionWords: Set<String> = ["on", "at", "in", "the", "a", "an", "to", "for", "by", "在"]
    /// 本機版會把「第二版不是第三版」排成清單、在「不是」後面換行；換行不是停頓，接回去才認得出對比。
    private static let lineBreakAfterNegation = try! NSRegularExpression(pattern: #"(不是|而非|並非|并非|(?<![A-Za-z])(?i:not))[ \t]*\n+[ \t]*"#)

    /// 對比句「是 A 不是 B」「A，不是 B」「星期三不是星期四」被整理成 B 才是對的＝意思整個反過來（「我要的是三點不是四點」→「我要的是四點。」）。
    /// 改口要有「不是，是 B」「不是是 B」這種形狀，不在此列；英文的「A, not B」「Wednesday not Thursday」也照算。
    /// 「A 而非／並非 B」「A instead of／rather than B」同樣是 A 對；「不是 B 而是 A」「不是 B，是 A」「not B but A」是後面那個 A 對。
    /// 英文的 isn't／don't 跟 not 一樣；「A, it's not B」「A, don't B」否定詞前面只有主詞的，跟「A, not B」一樣 A 在前一個子句。
    /// 沒有「是」也沒有逗號的「X不是Y」前後是同一種東西時（星期三／星期四、三點／四點、A版／B版）照下面三條看；
    /// 其他的（「我要喝拿鐵不是美式」「Alice and not Bob」）看不準 A 是哪幾個詞，只擋「A 變少了、B 變成肯定」（FX-3 第四輪 G3）——
    /// 「這不是問題」這類一般否定、留著 A 的改寫都不受影響。每一組對比各自看（FX-3 ③），任何一條成立就是翻轉：
    /// 1. 輸出裡沒被否定的 B 比原文多（B 只能留在「不是／not」後面）；本機版把「不是星期四，星期四我要出差」的兩個 B 併成一個、
    ///    整理模型照原話補回來（「不是 B」後面緊接一樣的 B、再接原文同一個字）不算；
    /// 2. B 坐上了 A 的位置：B 前面緊接的兩個詞跟原文 A 前面的一樣（「預定的是台北不是台南，台南那家…」→「預定的是台南，那家…」）；
    /// 3. A 是明確的一個詞時，A 變少了、B 還在——輸出還留著整組「A 不是 B」（後面省掉重提的 A）不算。
    /// 別處還有「不是」、或 A／B 在別處出現，都不能拿來抵；連 B 都拿掉了不算翻轉。禮拜／星期、台／臺這類換說法照樣認得。
    public static func invertsContrast(original: String, cleaned: String) -> Bool {
        // 沒有否定詞就不可能有對比，省掉兩千字長段落的斷詞（每次把關都會先走這裡）。
        guard original.contains("不") || original.contains("非") || original.range(of: "not", options: .caseInsensitive) != nil
                || original.range(of: "n't", options: .caseInsensitive) != nil || original.range(of: "n’t", options: .caseInsensitive) != nil
                || original.range(of: "instead", options: .caseInsensitive) != nil
                || original.range(of: "rather", options: .caseInsensitive) != nil else { return false }
        let tokens = meaningTokens(replace(lineBreakAfterNegation, in: original, with: "$1"))
        let pairs = contrastPairs(in: tokens)
        guard !pairs.isEmpty else { return false }
        let source = IndexedWords(tokens.filter { $0 != "|" }), output = IndexedWords(meaningTokens(cleaned).filter { $0 != "|" })
        for pair in pairs {
            var alternatives = [pair.b]
            let head = Array(pair.b.prefix(max(2, pair.a.count)))
            if head.count < pair.b.count { alternatives.append(head) }
            if let core = pair.bCore { alternatives.append(core) }
            let assertsB = alternatives.contains(where: {
                assertedCount($0, in: output) - restoredRepeats(of: $0, in: output, source: source) > assertedCount($0, in: source)
            })
            if pair.bare {
                if assertsB && assertedCount(pair.a, in: output) < assertedCount(pair.a, in: source) { return true }
                continue
            }
            if assertsB { return true }
            if let context = pair.context,
               occurrences(of: context + pair.b, in: output) > occurrences(of: context + pair.b, in: source) { return true }
            if pair.narrow, assertedCount(pair.a, in: output) < assertedCount(pair.a, in: source),
               assertedCount(pair.b, in: output) > 0, !keepsContrast(pair, in: output.list) { return true }
        }
        return false
    }

    /// 原文裡的每一組對比（`tokens` 是 `meaningTokens`，含子句分隔「|」）。
    private static func contrastPairs(in tokens: [String]) -> [ContrastPair] {
        func clauseStart(_ end: Int) -> Int {
            var start = end
            while start > 0 && tokens[start - 1] != "|" { start -= 1 }
            return start
        }
        func clauseEnd(_ start: Int) -> Int {
            var end = start
            while end < tokens.count && tokens[end] != "|" { end += 1 }
            return end
        }
        var pairs: [ContrastPair] = []
        for marker in tokens.indices {
            let following = marker + 1 < tokens.count ? tokens[marker + 1] : ""
            let length: Int, chinese: Bool
            switch tokens[marker] {
            case "不" where following == "是": (length, chinese) = (2, true)
            case "非" where marker > 0 && ["而", "並", "并"].contains(tokens[marker - 1]): (length, chinese) = (1, true)
            case "not": (length, chinese) = (1, false)
            case "instead" where following == "of", "rather" where following == "than": (length, chinese) = (2, false)
            // isn't／don't／won't（FX-3 第四輪 G3：「It's Wednesday, it isn't Thursday」「…, don't use the 96k version」）。
            case let word where word.hasSuffix("n't") || word.hasSuffix("n’t"): (length, chinese) = (1, false)
            default: continue
            }
            let after = marker + length
            let yEnd = clauseEnd(after)
            let y = Array(tokens[after ..< min(yEnd, after + 15)])
            // 改口（不是，是…）、反問（不是嗎）、口吃（不是不是）、程度（不是很）、not only 之類都不是對比。
            var next = after
            while next < tokens.count && tokens[next] == "|" { next += 1 }
            if chinese && next < tokens.count && tokens[next] == "是" { continue }
            guard let first = y.first, !(chinese ? contrastStopsAfterChinese : contrastStopsAfterEnglish).contains(first) else { continue }
            // 「不是 B 而是 A」「不是 B，是 A」「not B but A」：後面那個 A 才對。
            if let turned = turnedContrast(tokens, after: after, yEnd: yEnd, chinese: chinese, clauseEnd: clauseEnd) {
                pairs.append(turned)
                continue
            }
            let adverbs: Set<String> = chinese ? ["而", "並", "并", "也"] : ["and", "but"]
            var start = clauseStart(marker), baseEnd = marker
            func strip() { while baseEnd > start && adverbs.contains(tokens[baseEnd - 1]) { baseEnd -= 1 } }
            strip()
            // 英文否定詞前面只有主詞（和助動詞）＝「A, it's not B」「A, we don't B」：跟「A, not B」一樣，A 在前一個子句；
            // 沒有前一個子句（「I don't know」）就不是對比。
            let subjectOnly = !chinese && baseEnd > start && tokens[start ..< baseEnd].allSatisfy {
                englishSubjectWords.contains($0.replacingOccurrences(of: "’", with: "'"))
            }
            if subjectOnly && start == 0 { continue }
            // 「A，不是 B」：A 在前一個子句。
            let comma = (baseEnd == start || subjectOnly) && start > 0
            if comma {
                baseEnd = start - 1
                start = clauseStart(baseEnd)
                strip()
            }
            let x = Array(tokens[start ..< baseEnd])
            // 「是不是」是在問，不是對比。
            guard !x.isEmpty, !(chinese && x.last == "是") else { continue }
            let copulas: Set<String> = chinese ? ["是"] : ["is", "are", "was", "were"]
            var base = x, copula = false
            if let index = x.lastIndex(where: copulas.contains), index < x.count - 1 {
                base = Array(x[(index + 1)...])
                copula = true
            }
            let a: [String], b: [String], narrow: Bool
            var bare = false
            if let (aLength, bLength) = sameShape(base, y) {
                (a, b, narrow) = (Array(base.suffix(aLength)), Array(y.prefix(bLength)), true)
            } else if copula || comma {
                (a, b) = copula ? (Array(base.suffix(15)), y) : (Array(base.suffix(max(2, min(y.count, 6)))), y)
                narrow = copula && a.count <= 6
            } else {
                // 沒有「是」、沒有逗號、前後也不是同一種東西的「A不是B」「A and not B」（FX-3 第四輪 G3：「我要喝拿鐵不是美式」）：
                // A 是否定詞前面緊接的幾個詞，看不準是哪幾個，所以只擋「A 不見了、B 變成肯定」這一種。
                (a, b, narrow) = (Array(base.suffix(max(2, min(y.count, 6)))), y, false)
                bare = true
            }
            guard a != b else { continue }
            let aStart = baseEnd - a.count
            var context: [String]? = nil
            if !bare && aStart - 2 >= start {
                let candidate = Array(tokens[(aStart - 2) ..< aStart])
                if candidate != ["不", "是"] && candidate.last != "not" { context = candidate }
            }
            pairs.append(ContrastPair(a: a, b: b, bCore: contrastCore(b), context: context, narrow: narrow, bare: bare))
        }
        return pairs
    }

    /// 「不是 B 而是 A」「不是 B，（而）是 A」「not B but A」：B 在否定詞後面，A 在同一個子句的「而是／but」後面、
    /// 或下一個子句開頭的「是／而是／but」後面。英文的 A 最多 4 個詞、不含人稱（「not going, but my sister is」是兩件事）。
    private static func turnedContrast(_ tokens: [String], after: Int, yEnd: Int, chinese: Bool, clauseEnd: (Int) -> Int) -> ContrastPair? {
        var b: [String] = [], aStart: Int? = nil
        var index = after + 1
        while index < yEnd {
            if chinese ? (tokens[index] == "而" && index + 1 < yEnd && tokens[index + 1] == "是") : tokens[index] == "but" {
                b = Array(tokens[after ..< index])
                aStart = index + (chinese ? 2 : 1)
                break
            }
            index += 1
        }
        if aStart == nil {
            var next = yEnd
            while next < tokens.count && tokens[next] == "|" { next += 1 }
            if next > yEnd && next < tokens.count {
                let following = next + 1 < tokens.count ? tokens[next + 1] : ""
                if chinese && tokens[next] == "是" && !(following == "不" && next + 2 < tokens.count && tokens[next + 2] == "是") {
                    aStart = next + 1
                } else if chinese && tokens[next] == "而" && following == "是" {
                    aStart = next + 2
                } else if !chinese && tokens[next] == "but" {
                    aStart = next + 1
                }
                if aStart != nil { b = Array(tokens[after ..< yEnd]) }
            }
        }
        guard let start = aStart, !b.isEmpty, start < tokens.count else { return nil }
        let a = Array(tokens[start ..< min(clauseEnd(start), start + 15)])
        b = Array(b.prefix(15))
        guard !a.isEmpty, a != b else { return nil }
        if !chinese {
            guard a.count <= 4, !a.contains(where: { englishPersons[$0] != nil || $0 == "i" }) else { return nil }
        }
        return ContrastPair(a: a, b: b, bCore: contrastCore(b), context: nil, narrow: a.count <= 6)
    }

    private static func contrastCore(_ b: [String]) -> [String]? {
        let core = Array(b.drop(while: contrastFunctionWords.contains))
        return core.isEmpty || core.count == b.count ? nil : core
    }

    /// A（`base` 的結尾）和 B（`y` 的開頭）是同一種東西的兩個選項時，回傳 A、B 各取幾個詞：
    /// 結尾一樣（三點／四點、A版／B版）、開頭一樣（星期三／星期四、台北／台南、小王／小李），
    /// 或是兩個數字、兩個同字尾（至少三個字母）的英文字（wednesday／thursday）。
    private static func sameShape(_ base: [String], _ y: [String]) -> (Int, Int)? {
        for shared in stride(from: min(4, base.count - 1), through: 1, by: -1) where y.count - shared >= 1 {
            let ending = base.suffix(shared)
            for offset in 1 ... min(3, y.count - shared) where y[offset ..< offset + shared].elementsEqual(ending) {
                return (min(offset, base.count - shared) + shared, offset + shared)
            }
        }
        for shared in stride(from: min(4, y.count - 1), through: 1, by: -1) where base.count - shared >= 1 {
            let beginning = y.prefix(shared)
            for extra in 1 ... min(3, base.count - shared) where base.suffix(shared + extra).prefix(shared).elementsEqual(beginning) {
                return (shared + extra, min(shared + extra, y.count))
            }
        }
        guard let last = base.last, let first = y.first, last != first,
              let lastInitial = last.unicodeScalars.first, let firstInitial = first.unicodeScalars.first else { return nil }
        func isDigit(_ scalar: UnicodeScalar) -> Bool { (48...57).contains(scalar.value) }
        if isDigit(lastInitial) && isDigit(firstInitial) { return (1, 1) }
        func isWord(_ token: String) -> Bool { token.count >= 4 && token.unicodeScalars.allSatisfy { (97...122).contains($0.value) } }
        if isWord(last) && isWord(first) {
            let shared = zip(last.reversed(), first.reversed()).prefix(while: { $0 == $1 }).count
            if shared >= 3 { return (1, 1) }
        }
        return nil
    }

    /// `words[index...]` 開頭的否定詞（不是、而非／並非、非、not、isn't 這類、instead of、rather than）結束在哪裡；不是否定詞回 nil。
    private static func negationEnd(_ words: [String], at index: Int) -> Int? {
        guard index < words.count else { return nil }
        let word = words[index], following = index + 1 < words.count ? words[index + 1] : ""
        if (word == "不" && following == "是") || (["而", "並", "并"].contains(word) && following == "非")
            || (word == "instead" && following == "of") || (word == "rather" && following == "than") { return index + 2 }
        if word == "非" || word == "not" || word.hasSuffix("n't") || word.hasSuffix("n’t") { return index + 1 }
        return nil
    }

    /// `words[..<end]` 結尾是否定詞。
    private static func endsWithNegation(_ words: [String], at end: Int) -> Bool {
        guard end >= 1 else { return false }
        let last = words[end - 1]
        if last == "非" || last == "not" || last.hasSuffix("n't") || last.hasSuffix("n’t") { return true }
        guard end >= 2 else { return false }
        let previous = words[end - 2]
        return (previous == "不" && last == "是") || (previous == "instead" && last == "of") || (previous == "rather" && last == "than")
    }

    /// 第 `index` 個詞被否定：前面緊接否定詞，或中間只隔一個介系詞、冠詞（not on Thursday、不是在星期四）。
    private static func isNegated(_ words: [String], at index: Int) -> Bool {
        endsWithNegation(words, at: index)
            || (index >= 1 && contrastFunctionWords.contains(words[index - 1]) && endsWithNegation(words, at: index - 1))
    }

    /// 一串詞，加上每個詞出現在哪些位置：每一組對比只從 needle 第一個詞出現的地方比，兩千字的段落不必每組都整串掃一遍。
    private struct IndexedWords {
        let list: [String]
        let positions: [String: [Int]]

        init(_ list: [String]) {
            self.list = list
            var positions: [String: [Int]] = [:]
            for (index, word) in list.enumerated() { positions[word, default: []].append(index) }
            self.positions = positions
        }

        func starts(_ needle: [String], at index: Int) -> Bool {
            index >= 0 && index + needle.count <= list.count && list[index ..< index + needle.count].elementsEqual(needle)
        }

        /// `needle` 開頭的每一個位置（可以重疊），由前往後。
        func matches(of needle: [String]) -> [Int] {
            guard let first = needle.first else { return [] }
            return (positions[first] ?? []).filter { starts(needle, at: $0) }
        }
    }

    /// `needle` 在 `words` 裡出現、但沒被否定（`isNegated`）的次數（不重疊地數）。
    private static func assertedCount(_ needle: [String], in words: IndexedWords) -> Int {
        var count = 0, next = 0
        for index in words.matches(of: needle) where index >= next {
            if !isNegated(words.list, at: index) { count += 1 }
            next = index + needle.count
        }
        return count
    }

    /// 輸出裡「不是 B」後面緊接著又一個 B、再接原文「不是 B」後面那個字的次數（「不是星期四；星期四我要出差」對原文
    /// 「不是星期四我要出差」）：本機版把重複的 B 併掉了，整理模型照原話補回來，第二個 B 不算新的肯定。
    private static func restoredRepeats(of needle: [String], in output: IndexedWords, source: IndexedWords) -> Int {
        let length = needle.count
        guard length > 0 else { return 0 }
        func follower(_ words: [String], _ index: Int) -> String { index < words.count ? words[index] : "" }
        var continuations = Set<String>()
        for index in source.matches(of: needle) where isNegated(source.list, at: index) {
            continuations.insert(follower(source.list, index + length))
        }
        guard !continuations.isEmpty else { return 0 }
        var count = 0
        for index in output.matches(of: needle) where output.starts(needle, at: index - length) && isNegated(output.list, at: index - length)
            && continuations.contains(follower(output.list, index + length)) {
            count += 1
        }
        return count
    }

    /// 輸出還留著這組對比：「A（而／並）不是 B」或「不是 B（而）是 A」「not B but A」（B 可以去掉開頭的介系詞、冠詞）。
    private static func keepsContrast(_ pair: ContrastPair, in words: [String]) -> Bool {
        let options = [pair.b] + (pair.bCore.map { [$0] } ?? [])
        func starts(_ needle: [String], _ index: Int) -> Bool {
            index >= 0 && index + needle.count <= words.count && words[index ..< index + needle.count].elementsEqual(needle)
        }
        func startsWithB(_ index: Int) -> Int? {
            for option in options where starts(option, index) { return index + option.count }
            if index < words.count, contrastFunctionWords.contains(words[index]) {
                for option in options where starts(option, index + 1) { return index + 1 + option.count }
            }
            return nil
        }
        let links: Set<String> = ["而", "並", "并", "也", "and", "but", "是"]
        for index in words.indices {
            if starts(pair.a, index) {
                var cursor = index + pair.a.count
                if negationEnd(words, at: cursor) == nil, cursor < words.count, links.contains(words[cursor]) { cursor += 1 }
                if let end = negationEnd(words, at: cursor), startsWithB(end) != nil { return true }
            }
            if let end = negationEnd(words, at: index), var cursor = startsWithB(end) {
                for _ in 0 ..< 2 where cursor < words.count && links.contains(words[cursor]) { cursor += 1 }
                if starts(pair.a, cursor) { return true }
            }
        }
        return false
    }

    /// `needle` 在 `words` 裡出現的次數（不重疊地數）。
    private static func occurrences(of needle: [String], in words: IndexedWords) -> Int {
        var count = 0, next = 0
        for index in words.matches(of: needle) where index >= next {
            count += 1
            next = index + needle.count
        }
        return count
    }

    /// 兩段內容繞著中間不動的一段對調了＝誰對誰被換掉（FX-3 ⑤：「王經理要把合約寄給李律師」→「李律師要把合約寄給王經理」、
    /// 「小明欠小華五百元」→「小華欠小明500元」、「Alice owes Bob」→「Bob owes Alice」）。
    /// M 是兩邊都恰好出現一次的詞：原文在 M 前面的某個詞跑到了 M 後面、同時原文在 M 後面的某個詞跑到了 M 前面。
    /// 搬動的詞可以是重複的詞，兩邊次數一樣時第 k 次對第 k 次（FX-7 R3：「王經理…李律師，王經理明天休假」的王經理）。
    /// 只把一段話挪個位置（「明天我去」→「我明天去」、把原因子句搬到後面）不會兩邊同時越過 M，照樣放行；
    /// 兩段還要互相坐上對方原本的位置（前一個或後一個詞跟對方原本的一樣）才算——「如果明天下雨我們就…」→「我們明天如果下雨就…」
    /// 只是把「我們」挪到前面，「如果」沒有坐上「我們」的位置。
    /// 英文 and／or 不當 M（「Me and him」→「He and I」是文法修正），「跟／和」後面接數量時也不當 M（「一杯咖啡跟一個蛋糕」是清單）。改口照樣放行：原文的幾種讀法（刪掉被改口取代的片段、
    /// 照改口改好）任何一種沒有對調就好（「小雅跟小波不是是小雅跟小潘」→「小雅跟小潘，不是小雅跟小波」）。
    /// 兩邊要先轉成同一種數字寫法（`passesRelaxed` 已經轉好）。
    public static func swapsAroundSharedMiddle(original: String, cleaned: String) -> Bool {
        let output = meaningTokens(cleaned).filter { $0 != "|" }
        return prepareSource(original, allowListFormatting: false, outputKeepsListIntroCopula: false, listItems: []).allSatisfy {
            swapsAroundSharedMiddle(source: meaningTokens($0).filter { $0 != "|" }, output: output)
        }
    }

    private typealias SwapAnchor = (token: String, index: Int, position: Int, time: Bool, unique: Bool)

    private static func swapsAroundSharedMiddle(source: [String], output: [String]) -> Bool {
        var sourceCount: [String: Int] = [:], outputPositions: [String: [Int]] = [:]
        for token in source { sourceCount[token, default: 0] += 1 }
        for (position, token) in output.enumerated() { outputPositions[token, default: []].append(position) }
        let time = timeMask(source)
        // 兩邊出現次數一樣的詞，依原文順序排，記下它在原文、輸出的位置（第 k 次對第 k 次），是不是時間的一部分。
        // 重複的詞也算（FX-7 R3：「王經理要把合約寄給李律師，王經理明天休假」的第一個王經理被換到後面）；
        // 中間不動的 M 還是只用兩邊都恰好出現一次的詞（`unique`）。
        var seen: [String: Int] = [:]
        let anchors: [SwapAnchor] = source.indices.compactMap { index in
            let token = source[index]
            let occurrence = seen[token, default: 0]
            seen[token] = occurrence + 1
            guard let positions = outputPositions[token], positions.count == sourceCount[token] else { return nil }
            return (token, index, positions[occurrence], time[index], positions.count == 1)
        }
        func neighbor(_ words: [String], _ index: Int, _ step: Int) -> String {
            words.indices.contains(index + step) ? words[index + step] : (step < 0 ? "^" : "$")
        }
        func isNumber(_ token: String) -> Bool {
            guard let first = token.unicodeScalars.first else { return false }
            return (48...57).contains(first.value) || (first == "-" && token.count > 1)
        }
        let coordinators: Set<String> = ["跟", "和", "與", "与", "及", "或"]
        guard anchors.count >= 3 else { return false }
        var laterMinimum = Array(repeating: Int.max, count: anchors.count + 1)
        for index in stride(from: anchors.count - 1, through: 0, by: -1) {
            laterMinimum[index] = min(laterMinimum[index + 1], anchors[index].position)
        }
        var earlierMaximum = Int.min
        for (index, anchor) in anchors.enumerated() {
            defer { earlierMaximum = max(earlierMaximum, anchor.position) }
            guard anchor.unique, anchor.token != "and" && anchor.token != "or",
                  !(coordinators.contains(anchor.token) && isNumber(neighbor(source, anchor.index, 1))),
                  earlierMaximum > anchor.position, laterMinimum[index + 1] < anchor.position else { continue }
            // 從 M 前面搬到後面的那段、與從後面搬到前面的那段。其中一段全是時間（下午三點、at 3 pm、on October 22）、
            // 另一段完全沒有時間＝把時間副詞挪個位置（「at 3 pm on October 22 we meet」→「We meet on October 22 at 3 pm」），不是對調。
            // 兩段都是時間（「明天見客戶，後天見老闆」→「後天見客戶，明天見老闆」）照樣算對調。
            let back = anchors[..<index].filter { $0.position > anchor.position }
            let forward = anchors[(index + 1)...].filter { $0.position < anchor.position }
            let movedBack = back.map(\.time), movedForward = forward.map(\.time)
            func onlyTime(_ marks: [Bool]) -> Bool { !marks.contains(false) }
            func noTime(_ marks: [Bool]) -> Bool { !marks.contains(true) }
            if (onlyTime(movedBack) && noTime(movedForward)) || (onlyTime(movedForward) && noTime(movedBack)) { continue }
            // 搬過去的那段，前一個或後一個詞跟另一段原本的一樣＝坐上了對方的位置；兩段都坐上了才是對調。
            func takes(_ movers: [SwapAnchor], _ owners: [SwapAnchor]) -> Bool {
                movers.contains { mover in
                    owners.contains { owner in
                        neighbor(output, mover.position, -1) == neighbor(source, owner.index, -1)
                            || neighbor(output, mover.position, 1) == neighbor(source, owner.index, 1)
                    }
                }
            }
            if takes(back, forward) && takes(forward, back) { return true }
        }
        return false
    }

    private static let timeBigrams: Set<String> = [
        "今天", "明天", "昨天", "後天", "后天", "前天", "今年", "明年", "去年", "前年", "早上", "上午", "中午", "下午", "晚上",
        "凌晨", "清晨", "傍晚", "半夜", "午夜", "今晚", "明晚", "昨晚", "月底", "月初", "年底", "年初"
    ]
    /// 接在數字後面就是時間的字：3點、10月、23號、2026年、3 pm、22nd。
    private static let timeUnitsAfterNumber: Set<String> = [
        "點", "点", "分", "秒", "半", "刻", "月", "日", "號", "号", "年", "時", "时", "am", "pm", "o'clock", "st", "nd", "rd", "th"
    ]
    private static let englishTimeWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "yesterday", "tonight",
        "noon", "midnight", "morning", "afternoon", "evening", "night", "week", "weekend", "month", "year"
    ]
    /// 後面接著時間才算時間的英文字（「at 3 pm」「on the 22nd」「next week」）。
    private static let englishTimeLeads: Set<String> = [
        "at", "on", "in", "by", "before", "after", "until", "till", "around", "from", "since", "the", "this", "next", "last", "every"
    ]

    /// 每個詞是不是時間的一部分（`meaningTokens` 的詞）：今天、下午、星期三、3點、10月23號、3:30、at 3 pm、on October 22、next week。
    /// 單看一個字不算（「小明」的明、「樓上」的上不是時間）。
    private static func timeMask(_ tokens: [String]) -> [Bool] {
        var mask = Array(repeating: false, count: tokens.count)
        func isNumber(_ index: Int) -> Bool {
            guard index >= 0, index < tokens.count, let first = tokens[index].unicodeScalars.first else { return false }
            return (48...57).contains(first.value) || (first == "-" && tokens[index].count > 1)
        }
        for index in tokens.indices {
            let token = tokens[index]
            if index + 1 < tokens.count, timeBigrams.contains(token + tokens[index + 1]) { mask[index] = true; mask[index + 1] = true }
            if token == "星", index + 1 < tokens.count, tokens[index + 1] == "期" {
                mask[index] = true; mask[index + 1] = true
                if index + 2 < tokens.count, isNumber(index + 2) || ["日", "天", "末"].contains(tokens[index + 2]) { mask[index + 2] = true }
            }
            if englishTimeWords.contains(token) || englishMonths.contains(token) { mask[index] = true }
            if isNumber(index) {
                if token.contains(":") { mask[index] = true }
                if index + 1 < tokens.count, timeUnitsAfterNumber.contains(tokens[index + 1]) { mask[index] = true; mask[index + 1] = true }
                if index > 0, englishMonths.contains(tokens[index - 1]) || ["at", "by", "around", "until", "till", "before", "after", "since"].contains(tokens[index - 1]) {
                    mask[index] = true
                }
            }
            if token == "半", index > 0, mask[index - 1] { mask[index] = true }
        }
        for index in tokens.indices.reversed() where englishTimeLeads.contains(tokens[index]) {
            if index + 1 < tokens.count, mask[index + 1] { mask[index] = true }
        }
        return mask
    }

    private static let meaningFolds = [("禮拜", "星期"), ("礼拜", "星期"), ("週", "星期"), ("周", "星期"), ("星期天", "星期日"), ("臺", "台")]
    private static let chineseNumerals: Set<Character> = Set("零〇一二兩两三四五六七八九十百千萬万億亿")
    private static let clauseSeparators: Set<Character> = Set("，。！？,!?、；;：:.")

    /// 比對意思用的詞（對比、調換）：中文一字一詞、英文一個單字一詞（小寫，含 isn't 的撇號）、數字一串一詞
    /// （中文數字換成阿拉伯數字、千分位拿掉，小數點與時間的冒號留著），子句之間的標點換成「|」，空白與其他符號略過。
    /// 同一個東西的不同寫法先換成一種：禮拜／週／周→星期、星期天→星期日、臺→台——整理時常換說法，換了說法不能拿來躲過檢查。
    static func meaningTokens(_ text: String) -> [String] {
        meaningTokenLists(text)
    }

    private static func tokenizeMeaning(_ text: String) -> [String] {
        var folded = normalizeFullwidthDigits(in: text)
        for (from, to) in meaningFolds { folded = folded.replacingOccurrences(of: from, with: to) }
        let characters = Array(folded)
        func isDigit(_ index: Int) -> Bool { index < characters.count && characters[index].isASCII && characters[index].isNumber }
        func isLatin(_ index: Int) -> Bool { index < characters.count && characters[index].isASCII && characters[index].isLetter }
        func isNumeral(_ index: Int) -> Bool { isDigit(index) || (index < characters.count && chineseNumerals.contains(characters[index])) }
        func afterSpaces(_ index: Int) -> Int {
            var next = index
            while next < characters.count && (characters[next] == " " || characters[next] == "\t") { next += 1 }
            return next
        }
        // 「LUFS-14」：減號前面的英文字是響度、電平單位，減號就是負號（同 `minusSign`）。
        func afterLevelUnit(_ index: Int) -> Bool {
            var start = index
            while start > 0 && isLatin(start - 1) { start -= 1 }
            return levelUnits.contains(String(characters[start ..< index]).lowercased())
        }
        var tokens: [String] = []
        var index = 0
        // 負號跟著數字走（「-5」「負五」「零下五」≠「5」），規則同 `numberValueRun`：數字中間的連字號不是負號。
        var negative = false
        func appendNumber(_ value: String) {
            tokens.append(negative && value != "0" ? "-" + value : value)
            negative = false
        }
        while index < characters.count {
            let character = characters[index]
            // 負號跟數字中間隔空白也算（FX-7 M4，同 `minusSign`）：「−」「－」都算，ASCII「-」前面要緊接非空白的字。
            let spacedSign = "−－".contains(character)
                || (character == "-" && index > 0 && !characters[index - 1].isWhitespace)
            if "-−－".contains(character), isDigit(index + 1) || (spacedSign && afterSpaces(index + 1) > index + 1 && isDigit(afterSpaces(index + 1))),
               !(index > 0 && (isDigit(index - 1) || (isLatin(index - 1) && !afterLevelUnit(index)))),
               !(index > 1 && (characters[index - 1] == " " || characters[index - 1] == "\t") && isDigit(index - 2)) {
                negative = true
                index += 1
                continue
            }
            // 「負的三」也是負號（FX-3 第四輪 G4）。
            let signLength = character == "零" ? 2 : (index + 1 < characters.count && characters[index + 1] == "的" ? 2 : 1)
            if character == "負" || character == "负" || (character == "零" && index + 1 < characters.count && characters[index + 1] == "下"),
               isNumeral(afterSpaces(index + signLength)) {
                negative = true
                index = afterSpaces(index + signLength)
                continue
            }
            if isDigit(index) {
                var run = ""
                while index < characters.count {
                    if isDigit(index) {
                        run.append(characters[index]); index += 1
                    } else if (characters[index] == "." || characters[index] == ":") && isDigit(index + 1) {
                        run.append(characters[index]); index += 1
                    } else if characters[index] == ",", isDigit(index + 1), isDigit(index + 2), isDigit(index + 3), !isDigit(index + 4) {
                        index += 1
                    } else {
                        break
                    }
                }
                appendNumber(run)
            } else if chineseNumerals.contains(character) {
                var run = ""
                while index < characters.count && chineseNumerals.contains(characters[index]) { run.append(characters[index]); index += 1 }
                if let value = Normalizer.chineseToInt(run) {
                    appendNumber(String(value))
                } else {
                    negative = false
                    tokens += run.map { String($0) }
                }
            } else if isLatin(index) {
                var run = ""
                while index < characters.count {
                    if isLatin(index) {
                        run.append(characters[index]); index += 1
                    } else if (characters[index] == "'" || characters[index] == "’") && isLatin(index + 1) && !run.isEmpty {
                        run.append(characters[index]); index += 1
                    } else {
                        break
                    }
                }
                tokens.append(run.lowercased())
            } else {
                if character.isNewline || clauseSeparators.contains(character) {
                    if let last = tokens.last, last != "|" { tokens.append("|") }
                } else if character.isLetter {
                    tokens.append(String(character))
                }
                index += 1
            }
        }
        return tokens
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count >= 2 else { return [] }
        return Set((0 ..< characters.count - 1).map { String(characters[$0 ..< $0 + 2]) })
    }

    /// 原文雙字詞有幾成留在輸出裡（原文太短沒有雙字詞＝1）。
    public static func bigramRecall(_ output: String, source: String) -> Double {
        let sourceTerms = bigrams(source)
        guard !sourceTerms.isEmpty else { return 1 }
        return Double(sourceTerms.intersection(bigrams(output)).count) / Double(sourceTerms.count)
    }

    /// 輸出出現原文沒有的數字＝在回答（「一加一等於多少」→「一加一等於二」、「台北101有多高」→「508公尺」）。
    /// 比的是 0–9 各個數字（阿拉伯與中文數字都算），行首的清單編號「1. 」不算。2026-10-18 關掉 Claude 思考後加的。
    public static func introducesDigits(original: String, cleaned: String) -> Bool {
        func digits(_ text: String) -> Set<Character> {
            let body = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
                var rest = line.drop(while: { $0 == " " })
                let number = rest.prefix(while: { $0.isASCII && $0.isNumber })
                if !number.isEmpty, rest.dropFirst(number.count).first == "." { rest = rest.dropFirst(number.count + 1) }
                return rest
            }.joined(separator: "\n")
            var set = Set(body.compactMap { c in (c.isASCII && c.isNumber) ? c : chineseDigits[c] })
            // 位數字換成阿拉伯數字會多出 0／1（「十月十三號」→「10 月 13 號」、「一萬兩千」→「12,000」）：
            // 2026-10-19 Mac 真人錄音 6 句數字句被誤擋。十＝1＋0，百千萬億＝0。
            if body.contains(where: { "十拾".contains($0) }) { set.formUnion(["1", "0"]) }
            if body.contains(where: { "百佰千仟萬万億亿".contains($0) }) { set.insert("0") }
            return set
        }
        return !digits(cleaned).isSubset(of: digits(original))
    }

    /// 輸出的雙字詞有幾成是原文沒有的（輸出太短沒有雙字詞＝0）。
    public static func novelBigramShare(_ output: String, source: String) -> Double {
        let outputTerms = bigrams(output)
        guard !outputTerms.isEmpty else { return 0 }
        return Double(outputTerms.subtracting(bigrams(source)).count) / Double(outputTerms.count)
    }

    /// True when cleanup keeps every substantive letter and digit in the original order.
    /// Contextually optional filler words may either remain or be removed.
    public static func preservesContent(original: String, cleaned: String) -> Bool {
        rejectionReason(original: original, cleaned: cleaned) == nil
    }

    /// A short diagnostic for rejected cleanup output, including the source text that was lost.
    public static func rejectionReason(original: String, cleaned: String) -> String? {
        // FX-3 ④：對比句被翻成相反的意思，來源怎麼讀都不放行（「星期三不是星期四」→「星期四」）。
        if invertsContrast(original: original, cleaned: cleaned) { return "對比句被改成相反的意思" }
        let listItems = numberedListItems(in: cleaned)
        let allowListFormatting = listItems.count >= 2 && hasListContext(original, numberedItemCount: listItems.count)
        let cleanedRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        let outputKeepsListIntroCopula = listIntroCopula.firstMatch(in: cleaned, range: cleanedRange) != nil
        let sources = prepareSource(
            original,
            allowListFormatting: allowListFormatting,
            outputKeepsListIntroCopula: outputKeepsListIntroCopula,
            listItems: listItems
        )
        let output = replace(listPrefix, in: Normalizer.normalizeNumbers(normalizeFullwidthDigits(in: cleaned)), with: "")
        let outputTokens = tokens(in: output, optionalRanges: optionalFillerRanges(in: output))
        var readings = ReadingMemo()
        // 來源有幾種合理讀法：刪掉被改口取代的片段（舊做法）、原樣保留、或照改口改好；輸出對得上任何一種就放行。
        var sourceTokens: [Token] = []
        for (index, candidate) in sources.enumerated() {
            let candidateTokens = tokens(in: candidate, optionalRanges: optionalFillerRanges(in: candidate))
            if index == 0 { sourceTokens = candidateTokens }
            let budget = homophoneBudget(candidate)
            if matches(source: candidateTokens, output: outputTokens, budget: budget, readings: &readings) { return nil }
        }

        let missing = missingSourceTokens(source: sourceTokens, output: outputTokens)
            .map(displayValue)
            .joined()
        if !missing.isEmpty {
            return "來源實詞未保留：「\(String(missing.prefix(32)))」"
        }
        return "輸出新增或調動了實詞"
    }

    /// 來源的幾種讀法，第一個是主讀法（拒絕原因以它為準）：
    /// 1. 刪掉被改口取代的片段（舊做法，原本放行的照樣放行）；
    /// 2. 原樣保留（「我們約禮拜三，不是禮拜四開會。」忠實照抄不該被擋）；
    /// 3. 改口詞前後補逗號後，用 Normalizer 的改口對齊改好（沒標點的改口）。對不齊就沒有這一種。
    private static func prepareSource(
        _ original: String,
        allowListFormatting: Bool,
        outputKeepsListIntroCopula: Bool,
        listItems: [String]
    ) -> [String] {
        var source = replace(listPrefix, in: numberForms(normalizeFullwidthDigits(in: original)), with: "")
        if allowListFormatting {
            source = replace(spokenListMarker, in: source, with: "")
            source = replace(firstlyListMarker, in: source, with: "")
            if !outputKeepsListIntroCopula {
                source = replace(listIntroCopula, in: source, with: "$1")
            }
            source = removingListConnectors(in: source, listItems: listItems)
        }
        // Corrections and repeated words are represented as optional source tokens below. Keeping
        // the words here lets the gate accept either a cleaned result or an unchanged transcript.
        var superseded = replace(numericCorrectionWithTail, in: source, with: "$3$2")
        superseded = replace(supersededCorrection, in: superseded, with: "")
        superseded = replace(unpunctuatedWeekdayCorrection, in: superseded, with: "")
        var candidates = [numberForms(normalizeFullwidthDigits(in: superseded))]
        func add(_ candidate: String) {
            let value = numberForms(normalizeFullwidthDigits(in: candidate))
            if !candidates.contains(value) { candidates.append(value) }
        }
        if superseded != source { add(source) }
        let separated = separatingCorrectionMarkers(in: source)
        let corrected = correctedForms(separated)
        if corrected != separated { add(corrected) }
        return candidates
    }

    /// 同一次把關裡 passesRelaxed、introducesNumberValues、reordersNumberValues、invertsContrast、swapsAroundSharedMiddle
    /// 會對同一段原文重複轉數字寫法、套改口、找數值、斷詞，兩千字的段落一次要好幾毫秒。這些都是純函式：
    /// 記住最近 8 次的結果，省掉重算（FX-3 第三輪：長段落把關約快一半；第四輪起短句也記——一次把關會把同一句
    /// 轉好幾次數字寫法，實錄的 20 句一次把關從 b8817d8 的 2 倍降回 1.1 倍）。
    private final class RecentResults<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: String, value: Value)] = []
        private let transform: (String) -> Value

        init(_ transform: @escaping (String) -> Value) { self.transform = transform }

        func callAsFunction(_ key: String) -> Value {
            lock.lock()
            let hit = entries.last(where: { $0.key == key })?.value
            lock.unlock()
            if let hit { return hit }
            let value = transform(key)
            lock.lock()
            entries.append((key, value))
            if entries.count > 8 { entries.removeFirst(entries.count - 8) }
            lock.unlock()
            return value
        }
    }

    private static let numberForms = RecentResults<String> { Normalizer.normalizeNumbers($0) }
    private static let correctedForms = RecentResults<String> { Normalizer.correctionMarkers($0) }
    private static let numberValueScans = RecentResults<(body: NSString, values: [NumberValue])> { scanNumberValues(in: $0) }
    /// 掉值那條規則用的掃描（清單編號的判斷不同，見 `dropsLineOrdinal`）。
    private static let dropsNumberValueScans = RecentResults<(body: NSString, values: [NumberValue])> { scanNumberValues(in: $0, dropsOnly: true) }
    private static let meaningTokenLists = RecentResults<[String]> { tokenizeMeaning($0) }

    /// 「不對」類改口詞（含前面的「啊／呃」）一律變成「，不對，」；「不是」只在後面接「是」時變成「，不是，」；
    /// 「我是說」前面補逗號。沒有這些詞就原樣回傳。
    static func separatingCorrectionMarkers(in value: String) -> String {
        var out = replace(unpunctuatedNotRightMarker, in: value, with: "，不對，")
        out = replace(unpunctuatedNotIsMarker, in: out, with: "，不是，")
        out = replace(unpunctuatedIMeanMarker, in: out, with: "，我是說")
        return out
    }

    private static func numberedListItems(in value: String) -> [String] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return numberedListItem.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let itemRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[itemRange])
        }
    }

    private static func hasListContext(_ value: String, numberedItemCount: Int) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        if listCue.firstMatch(in: value, range: range) != nil { return true }
        if spokenListMarker.numberOfMatches(in: value, range: range) >= 2 { return true }
        let separatorCount = value.filter { "，,、".contains($0) }.count
        if separatorCount >= 2 { return true }
        return numberedItemCount >= 3 && separatorCount >= 1 &&
            listConnector.numberOfMatches(in: value, range: range) > 0
    }

    /// Drop a conjunction only when it separates adjacent items that are independently present
    /// on numbered output lines. This keeps conjunctions inside an item substantive.
    private static func removingListConnectors(in source: String, listItems: [String]) -> String {
        guard listItems.count >= 2 else { return source }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let separators = listSeparator.matches(in: source, range: fullRange).map(\.range)
        let cues = listCue.matches(in: source, range: fullRange).map(\.range)
        let outputTokens = listItems.map { tokens(in: $0).map(\.value) }
        let connectorMatches = listConnector.matches(in: source, range: fullRange)
        let removableRanges = connectorMatches.compactMap { match -> NSRange? in
            let connectorRange = match.range
            if !cues.isEmpty {
                guard let cue = cues.last(where: { NSMaxRange($0) <= connectorRange.location }),
                      separators.contains(where: {
                          $0.location >= NSMaxRange(cue) && $0.location < connectorRange.location
                      }) else { return nil }
            }
            let previousSeparators = separators.filter { $0.location < connectorRange.location }
            guard let previousSeparator = previousSeparators.last else { return nil }
            let nextSeparator = separators.first { $0.location >= NSMaxRange(connectorRange) }

            var leftStart = NSMaxRange(previousSeparator)
            var leftEnd = connectorRange.location
            var left = substring(source, location: leftStart, length: leftEnd - leftStart)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if left.isEmpty, previousSeparators.count >= 2 {
                let earlierSeparator = previousSeparators[previousSeparators.count - 2]
                leftStart = NSMaxRange(earlierSeparator)
                leftEnd = previousSeparator.location
                left = substring(source, location: leftStart, length: leftEnd - leftStart)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rightEnd = nextSeparator?.location ?? fullRange.length
            let right = substring(source, location: NSMaxRange(connectorRange), length: rightEnd - NSMaxRange(connectorRange))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let leftTokens = tokens(in: left).map(\.value)
            let rightTokens = tokens(in: right).map(\.value)
            guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return nil }

            let separatesNumberedItems = outputTokens.indices.dropLast().contains { index in
                isSuffix(leftTokens, of: outputTokens[index]) && isPrefix(rightTokens, of: outputTokens[index + 1])
            }
            return separatesNumberedItems ? connectorRange : nil
        }
        guard !removableRanges.isEmpty else { return source }
        var result = source
        for range in removableRanges.sorted(by: { $0.location > $1.location }) {
            guard let stringRange = Range(range, in: result) else { continue }
            result.removeSubrange(stringRange)
        }
        return result
    }

    private static func substring(_ value: String, location: Int, length: Int) -> String {
        guard length > 0,
              let start = Range(NSRange(location: location, length: length), in: value) else { return "" }
        return String(value[start])
    }

    private static func isPrefix(_ part: [String], of whole: [String]) -> Bool {
        part.count <= whole.count && Array(whole.prefix(part.count)) == part
    }

    private static func isSuffix(_ part: [String], of whole: [String]) -> Bool {
        part.count <= whole.count && Array(whole.suffix(part.count)) == part
    }

    private static func optionalFillerRanges(in value: String) -> [NSRange] {
        let patterns: [(NSRegularExpression, Int)] = [
            (leadingFillers, 1),
            (pausedFillers, 1),
            (hesitatedDemonstrative, 1),
            (hesitatedDemonstrativeChain, 1),
            (sentenceInitialThen, 1),
            (repeatedPronoun, 3),
            (repeatedHanWord, 2)
        ]
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return patterns.flatMap { regex, group in
            regex.matches(in: value, range: fullRange).compactMap { match in
                guard group < match.numberOfRanges else { return nil }
                let range = match.range(at: group)
                return range.location != NSNotFound && range.length > 0 ? range : nil
            }
        }
    }

    private static func tokens(in value: String, optionalRanges: [NSRange] = []) -> [Token] {
        var result: [Token] = []
        var index = value.startIndex
        var utf16Offset = 0
        let utf16Length = value.utf16.count
        let nsValue = value as NSString
        let optionalPrefix = optionalPrefixCounts(length: utf16Length, ranges: optionalRanges)
        // 負號是數值的一部分（FX-3 ①：「-14」≠「14」）；規則同 `numberValueRun`。
        let signs = Set(numberSign.matches(in: value, range: NSRange(location: 0, length: utf16Length)).map(\.range.location))
        while index < value.endIndex {
            let character = value[index]
            if signs.contains(utf16Offset) {
                // 負號後面可以隔空白（FX-7 M4：「− 14」）。
                var digitStart = utf16Offset + 1
                while digitStart < utf16Length, [0x20, 0x09].contains(nsValue.character(at: digitStart)) { digitStart += 1 }
                if let match = number.firstMatch(in: value, range: NSRange(location: digitStart, length: utf16Length - digitStart)),
                   match.range.location == digitStart {
                    let numberText = nsValue.substring(with: match.range)
                    result.append(Token(value: "n:-\(numberText.replacingOccurrences(of: ",", with: ""))", optional: false))
                    index = value.index(index, offsetBy: digitStart - utf16Offset + numberText.count)
                    utf16Offset = NSMaxRange(match.range)
                    continue
                }
            }
            if let filler = fillerTokensByInitial[character]?.first(where: { value[index...].hasPrefix($0) }) {
                let end = value.index(index, offsetBy: filler.count)
                let tokenRange = NSRange(location: utf16Offset, length: filler.utf16.count)
                let optional = isOptional(tokenRange, prefix: optionalPrefix)
                result.append(Token(value: "f:\(filler)", optional: optional))
                index = end
                utf16Offset += tokenRange.length
                continue
            }

            let range = NSRange(location: utf16Offset, length: utf16Length - utf16Offset)
            if character.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
               let match = number.firstMatch(in: value, range: range),
               match.range.location == utf16Offset {
                let numberText = nsValue.substring(with: match.range)
                result.append(Token(value: "n:\(numberText.replacingOccurrences(of: ",", with: ""))", optional: false))
                index = value.index(index, offsetBy: numberText.count)
                utf16Offset += match.range.length
            } else {
                let characterLength = character.utf16.count
                if character.isLetter {
                    let characterRange = NSRange(location: utf16Offset, length: characterLength)
                    let optional = isOptional(characterRange, prefix: optionalPrefix)
                    result.append(Token(value: "l:\(String(character).lowercased())", optional: optional))
                }
                index = value.index(after: index)
                utf16Offset += characterLength
            }
        }
        return result
    }

    private static func optionalPrefixCounts(length: Int, ranges: [NSRange]) -> [Int] {
        var changes = Array(repeating: 0, count: length + 1)
        for range in ranges {
            let start = range.location
            let end = NSMaxRange(range)
            guard start >= 0, end <= length, start < end else { continue }
            changes[start] += 1
            changes[end] -= 1
        }
        var prefix = Array(repeating: 0, count: length + 1)
        var active = 0
        for offset in 0..<length {
            active += changes[offset]
            prefix[offset + 1] = prefix[offset] + (active > 0 ? 1 : 0)
        }
        return prefix
    }

    private static func isOptional(_ range: NSRange, prefix: [Int]) -> Bool {
        let start = range.location
        let end = NSMaxRange(range)
        return start >= 0 && end < prefix.count && end - start == prefix[end] - prefix[start]
    }

    private static func homophoneBudget(_ source: String) -> Int {
        let cjkCount = source.reduce(into: 0) { count, character in
            if MandarinReading.isCJK(character) { count += 1 }
        }
        // 25% 的整數除法會讓 2–3 字短句直接歸零（2*25/100 = 0），「除值→儲值」這種
        // 一個字的修正就整個被擋掉。兩個字以上至少留一個名額；單字仍維持 0。
        guard cjkCount >= 2 else { return 0 }
        return max(1, cjkCount * homophoneSubstitutionPercent / 100)
    }

    /// 對齊成本：完全相同 0、同音替換 1、optional 略過 0、其他＝不可行。
    ///
    /// 取「同音替換總數最少、且不超過預算」的對齊（動態規劃），而不是靠貪婪順序：
    /// 之前同音比對搶在 optional 前面，「研討研討陶器」→「研討陶器」會讓被刪的那個
    /// 「討」先跟後面的「陶」同音配上，之後整條對齊就錯位。反過來一律先 optional，
    /// 又會讓「悠悠卡→悠遊卡」被擋——所以兩種都不能靠順序取捨，只能回頭找最省的解。
    ///
    /// 權利→權力、期中→期終這類兩字詞同音**刻意不擋**：那正是語音辨識最常見的錯字，
    /// 要交給模型判斷；擋掉會連真正的修正一起擋。攔截靠的是預算上限，不是字級清單。
    private static func matches(
        source: [Token],
        output: [Token],
        budget: Int,
        readings: inout ReadingMemo
    ) -> Bool {
        let width = output.count + 1
        // best[j] = 對齊 source[0..<i) 與 output[0..<j) 所需的最少同音替換；-1 = 走不到。
        // 成本只增不減，超過預算的格子直接當不可行，省掉後面所有不可能的分支。
        var best = Array(repeating: -1, count: width)
        best[0] = 0
        for sourceToken in source {
            // 本列最後一個移動：略過 optional 的輸出 token（不動用來源）。
            for outputIndex in 0..<output.count where output[outputIndex].optional {
                let carried = best[outputIndex]
                merge(cost: carried, into: &best[outputIndex + 1], limit: budget)
            }
            var next = Array(repeating: -1, count: width)
            for outputIndex in 0..<width {
                let current = best[outputIndex]
                guard current >= 0 else { continue }
                if sourceToken.optional {
                    merge(cost: current, into: &next[outputIndex], limit: budget)
                }
                guard outputIndex < output.count else { continue }
                let cost = alignmentCost(sourceToken.value, output[outputIndex].value, readings: &readings)
                if cost >= 0 {
                    merge(cost: current + cost, into: &next[outputIndex + 1], limit: budget)
                }
            }
            guard next.contains(where: { $0 >= 0 }) else { return false }
            best = next
        }
        for outputIndex in 0..<output.count where output[outputIndex].optional {
            let carried = best[outputIndex]
            merge(cost: carried, into: &best[outputIndex + 1], limit: budget)
        }
        return best[output.count] >= 0
    }

    private static func merge(cost: Int, into cell: inout Int, limit: Int) {
        guard cost >= 0, cost <= limit, cell < 0 || cost < cell else { return }
        cell = cost
    }

    /// 同位置的同音單字替換＝語音辨識錯字修正（除值→儲值、元山→圓山），視為保留。
    /// 讀音取不到就回 -1（不可行），不猜。
    private static func alignmentCost(
        _ sourceValue: String,
        _ outputValue: String,
        readings: inout ReadingMemo
    ) -> Int {
        if sourceValue == outputValue { return 0 }
        guard let sourceCharacter = singleCJKCharacter(sourceValue),
              let outputCharacter = singleCJKCharacter(outputValue) else { return -1 }
        let sourceReading = readings.reading(of: sourceCharacter)
        let outputReading = readings.reading(of: outputCharacter)
        return MandarinReading.isHomophoneSubstitution(sourceCharacter, outputCharacter, sourceReading, outputReading)
            ? 1
            : -1
    }

    private static func singleCJKCharacter(_ token: String) -> Character? {
        guard token.count == 3, token.hasPrefix("l:") else { return nil }
        let character = token[token.index(token.startIndex, offsetBy: 2)]
        return MandarinReading.isCJK(character) ? character : nil
    }

    private static func missingSourceTokens(source: [Token], output: [Token]) -> [String] {
        var missing: [String] = []
        let outputPositions = tokenPositions(output)
        let sourcePositions = tokenPositions(source)
        var sourceIndex = 0
        var outputIndex = 0
        while sourceIndex < source.count, outputIndex < output.count {
            if source[sourceIndex].value == output[outputIndex].value {
                sourceIndex += 1
                outputIndex += 1
            } else if output[outputIndex].optional {
                outputIndex += 1
            } else if source[sourceIndex].optional {
                sourceIndex += 1
            } else if outputIndex + 1 < output.count,
                      nextOccurrence(of: source[sourceIndex].value, in: outputPositions, startingAt: outputIndex + 1) != nil {
                outputIndex += 1
            } else if sourceIndex + 1 < source.count,
                      let nextSource = nextOccurrence(of: output[outputIndex].value, in: sourcePositions, startingAt: sourceIndex + 1) {
                missing.append(contentsOf: source[sourceIndex..<nextSource].filter { !$0.optional }.map(\.value))
                sourceIndex = nextSource
            } else {
                missing.append(source[sourceIndex].value)
                sourceIndex += 1
                outputIndex += 1
            }
        }
        if sourceIndex < source.count {
            missing.append(contentsOf: source[sourceIndex...].filter { !$0.optional }.map(\.value))
        }
        return missing
    }

    private static func tokenPositions(_ tokens: [Token]) -> [String: [Int]] {
        var positions: [String: [Int]] = [:]
        for (index, token) in tokens.enumerated() {
            positions[token.value, default: []].append(index)
        }
        return positions
    }

    private static func nextOccurrence(of value: String, in positions: [String: [Int]], startingAt start: Int) -> Int? {
        guard let indices = positions[value] else { return nil }
        var low = 0
        var high = indices.count
        while low < high {
            let middle = low + (high - low) / 2
            if indices[middle] < start { low = middle + 1 } else { high = middle }
        }
        return low < indices.count ? indices[low] : nil
    }

    private static func normalizeFullwidthDigits(in value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            if (0xFF10...0xFF19).contains(scalar.value) {
                return UnicodeScalar(scalar.value - 0xFEE0)!
            }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func displayValue(_ token: String) -> String {
        guard token.count > 2 else { return token }
        return String(token.dropFirst(2))
    }

    private static func replace(_ regex: NSRegularExpression, in value: String, with replacement: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}
