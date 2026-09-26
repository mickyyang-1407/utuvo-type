import Foundation

/// UTUVO Type — deterministic normalization pipeline.
///
/// 這個模組是純函式，沒有 IO、沒有 SDK、沒有 async。任何在
/// deterministic 路徑上看到的東西都應該能從 `text` 重現出來。
/// LLM 絕對不會被這條路徑呼叫——它是雲端 formatter 失敗／逾時時
/// 的 fallback，必須能在錄音結束後立刻輸出可貼上的版本。

public struct NormalizedText: Sendable, Equatable {
    public let original: String
    public let cleaned: String
    /// 每一步驟的名字，依執行順序列出。測試用來證明 pipeline 真有跑。
    public let appliedSteps: [String]

    public init(original: String, cleaned: String, appliedSteps: [String]) {
        self.original = original
        self.cleaned = cleaned
        self.appliedSteps = appliedSteps
    }
}

public struct NormalizerOptions: Sendable {
    public var dictionary: [String: String]
    public var fillerSet: Set<String>
    public var localeIdentifier: String
    /// 使用者自己的英文專名（個人字典的輸出寫法＋開著的詞庫包＋聯絡人）；給 LatinNameFixer 當比對目標。
    public var latinTerms: [String]

    public init(
        dictionary: [String: String] = [:],
        fillerSet: Set<String> = NormalizerOptions.defaultFillers,
        localeIdentifier: String = "zh_TW",
        latinTerms: [String] = []
    ) {
        self.dictionary = dictionary
        self.fillerSet = fillerSet
        self.localeIdentifier = localeIdentifier
        self.latinTerms = latinTerms
    }

    /// 常見中文口述贅詞。刻意保持精簡——只有真的會被誤投進句子的。
    public static let defaultFillers: Set<String> = [
        "嗯", "嗯嗯", "啊", "啊啊", "呃", "呃呃",
        "那個", "那個那個", "這個", "這個這個",
        "就是說", "就是說說", "然後那個", "對", "欸",
        // 簡體（規則與繁體相同；「对」「这个」「那个」同樣受邊界限制）
        "那个", "那个那个", "这个", "这个这个", "就是说", "然后那个", "对"
    ]
}

public struct Normalizer: Sendable {
    public let options: NormalizerOptions

    public init(options: NormalizerOptions = NormalizerOptions()) {
        self.options = options
    }

    public func normalize(_ text: String) -> NormalizedText {
        var working = text
        var steps: [String] = []

        working = stage(&steps, "trim", from: working) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Edit Selection 的語音指令與選取內容要交給 editor adapter；
        // deterministic fallback 必須保留原始 selection request，不能把
        // 「改成更白話」誤當成一般聽寫的自我修正。
        if InputFeatures.hasSelectedBlock(working) {
            steps.append("selection-preserved")
            return NormalizedText(original: text, cleaned: working, appliedSteps: steps)
        }

        // 逐字母念的縮寫合回一個字（「K C F S」→「KCFS」，2026-09-19 Micky 實機）；放字典前面，字典才對得到。
        working = stage(&steps, "spelled-letters", from: working) { input in
            Normalizer.joinSpelledLetters(input)
        }

        // 英文專名（grook→Grok、clote coate→Claude Code）：放字典前面，字典的替換規則才對得到正式寫法。
        if !options.latinTerms.isEmpty {
            working = stage(&steps, "latin-names", from: working) { input in
                LatinNameFixer.fix(input, terms: options.latinTerms)
            }
        }

        // 字典先套：長詞優先，避免短詞先匹配把長詞吃掉。
        if !options.dictionary.isEmpty {
            working = stage(&steps, "dictionary", from: working) { input in
                Normalizer.applyDictionary(input, dict: options.dictionary)
            }
        }

        working = stage(&steps, "filler", from: working) { input in
            Normalizer.removeFillers(input, fillers: options.fillerSet)
        }

        working = stage(&steps, "repeat", from: working) { input in
            Normalizer.collapseRepeats(input)
        }

        working = stage(&steps, "self-correction", from: working) { input in
            Normalizer.applySelfCorrection(input)
        }

        working = stage(&steps, "number-date-amount", from: working) { input in
            Normalizer.normalizeNumbers(input)
        }

        working = stage(&steps, "list", from: working) { input in
            // Markdown 結構（# / - / * / 1.）出現時不動 list cue，
            // 避免把 markdown bullets 拆壞。
            if InputFeatures.hasMarkdown(input) {
                return input
            }
            return Normalizer.normalizeListCues(input)
        }

        working = stage(&steps, "punctuation", from: working) { input in
            Normalizer.normalizePunctuation(input)
        }

        // 句尾語助詞被標點切開（「走過去學校，了」，2026-09-19 Micky 實機）→ 黏回前一句。
        working = stage(&steps, "particles", from: working) { input in
            Normalizer.reattachParticles(input)
        }

        // 收尾：把多餘空白壓回單一。
        working = stage(&steps, "collapse-whitespace", from: working) { input in
            Normalizer.collapseWhitespace(input)
        }

        // 長文分段（2026-09-19，Micky：長文分段整理落後 Typeless）：放最後，只在整段沒有換行時動。
        working = stage(&steps, "paragraph", from: working) { input in
            Normalizer.paragraphize(input)
        }

        return NormalizedText(original: text, cleaned: working, appliedSteps: steps)
    }

    // MARK: - Pipeline helpers

    /// 即使 transform 沒改東西也記錄下來，證明這個 step 真有進入 pipeline。
    /// 測試會檢查這份清單，等於「這條規則沒有被悄悄拔掉」的 sentinel。
    private func stage(_ steps: inout [String], _ name: String, from input: String, _ transform: (String) -> String) -> String {
        let out = transform(input)
        if steps.last != name { steps.append(name) }
        return out
    }

