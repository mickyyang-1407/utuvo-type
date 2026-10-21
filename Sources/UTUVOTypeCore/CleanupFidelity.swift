import Foundation

/// Conservative content check for smart cleanup. Formatting and number presentation may change,
/// while substantive text must stay in the same order.
public enum CleanupFidelity {
    /// 同音替換上限：一次 cleanup 最多能換掉來源這麼多比例的實詞。
    /// 語音辨識錯字修正（除值→儲值）通常只換一兩個字；整句被換成另一句同音的話不是修正。
    public static let homophoneSubstitutionPercent = 25

    // These ranges mark contextually recognized fillers as optional on both sides of the comparison.
    private static let leadingFillers = try! NSRegularExpression(
        pattern: #"(?m)(?:^|(?<=[，,、。！？!?;；\n]))((?:(?:嗯嗯|嗯|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是|然後|然后)[，,、\s]*)+)(?=[\p{L}\p{N}])"#
    )
    private static let pausedFillers = try! NSRegularExpression(
        pattern: #"[，,、;；](嗯嗯|嗯|呃|欸|喔|啊|對對|对对|對啊|对啊|那個|那个|這個|这个|就是說|就是说|就是)[，,、;；]"#
    )
    private static let hesitatedDemonstrative = try! NSRegularExpression(
        pattern: #"(?:我覺得|我觉得|我想|我認為|我认为)(那個|那个)(?=[，,、;；](?:就是說|就是说|就是|我|你|我們|我们|大家|今天|明天|後天|昨天))"#
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
    private static let numericCorrectionWithTail = try! NSRegularExpression(
        pattern: #"((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?)([\u3400-\u9FFF]{2,6})[，,;；]\s*(?:啊[，,、\s]*)?(?:不對|不是|更正|講錯了|說錯了|no|I mean|sorry)[，,;；]\s*(?:是|為)?\s*((?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)"#,
        options: [.caseInsensitive]
    )
    private static let supersededCorrection = try! NSRegularExpression(
        pattern: #"(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|[\u3400-\u9FFF]{2}(?:(?:跟|和|與|与)[\u3400-\u9FFF]{2,4})*|(?:[A-Za-z]+\s+)?[A-Za-z]+[0-9]*|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+)(?::[0-9]{1,2})?(?:點|点|時|时|日|月|號|号|樓|楼|元)?)[，,;；]\s*(?:啊[，,、\s]*)?(?:不對|不是|更正|講錯了|說錯了|no|I mean|sorry)[，,;；]\s*(?:是|為)?\s*"#,
        options: [.caseInsensitive]
    )
    private static let unpunctuatedWeekdayCorrection = try! NSRegularExpression(
        pattern: #"(?:(?:禮拜|星期|週|周)[一二三四五六日天]|(?:今|明|後|昨)天|(?:[0-9]+|[零〇一二三四五六七八九十百千兩两]+))\s*不是\s*"#
    )
    private static let listPrefix = try! NSRegularExpression(
        pattern: #"(?m)^\s*(?:\d+[.、)]|[一二三四五六七八九十百]+[.、)]|[•*\-])\s*"#
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
        let original = Normalizer.normalizeNumbers(original), cleaned = Normalizer.normalizeNumbers(cleaned)
        return bigramRecall(cleaned, source: original) >= 0.35
            && novelBigramShare(cleaned, source: original) <= 0.6
            && !introducesDigits(original: original, cleaned: cleaned)
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
        let chinese: [Character: Character] = ["零": "0", "〇": "0", "一": "1", "二": "2", "兩": "2", "两": "2", "三": "3",
                                               "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
        func digits(_ text: String) -> Set<Character> {
            let body = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
                var rest = line.drop(while: { $0 == " " })
                let number = rest.prefix(while: { $0.isASCII && $0.isNumber })
                if !number.isEmpty, rest.dropFirst(number.count).first == "." { rest = rest.dropFirst(number.count + 1) }
                return rest
            }.joined(separator: "\n")
            var set = Set(body.compactMap { c in (c.isASCII && c.isNumber) ? c : chinese[c] })
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
        let listItems = numberedListItems(in: cleaned)
        let allowListFormatting = listItems.count >= 2 && hasListContext(original, numberedItemCount: listItems.count)
        let cleanedRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        let outputKeepsListIntroCopula = listIntroCopula.firstMatch(in: cleaned, range: cleanedRange) != nil
        let source = prepareSource(
            original,
            allowListFormatting: allowListFormatting,
            outputKeepsListIntroCopula: outputKeepsListIntroCopula,
            listItems: listItems
        )
        let output = replace(listPrefix, in: Normalizer.normalizeNumbers(normalizeFullwidthDigits(in: cleaned)), with: "")
        let sourceTokens = tokens(in: source, optionalRanges: optionalFillerRanges(in: source))
        let outputTokens = tokens(in: output, optionalRanges: optionalFillerRanges(in: output))
        var readings = ReadingMemo()
        let budget = homophoneBudget(source)
        guard !matches(source: sourceTokens, output: outputTokens, budget: budget, readings: &readings) else { return nil }

        let missing = missingSourceTokens(source: sourceTokens, output: outputTokens)
            .map(displayValue)
            .joined()
        if !missing.isEmpty {
            return "來源實詞未保留：「\(String(missing.prefix(32)))」"
        }
        return "輸出新增或調動了實詞"
    }

    private static func prepareSource(
        _ original: String,
        allowListFormatting: Bool,
        outputKeepsListIntroCopula: Bool,
        listItems: [String]
    ) -> String {
        var source = replace(listPrefix, in: Normalizer.normalizeNumbers(normalizeFullwidthDigits(in: original)), with: "")
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
        source = replace(numericCorrectionWithTail, in: source, with: "$3$2")
        source = replace(supersededCorrection, in: source, with: "")
        source = replace(unpunctuatedWeekdayCorrection, in: source, with: "")
        return Normalizer.normalizeNumbers(normalizeFullwidthDigits(in: source))
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
        while index < value.endIndex {
            let character = value[index]
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
