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

    public init(
        dictionary: [String: String] = [:],
        fillerSet: Set<String> = NormalizerOptions.defaultFillers,
        localeIdentifier: String = "zh_TW"
    ) {
        self.dictionary = dictionary
        self.fillerSet = fillerSet
        self.localeIdentifier = localeIdentifier
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

        // 收尾：把多餘空白壓回單一。
        working = stage(&steps, "collapse-whitespace", from: working) { input in
            Normalizer.collapseWhitespace(input)
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
    static func replaceDictionaryTerm(in text: String, target: String, replacement: String) -> String {
        let chars = Array(text)
        let targetChars = Array(target)
        guard !targetChars.isEmpty else { return text }
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let end = i + targetChars.count
            if end <= chars.count && Array(chars[i..<end]) == targetChars {
                let rightBoundary = end == chars.count || !isTokenChar(chars[end])
                if rightBoundary {
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
    public static func applySelfCorrection(_ text: String) -> String {
        var out = text
        // 順序刻意：較長的 pattern 先匹配，避免短 pattern 把長 pattern 切掉。
        let patterns: [(NSRegularExpression, String)] = [
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

    /// 數字／日期／金額正規化（純 deterministic，只動常見形狀）：
    /// - 阿拉伯數字混雜的數字（如 1 2 3 → 123）保留原樣
    /// - 全數字中文「一二三四五六七八九十百千萬億」轉阿拉伯
    /// - 年月日「二〇二六年八月」 → 「2026 年 8 月」
    /// - 金額「一百二十三元」 → 「123 元」
    /// - 時間「五點半」 → 「5:30」 / 「五點十五分」 → 「5:15」
    public static func normalizeNumbers(_ text: String) -> String {
        var out = text

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
            if let v = Normalizer.chineseToInt(groups[1]) {
                return "\(Normalizer.formatThousands(v))\(groups[2])"
            }
            return groups[1] + groups[2]
        }

        // 6. 純中文大數字（沒接單位）：保留「一隻蘋果」這種量詞上下文不動，
        // 只動「單獨成段」的純數字詞；保守處理以免誤傷。
        return out
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
    public static func normalizeListCues(_ text: String) -> String {
        var out = text

        let numberedCues = ["第一", "第二", "第三", "第四", "第五", "第六", "第七", "第八", "第九", "第十"]
        let verbalCues = ["首先", "其次", "再次", "然後", "接下來", "最後"]
        let numberedCount = numberedCues.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
        let verbalCount = verbalCues.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
        // 單獨一句「最後決議是…」不是條列；至少兩個 cue 才換行。
        guard numberedCount >= 2 || verbalCount >= 2 else { return text }

        // 「第一...第二...第三...」型
        out = applyRegex(out, pattern: "(第一|第二|第三|第四|第五|第六|第七|第八|第九|第十)([^第]{1,40}?)(?=第|[。！？!?]|$)") { groups in
            return "\n\(groups[1])\(groups[2])"
        }

        // 「首先...其次...最後...」
        out = applyRegex(out, pattern: "(首先|其次|再次|然後|接下來|最後)(.{1,40}?)(?=首先|其次|再次|然後|接下來|最後|[。！？!?]|$)") { groups in
            return "\n\(groups[1])\(groups[2])"
        }

        // 「幫我記一下 A B C」風格（粗略：以頓號分隔）
        // 由 punctuation 階段處理；這裡不動。
        return out
    }

    /// 標點符號正體化：
    /// - 全形逗號、句號、問號、驚嘆號統一為繁體中文常用形（， 。 ？！）
    /// - 半形逗號／句號在中文字境下轉全形
    public static func normalizePunctuation(_ text: String) -> String {
        var out = text
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