    // MARK: - Static transforms
    //
    // 全部 `static` 是刻意的：方便測試單獨打，也讓 normalizer
    // 本身沒有隱藏狀態。

    /// 兩個以上「單獨的英文字母」用單一空白隔開 → 合成一個字（辨識器把逐字母念的縮寫輸出成「K C F S」）。
    /// 字母前後不能緊接其他英文字母（「plan A」「I am」不動：只有一個單字母）。
    public static func joinSpelledLetters(_ text: String) -> String {
        applyRegex(text, pattern: "(?<![A-Za-z])[A-Za-z](?: [A-Za-z])+(?![A-Za-z])") { groups in
            groups[0].replacingOccurrences(of: " ", with: "")
        }
    }

    /// 單獨一個的句尾語助詞（前面被標點切開、後面是標點或結尾）→ 黏回前一句，標點移到它後面。
    /// 「學校，了」→「學校了」、「學校。了」→「學校了。」、「好，啦，走吧」→「好啦，走吧」；「了解」不動。
    public static let sentenceParticles = "了啦喔哦吧呢嗎吗呀啊囉嘛耶欸哈"
    public static func reattachParticles(_ text: String) -> String {
        // 句尾單獨一個感嘆詞（「搞不懂。哎。」）→ 接回前一句：「搞不懂，哎。」
        let interjection = applyRegex(text, pattern: "[。．.]\\s*(哎|唉|欸|哇|嗯|哈|喔|哎呀|唉呀)([。！!．.]?)$") { groups in
            "，\(groups[1])\(groups[2].isEmpty ? "。" : groups[2])"
        }
        return applyRegex(interjection, pattern: "([，,、。．.！!？?])\\s*([\(sentenceParticles)])(?=[，,、。．.！!？?\\s]|$)") { groups in
            let mark = groups[1]
            return ["，", ",", "、"].contains(mark) ? groups[2] : groups[2] + mark
        }
    }

    /// 辨識器把「五點四十九」寫成「5.49」：前後文是時間（…的時候／左右／出門、早上／下午…）就改成「5:49」，
    /// 同一段裡一模一樣的數字也一起改（2026-09-19 實機「他是寫 5.49，但是 5.49的時候我…」）。
    static func decimalTimes(_ text: String) -> String {
        // 辨識器把「四十二」拆開（2026-09-19 實機）：「7:4。12」＝四｜十二、「7.40二」＝四十｜二 → 先接回 7:42 / 7.42。
        var text = applyRegex(text, pattern: "(?<![\\d.:])(\\d{1,2})[:.]([1-5])[，。、\\s]*1([0-9])(?![\\d.])") { g in "\(g[1]):\(g[2])\(g[3])" }
        text = applyRegex(text, pattern: "(?<![\\d.:])(\\d{1,2})([:.])([1-5])0([一二三四五六七八九])") { g in
            "\(g[1])\(g[2])\(g[3])\(["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9][g[4]] ?? 0)"
        }
        let shape = "(?<![\\d.])([01]?\\d|2[0-3])\\.([0-5]\\d)(?![\\d.])"
        guard let re = try? NSRegularExpression(pattern: shape) else { return text }
        let ns = text as NSString
        var times = Set<String>()
        let after = ["的時候", "的时候", "時", "左右", "前", "後", "那班", "出門", "開始", "到", "準時", "整"]
        let before = ["早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "大概", "約"]
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            let tail = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
            let headStart = max(0, m.range.location - 4)
            let head = ns.substring(with: NSRange(location: headStart, length: m.range.location - headStart))
            if after.contains(where: { tail.hasPrefix($0) }) || before.contains(where: { head.hasSuffix($0) || head.contains($0) }) {
                times.insert(token)
            }
        }
        guard !times.isEmpty else { return text }
        return applyRegex(text, pattern: shape) { g in times.contains(g[0]) ? "\(g[1]):\(g[2])" : g[0] }
    }

    public static func applyDictionary(_ text: String, dict: [String: String]) -> String {
        guard !dict.isEmpty else { return text }
        // 長詞優先，避免短詞覆蓋長詞。
        let keys = dict.keys.sorted { $0.count > $1.count }
        var out = text
        for key in keys {
            guard let value = dict[key], !value.isEmpty else { continue }
            out = replaceDictionaryTerm(in: out, target: key, replacement: value)
        }
        return out
    }

    /// 字典詞的左側可以緊接中文（「我去台藝大」），但右側若仍是文字，
    /// 通常代表它只是更長詞的一部分（「蘋果派」），因此保留原文。
    /// 例外是拼音文字詞（pik）：語音辨識常把英文黏在中文前後（「用pik播放器」），
    /// 這時只有同樣是拼音文字的字元才算「更長的詞」（pika、apik），中文是邊界。
    static func replaceDictionaryTerm(in text: String, target: String, replacement: String) -> String {
        let chars = Array(text)
        let targetChars = Array(target)
        guard let first = targetChars.first, let last = targetChars.last else { return text }
        let latinStart = isAlphabeticWordChar(first)
        let latinEnd = isAlphabeticWordChar(last)
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let end = i + targetChars.count
            if end <= chars.count && Array(chars[i..<end]) == targetChars {
                let leftBoundary = !latinStart || i == 0 || !isAlphabeticWordChar(chars[i - 1])
                let rightBoundary = end == chars.count
                    || !(latinEnd ? isAlphabeticWordChar(chars[end]) : isTokenChar(chars[end]))
                if leftBoundary && rightBoundary {
                    result.append(contentsOf: replacement)
                    i = end
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return String(result)
    }

    /// 把 `target` 視為完整 token 來替換。中文之間無空白，所以
    /// 邊界就是「前面不是 CJK／字母／數字，且後面也不是」。
    static func replaceWholeToken(in text: String, target: String, replacement: String) -> String {
        guard !target.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        let chars = Array(text)
        let targetChars = Array(target)
        let n = chars.count
        let m = targetChars.count
        var i = 0
        while i < n {
            if i + m <= n {
                var match = true
                for k in 0..<m where chars[i + k] != targetChars[k] {
                    match = false
                    break
                }
                if match {
                    let leftBoundaryOK: Bool
                    if i == 0 {
                        leftBoundaryOK = true
                    } else {
                        leftBoundaryOK = !isTokenChar(chars[i - 1])
                    }
                    let rightBoundaryOK: Bool
                    if i + m == n {
                        rightBoundaryOK = true
                    } else {
                        rightBoundaryOK = !isTokenChar(chars[i + m])
                    }
                    if leftBoundaryOK && rightBoundaryOK {
                        result.append(replacement)
                        i += m
                        continue
                    }
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// 拼音文字（拉丁等）的詞字元：token 字元裡扣掉 CJK／假名／諺文。
    static func isAlphabeticWordChar(_ char: Character) -> Bool {
        isTokenChar(char) && !isCJKChar(char)
    }

    static func isCJKChar(_ char: Character) -> Bool {
        guard let v = char.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }

    static func isTokenChar(_ char: Character) -> Bool {
        // 把 CJK 文字、英數字、底線都當 token 字元；標點／空白不算。
        if char.isLetter || char.isNumber || char == "_" { return true }
        if let scalar = char.unicodeScalars.first {
            // CJK Unified Ideographs + Extension A + Hiragana/Katakana + Hangul
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) { return true }
            if (0x3400...0x4DBF).contains(v) { return true }
            if (0x3040...0x30FF).contains(v) { return true }
            if (0xAC00...0xD7AF).contains(v) { return true }
        }
        return false
    }

    public static func removeFillers(_ text: String, fillers: Set<String>) -> String {
        guard !fillers.isEmpty else { return text }
        var chars = Array(text)
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            let target = Array(filler)
            guard !target.isEmpty else { continue }
            var index = 0
            while index + target.count <= chars.count {
                let matches = Array(chars[index..<(index + target.count)]) == target
                guard matches else {
                    index += 1
                    continue
                }

                // 贅詞常會黏在中文前後（「嗯今天天氣」「不錯啊」），
                // 所以不能只靠 whitespace token boundary。句首／句尾，
                // 或至少一側是標點／空白時，才視為 filler；中文句中的
                // 「那個」若兩側都是文字則保留，避免誤刪事實內容。
                let rightIndex = index + target.count
                let leftBoundary = index == 0 || !isTokenChar(chars[index - 1])
                let rightBoundary = rightIndex == chars.count || !isTokenChar(chars[rightIndex])
                // 兼作實詞的贅詞規則更嚴（2026-09-17 鍵盤實測「在錄音室對 Atmos 母帶」的「對」被刪、「這個不對」剩「不」）：
                //   「對」「這個」：兩側都要是邊界（「對，明天見」刪、「不對」「對 Atmos」「這個不對」留）。
                //   「那個」：空白不算邊界，只有句首句尾或標點算（「那個我今天」刪、「用那個 app」留）。
                let leftHard = index == 0 || isHardBoundary(chars[index - 1])
                let rightHard = rightIndex == chars.count || isHardBoundary(chars[rightIndex])
                let isFiller: Bool
                if bothSidesFillers.contains(filler) {
                    isFiller = leftBoundary && rightBoundary
                } else if hardSideFillers.contains(filler) {
                    isFiller = leftHard || rightHard
                } else if leadingOnlyFillers.contains(filler) {
                    isFiller = leftBoundary
                } else {
                    isFiller = leftBoundary || rightBoundary
                }
                if isFiller {
                    chars.removeSubrange(index..<rightIndex)
                    // 刪掉贅詞後不留孤兒標點：「對，明天見」→「明天見」、「好，對，就這樣」→「好，就這樣」。
                    if index < chars.count, isPunctuation(chars[index]),
                       index == 0 || isPunctuation(chars[index - 1]) {
                        chars.remove(at: index)
                    }
                    continue
                }
                index += 1
            }
        }
        // 多餘空白留給 collapse-whitespace 統一壓。
        return String(chars)
    }

    /// 兼作實詞、兩側都要是邊界才算贅詞。
    /// 「這個」句首常是主詞（「這個不對」「這個好吃」），刪了會丟內容，所以也要兩側都是邊界。
    static let bothSidesFillers: Set<String> = ["對", "這個", "对", "这个"]
    /// 兼作實詞、至少一側要是「硬邊界」（句首句尾或標點，空白不算）才算贅詞。
    /// 「那個」放句首幾乎都是口頭禪（「那個我今天很累」），保留句首可刪。
    static let hardSideFillers: Set<String> = ["那個", "這個這個", "那個那個", "然後那個", "那个", "这个这个", "那个那个", "然后那个"]

    /// 兼作句尾語氣詞、只有左邊是邊界（句首、標點、空白）才算贅詞（2026-09-25 Micky 實機：「當然啊」被刪成「當然」）。
    /// 「啊，我忘了」「欸，你看」刪；「當然啊」「好啊」「不錯啊」「好欸」黏在字後面是語氣，留。
    static let leadingOnlyFillers: Set<String> = ["啊", "啊啊", "欸"]

    static func isPunctuation(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    static func isHardBoundary(_ c: Character) -> Bool {
        isPunctuation(c) || c.isNewline
    }

    /// 把同一個 token 重複出現的狀況壓回一次。
    /// 例：「我我覺得」→「我覺得」、「那個那個蘋果」→「那個蘋果」。
    public static func collapseRepeats(_ text: String) -> String {
        var working = text

        // ASR often places a pause marker between repeated starts. Keep sentence-ending
        // punctuation out of this rule so two deliberate sentences stay separate.
        let repeatedPhrase = try? NSRegularExpression(pattern: "([\\u4E00-\\u9FFF]{3,8})[、，,\\s]+\\1")
        if let repeatedPhrase {
            while true {
                let range = NSRange(working.startIndex..<working.endIndex, in: working)
                guard let match = repeatedPhrase.firstMatch(in: working, range: range),
                      let whole = Range(match.range(at: 0), in: working),
                      let first = Range(match.range(at: 1), in: working) else { break }
                working.replaceSubrange(whole, with: working[first])
            }
        }
        working = applyRegex(working, pattern: "([我你他它這那是不就要很請等])(?:[、，,\\s]+\\1)+(?=[\\u4E00-\\u9FFF]|[、，,\\s]|$)") { $0[1] }

        // 兩個以上 CJK 字元組成的重複片段（「這樣這樣」）是高訊號口吃，
        // 用 bounded regex 處理；單字「看看」不符合這個形狀，會保留。
        if let phraseRegex = try? NSRegularExpression(pattern: "([\\u4E00-\\u9FFF]{2,8})\\1") {
            while true {
                let range = NSRange(working.startIndex..<working.endIndex, in: working)
                guard let match = phraseRegex.firstMatch(in: working, range: range),
                      match.numberOfRanges > 1,
                      let whole = Range(match.range(at: 0), in: working),
                      let first = Range(match.range(at: 1), in: working) else {
                    break
                }
                working.replaceSubrange(whole, with: working[first])
            }
        }

        let chars = Array(working)
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            // 找出目前 token 的最長匹配（同字元連續）
            var j = i + 1
            while j < chars.count, chars[j] == chars[i] { j += 1 }
            let tokenLen = j - i
            // ASR 口吃常是「我我覺得」。只對高訊號的代名詞／功能字做
            // 單字去重，避免把「今天天氣」或「看看」這種正常中文吃掉。
            let repeatableCharacters: Set<Character> = ["我", "你", "他", "它", "這", "那", "是", "不", "就", "要", "很", "請", "等"]
            let repeatable = repeatableCharacters.contains(chars[i])
            if tokenLen >= 2 && repeatable {
                result.append(chars[i])
                i = j
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return String(result)
    }

    /// 自修正：「不是 A，是 B」→ B；「A 不對，是 B」→ B；「A 不對 B」→ B；
    /// 「改成 B」→ 保留 B 但去掉前綴。
    /// 故意只處理最常見的形狀，避免誤殺正常句。
    /// 「X不是A，是B」刪掉 A 後還需要「是」的主詞／指示詞（長的排前面，regex 交替才會先比長的）。
    static let copulaSubjects = ["這些", "那些", "這個", "那個", "我們", "你們", "他們", "她們", "它們", "這", "那", "它", "他", "她", "我", "你", "您"]
        .joined(separator: "|")

    public static func applySelfCorrection(_ text: String) -> String {
        var out = repairAfterFiller(correctionMarkers(text))
        // 順序刻意：較長的 pattern 先匹配，避免短 pattern 把長 pattern 切掉。
        let patterns: [(NSRegularExpression, String)] = [
            // 前面是主詞／指示詞：刪掉「不是A」要留下「是」（「這不是我的，是他的」→「這是他的」，不是「這他的」）。
            (try! NSRegularExpression(pattern: "(\(copulaSubjects))不是([^，。！？,!?\\s]{1,30})[，,。是]?是([^，。！？,!?\\s]{1,30})"), "$1是$3"),
            (try! NSRegularExpression(pattern: "不是([^，。！？,!?\\s]{1,30})[，,。是]?是([^，。！？,!?\\s]{1,30})"), "$2"),
            (try! NSRegularExpression(pattern: "([^，。！？,!?\\s]{1,30})不對[，,]?是([^，。！？,!?\\s]{1,30})"), "$2"),
            (try! NSRegularExpression(pattern: "([^，。！？,!?\\s]{1,30})不對([^，。！？,!?\\s]{1,30})"), "$2"),
            (try! NSRegularExpression(pattern: "改成([^，。！？,!?\\s]{1,30})"), "$1"),
            (try! NSRegularExpression(pattern: "應該是([^，。！？,!?\\s]{1,30})"), "$1")
        ]
        for (pattern, replacement) in patterns {
            // 每次重新算 range：上一輪的替換可能縮短字串。
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = pattern.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }

    /// 講到一半改口（2026-09-19 實機「我上次做完，應該說我上次坐車之前」）：
    /// 停頓（逗號）後接「應該說／我是說／我的意思是」＝前一小句作廢。新說法的開頭如果在舊的一小句裡出現過，
    /// 就從那裡切（保留前面的「而且你看」）；沒出現過就整個小句拿掉。句中沒停頓的「我應該說實話」不動。
    static let correctionMarkers = ["我的意思是", "應該說", "我是說", "应该说"]
    /// 兩個逗號中間單獨講的改口詞（「禮拜三，不是，禮拜四」「剛上去，喔不對，剛出門」）；前後都要有停頓，
    /// 「但是不是應該」這種句中的「不是」不算。Mac 實測 Apple 裝置端模型這兩種會把方向弄反，所以用規則。
    static let standaloneCorrections = ["喔不對", "哦不對", "噢不對", "不對不對", "不對", "不是不是", "不是", "說錯了", "講錯了", "说错了"]
    static func correctionMarkers(_ text: String) -> String {
        var out = text
        for _ in 0..<5 {
            guard let (clauseStart, commaIndex, afterMarker) = findCorrection(out) else { break }
            let old = String(out[clauseStart..<commaIndex])
            let rest = String(out[afterMarker...]).drop(while: { $0 == "，" || $0 == "," || $0 == " " })
            // 新說法的開頭在舊的一小句裡出現過就從那裡切（先比兩個字、再比一個字），保留前面的「我是」「而且你看」。
            var keep = ""
            for n in [2, 1] {
                let anchor = String(rest.prefix(n))
                if anchor.count == n, let r = old.range(of: anchor, options: .backwards) { keep = String(old[..<r.lowerBound]); break }
            }
            out = String(out[..<clauseStart]) + keep + rest
        }
        return out
    }

    private static func findCorrection(_ s: String) -> (String.Index, String.Index, String.Index)? {
        // 單獨的改口詞：「，不是，」→ 當成「應該說」處理（afterMarker 跳過後面的逗號）。
        for marker in standaloneCorrections {
            var search = s.startIndex..<s.endIndex
            while let r = s.range(of: marker, range: search) {
                let hasCommaBefore = r.lowerBound > s.startIndex && "，,".contains(s[s.index(before: r.lowerBound)])
                let hasCommaAfter = r.upperBound < s.endIndex && "，,".contains(s[r.upperBound])
                if hasCommaBefore && hasCommaAfter {
                    let comma = s.index(before: r.lowerBound)
                    let breakers: Set<Character> = ["，", ",", "。", "！", "？", "!", "?", "\n"]
                    var start = comma
                    while start > s.startIndex, !breakers.contains(s[s.index(before: start)]) { start = s.index(before: start) }
                    if start < comma { return (start, comma, r.upperBound) }
                }
                search = r.upperBound..<s.endIndex
            }
        }
        for marker in correctionMarkers {
            var search = s.startIndex..<s.endIndex
            while let r = s.range(of: marker, range: search) {
                // 前面緊接逗號（容許一個空白）
                var p = r.lowerBound
                if p > s.startIndex, s[s.index(before: p)] == " " { p = s.index(before: p) }
                if p > s.startIndex, "，,".contains(s[s.index(before: p)]) {
                    let comma = s.index(before: p)
                    let breakers: Set<Character> = ["，", ",", "。", "！", "？", "!", "?", "\n"]
                    var start = comma
                    while start > s.startIndex, !breakers.contains(s[s.index(before: start)]) { start = s.index(before: start) }
                    if start < comma { return (start, comma, r.upperBound) }
                }
                search = r.upperBound..<s.endIndex
            }
        }
        return nil
    }

    /// 「剛上去哦剛出門」：語氣詞前後開頭同一個字、前面那段 ≤ 4 字＝改口，拿掉舊的那段。
    /// 「喔」不收（台灣口語多半是句尾語助詞），人稱開頭不收（「我先走哦我明天再來」）。
    static let repairFillers: Set<Character> = ["哦", "噢", "呃"]
    static let pronounStarts: Set<Character> = ["我", "你", "妳", "您", "他", "她", "它"]
    static func repairAfterFiller(_ text: String) -> String {
        var chars = Array(text)
        var i = 1
        while i < chars.count - 1 {
            let next = chars[i + 1]
            if repairFillers.contains(chars[i]), isCJKChar(next), !pronounStarts.contains(next) {
                var j = i - 1
                var found: Int?
                while j >= 0, i - j <= 4, isCJKChar(chars[j]) {
                    if chars[j] == next { found = j; break }
                    j -= 1
                }
                if let f = found, i - f >= 2 {
                    chars.removeSubrange(f...i)
                    i = f
                    continue
                }
            }
            i += 1
        }
        return String(chars)
    }

    /// 數字／日期／金額正規化（純 deterministic，只動常見形狀）：
    /// - 阿拉伯數字混雜的數字（如 1 2 3 → 123）保留原樣
    /// - 全數字中文「一二三四五六七八九十百千萬億」轉阿拉伯
    /// - 年月日「二〇二六年八月」 → 「2026 年 8 月」
    /// - 金額「一百二十三元」 → 「123 元」
    /// - 時間「五點半」 → 「5:30」 / 「五點十五分」 → 「5:15」
    public static func normalizeNumbers(_ text: String) -> String {
        var out = decimalTimes(text)

        // 1. 日期：X 年 Y 月 Z 日，其中 X/Y/Z 為中文數字或已含阿拉伯。
        out = applyRegex(out, pattern: "([\\d零〇一二三四五六七八九十百千兩]{1,10})年([\\d零〇一二三四五六七八九十百千兩]{1,5})月([\\d零〇一二三四五六七八九十百千兩]{1,5})日") { groups in
            let y = Normalizer.chineseToInt(groups[1]).map(String.init) ?? groups[1]
            let m = Normalizer.chineseToInt(groups[2]).map(String.init) ?? groups[2]
            let d = Normalizer.chineseToInt(groups[3]).map(String.init) ?? groups[3]
            return "\(y) 年 \(m) 月 \(d) 日"
        }

        // 2. 年月（沒寫日）：「二〇二六年八月」 → 「2026 年 8 月」
        out = applyRegex(out, pattern: "([\\d零〇一二三四五六七八九十百千兩]{1,10})年([\\d零〇一二三四五六七八九十百千兩]{1,5})月(?!日)") { groups in
            let y = Normalizer.chineseToInt(groups[1]).map(String.init) ?? groups[1]
            let m = Normalizer.chineseToInt(groups[2]).map(String.init) ?? groups[2]
            return "\(y) 年 \(m) 月"
        }

        // 3. 月日：「八月十七日」
        out = applyRegex(out, pattern: "([\\d零〇一二三四五六七八九十百千兩]{1,5})月([\\d零〇一二三四五六七八九十百千兩]{1,5})日") { groups in
            let m = Normalizer.chineseToInt(groups[1]).map(String.init) ?? groups[1]
            let d = Normalizer.chineseToInt(groups[2]).map(String.init) ?? groups[2]
            return "\(m) 月 \(d) 日"
        }

        // 4. 時間：「五點半」「五點十五分」「五點」
        out = applyRegex(out, pattern: "([\\d零〇一二三四五六七八九十兩]{1,3})點(半|十五分|三十分|四十五分|([\\d零〇一二三四五六七八九十]{1,3})分|(?=[開出到交會鐘]))") { groups in
            let h = Normalizer.chineseToInt(groups[1]).map(String.init) ?? groups[1]
            let suffix = groups[2]
            if suffix.isEmpty { return "\(h):00" }
            if suffix == "半" { return "\(h):30" }
            if suffix == "十五分" { return "\(h):15" }
            if suffix == "三十分" { return "\(h):30" }
            if suffix == "四十五分" { return "\(h):45" }
            // 分鐘部分
            let minutePart = String(suffix.dropLast()) // 去掉「分」
            let mm = Normalizer.chineseToInt(minutePart) ?? 0
            let mmStr = String(format: "%02d", mm)
            return "\(h):\(mmStr)"
        }

        // 5. 金額：「一百二十三元」「一百二十萬元」
        // 為了可預期，這裡把所有常見形狀（含 萬/億）都轉成阿拉伯數字 + 千分位。
        out = applyRegex(out, pattern: "([\\d零〇一二三四五六七八九十百千萬億兩]{1,15})(元|塊|圓| dollars?)") { groups in
            if let v = Normalizer.chineseToInt(Normalizer.colloquial(groups[1])) {
                return "\(Normalizer.formatThousands(v))\(groups[2])"
            }
            return groups[1] + groups[2]
        }

        // 2026-09-24 實機回報（Fast 模式講數字不轉）：以下規則都在金額之後，避免金額規則重讀已轉好的「35,000」。
        let digit = "零〇一二三四五六七八九"
        let numeral = "零〇一二三四五六七八九十百千萬億兩"
        // 前面是這些＝不是一個確定的數（幾十個、好幾百、上百人、十多）；不轉。
        let vague = "\\d幾好數多上來餘"

        // 6. 百分比：「百分之二十」「百分之三點五」
        out = applyRegex(out, pattern: "百分之([\(numeral)]{1,5})(?:點([\(digit)]{1,3}))?") { groups in
            guard let v = Normalizer.chineseToInt(groups[1]) else { return groups[0] }
            let fraction = groups[2].isEmpty ? "" : "." + (Normalizer.chineseToInt(groups[2]).map { String(format: "%0\(groups[2].count)d", $0) } ?? "")
            return "\(v)\(fraction)%"
        }

        // 7. 月日（口語「號」）：「九月二十四號」
        out = applyRegex(out, pattern: "(?<![\(numeral)\\d])([\(numeral)]{1,3})月([\(numeral)]{1,3})(號|号)") { groups in
            guard let m = Normalizer.chineseToInt(groups[1]), (1...12).contains(m),
                  let d = Normalizer.chineseToInt(groups[2]), (1...31).contains(d) else { return groups[0] }
            return "\(m) 月 \(d) \(groups[3])"
        }

        // 8. 整點：「下午三點」「三點見」。「有兩點要說」「快一點」不轉：要前面有時段詞，或後面接見／左右／之前…
        out = applyRegex(out, pattern: "(早上|上午|中午|下午|晚上|凌晨|傍晚|半夜|今天|明天|後天|昨天|禮拜[一二三四五六天日]|星期[一二三四五六天日])([\(numeral)]{1,3})點(?![點半\(numeral)\\d])") { groups in
            guard let h = Normalizer.chineseToInt(groups[2]), (0...24).contains(h) else { return groups[0] }
            return "\(groups[1])\(h)點"
        }
        out = applyRegex(out, pattern: "(?<![\(numeral)\(vague)有差快慢早晚多少好])([二兩三四五六七八九十]{1,3})點(?=見|左右|之前|以前|前|之後|以後|後|到|至|整|鐘)") { groups in
            guard let h = Normalizer.chineseToInt(groups[1]), (1...24).contains(h) else { return groups[0] }
            return "\(h)點"
        }

        // 9. 小數＋單位：「三點五公斤」（「三點五分」是時間，上面已處理）
        out = applyRegex(out, pattern: "(?<![\(numeral)\\d])([\(numeral)]{1,5})點([\(digit)]{1,3})(公斤|公里|公尺|公分|公升|倍|度|秒|個百分點|吋|寸|歲|小時|個小時|萬|億|G|GB|TB|K|kHz|Hz|dB)") { groups in
            guard let whole = Normalizer.chineseToInt(groups[1]) else { return groups[0] }
            let fraction = groups[2].compactMap { Normalizer.chineseToInt(String($0)).map(String.init) }.joined()
            return "\(whole).\(fraction)\(groups[3])"
        }

        // 10. 千以上的數字（含口語「三萬五」「兩千五」）：「預算大概三萬五」→「35,000」。
        //     必須以數字開頭：「千萬不要」不轉。
        out = applyRegex(out, pattern: "(?<![\(numeral)\(vague)])([一二兩三四五六七八九十][\(numeral)]*[千萬億][\(numeral)]*)(?![\(numeral)\\d])") { groups in
            guard let v = Normalizer.chineseToInt(Normalizer.colloquial(groups[1])), v >= 1000 else { return groups[0] }
            return Normalizer.formatThousands(v)
        }

        // 11. 數字＋單位，數值 ≥ 10：「十五分鐘」→「15分鐘」；「三個問題」「一下」「十分好」不動。
        out = applyRegex(out, pattern: "(?<![\(numeral)\(vague)第])([\(numeral)]{1,6})(分鐘|秒鐘|秒|小時|個小時|天|週|個禮拜|個星期|個月|年|歲|公斤|公里|公尺|公分|公升|度|人|次|張|頁|首|軌|個|位|本|台|支|件|題|篇|集|樓)") { groups in
            // 「三四五個人」＝概數：沒有十／百／千這類位值字的逐位數字不轉。
            guard groups[1].contains(where: { "十百千萬億".contains($0) }),
                  let v = Normalizer.chineseToInt(Normalizer.colloquial(groups[1])), v >= 10 else { return groups[0] }
            return "\(v)\(groups[2])"
        }

        // 12. 逐位念的數字（至少 3 位）：「一二三四五」「零九一二…」→ 阿拉伯數字；
        //     「一五一十」「九九八十一」這種成語中間有十，不會整段成立；後面接量詞（三四五個人）＝概數，不轉。
        out = applyRegex(out, pattern: "(?<![\(numeral)\\d])([\(digit)]{3,})(十)?(?![\(numeral)\\d個人天次位年歲種隻本件])") { groups in
            let run = groups[1]
            if !groups[2].isEmpty && run.last != "九" { return groups[0] }
            let digits = run.compactMap { Normalizer.chineseToInt(String($0)).map(String.init) }.joined()
            return digits + (groups[2].isEmpty ? "" : "10")
        }
        return out
    }

    /// 口語省略單位：「兩千五」＝2500、「三萬五」＝35000、「一百二」＝120（最後一個數字跟在單位後面、中間沒有零）。
    static func colloquial(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= 3, let last = chars.last, "一二兩三四五六七八九".contains(last) else { return s }
        switch chars[chars.count - 2] {
        case "百": return s + "十"
        case "千": return s + "百"
        case "萬": return s + "千"
        case "億": return s + "千萬"
        default: return s
        }
    }

    static func applyRegex(_ text: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        // 由後往前替換，避免 range 漂移。
        var result = text
        for match in matches.reversed() {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                if r.location == NSNotFound {
                    groups.append("")
                } else {
                    groups.append(nsText.substring(with: r))
                }
            }
            let replacement = transform(groups)
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        return result
    }

    /// 中文數字轉整數。支援 0~99,999,999,999 的常用組合。
    /// 不支援小數／負數／分數——這些交給 LLM formatter。
    public static func chineseToInt(_ s: String) -> Int? {
        if let v = Int(s) { return v }
        let map: [Character: Int] = [
            "零": 0, "〇": 0,
            "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let sectionWeights: [Character: Int] = [
            "十": 10, "百": 100, "千": 1000, "萬": 10000, "億": 100_000_000
        ]
        let characters = Array(s)
        guard !characters.isEmpty else { return nil }

        // 連續 digit 讀法（「二〇二六」）不是 positional unit 讀法，
        // 必須保留每一位，而不是只留下最後一個 current digit。
        if characters.allSatisfy({ map[$0] != nil }) {
            return Int(characters.compactMap { map[$0].map(String.init) }.joined())
        }

        var total = 0
        var section = 0
        var current = 0
        var sawAny = false
        for ch in s {
            if let d = map[ch] {
                current = d
                sawAny = true
                continue
            }
            if let w = sectionWeights[ch] {
                if w >= 10000 {
                    section = (section + current) * w
                    total += section
                    section = 0
                } else {
                    section += (current == 0 ? 1 : current) * w
                }
                current = 0
                sawAny = true
                continue
            }
            return nil
        }
        total += section + current
        return sawAny ? total : nil
    }

    /// 千分位格式化（避免 locale-dependent NumberFormatter）。
    public static func formatThousands(_ n: Int) -> String {
        let s = String(n)
        if s.count <= 3 { return s }
        var result = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { result.append(",") }
            result.append(ch)
        }
        return String(result.reversed())
    }

    /// 清單線索：
    /// - 「第一 X 第二 X 第三 X」 → 換行 + 編號
    /// - 「首先 X 其次 X 最後 X」 → 換行
    /// - 「接下來 X 然後 X 最後 X」 → 換行
    /// - 「記一下 A B C」風格 → 換行 + 編號
    static let numberedListCues = ["第一", "第二", "第三", "第四", "第五", "第六", "第七", "第八", "第九", "第十"]
    static let verbalListCues = ["首先", "其次", "再次", "然後", "接下來", "最後"]

    /// 條列：以「句」為單位判斷（2026-09-19 改規則）。
    /// 舊版整段計數：口語長文講兩次「然後」或「最後…最後的時程」就被切在句子中間
    /// （「確認\n最後的時程」）。現在一句裡要有兩種以上**不同**的 cue 才換行，
    /// 且 cue 後面緊接「的」不算（「最後的」「第一的」是形容，不是條列）。
    public static func normalizeListCues(_ text: String) -> String {
        splitSentences(text).map(listifySentence).joined()
    }

    static func listifySentence(_ sentence: String) -> String {
        func distinct(_ cues: [String]) -> Int {
            cues.filter { cue in
                var searchRange = sentence.startIndex..<sentence.endIndex
                while let r = sentence.range(of: cue, range: searchRange) {
                    if r.upperBound == sentence.endIndex || sentence[r.upperBound] != "的" { return true }
                    searchRange = r.upperBound..<sentence.endIndex
                }
                return false
            }.count
        }
        let numbered = distinct(numberedListCues)
        let verbal = distinct(verbalListCues)
        guard numbered >= 2 || verbal >= 2 else { return sentence }
        var out = sentence
        if numbered >= 2 {
            out = applyRegex(out, pattern: "(第一|第二|第三|第四|第五|第六|第七|第八|第九|第十)(?!的)([^第]{1,40}?)(?=第|[。！？!?]|$)") { groups in
                return "\n\(groups[1])\(groups[2])"
            }
        }
        if verbal >= 2 {
            out = applyRegex(out, pattern: "(首先|其次|再次|然後|接下來|最後)(?!的)(.{1,40}?)(?=首先|其次|再次|然後|接下來|最後|[。！？!?]|$)") { groups in
                return "\n\(groups[1])\(groups[2])"
            }
        }
        return out
    }

    /// 切句，保留句尾標點（連續的 。！？!? 與後面的收尾引號／括號一起算）與原本的空白；
    /// 英文句點只在後面接空白時才算句尾（避免 3.5、v0.2.1）。換行本身也是句界。
    static func splitSentences(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
        let closers: Set<Character> = ["」", "』", "”", "\"", "）", ")"]
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)
            let englishStop = ch == "." && i + 1 < chars.count && chars[i + 1] == " "
            if terminators.contains(ch) || englishStop {
                var j = i + 1
                while j < chars.count, terminators.contains(chars[j]) && chars[j] != "\n" || closers.contains(chars[j]) {
                    current.append(chars[j]); j += 1
                }
                out.append(current); current = ""
                i = j
                continue
            }
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static let paragraphOpeners = ["另外", "還有", "再來", "再者", "接下來", "此外", "至於", "關於", "對了", "順便", "最後",
                                   "總之", "總而言之", "整體來說", "整體而言", "總結", "結論是", "首先", "其次", "第二", "第三", "第四", "第五",
                                   "Also", "Another", "Finally", "By the way", "Anyway", "Overall", "In summary"]
    static let paragraphClosers = ["謝謝", "感謝", "麻煩", "不好意思", "辛苦了", "Thanks", "Thank you"]
    static let paragraphWeakOpeners = ["不過", "但是", "可是", "然而", "However", "But"]

    /// 長文分段（2026-09-19）：只在沒有換行、至少 3 句且 100 字以上時動，切點都在句界。
    /// ・轉折開頭（另外／還有／對了／總之…）且目前這段已 ≥ 20 字 → 新段
    /// ・弱轉折（不過／但是…）要目前這段 ≥ 40 字
    /// ・結尾致謝（謝謝／不好意思…）自成一段
    /// ・一段超過 120 字，下一句就開新段
    /// ・開頭的招呼（「老師你好，」）單獨一行
    /// 句首的「然後」「那」後面接轉折詞時照樣算，而且新段開頭的這個「然後／那」拿掉（「然後關於預算」→「關於預算」）。
    public static func paragraphize(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        var sentences = splitSentences(text)
        guard sentences.count >= 3, text.count >= 100 else { return text }

        var greeting: String?
        if let first = sentences.first,
           let m = first.range(of: "^[^，,。！？]{0,10}(你好|您好|哈囉|嗨|早安|午安|晚安)[，,]", options: .regularExpression) {
            greeting = String(first[m]).trimmingCharacters(in: .whitespaces)
            let rest = String(first[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { sentences.removeFirst() } else { sentences[0] = rest }
        }

        /// 去掉句首「然後／那」（只在後面緊接轉折詞時）。
        func core(_ sentence: String) -> String {
            let t = sentence.trimmingCharacters(in: .whitespaces)
            for lead in ["然後", "那"] where t.hasPrefix(lead) {
                let rest = String(t.dropFirst(lead.count))
                if (paragraphOpeners + paragraphClosers + paragraphWeakOpeners).contains(where: { rest.hasPrefix($0) }) { return rest }
            }
            return t
        }
        func starts(_ sentence: String, with list: [String]) -> Bool {
            let t = core(sentence)
            return list.contains { t.hasPrefix($0) }
        }

        var paragraphs: [String] = []
        var current = ""
        for sentence in sentences {
            let length = current.trimmingCharacters(in: .whitespaces).count
            let breakHere = length > 0 && (
                (starts(sentence, with: paragraphOpeners) && length >= 20)
                || (starts(sentence, with: paragraphClosers) && length >= 20)
                || (starts(sentence, with: paragraphWeakOpeners) && length >= 40)
                || length >= 120)
            if breakHere {
                paragraphs.append(current.trimmingCharacters(in: .whitespaces))
                current = core(sentence)
            } else {
                current += sentence
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { paragraphs.append(tail) }
        return ((greeting.map { [$0] } ?? []) + paragraphs).joined(separator: "\n\n")
    }

    /// 標點符號正體化：
    /// - 全形逗號、句號、問號、驚嘆號統一為繁體中文常用形（， 。 ？！）
    /// - 半形逗號／句號在中文字境下轉全形
    public static func normalizePunctuation(_ text: String) -> String {
        // 全形標點前不留空白（新引擎輸出「老師你好 ，我是」，2026-09-19）。
        var out = applyRegex(text, pattern: "[ \\t]+([，。？！、：；])") { groups in groups[1] }
        out = applyRegex(out, pattern: "([，。？！、：；])[ \\t]+") { groups in groups[1] }
        let pairs: [(String, String)] = [
            (",", "，"),  // 半形逗號
            (".", "。"),  // 半形句號（在中文之間）
            (";", "；"),
            (":", "："),
            ("?", "？"),
            ("!", "！")
        ]
        for (from, to) in pairs {
            out = applyRegex(out, pattern: "([\\u4E00-\\u9FFF])(" + NSRegularExpression.escapedPattern(for: from) + ")") { groups in
                return groups[1] + to
            }
        }
        return out
    }

    public static func collapseWhitespace(_ text: String) -> String {
        // 把多個空白（含換行以外的）壓成單一；
        // 但保留使用者／list cue 階段已加入的換行。
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        var lastWasNewline = false
        for ch in text {
            if ch == " " || ch == "\t" {
                if !lastWasSpace && !lastWasNewline {
                    out.append(" ")
                }
                lastWasSpace = true
            } else if ch == "\n" {
                if !lastWasNewline {
                    out.append("\n")
                }
                lastWasSpace = false
                lastWasNewline = true
            } else {
                out.append(ch)
                lastWasSpace = false
                lastWasNewline = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
