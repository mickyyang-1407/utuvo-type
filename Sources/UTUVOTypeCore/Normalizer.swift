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
    /// 序數／明講數量的列舉改成「1. 」編號清單（2026-10-22 W2-6）。輸入框放不下換行（單行框）時關掉：
    /// 接成一行的「1. 2.」比原本的逗號句難讀，照舊只切 list cue 的行（2026-10-22 修正）。
    public var numberedLists: Bool

    public init(
        dictionary: [String: String] = [:],
        fillerSet: Set<String> = NormalizerOptions.defaultFillers,
        localeIdentifier: String = "zh_TW",
        latinTerms: [String] = [],
        numberedLists: Bool = true
    ) {
        self.dictionary = dictionary
        self.fillerSet = fillerSet
        self.localeIdentifier = localeIdentifier
        self.latinTerms = latinTerms
        self.numberedLists = numberedLists
    }

    /// 常見中文口述贅詞。刻意保持精簡——只有真的會被誤投進句子的。
    public static let defaultFillers: Set<String> = [
        "嗯", "嗯嗯", "啊", "啊啊", "呃", "呃呃",
        "那個", "那個那個", "這個", "這個這個",
        "就是說", "就是說說", "然後那個", "對", "欸",
        // 「恩」是語音辨識把「嗯」寫錯的字（2026-10-17 Groq 真人錄音「恩恩，然後就是說…」）；
        // 也是實詞（感恩、恩人），所以兩側都要是邊界才算（bothSidesFillers）。
        "恩", "恩恩",
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
        normalize(text, stoppingBefore: nil)
    }

    /// 測試用：跑到 `stop` 這一關之前就回傳（給「條列／分段不吃字」「整理兩次結果一樣」的性質測試拿前一關的輸出）。
    func normalize(_ text: String, stoppingBefore stop: String?) -> NormalizedText {
        var working = text
        var steps: [String] = []

        // 小型標點（Groq Whisper 會輸出「﹐」「﹑」）先換成一般全形，後面的改口／清單規則才認得（2026-10-22 ls03／sc04／sc05）。
        working = stage(&steps, "trim", from: working) { Normalizer.foldSmallFormPunctuation($0).trimmingCharacters(in: .whitespacesAndNewlines) }

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
                LatinNameFixer.fix(input, terms: options.latinTerms, source: .speech,
                                   keep: Normalizer.dictionaryRuleKeys(options.dictionary))
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

        // 疊字收掉之後可能才露出完整的贅詞（「然後然後那個高頻」→「然後那個高頻」），再掃一次贅詞，
        // 整理一次就到位、再整理也不變（2026-10-22 修正：normalize 要冪等）。
        // 連說兩次的改口詞（不對不對）在這裡被壓成一個，下一關要知道它原本連說過（＝有訊號的改口），先留一個看不見的記號。
        working = stage(&steps, "repeat", from: working) { input in
            let collapsed = Normalizer.collapseRepeats(Normalizer.flaggingDoubledCorrections(input))
            return collapsed == input ? collapsed : Normalizer.removeFillers(collapsed, fillers: options.fillerSet)
        }

        working = stage(&steps, "self-correction", from: working) { input in
            Normalizer.applySelfCorrection(input)
        }

        working = stage(&steps, "number-date-amount", from: working) { input in
            Normalizer.normalizeNumbers(input)
        }

        if stop == "list" { return NormalizedText(original: text, cleaned: working, appliedSteps: steps) }
        working = stage(&steps, "list", from: working) { input in
            // Markdown 結構（# / - / * / 1.）出現時不動 list cue，
            // 避免把 markdown bullets 拆壞。
            if InputFeatures.hasMarkdown(input) {
                return input
            }
            // 編號清單（2026-10-22 W2-6；第三輪改成保守規則）：符合條列規則的序數串 →「1. 」；明講數量的頓號列舉 → 編號清單。
            // 單行框（numberedLists = false）與已經分好段（有空行）的文字只切行、不編號——第二次整理結果不變。
            let numbered = options.numberedLists && !input.contains("\n\n")
            let lined = Normalizer.normalizeListCues(input, numbered: numbered)
            return numbered ? Normalizer.numberCountedEnumerations(lined) : lined
        }

        working = stage(&steps, "punctuation", from: working) { input in
            Normalizer.normalizePunctuation(input)
        }

        // 句尾語助詞被標點切開（「走過去學校，了」，2026-09-19 Micky 實機）→ 黏回前一句。
        working = stage(&steps, "particles", from: working) { input in
            Normalizer.reattachParticles(input)
        }

        // 句尾語氣（2026-10-02 Micky：不要每句都句號）：問句改「？」、明確的感嘆改「！」。
        // 最後一句的句號由各平台送出前的 SentenceMood.finish 拿掉（智慧整理回來的文字也要走同一步）。
        working = stage(&steps, "mood", from: working) { input in
            SentenceMood.apply(input)
        }

        // 收尾：把多餘空白壓回單一。
        working = stage(&steps, "collapse-whitespace", from: working) { input in
            Normalizer.collapseWhitespace(input)
        }

        // 長文分段（2026-09-19，Micky：長文分段整理落後 Typeless）：放最後，只在整段沒有換行時動。
        if stop == "paragraph" { return NormalizedText(original: text, cleaned: working, appliedSteps: steps) }
        // 有換行（清單／分段）的結果不會再經過 SentenceMood.finish 拿掉句尾吊著的「，」「、」，這裡收掉（2026-10-22 修正）。
        working = stage(&steps, "paragraph", from: working) { input in
            Normalizer.dropDanglingEndOfLines(Normalizer.paragraphize(input))
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
    /// 小型標點（U+FE50–FE57，直排／相容字元）→ 一般寫法：﹐→，、﹑→、、﹔→；、﹕→：、﹖→？、﹗→！；﹒→「.」交給後面的中文句號規則。
    public static let smallFormPunctuation: [Character: String] = [
        "\u{FE50}": "，", "\u{FE51}": "、", "\u{FE52}": ".", "\u{FE54}": "；",
        "\u{FE55}": "：", "\u{FE56}": "？", "\u{FE57}": "！"
    ]
    public static func foldSmallFormPunctuation(_ text: String) -> String {
        guard text.contains(where: { smallFormPunctuation[$0] != nil }) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text { out += smallFormPunctuation[ch] ?? String(ch) }
        return out
    }

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

    /// 時間後面常接的字（「5.49的時候」「7.40二到」）。
    static let decimalTimeAfterWords = ["的時候", "的时候", "時", "左右", "前", "後", "那班", "出門", "開始", "到", "準時", "整"]

    /// 辨識器把「五點四十九」寫成「5.49」：前後文是時間（…的時候／左右／出門、早上／下午…）就改成「5:49」，
    /// 同一段裡一模一樣的數字也一起改（2026-09-19 實機「他是寫 5.49，但是 5.49的時候我…」）。
    static func decimalTimes(_ text: String) -> String {
        // 辨識器把「四十二」拆開（2026-09-19 實機）：「7:4。12」＝四｜十二、「7.40二」＝四十｜二 → 先接回 7:42 / 7.42。
        var text = applyRegex(text, pattern: "(?<![\\d.:])(\\d{1,2})[:.]([1-5])[，。、\\s]*1([0-9])(?![\\d.])") { g in "\(g[1]):\(g[2])\(g[3])" }
        // 「40二」只在那個中文數字後面就收尾（結尾、標點、或上面這些時間字、後面不再接數字）才接回（FX-6 T3）。
        // 其他時候它是下一個數或詞的開頭：整理過的「11:30二萬」「3:30一分鐘」「1:30八 ms」「3:30一起去」「3:30三到五個人」
        // 再整理一次以前會變成「11:320,000」「3:31分鐘」「1:38 ms」「3:31起去」「3:33到五個人」。「一」（一到、一開始）不接。
        let closers = decimalTimeAfterWords.joined(separator: "|")
        text = applyRegex(text, pattern: "(?<![\\d.:])(\\d{1,2})([:.])([1-5])0([二三四五六七八九])(?=$|[，。、,!?！？；;]|(?:\(closers))(?![零〇一二三四五六七八九十百千萬億兩\\d]))") { g in
            "\(g[1])\(g[2])\(g[3])\(["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9][g[4]] ?? 0)"
        }
        let shape = "(?<![\\d.])([01]?\\d|2[0-3])\\.([0-5]\\d)(?![\\d.])"
        guard let re = try? NSRegularExpression(pattern: shape) else { return text }
        let ns = text as NSString
        var times = Set<String>()
        let after = decimalTimeAfterWords
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
        applyDictionary(text, dict: dict, keepingExistingValues: false)
    }

    /// `keepingExistingValues`：命中的位置本來就是完整的字典值（{"UTUVO":"UTUVO Type"} 遇到「UTUVO Type」）就跳過，
    /// 套幾次結果都一樣。給 `applyVocabulary`（已經整理過的文字）用；一般 normalize 照舊。
    static func applyDictionary(_ text: String, dict: [String: String], keepingExistingValues: Bool) -> String {
        guard !dict.isEmpty else { return text }
        // 長詞優先，避免短詞覆蓋長詞；一樣長的照 UTF-16 排（Kotlin `longestFirst` 的 thenBy 同一個順序），
        // 不然順序跟著 Dictionary 每個 process 都不一樣（W2-1 verifier 那條同類，2026-10-22）。
        let keys = dict.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0.utf16.lexicographicallyPrecedes($1.utf16) }
        var out = text
        for key in keys {
            guard let value = dict[key], !value.isEmpty else { continue }
            out = replaceDictionaryTerm(in: out, target: key, replacement: value, keepingExistingValue: keepingExistingValues)
        }
        return out
    }

    /// 只跑「英文專名＋個人字典」兩關（asr-vocab-2，2026-10-22）：給智慧整理回來的文字補套使用者的詞，
    /// 不重跑贅詞、改口、數字、條列、分段，整理好的格式一個字都不動。跟 `normalize` 的 latin-names／dictionary 兩關同一套規則，
    /// 只多一條冪等防護：命中的地方已經是完整的字典值就跳過（「UTUVO Type」不會變「UTUVO Type Type」）。
    /// 英文專名用 `.cleanup` 規則（W2-1 verifier，2026-10-22）：模型寫對的英文（codec、Daisy、Tone Master、vibe coding）
    /// 不准被拉成個人詞或改大小寫，只修使用者自己的寫法（Darmy Music→DAMI music、Utuvo Type→UTUVO Type、ToneMaster→Tonmeister）。
    public static func applyVocabulary(_ text: String, dictionary: [String: String], latinTerms: [String]) -> String {
        var out = text
        if !latinTerms.isEmpty {
            out = LatinNameFixer.fix(out, terms: latinTerms, source: .cleanup, keep: dictionaryRuleKeys(dictionary))
        }
        return applyDictionary(out, dict: dictionary, keepingExistingValues: true)
    }

    /// 個人字典裡真的會換字的規則（輸出不是空字串、也不等於自己）的 key：英文專名修正原樣留給字典那一關，
    /// 明確規則先於模糊比對（字典有 cloud→Claude，修正器不能先把 cloud 拉成 iCloud）。
    static func dictionaryRuleKeys(_ dictionary: [String: String]) -> Set<String> {
        Set(dictionary.lazy.filter { !$0.value.isEmpty && $0.key != $0.value }.map(\.key))
    }

    /// 智慧整理回來的文字要補套的英文專名目標（asr-vocab-2 接線，2026-10-22）：個人字典的寫法全部保留（使用者自己要的），
    /// 詞庫包的詞只留多字詞（Pro Tools、Claude Code）。單字的包內詞已經在整理提示詞裡給過模型，而且太短，
    /// 加權距離會撞到一般英文：模型寫對的「I'm glad the cloud sync works」會被改成「I'm Claude the Claude sync works」。
    /// Kotlin 鏡像：android/core `Normalizer.latinTermsForCleanedText`。
    public static func latinTermsForCleanedText(personal: [String], packTerms: [String]) -> [String] {
        var seen = Set<String>()
        let phrases = packTerms.filter { $0.contains(" ") }
        return (personal + phrases).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 用這個 normalizer 自己的字典與英文專名。
    public func applyVocabulary(_ text: String) -> String {
        Normalizer.applyVocabulary(text, dictionary: options.dictionary, latinTerms: options.latinTerms)
    }

    /// 字典詞的左側可以緊接中文（「我去台藝大」），但右側若仍是文字，
    /// 通常代表它只是更長詞的一部分（「蘋果派」），因此保留原文。
    /// 例外是拼音文字詞（pik）：語音辨識常把英文黏在中文前後（「用pik播放器」），
    /// 這時只有同樣是拼音文字的字元才算「更長的詞」（pika、apik），中文是邊界。
    static func replaceDictionaryTerm(in text: String, target: String, replacement: String) -> String {
        replaceDictionaryTerm(in: text, target: target, replacement: replacement, keepingExistingValue: false)
    }

    static func replaceDictionaryTerm(in text: String, target: String, replacement: String, keepingExistingValue: Bool) -> String {
        let chars = Array(text)
        let targetChars = Array(target)
        guard let first = targetChars.first, let last = targetChars.last else { return text }
        let latinStart = isAlphabeticWordChar(first)
        let latinEnd = isAlphabeticWordChar(last)
        let valueChars = Array(replacement)
        // key 在 value 裡出現的位置（「UTUVO」在「UTUVO Type」的 0）：命中時往回對，看完整的 value 是不是已經在那裡。
        let offsetsInValue: [Int] = keepingExistingValue && valueChars.count >= targetChars.count
            ? (0...(valueChars.count - targetChars.count)).filter { Array(valueChars[$0..<($0 + targetChars.count)]) == targetChars }
            : []
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let end = i + targetChars.count
            if end <= chars.count && Array(chars[i..<end]) == targetChars {
                let leftBoundary = !latinStart || i == 0 || !isAlphabeticWordChar(chars[i - 1])
                let rightBoundary = end == chars.count
                    || !(latinEnd ? isAlphabeticWordChar(chars[end]) : isTokenChar(chars[end]))
                let valueAlreadyThere = offsetsInValue.contains { offset in
                    let start = i - offset
                    return start >= 0 && start + valueChars.count <= chars.count
                        && Array(chars[start..<(start + valueChars.count)]) == valueChars
                }
                if leftBoundary && rightBoundary && !valueAlreadyThere {
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
        var chars = stripLeadingFillerChains(Array(text))
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
                if isDeterminer(filler, before: chars, at: rightIndex) {
                    // 「這個 delay」「那個 compressor」：後面接英文或數字＝限定詞，不是贅詞（2026-10-22 bench fl03／ml02）。
                    isFiller = false
                } else if bothSidesFillers.contains(filler) {
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
                    // 中間隔著空白也算（iOS 停頓標點「嗯 ，我覺得」以前會剩「，我覺得」）。
                    var next = index
                    while next < chars.count, isInlineSpace(chars[next]) { next += 1 }
                    var previous = index - 1
                    while previous >= 0, isInlineSpace(chars[previous]) { previous -= 1 }
                    if next < chars.count, isPunctuation(chars[next]),
                       previous < 0 || isPunctuation(chars[previous]) {
                        chars.remove(at: next)
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
    /// 「恩」兼作實詞（感恩、恩人），同樣兩側都要是邊界。
    static let bothSidesFillers: Set<String> = ["對", "這個", "对", "这个", "恩", "恩恩"]
    /// 兼作實詞、至少一側要是「硬邊界」（句首句尾或標點，空白不算）才算贅詞。
    /// 「那個」放句首幾乎都是口頭禪（「那個我今天很累」），保留句首可刪。
    static let hardSideFillers: Set<String> = ["那個", "這個這個", "那個那個", "然後那個", "那个", "这个这个", "那个那个", "然后那个"]

    /// 兼作句尾語氣詞、只有左邊是邊界（句首、標點、空白）才算贅詞（2026-09-25 Micky 實機：「當然啊」被刪成「當然」）。
    /// 「啊，我忘了」「欸，你看」刪；「當然啊」「好啊」「不錯啊」「好欸」黏在字後面是語氣，留。
    static let leadingOnlyFillers: Set<String> = ["啊", "啊啊", "欸"]

    /// 同一行裡的空白（不含換行）：孤兒標點與限定詞判斷都跳過這些。
    static func isInlineSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\u{3000}" || c == "\u{00A0}"
    }

    /// 英文字母或數字（半形、全形）：限定詞判斷用。
    static func isLatinOrDigit(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0x30...0x39).contains(v)
            || (0xFF10...0xFF19).contains(v) || (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v)
    }

    /// 結尾是「這個／那個」的贅詞，後面（跳過空白）接英文或數字＝限定詞（「這個 delay」「那個 compressor」「那個 3 號」）。
    static func isDeterminer(_ filler: String, before chars: [Character], at index: Int) -> Bool {
        guard ["這個", "那個", "这个", "那个"].contains(where: { filler.hasSuffix($0) }) else { return false }
        var next = index
        while next < chars.count, isInlineSpace(chars[next]) { next += 1 }
        return next < chars.count && isLatinOrDigit(chars[next])
    }

    /// 句首的贅詞串（「嗯嗯，然後就是說，」「然後然後，呃，」）：只在串裡有純猶豫詞（嗯／呃／恩）或「就是說」、
    /// 或「然後」後面緊接逗號時才拿掉；「然後就是這樣。」不動（2026-10-22 bench fl02／fl04）。
    /// 拿到最後一個猶豫詞為止，後面只再拿掉「有停頓（後面有逗號或空白）」的贅詞；黏著下一個字的「就是」「然後」「那個」可能是實詞，留著。
    static let leadingChainTokens = ["就是說", "就是说", "嗯嗯", "呃呃", "恩恩", "然後", "然后", "就是", "那個", "那个", "嗯", "呃", "恩"]
    static let leadingChainHesitations: Set<String> = ["就是說", "就是说", "嗯嗯", "呃呃", "恩恩", "嗯", "呃", "恩"]

    static func isChainSeparator(_ c: Character) -> Bool {
        c == "，" || c == "," || c == "、" || isInlineSpace(c)
    }

    static func stripLeadingFillerChains(_ chars: [Character]) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        var atSentenceStart = true
        while index < chars.count {
            if atSentenceStart {
                if isInlineSpace(chars[index]) {
                    out.append(chars[index])
                    index += 1
                    continue
                }
                atSentenceStart = false
                if let end = leadingChainEnd(chars, from: index) {
                    index = end
                    continue
                }
            }
            out.append(chars[index])
            if "。！？!?".contains(chars[index]) || chars[index].isNewline { atSentenceStart = true }
            index += 1
        }
        return out
    }

    /// 句首贅詞串要拿掉的結尾位置；不該拿就回 nil。
    private static func leadingChainEnd(_ chars: [Character], from start: Int) -> Int? {
        struct Item { let token: String; let tokenEnd: Int; let separatorEnd: Int }
        var items: [Item] = []
        var position = start
        while position < chars.count {
            guard let token = leadingChainTokens.first(where: { token in
                let t = Array(token)
                return position + t.count <= chars.count && Array(chars[position..<(position + t.count)]) == t
            }) else { break }
            let tokenEnd = position + token.count
            var separatorEnd = tokenEnd
            while separatorEnd < chars.count, isChainSeparator(chars[separatorEnd]) { separatorEnd += 1 }
            items.append(Item(token: token, tokenEnd: tokenEnd, separatorEnd: separatorEnd))
            position = separatorEnd
        }
        // 後面要接著實際內容（字或數字），整句都是贅詞的交給逐詞規則。
        guard position < chars.count, chars[position].isLetter || chars[position].isNumber else { return nil }
        guard let last = items.lastIndex(where: { item in
            // 「恩」黏著下一個字可能是實詞（恩人），後面要有停頓才算猶豫詞。
            if item.token == "恩" || item.token == "恩恩" { return item.separatorEnd > item.tokenEnd }
            if leadingChainHesitations.contains(item.token) { return true }
            return (item.token == "然後" || item.token == "然后")
                && item.tokenEnd < chars.count && "，,".contains(chars[item.tokenEnd])
        }) else { return nil }
        var end = last
        while end + 1 < items.count {
            let next = items[end + 1]
            guard next.separatorEnd > next.tokenEnd,
                  !isDeterminer(next.token, before: chars, at: next.tokenEnd) else { break }
            end += 1
        }
        return items[end].separatorEnd
    }

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
        // 「不是,是」是明確改口，不要把「不是」末尾的「是」和後面的「是」當口吃合併。
        working = applyRegex(working, pattern: "(?<!不)([我你他它這那是不就要很請等])(?:[、，,\\s]+\\1)+(?=[\\u4E00-\\u9FFF]|[、，,\\s]|$)") { $0[1] }

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
            let negatedCopula = chars[i] == "是" && i > 0 && chars[i - 1] == "不"
            if tokenLen >= 2 && repeatable && !negatedCopula {
                result.append(chars[i])
                i = j
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return String(result)
    }

    /// 「不是 A，是 B」保留明確主詞；逗號式改口只在片段能可靠對齊時才替換。
    static let copulaSubjects = ["這些", "那些", "這個", "那個", "我們", "你們", "他們", "她們", "它們", "這", "那", "它", "他", "她", "我", "你", "您"]
        .joined(separator: "|")

    public static func applySelfCorrection(_ text: String) -> String {
        let out = repairAfterFiller(correctionMarkers(unpunctuatedCorrections(text), valueOnly: false))
        return applyExplicitNotCorrection(out)
    }

    /// 改口詞後面沒停頓（「48k，不對是96k」「小柏、不是，是小潘」，2026-10-22 sc04／sc05）：
    /// 借把關用的同一份補逗號規則，只有補完真的對齊、改得掉才採用；否則原樣，不留多出來的逗號（「這樣不對是因為…」）。
    /// 不能當改口的改口詞（C1 描述詞、沒訊號又不是值換值，見 `maskingUnresolvableMarkers`）先遮起來，補逗號的規則認不得它們。
    static func unpunctuatedCorrections(_ flagged: String) -> String {
        // 連說記號（repeat 關留下的）只在判斷訊號時用，之後一律拿掉。
        let text = flagged.unicodeScalars.contains(doubledFlag)
            ? flagged.replacingOccurrences(of: String(doubledFlag), with: "") : flagged
        guard let masked = maskingUnresolvableMarkers(in: flagged) else { return text }
        let separated = CleanupFidelity.separatingCorrectionMarkers(in: masked)
        guard separated != masked else { return text }
        let corrected = correctionMarkers(separated, valueOnly: false)
        guard corrected != separated else { return text }
        for marker in ["，不對，", "，不是，", "，我是說"]
        where corrected.components(separatedBy: marker).count > text.components(separatedBy: marker).count {
            return text
        }
        return masked == text ? corrected : corrected.replacingOccurrences(of: String(markerMask), with: "")
    }

    // MARK: - 沒訊號的改口詞（FX-1 v2，2026-10-22）
    //
    // C1 「不對」後面直接接 齊應勁稱外盤焦等頭味題口＝描述詞（不對齊、不對應、不對勁…），永遠不是改口詞。
    // C2 改口詞（不對／我是說／啊不對）前後緊貼著停頓（，,、。；;：:！!？? 或空白）或連說兩次（不對不對）＝有訊號，
    //    照原本的規則。沒訊號的只有前後緊鄰的是同一種值（48K、44.1K、1.5倍、三點、兩萬、週六、明天、V3），而且新值後面
    //    到下一個標點最多 2 個中文字才改，其他照講的留著（「給他的檔案不對給他的同事公開」以前會被改成「給他的同事公開」，
    //    意思整個反過來）。「不是」維持原本的規則（單獨的「我住三樓不是四樓」是對比，本來就不動）。

    /// C1：「不對」後面直接接這些字是描述詞。
    static let notRightWordFollowers: Set<Unicode.Scalar> = ["齊", "應", "勁", "稱", "外", "盤", "焦", "等", "頭", "味", "題", "口"]
    /// 補逗號規則（CleanupFidelity.unpunctuatedNotRightMarker）會一起收進「不對」的語氣詞。
    static let correctionInterjections: Set<Unicode.Scalar> = ["啊", "呃", "喔", "哦", "噢", "欸"]
    /// 緊貼在改口詞前後就算有停頓的標點（另外任何空白也算）。
    static let correctionPausePunctuation: Set<Unicode.Scalar> = ["，", ",", "、", "。", "；", ";", "：", ":", "！", "!", "？", "?"]
    /// 遮改口詞用的字（WORD JOINER）：插在改口詞第一個字後面，補逗號的規則就對不到；改完再拿掉。
    static let markerMask: Unicode.Scalar = "\u{2060}"
    /// 連說記號（INVISIBLE SEPARATOR）：repeat 關把「不對不對」壓成「不對」＋這個字，self-correction 關認得、用完拿掉。
    static let doubledFlag: Unicode.Scalar = "\u{2063}"
    private static let doubledCorrection = try! NSRegularExpression(pattern: "(不對|不是|我是說)\\1+")

    /// 直接連說的改口詞（不對不對、不是不是、我是說我是說）壓成一個並留下連說記號；原文本來就有記號字元就不動。
    static func flaggingDoubledCorrections(_ text: String) -> String {
        guard !text.unicodeScalars.contains(doubledFlag) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return doubledCorrection.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\u{2063}")
    }

    private enum CorrectionMarkerKind { case notRight, notIs, iMean }

    private struct CorrectionMarkerSpan {
        let start: Int          // 含前面的語氣詞（啊不對）
        let end: Int            // 最後一個改口詞後面
        let positions: [Int]    // 每個改口詞第一個字的位置（遮的時候插在它後面）
        let kind: CorrectionMarkerKind
        let signalled: Bool
        let descriptive: Bool   // C1
    }

    private static func isCorrectionWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        isCorrectionWhitespace(Character(scalar))
    }

    /// 跟 CleanupFidelity.separatingCorrectionMarkers 對到的是同一批位置：「不對」（前面不是「對」，可帶語氣詞、可連說）、
    /// 後面接「是」的「不是」、「我是說」。
    private static func correctionMarkerSpans(_ s: [Unicode.Scalar]) -> [CorrectionMarkerSpan] {
        func at(_ i: Int, _ word: String) -> Bool {
            let w = Array(word.unicodeScalars)
            return i >= 0 && i + w.count <= s.count && Array(s[i..<(i + w.count)]) == w
        }
        func isSeparator(_ i: Int) -> Bool { s[i] == "，" || s[i] == "," || s[i] == "、" || isCorrectionWhitespace(s[i]) }
        func isPause(_ i: Int) -> Bool {
            i >= 0 && i < s.count && (correctionPausePunctuation.contains(s[i]) || isCorrectionWhitespace(s[i]))
        }
        // 連說：同一個詞再出現一次（中間可隔逗號空白），或後面帶著 repeat 關留下的連說記號。
        func run(from first: Int, word: String) -> (positions: [Int], end: Int, next: Int, doubled: Bool) {
            var positions = [first]
            var end = first + 2
            var doubled = false
            while true {
                if end < s.count, s[end] == doubledFlag { doubled = true; end += 1 }
                var j = end
                while j < s.count, isSeparator(j) { j += 1 }
                guard at(j, word) else { return (positions, end, j, doubled || positions.count > 1) }
                positions.append(j)
                end = j + 2
            }
        }
        var spans: [CorrectionMarkerSpan] = []
        var i = 0
        while i < s.count {
            if at(i, "不對") {
                if i > 0, s[i - 1] == "對" || s[i - 1] == "对" { i += 2; continue }
                let (positions, end, _, doubled) = run(from: i, word: "不對")
                var start = i
                var k = i
                while k > 0, isSeparator(k - 1) { k -= 1 }
                var gapped = false
                if k > 0, correctionInterjections.contains(s[k - 1]) { start = k - 1; gapped = k < i }
                let descriptive = end < s.count && notRightWordFollowers.contains(s[end])
                let signalled = doubled || gapped || isPause(start - 1) || isPause(end)
                spans.append(CorrectionMarkerSpan(start: start, end: end, positions: positions, kind: .notRight,
                                                  signalled: signalled, descriptive: descriptive))
                i = end
            } else if at(i, "不是") {
                let (positions, end, next, doubled) = run(from: i, word: "不是")
                if next < s.count, s[next] == "是" {
                    let signalled = doubled || isPause(i - 1) || isPause(end)
                    spans.append(CorrectionMarkerSpan(start: i, end: end, positions: positions, kind: .notIs,
                                                      signalled: signalled, descriptive: false))
                }
                i = end
            } else if at(i, "我是說") {
                var end = i + 3
                let doubled = end < s.count && s[end] == doubledFlag
                if doubled { end += 1 }
                spans.append(CorrectionMarkerSpan(start: i, end: end, positions: [i], kind: .iMean,
                                                  signalled: doubled || isPause(i - 1) || isPause(end), descriptive: false))
                i = end
            } else {
                i += 1
            }
        }
        return spans
    }

    /// 把不能當改口的改口詞遮起來（C1 描述詞；沒訊號的「不是」；沒訊號又不是值換值的「不對／我是說」）。
    /// 回傳的字串一律拿掉連說記號；沒有要遮的就是原文（去記號）；原文本來就有遮字用的字元（遮了拿不回來）回 nil＝整句不做沒標點的改口。
    static func maskingUnresolvableMarkers(in text: String) -> String? {
        let s = Array(text.unicodeScalars)
        let spans = correctionMarkerSpans(s)
        var masks = Set<Int>()
        for (index, span) in spans.enumerated() {
            if span.descriptive { masks.formUnion(span.positions); continue }
            // 「不是」照原本的規則：補逗號只碰後面接「是」的（「小柏不是，是小潘」），單獨的「三樓不是四樓」本來就不動。
            if span.signalled || span.kind == .notIs { continue }
            // 新值後面的字數算到下一個改口詞為止（「三點不對四點不對五點」）。
            let limit = spans[(index + 1)...].first(where: { !$0.descriptive })?.start ?? s.count
            if !isValueForValueCorrection(before: scalarString(s[..<span.start]), after: scalarString(s[span.end..<limit])) {
                masks.formUnion(span.positions)
            }
        }
        guard masks.isEmpty || !s.contains(markerMask) else { return nil }
        var out = String.UnicodeScalarView()
        for (index, scalar) in s.enumerated() where scalar != doubledFlag {
            out.append(scalar)
            if masks.contains(index) { out.append(markerMask) }
        }
        return String(out)
    }

    private static func scalarString(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private enum CorrectionValueKind { case relativeDay, weekday, version, arabic, chinese }

    /// 量詞（中文數字後面一定要有，或數字本身帶十百千萬億）；「點」後面可以接「半」「十五分」。
    private static let correctionMeasure = "(?:[點点](?:半|[0-9零〇一二三四五六七八九十]+分?)?|[號号樓楼層层塊块元倍個个位人次年月日天週周歲岁分秒度張张台臺軌轨頁页章集期版杯份本件間间條条種种堂節节班萬万千百億亿])"
    private static let correctionNumerals = "零〇一二三四五六七八九十百千萬万億亿兩两"
    /// 「禮拜五下午」「明天晚上」整個算一個值（不然「禮拜三不對禮拜五下午見」的「下午見」會被算成三個字的後文）。
    private static let correctionDayPeriod = "(?:上午|下午|中午|晚上|早上|傍晚|凌晨|半夜)?"
    private static let correctionValuePatterns: [(CorrectionValueKind, String)] = [
        (.relativeDay, "(?:大後天|大前天|後天|后天|前天|昨天|今天|明天)" + correctionDayPeriod),
        (.weekday, "(?:下個|這個|上個|下|這|上)?(?:星期|禮拜|礼拜|週|周)[一二三四五六日天]" + correctionDayPeriod),
        (.version, "(?<![A-Za-z])[Vv](?>[0-9]+(?:\\.[0-9]+)*)"),
        // 時間「3:30」不算（對齊規則會把它拆壞）。
        (.arabic, "(?<![A-Za-z0-9_.:：])(?>[0-9]+(?:\\.[0-9]+)*)(?![:：])(?:[A-Za-z%]+|\(correctionMeasure))?"),
        (.chinese, "(?<![\(correctionNumerals)])(?>[\(correctionNumerals)]+)\(correctionMeasure)?"),
    ]
    private static let correctionValueAtEnd: [(CorrectionValueKind, NSRegularExpression)] = correctionValuePatterns.map {
        ($0.0, try! NSRegularExpression(pattern: $0.1 + "\\z"))
    }
    private static let correctionValueAtStart: [(CorrectionValueKind, NSRegularExpression)] = correctionValuePatterns.map {
        ($0.0, try! NSRegularExpression(pattern: "\\A" + $0.1))
    }

    /// 中文數字要帶量詞，或本身有十百千萬億（「兩萬」）；光一個「三」不算值。
    private static func isCorrectionValue(_ kind: CorrectionValueKind, _ value: String) -> Bool {
        guard kind == .chinese else { return true }
        let numerals = Set("零〇一二三四五六七八九十百千萬万億亿兩两")
        guard let last = value.last else { return false }
        return !numerals.contains(last) || value.contains(where: { "十百千萬万億亿".contains($0) })
    }

    private static func correctionValue(in text: String, patterns: [(CorrectionValueKind, NSRegularExpression)]) -> (CorrectionValueKind, Range<String.Index>)? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (kind, regex) in patterns {
            guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { continue }
            if isCorrectionValue(kind, String(text[r])) { return (kind, r) }
        }
        return nil
    }

    /// C2：改口詞前面緊鄰的值跟後面緊鄰的值是同一種，而且新值後面到下一個標點最多 2 個中文字。
    /// `after` 從改口詞後面開始（可帶「是」「就是」這類開頭）。
    static func isValueForValueCorrection(before: String, after: String) -> Bool {
        guard let (oldKind, _) = correctionValue(in: trimCorrectionWhitespace(before), patterns: correctionValueAtEnd) else { return false }
        let rest = stripCorrectionLead(after)
        guard let (newKind, range) = correctionValue(in: rest, patterns: correctionValueAtStart), newKind == oldKind else { return false }
        var hanCount = 0
        for scalar in rest[range.upperBound...].unicodeScalars {
            if correctionPausePunctuation.contains(scalar) || scalar == "\n" || scalar == "\r" { break }
            if isCJKChar(Character(scalar)) { hanCount += 1 }
        }
        return hanCount <= 2
    }

    private static func applyExplicitNotCorrection(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "([^，。！？,!?\\s　]{0,30})不是([^，。！？,!?\\s　]{1,30})([，,。]?)是(?!不是|對不對|要不要)([^，。！？,!?\\s　]{1,30})")
        var out = text
        for _ in 0..<5 {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            guard let match = pattern.firstMatch(in: out, range: range),
                  let fullRange = Range(match.range, in: out),
                  let prefixRange = Range(match.range(at: 1), in: out),
                  let oldRange = Range(match.range(at: 2), in: out),
                  let separatorRange = Range(match.range(at: 3), in: out),
                  let newRange = Range(match.range(at: 4), in: out) else { break }
            let prefix = String(out[prefixRange])
            let separator = String(out[separatorRange])
            if separator.isEmpty, prefix.hasSuffix("是") { break }
            // 「不是星期四而是星期三」是對比（後面那個對），不是改口；當成改口會切出「星期三而」（FX-3 第四輪 G3）。照原話留著。
            if separator.isEmpty, out[oldRange].hasSuffix("而") { break }
            let old = prefix + String(out[oldRange])
            let replacement = String(out[newRange])
            let corrected: String
            if let aligned = alignCorrection(old: old, replacement: replacement) {
                corrected = aligned
            } else if copulaSubjects.split(separator: "|").contains(where: { prefix.hasSuffix($0) }) {
                corrected = prefix + "是" + replacement
            } else {
                // No reliable relationship between the old and new phrases: preserve the utterance.
                break
            }
            out.replaceSubrange(fullRange, with: corrected)
        }
        return out
    }

    /// 停頓後的改口只替換可對齊的片段；找不到可靠對應時保留原句。
    static let correctionMarkerWords = ["我的意思是", "應該說", "我是說", "应该说"]
    static let standaloneCorrections = ["啊不對", "喔不對", "哦不對", "噢不對", "不對不對", "不對", "不是不是", "不是", "說錯了", "講錯了", "说错了"]
    private static let weekdayModifiers = [
        "大後天的", "明天的", "昨天的", "後天的",
        "大後天", "明天", "昨天", "後天", "下個", "這個", "上個", "下", "這", "上"
    ]

    private static func isCorrectionWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
                 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
                return true
            default:
                return false
            }
        }
    }

    private static func trimCorrectionWhitespace(_ text: String) -> String {
        var lower = text.startIndex
        var upper = text.endIndex
        while lower < upper, isCorrectionWhitespace(text[lower]) {
            lower = text.index(after: lower)
        }
        while lower < upper {
            let previous = text.index(before: upper)
            guard isCorrectionWhitespace(text[previous]) else { break }
            upper = previous
        }
        return String(text[lower..<upper])
    }

    /// 把關（CleanupFidelity.prepareSource）用：它先把每個改口詞都補上逗號，看不出原本有沒有停頓，
    /// 所以「不對」類與「我是說」都照沒訊號的規則（C2，只認值換值）。第一次貼上走 `correctionMarkers(_:valueOnly: false)`。
    static func correctionMarkers(_ text: String) -> String {
        correctionMarkers(text, valueOnly: true)
    }

    static func correctionMarkers(_ text: String, valueOnly: Bool) -> String {
        var out = text
        for _ in 0..<5 {
            guard let (clauseStart, commaIndex, afterMarker) = findCorrection(out) else { break }
            let old = String(out[clauseStart..<commaIndex])
            let rawRest = String(out[afterMarker...]).drop(while: { $0 == "，" || $0 == "," || isCorrectionWhitespace($0) })
            // 只有「不對」類與「我是說」照 C2；「不是」與其他改口詞照原本的規則。
            if valueOnly {
                let marker = trimCorrectionWhitespace(String(out[out.index(after: commaIndex)..<afterMarker]))
                if marker.contains("不對") || marker == "我是說",
                   !isValueForValueCorrection(before: old, after: String(rawRest)) { break }
            }
            let rest = stripCorrectionLead(String(rawRest))
            guard let (replacement, suffix) = splitCorrectionPayload(rest),
                  let corrected = alignCorrection(old: old, replacement: replacement) else {
                // Keep the full utterance when there is no reliable alignment.
                break
            }
            out = String(out[..<clauseStart]) + corrected + suffix
        }
        return out
    }

    private static func stripCorrectionLead(_ text: String) -> String {
        var value = trimCorrectionWhitespace(text)
        let leads = ["就是啊", "就是", "是", "啊", "欸", "诶"]
        for _ in 0..<3 {
            guard let lead = leads.first(where: { value.hasPrefix($0) }) else { break }
            value.removeFirst(lead.count)
        }
        return trimCorrectionWhitespace(value)
    }

    private static func splitCorrectionPayload(_ text: String) -> (String, String)? {
        let boundaries: Set<Character> = ["，", ",", "。", "！", "？", "!", "?", "\r", "\n", "\r\n"]
        guard let boundary = text.firstIndex(where: { boundaries.contains($0) }) else {
            let value = trimCorrectionWhitespace(text)
            return value.isEmpty ? nil : (value, "")
        }
        let value = trimCorrectionWhitespace(String(text[..<boundary]))
        guard !value.isEmpty else { return nil }
        return (value, String(text[boundary...]))
    }

    /// Replace only a confidently aligned value in the old clause; keep surrounding words intact.
    private static func alignCorrection(old: String, replacement: String) -> String? {
        let oldRange = NSRange(old.startIndex..<old.endIndex, in: old)
        let newRange = NSRange(replacement.startIndex..<replacement.endIndex, in: replacement)

        // Same-kind relative dates have a stable lexical shape: 今天 → 明天, 昨天 → 後天.
        let relativeDays = ["大後天", "前天", "後天", "昨天", "今天", "明天"]
        for newDay in relativeDays where replacement.hasPrefix(newDay) {
            for oldDay in relativeDays where oldDay != newDay {
                guard let oldDayRange = old.range(of: oldDay, options: .backwards) else { continue }
                let newSuffix = String(replacement.dropFirst(newDay.count))
                if let result = replaceAlignedToken(in: old, range: oldDayRange, with: newDay, suffix: newSuffix) {
                    return result
                }
            }
        }

        // Stable weekday prefix and one-character value: 星期三 → 星期四, 禮拜三 → 禮拜四.
        let weekday = try! NSRegularExpression(pattern: "(星期|禮拜|週|周)([一二三四五六日天])")
        let oldDays = weekday.matches(in: old, range: oldRange)
        let newDays = weekday.matches(in: replacement, range: newRange)
        for newDay in newDays {
            guard let newTokenRange = Range(newDay.range, in: replacement),
                  let newPrefixRange = Range(newDay.range(at: 1), in: replacement) else { continue }
            let newLead = String(replacement[..<newTokenRange.lowerBound])
            let newModifier = weekdayModifiers.first(where: { newLead.hasSuffix($0) }) ?? ""
            for oldDay in oldDays.reversed() {
                guard oldDay.range(at: 1).length == newDay.range(at: 1).length,
                      let oldTokenRange = Range(oldDay.range, in: old),
                      let oldPrefixRange = Range(oldDay.range(at: 1), in: old),
                      old[oldPrefixRange] == replacement[newPrefixRange] else { continue }
                let oldLead = String(old[..<oldTokenRange.lowerBound])
                let oldModifier = newModifier.isEmpty
                    ? ""
                    : weekdayModifiers.first(where: { oldLead.hasSuffix($0) }) ?? ""
                let oldExpressionStart = old.index(oldTokenRange.lowerBound, offsetBy: -oldModifier.count)
                let oldExpressionRange = oldExpressionStart..<oldTokenRange.upperBound
                let newSuffix = String(replacement[newTokenRange.upperBound...])
                if let result = replaceAlignedToken(in: old, range: oldExpressionRange,
                                                    with: newModifier + String(replacement[newTokenRange]),
                                                    suffix: newSuffix) {
                    return result
                }
            }
        }

        // Numeric and version tokens align when their non-numeric shape matches (48K → 96K, V3 → V4).
        // 小數是一整個值（C3）：44.1K → 48K、1.5倍 → 2倍、1.2 → 1.3，不能只換小數點後面那段（以前變 44.48K、1.2倍、1.1.3）。
        // 鐘點「3:30」也是一整個值（FX-6 T2）：以前在「:」拆開，「3:30，不對，4:00」→「3:4:00」；緊貼「數字:」的數字不單獨當一個值。
        // 小數＋位值也是一整個值（FX-8 D2／D4）：「一點五萬」「三點五千」「兩點八百」以前拆成「一點」＋「五萬」，
        // 改口就落在小數裡面（還差一點五萬，不對，還差兩萬 → 還差一點20,000），或把「三點」當鐘點換掉（三點一萬塊，不對，四點 → 四點10,000塊）。
        // 小數點後面念零～九（不念兩），後面不再接數字（三點五千五百照舊拆）。形狀是「#點#」，只跟小數對齊（一點二萬 → 一點五萬）；
        // 小數對整數（兩萬）或整點（四點）對不上＝整句照講的留著。
        let token = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])(?<![0-9][:：])(?:[0-9]{1,2}[:：][0-9]{2}|[零〇一二三四五六七八九十兩两]+[點点][零〇一二三四五六七八九]{1,3}[百千萬万億亿](?![0-9零〇一二三四五六七八九十百千萬万億亿兩两])|[A-Za-z_]*[0-9]+(?:\\.[0-9]+)*[A-Za-z0-9_]*|[0-9零〇一二三四五六七八九十百千萬万億亿兩两]+(?:點|点|樓|楼|層|层|號|号|塊|块|元|K|k)?)(?![A-Za-z0-9_])(?![:：][0-9])")
        let numberRun = "[0-9]+(?:\\.[0-9]+)+|[0-9零〇一二三四五六七八九十百千萬万億亿兩两]+"
        let oldTokens = token.matches(in: old, range: oldRange)
        let newTokens = token.matches(in: replacement, range: newRange)
        for newMatch in newTokens {
            guard let newTokenRange = Range(newMatch.range, in: replacement),
                  !startsWithWeekdayDigit(replacement, newTokenRange) else { continue }
            let newToken = String(replacement[newTokenRange])
            let newShape = newToken.replacingOccurrences(of: numberRun, with: "#", options: .regularExpression).lowercased()
            for oldMatch in oldTokens.reversed() {
                guard var oldTokenRange = Range(oldMatch.range, in: old) else { continue }
                // FX-8 D1：「禮拜五三點」的值是「三點」，星期幾那個字留在值外面（以前「禮拜五三點，不對，四點」→「禮拜四點」）。
                // FX-12 C1：第N 後接鐘點時，序數的一～九也留在值外面；第十N／第二十照舊。
                let hasOrdinalClock = startsWithOrdinalClockDigit(old, oldTokenRange)
                if startsWithWeekdayDigit(old, oldTokenRange) || hasOrdinalClock {
                    oldTokenRange = old.index(after: oldTokenRange.lowerBound)..<oldTokenRange.upperBound
                }
                let oldToken = String(old[oldTokenRange])
                let oldShape = oldToken.replacingOccurrences(of: numberRun, with: "#", options: .regularExpression).lowercased()
                let sameNumberWithAddedUnit = newToken.hasPrefix(oldToken) && newToken.count > oldToken.count
                guard oldShape == newShape || sameNumberWithAddedUnit else { continue }
                let newSuffix = String(replacement[newTokenRange.upperBound...])
                if let clock = clockHourCorrection(old: old, oldTokenRange: oldTokenRange, newToken: newToken, newSuffix: newSuffix) {
                    return clock
                }
                if let result = replaceAlignedToken(in: old, range: oldTokenRange, with: newToken, suffix: newSuffix) {
                    // C1：鐘點先獨立讀完，避免下一關把「第二＋十點」又併成20:00。
                    if hasOrdinalClock {
                        let prefix = String(old[..<oldTokenRange.lowerBound])
                        return prefix + normalizeNumbers(String(result.dropFirst(prefix.count)))
                    }
                    return result
                }
            }
        }

        // Shared opening phrase aligns short edits such as 小雅跟小博 → 小雅跟小潘.
        let newCharacters = Array(replacement)
        guard newCharacters.count >= 2 else { return nil }
        for length in stride(from: newCharacters.count, through: 2, by: -1) {
            let anchor = String(newCharacters.prefix(length))
            guard let range = old.range(of: anchor, options: .backwards) else { continue }
            let oldTail = old[range.upperBound...]
            let newTail = String(newCharacters.dropFirst(length))
            // A longer unmatched tail may be context, so decline instead of deleting it.
            guard oldTail.count <= newTail.count + 1 else { continue }
            guard !newTail.isEmpty else { continue }
            return String(old[..<range.lowerBound]) + anchor + newTail
        }
        // A one-grapheme shared opening also anchors a correction: 剛上去 → 剛出門.
        // 單字錨點只認虛詞／副詞（剛、在、去…）：實詞的字可能在別的詞中間（「台南玩」對「南投下雨」會誤接成「台南投」）。
        let anchor = String(newCharacters[0])
        guard singleCharAnchors.contains(anchor), let range = old.range(of: anchor, options: .backwards) else { return nil }
        let oldTail = old[range.upperBound...]
        let newTail = String(newCharacters.dropFirst())
        guard oldTail.count <= newTail.count + 1, !newTail.isEmpty else { return nil }
        return String(old[..<range.lowerBound]) + anchor + newTail
    }

    static let singleCharAnchors: Set<String> = ["剛", "在", "去", "到", "要", "是", "給", "跟", "把", "從", "往", "用", "叫", "先", "再", "就", "還", "也", "都", "會", "想", "和", "對"]

    /// FX-8 D1：抓到的值第一個字是緊跟在「星期／禮拜／礼拜／週／周」後面的星期幾（一～六）、後面還接數字、而且是「N點」
    /// （鐘點或小數）＝那個字是星期幾，不是鐘點的一部分（「禮拜五三點」「週三十點」「星期二十二點零五分」）。
    /// 不帶「點」的（一個禮拜三十個小時、每週三十個）照舊：那可以是「每週 30 個」。
    /// FX-12 C1：只有第＋一個一～九＋鐘點才拆序數，非鐘點與第十N照舊。
    private static func startsWithOrdinalClockDigit(_ text: String, _ range: Range<String.Index>) -> Bool {
        let value = String(text[range])
        return value.contains(where: { $0 == "點" || $0 == "点" })
            && ordinalMerges(value, before: String(text[..<range.lowerBound]))
    }

    private static func startsWithWeekdayDigit(_ text: String, _ range: Range<String.Index>) -> Bool {
        let value = text[range]
        guard let first = value.first, "一二三四五六".contains(first),
              let second = value.dropFirst().first, "零〇一二三四五六七八九十兩两".contains(second),
              value.contains(where: { $0 == "點" || $0 == "点" }) else { return false }
        // FX-12 C2：三十點五小時等十位小數＋明確數量單位是每週的數量，不拆三當星期幾。
        let tail = String(text[range.upperBound...])
        if second == "十", value.last == "點" || value.last == "点",
           tail.range(of: "^[零〇一二三四五六七八九]{1,3}(?:個?小時|公里|公斤|分鐘)", options: .regularExpression) != nil { return false }
        let before = text[..<range.lowerBound]
        return ["星期", "禮拜", "礼拜", "週", "周"].contains { before.hasSuffix($0) }
    }

    /// Keep an existing tail when it agrees with the replacement; decline mismatched tails.
    private static func replaceAlignedToken(in old: String, range: Range<String.Index>, with token: String, suffix: String) -> String? {
        joinAligned(prefix: String(old[..<range.lowerBound]), token: token, oldSuffix: String(old[range.upperBound...]), suffix: suffix)
    }

    private static func joinAligned(prefix: String, token: String, oldSuffix: String, suffix: String) -> String? {
        if suffix.isEmpty || oldSuffix.contains(suffix) { return prefix + token + oldSuffix }
        if oldSuffix.isEmpty || suffix.hasSuffix(oldSuffix) { return prefix + token + suffix }
        return nil
    }

    /// 鐘點的分鐘（FX-6 T1）：半、一刻／三刻、N分（不是「分鐘」）、不帶「分」的十五／四十／零五（後面不能再接數字或量詞）。
    private static let clockMinutes = try! NSRegularExpression(pattern: "\\A(?:半|[一三]刻|[0-9]{1,2}分(?!鐘)|[零〇一二三四五六七八九十]{1,3}分(?!鐘)|(?:[二三四五]?十[一二三四五六七八九]?|[零〇][一二三四五六七八九])(?![零〇一二三四五六七八九十百千萬万億亿兩两0-9.分秒個个位人塊块元倍度]))")

    private static func clockMinutesPrefix(_ text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = clockMinutes.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }

    /// FX-6 T1：改口後的鐘點換掉整個舊時間。舊值是「N點＋分鐘」（三點半、三點十五分）、新值只有整點（四點）→ 舊的分鐘一起拿掉，
    /// 寫成「4:00」（舊時間在數字關會寫成 3:30，同一種寫法；以前只換「N點」、留著舊分鐘：三點半，不對，四點 → 4:30）。
    /// 新值自己有分鐘（四點半）、或舊值沒有分鐘＝不是這種形狀，回 nil 照原本的對齊。
    /// 是這種形狀但讀不出 0～24 點（「禮拜五三點半」的「五三」）或前後對不齊＝回 .some(nil)，整句照講的留著。
    private static func clockHourCorrection(old: String, oldTokenRange: Range<String.Index>, newToken: String, newSuffix: String) -> String?? {
        let points: Set<Character> = ["點", "点"]
        var oldHour = old[oldTokenRange], oldRest = old[oldTokenRange.upperBound...]
        if let last = oldHour.last, points.contains(last) { oldHour = oldHour.dropLast() }
        else if let first = oldRest.first, points.contains(first) { oldRest = oldRest.dropFirst() }
        else { return nil }
        var newHour = Substring(newToken), newRest = Substring(newSuffix)
        if let last = newHour.last, points.contains(last) { newHour = newHour.dropLast() }
        else if let first = newRest.first, points.contains(first) { newRest = newRest.dropFirst() }
        else { return nil }
        guard let minutes = clockMinutesPrefix(String(oldRest)), clockMinutesPrefix(String(newRest)) == nil else { return nil }
        guard let oh = chineseToInt(String(oldHour)), (0...24).contains(oh),
              let nh = chineseToInt(String(newHour)), (0...24).contains(nh) else { return .some(nil) }
        return .some(joinAligned(prefix: String(old[..<oldTokenRange.lowerBound]), token: "\(nh):00",
                                 oldSuffix: String(String(oldRest).dropFirst(minutes.count)), suffix: String(newRest)))
    }

    private static func findCorrection(_ s: String) -> (String.Index, String.Index, String.Index)? {
        // 單獨的改口詞：「，不是，」→ 當成「應該說」處理（afterMarker 跳過後面的逗號）。
        for marker in standaloneCorrections {
            var search = s.startIndex..<s.endIndex
            while let r = s.range(of: marker, range: search) {
                var beforeMarker = r.lowerBound
                while beforeMarker > s.startIndex, isCorrectionWhitespace(s[s.index(before: beforeMarker)]) {
                    beforeMarker = s.index(before: beforeMarker)
                }
                var afterMarker = r.upperBound
                while afterMarker < s.endIndex, isCorrectionWhitespace(s[afterMarker]) {
                    afterMarker = s.index(after: afterMarker)
                }
                let hasCommaBefore = beforeMarker > s.startIndex && "，,".contains(s[s.index(before: beforeMarker)])
                let hasCommaAfter = afterMarker < s.endIndex && "，,".contains(s[afterMarker])
                if hasCommaBefore && hasCommaAfter {
                    let comma = s.index(before: beforeMarker)
                    let breakers: Set<Character> = ["，", ",", "。", "！", "？", "!", "?", "\r", "\n", "\r\n"]
                    var start = comma
                    while start > s.startIndex, !breakers.contains(s[s.index(before: start)]) { start = s.index(before: start) }
                    if start < comma { return (start, comma, r.upperBound) }
                }
                search = r.upperBound..<s.endIndex
            }
        }
        for marker in correctionMarkerWords {
            var search = s.startIndex..<s.endIndex
            while let r = s.range(of: marker, range: search) {
                // 前面緊接逗號（容許空白）
                var p = r.lowerBound
                while p > s.startIndex, isCorrectionWhitespace(s[s.index(before: p)]) {
                    p = s.index(before: p)
                }
                if p > s.startIndex, "，,".contains(s[s.index(before: p)]) {
                    let comma = s.index(before: p)
                    let breakers: Set<Character> = ["，", ",", "。", "！", "？", "!", "?", "\r", "\n", "\r\n"]
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
        //    星期幾的數字不跟後面的鐘點黏在一起（FX-2 v2 N3）：「禮拜五三點半」＝禮拜五＋3:30，不是「禮拜53:30」。
        out = applyRegex(out, pattern: "([\\d零〇一二三四五六七八九十兩]{1,3})點(半|十五分|三十分|四十五分|([\\d零〇一二三四五六七八九十]{1,3})分|(?=[開出到交會鐘]))") { groups, before, after in
            var hourRun = groups[1], lead = ""
            //    序數「第N」的那個數字也不併進鐘點（FX-11 E4）：「第一三點開會」＝第一＋3:00，不是「第13:00」。
            if Normalizer.weekdayMerges(hourRun, before: before) || Normalizer.ordinalMerges(hourRun, before: before) {
                // 拆掉星期幾後不是 0～24 點、或「星期三十一點二分鐘」（11:02 還是 11.2 分鐘講不準）＝整段照講的留著。
                let scalars = hourRun.unicodeScalars
                let rest = String(String.UnicodeScalarView(scalars.dropFirst()))
                guard groups[3].isEmpty || after.unicodeScalars.first != "鐘",
                      let hour = Normalizer.chineseToInt(rest), (0...24).contains(hour) else { return groups[0] }
                lead = String(String.UnicodeScalarView(scalars.prefix(1)))
                hourRun = rest
            }
            let h = lead + (Normalizer.chineseToInt(hourRun).map(String.init) ?? hourRun)
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
        // 前面已經是數字／千分位逗號／小數點＝在數字中間，不能從那裡開始讀：「12,000塊」原本只抓到「000塊」→ 變「12,0塊」
        //（2026-10-19 Typeless 對打真人錄音抓到；貼出去的文字也會錯）。
        // 數字和 塊／元 中間可以有一個空白（Claude 會寫「1250 塊」，2026-10-22 Typeless 對打 nd02）；只認空白／不換行空白，
        // 不認換行（清單一行結尾的數字不能跟下一行開頭的「元」黏在一起）。原本的空白照留。
        // 概數、單獨的萬／億、星期幾、共用位值的範圍＝整段照講的留著（leavesSpoken，FX-2 v2）。
        out = applyRegex(out, pattern: "(?<![\\d,，.])([\\d零〇一二三四五六七八九十百千萬億兩]{1,15})(?:([ \\u00A0]?)(元|塊|圓)|( dollars?))") { groups, before, after in
            let unit = groups[2] + groups[3] + groups[4]
            if Normalizer.leavesSpoken(groups[1], before: before, after: unit + after) { return groups[0] }
            // 小數＋萬／億＋單位（FX-11）：「一點五萬塊」的「五萬」是小數的一部分，交給小數規則 9 整段讀（15,000塊）。
            if Normalizer.isDecimalWanYiTail(groups[1], before: before, after: unit + after) { return groups[0] }
            if let v = Normalizer.chineseToInt(Normalizer.colloquial(groups[1])) {
                return "\(Normalizer.formatThousands(v))\(unit)"
            }
            return groups[1] + unit
        }

        // 2026-09-24 實機回報（Fast 模式講數字不轉）：以下規則都在金額之後，避免金額規則重讀已轉好的「35,000」。
        let digit = "零〇一二三四五六七八九"
        let numeral = "零〇一二三四五六七八九十百千萬億兩"
        let technicalNumeral = "零〇一二三四五六七八九十百千兩"
        let technicalUnits = "kHz|Hz|kbps|Kbps|Mbps|K|k|bits|bit|dBFS|dBTP|dB|LUFS|LKFS|LU|ms|fps|MB|GB|TB|%"
        // 前面是這些＝不是一個確定的數（幾十個、好幾百、上百人、十多）；不轉。
        let vague = "\\d幾好數多上來餘"

        // 6. 百分比：「百分之二十」「百分之三點五」
        //    概數的百分比（百分之十幾、二十來、五十多、十餘）整段照講的留著：以前轉成「10%幾」（FX-6 T5）。
        out = applyRegex(out, pattern: "百分之([\(numeral)]{1,5})(?:點([\(digit)]{1,3}))?") { groups, _, after in
            if let next = after.unicodeScalars.first, Normalizer.vaguePercentFollowers.contains(next) { return groups[0] }
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
        // 8c. 對比／替代的另一個整點跟著同一句已經轉好的寫法（2026-10-22 W2-6：「我們約三點開會，不是四點」原本只轉前一個）。
        out = alignContrastedHours(out, original: text)

        // 9. 小數＋單位：「三點五公斤」（「三點五分」是時間，上面已處理）
        out = applyRegex(out, pattern: "(?<![\(numeral)\\d])([\(numeral)]{1,5})點([\(digit)]{1,3})(公斤|公里|公尺|公分|公升|倍|度|秒|個百分點|吋|寸|歲|小時|個小時|萬|億|G|GB|TB|K|kHz|Hz|dB)") { groups, before, after in
            guard !Normalizer.leavesSpoken(groups[1], before: before, after: "點" + groups[2] + groups[3] + after),
                  let whole = Normalizer.chineseToInt(groups[1]) else { return groups[0] }
            let fraction = groups[2].compactMap { Normalizer.chineseToInt(String($0)).map(String.init) }.joined()
            return "\(whole).\(fraction)\(groups[3])"
        }

        // 9b. 中文數字＋技術單位、負數（2026-10-22 Typeless 對打 ls04／ls05／sc05）：「九十六 kHz」→「96 kHz」、
        //     「負十四 LUFS」→「-14 LUFS」、「九十六K」→「96K」。數字跟單位中間的空白照留，但只認一個空白（不跨行）。
        //     不能從數字中間開始讀；單獨一個「一」緊接在中文字後面是詞的一部分（唯一、統一、之一），不轉（「負一」照轉）。
        out = applyRegex(out, pattern: "(?<![\(numeral)0-9])(負)?([\(technicalNumeral)]{2,}|[零〇二三四五六七八九十百千兩]|(?<=負)一|(?<![\\u4E00-\\u9FFF])一|一(?=點))(?:點([\(digit)]+))?( ?)(\(technicalUnits))(?![A-Za-z])") { groups, before, after in
            let run = groups[2], fractionDigits = groups[3]
            let tail = (fractionDigits.isEmpty ? "" : "點" + fractionDigits) + groups[4] + groups[5] + after
            if Normalizer.leavesSpoken(run, before: before + groups[1], after: tail) { return groups[0] }
            let spoken = fractionDigits.isEmpty ? Normalizer.colloquial(run) : run
            // 「一百二點五」這種口語省略＋小數講法不確定是多少，不猜。
            guard fractionDigits.isEmpty || spoken == Normalizer.colloquial(run),
                  let whole = Normalizer.chineseToInt(spoken) else { return groups[0] }
            let fraction = fractionDigits.compactMap { Normalizer.chineseToInt(String($0)).map(String.init) }.joined()
            return (groups[1].isEmpty ? "" : "-") + "\(whole)" + (fraction.isEmpty ? "" : ".\(fraction)") + groups[4] + groups[5]
        }

        // 9c. 阿拉伯數字＋萬／億（2026-10-22 Typeless 對打 nd05：「30萬」「10萬5」原樣留著，LLM 再寫成 100,000 也沒人發現）→ 完整數值。
        //     跟「三十萬」→「300,000」同一種寫法，兩個閘門兩邊正規化後才會一致。放在小數規則之後：「一點五萬」→「1.5萬」→「15,000」一次到位。
        //     一位數尾巴＝口語省略單位（10萬5＝105,000、2億5＝250,000,000）；多位數尾巴照字面（10萬5000＝105,000）。
        //     後面還接數字或中文數字（3萬五千、3萬一直）、算不出整數、3億5000（不知道是 5000 還是 5000 萬）＝不確定，不動。
        //     後面隔一個空白又是數字（10 萬 5000、30萬 2026年）也不動：分不出是尾巴還是下一個數，讀錯會變成「100,000 5,000」。
        //     「11:32萬」的 32 是鐘點的分鐘，不從那裡開始讀（FX-6 T3）。
        out = applyRegex(out, pattern: "(?<![0-9.,萬億:：])([0-9]+)(?:\\.([0-9]+))? ?(萬|億)(?:([0-9]{1,4}) ?萬)?(?:([0-9]{1,4})(千)?)?(?![0-9\(numeral)]|[.,][0-9]| [0-9])") { groups, before, after in
            if Normalizer.leavesSpoken(groups[0], before: before, after: after) { return groups[0] }
            return Normalizer.arabicWanYiValue(integer: groups[1], fraction: groups[2], unit: groups[3],
                                        wanSection: groups[4], tail: groups[5], thousand: !groups[6].isEmpty)
                .map(Normalizer.formatThousands) ?? groups[0]
        }

        // 10. 千以上的數字（含口語「三萬五」「兩千五」）：「預算大概三萬五」→「35,000」。
        //     必須以數字開頭：「千萬不要」不轉。
        out = applyRegex(out, pattern: "(?<![\(numeral)\(vague)])([一二兩三四五六七八九十][\(numeral)]*[千萬億][\(numeral)]*)(?![\(numeral)\\d])") { groups, before, after in
            guard !Normalizer.leavesSpoken(groups[1], before: before, after: after),
                  let v = Normalizer.chineseToInt(Normalizer.colloquial(groups[1])), v >= 1000 else { return groups[0] }
            return Normalizer.formatThousands(v)
        }

        // 11. 數字＋單位，數值 ≥ 10：「十五分鐘」→「15分鐘」；「三個問題」「一下」「十分好」不動。
        out = applyRegex(out, pattern: "(?<![\(numeral)\(vague)第])([\(numeral)]{1,6})(分鐘|秒鐘|秒|小時|個小時|天|週|個禮拜|個星期|個月|年|歲|公斤|公里|公尺|公分|公升|度|人|次|張|頁|首|軌|個|位|本|台|支|件|題|篇|集|樓)") { groups, before, after in
            // 「三四五個人」＝概數：沒有十／百／千這類位值字的逐位數字不轉。
            guard groups[1].contains(where: { "十百千萬億".contains($0) }),
                  !Normalizer.leavesSpoken(groups[1], before: before, after: groups[2] + after),
                  let v = Normalizer.chineseToInt(Normalizer.colloquial(groups[1])), v >= 10 else { return groups[0] }
            return "\(v)\(groups[2])"
        }

        // 12. 逐位念的數字（至少 3 位）：「一二三四五」「零九一二…」→ 阿拉伯數字；
        //     「一五一十」「九九八十一」這種成語中間有十，不會整段成立；後面接量詞（三四五個人）＝概數，不轉。
        //     星期幾的數字不併進來（「禮拜五三四點」不是「禮拜534點」，FX-2 v2 N3）。
        out = applyRegex(out, pattern: "(?<![\(numeral)\\d])([\(digit)]{3,})(十)?(?![\(numeral)\\d個人天次位年歲種隻本件])") { groups, before, _ in
            let run = groups[1]
            if !groups[2].isEmpty && run.last != "九" { return groups[0] }
            if Normalizer.weekdayMerges(run, before: before) { return groups[0] }
            let digits = run.compactMap { Normalizer.chineseToInt(String($0)).map(String.init) }.joined()
            return digits + (groups[2].isEmpty ? "" : "10")
        }

        // 13. 台灣電話（2026-10-22 Typeless 對打 nd03）：手機「0912-345-678」、台北市話「02-2333-3333」；其他區碼不動。
        //     兩個閘門兩邊都跑這裡，LLM 自己排好的電話才不會被嚴格閘門整段擋掉。前後接數字／字母／小數點＝序號或小數，不動。
        out = applyRegex(out, pattern: "(?<![0-9A-Za-z.\\-])(09[0-9]{2})[- ]?([0-9]{3})[- ]?([0-9]{3})(?![0-9A-Za-z\\-])") { groups in
            "\(groups[1])-\(groups[2])-\(groups[3])"
        }
        out = applyRegex(out, pattern: "(?<![0-9A-Za-z.\\-])02[- ]?([0-9]{4})[- ]?([0-9]{4})(?![0-9A-Za-z\\-])") { groups in
            "02-\(groups[1])-\(groups[2])"
        }
        return out
    }

    /// 「30萬」「10萬5」「1.5萬」「3億5000萬」「3萬2千」→ 數值（規則 9c）；講法不確定就回 nil，原文不動。
    static func arabicWanYiValue(integer: String, fraction: String, unit: String,
                                 wanSection: String, tail: String, thousand: Bool) -> Int? {
        let unitValue = unit == "億" ? 100_000_000 : 10_000
        // 「X萬Y萬」沒有意思；「Y萬」那段只跟在億後面。
        if unit == "萬" && !wanSection.isEmpty { return nil }
        // 小數後面再接尾巴（1.5萬3）講法不確定。
        if !fraction.isEmpty && !(wanSection.isEmpty && tail.isEmpty) { return nil }
        func add(_ a: Int, _ b: Int) -> Int? { let r = a.addingReportingOverflow(b); return r.overflow ? nil : r.partialValue }
        func mul(_ a: Int, _ b: Int) -> Int? { let r = a.multipliedReportingOverflow(by: b); return r.overflow ? nil : r.partialValue }
        guard let whole = Int(integer), var value = mul(whole, unitValue) else { return nil }
        if !fraction.isEmpty {
            guard fraction.count <= 8, let f = Int(fraction) else { return nil }
            let scale = (0..<fraction.count).reduce(1) { acc, _ in acc * 10 }
            let scaled = f * unitValue
            guard scaled % scale == 0, let sum = add(value, scaled / scale) else { return nil }
            value = sum
        }
        var lastUnit = unitValue
        if !wanSection.isEmpty {
            guard let w = Int(wanSection), let sum = add(value, w * 10_000) else { return nil }
            value = sum
            lastUnit = 10_000
        }
        guard !tail.isEmpty, let t = Int(tail) else { return tail.isEmpty ? value : nil }
        let addition: Int
        if thousand {
            // 「3萬2千」：只認一位數，而且前一個位值是萬。
            guard tail.count == 1, lastUnit == 10_000 else { return nil }
            addition = t * 1_000
        } else if tail.count == 1 {
            // 口語省略單位：10萬5＝10萬5千、2億5＝2億5千萬。
            addition = t * (lastUnit / 10)
        } else {
            // 多位數照字面，只認萬底下（3億5000 不知道是 5000 還是 5000 萬）。
            guard lastUnit == 10_000 else { return nil }
            addition = t
        }
        return add(value, addition)
    }

    /// 規則 8c：「不是／還是／或是／或者／而是／或」帶出來、自己收在子句結尾的中文整點（「，不是四點」「還是五點吧」），
    /// 跟著同一句（句界同 `splitSentences`）裡最近一個**這次由鐘點規則轉出來**的寫法：「3:00」那邊 →「4:00」、「3點」那邊 →「4點」。
    /// 這句沒有轉好的鐘點就不動（「我要的是三點不是四點」兩個都留中文，本來就一致）；
    /// 原文本來就寫好的數字（「比數是3:05，不是四點」）不算鐘點，不跟（2026-10-22 修正）；
    /// 對比的是「幾點（重點）」不是幾點鐘時不動（2026-10-22 修正，第二輪改成看「對比的是誰」）：
    /// ・對比的對象＝對比詞前面最近的一個「N點」。它是沒轉的中文 N點（數量：「重點有三點，不是四點」，鐘點在後面也一樣）、
    ///   或原文本來就寫好的數字 → 不動；只有它是這次轉出來的鐘點才對齊（鐘點只在候選後面＝沒有可對的，不動）。
    /// ・對比詞那一小段（上一個逗號之後）前面有別的主詞（「議程還是兩點」「要報告的還是三點」「重點還是兩點」）＝在講那個東西，不動；
    ///   只有對比詞直接開頭（「，不是四點」）、前面只有時間詞或語氣副詞（「下午還是兩點」「應該不是四點」）、
    ///   或同一小段裡就是那個鐘點（「三點開會還是四點」）才算。
    /// 單獨的「一點」不收（「不是一點點」「還是一點」常是「一些」）；後面還接數字／半／分＝別的講法，不動。
    /// 只改寫法、不碰改口與對比的判斷（那些在 applySelfCorrection／CleanupFidelity）。
    static let contrastedHourPattern = "(不是|還是|或是|或者|而是|或)([一二兩三四五六七八九十]{1,3})點(?![點半分鐘零〇一二三四五六七八九十百千萬億兩\\d])(?=[，,。！？!?、；;\\s喔哦啦吧呢耶欸]|$)"
    static let convertedHourPattern = "(?<![\\d:.,])\\d{1,2}(?::[0-5]\\d|點)(?!\\d)"
    /// 沒轉成數字的中文「N點」＝在數重點（時間的「N點」到這裡都已經轉好了）；本身也是對比候選的（還是三點，還是四點）不算。
    static let countedPointsPattern = "(?<![零〇一二兩三四五六七八九十]|不是|還是|或是|或者|而是|或)[零〇一二兩三四五六七八九十]+點"
    /// 對比詞前面這一小段裡、不是接在數字後面的「點」（重點、要點、三點…）。
    static let pointNounPattern = "(?<!\\d)點"
    /// 對比詞前面這一小段裡可以有的字：時間詞與不帶主詞的副詞（下午還是兩點、應該不是四點）；拿掉這些還剩東西＝另有主詞。
    static let contrastClauseFillerPattern = "今天|明天|後天|昨天|今晚|明晚|早上|上午|中午|下午|晚上|凌晨|傍晚|應該|可能|也許|或許|大概|還|也|就|都|那|是|[ \\t]"

    static func alignContrastedHours(_ text: String, original: String) -> String {
        guard text.contains("點"),
              let candidate = try? NSRegularExpression(pattern: contrastedHourPattern),
              let converted = try? NSRegularExpression(pattern: convertedHourPattern) else { return text }
        func tally(_ s: String) -> [String: Int] {
            let ns = s as NSString
            var counts: [String: Int] = [:]
            for m in converted.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                counts[ns.substring(with: m.range), default: 0] += 1
            }
            return counts
        }
        let before = tally(original)
        let produced = Set(tally(text).filter { $0.value > (before[$0.key] ?? 0) }.keys)
        guard !produced.isEmpty else { return text }
        let counted = try? NSRegularExpression(pattern: countedPointsPattern)
        // 半形「:」不算子句分隔（3:00 裡面就有一個）。
        let separators = CharacterSet(charactersIn: "，,、；;：")
        var out = ""
        for sentence in splitSentences(text) {
            let ns = sentence as NSString
            let full = NSRange(location: 0, length: ns.length)
            let times = converted.matches(in: sentence, range: full).map(\.range)
            guard times.contains(where: { produced.contains(ns.substring(with: $0)) }) else { out += sentence; continue }
            // 句子裡所有的「N點」：轉好的鐘點與沒轉的中文 N點（數量）。
            let points = times + (counted?.matches(in: sentence, range: full).map(\.range) ?? [])
            var result = sentence
            for match in candidate.matches(in: sentence, range: full).reversed() {
                let run = ns.substring(with: match.range(at: 2))
                guard run != "一", let hour = chineseToInt(run), (1...24).contains(hour) else { continue }
                let start = match.range(at: 2).location
                let contrast = match.range(at: 1).location
                let hourRange = NSRange(location: start, length: match.range.location + match.range.length - start)
                // 對比的對象：對比詞前面最近的一個 N點；要是這次轉出來的鐘點才對齊。
                guard let anchor = points.filter({ $0.location + $0.length <= contrast }).max(by: { $0.location < $1.location }),
                      produced.contains(ns.substring(with: anchor)),
                      let range = Range(hourRange, in: result) else { continue }
                // 對比詞那一小段：直接開頭，或錨點就在這一小段裡；前面另有主詞＝在講那個東西。
                let head = ns.substring(to: contrast) as NSString
                let separator = head.rangeOfCharacter(from: separators, options: .backwards)
                let clauseStart = separator.location == NSNotFound ? 0 : separator.location + separator.length
                let clause = head.substring(from: clauseStart)
                if anchor.location < clauseStart,
                   !clause.replacingOccurrences(of: contrastClauseFillerPattern, with: "", options: .regularExpression).isEmpty { continue }
                if clause.range(of: pointNounPattern, options: .regularExpression) != nil { continue }
                result.replaceSubrange(range, with: ns.substring(with: anchor).contains(":") ? "\(hour):00" : "\(hour)點")
            }
            out += result
        }
        return out
    }

    // MARK: 整段照講的留著（FX-2 v2，2026-10-22）
    // 規則 5／9／9b／9c／10／11 共用：一段數字有兩種讀法、或根本不是一個確定的數，就整段照原文，不轉、也不轉一半。

    private static let spokenDigitScalars = Set("一二兩三四五六七八九".unicodeScalars)
    private static let magnitudeScalars = Set("十百千萬億".unicodeScalars)
    private static let numeralScalars = Set("零〇一二三四五六七八九十百千萬億兩".unicodeScalars)
    private static let rangeRunScalars = Set("零〇一二三四五六七八九十百千萬億兩0123456789.,".unicodeScalars)
    private static let rangeMarkScalars = Set("到至～~".unicodeScalars)
    /// 小數點後面念的數字（不含「兩」，FX-6 T4）。
    private static let decimalDigitScalars = Set("零〇一二三四五六七八九".unicodeScalars)
    /// 百分比後面接這些＝概數（百分之十幾、二十來、五十多、十餘），整段照講的留著（FX-6 T5）。
    static let vaguePercentFollowers = Set("幾几來来多餘余".unicodeScalars)

    /// `run` 是規則抓到的那段數字，`before`／`after` 是它緊鄰的前後文（同一步的輸入，各最多幾十個字）。
    static func leavesSpoken(_ run: String, before: String, after: String) -> Bool {
        let r = Array(run.unicodeScalars), b = Array(before.unicodeScalars)
        guard let first = r.first else { return false }
        // N1 前面沒有確定數字的萬／億：「幾萬塊」「數萬元」「萬元戶」（舊版讀成 0）。
        if first == "萬" || first == "億" { return true }
        // N1 位值字開頭、前面（隔行內空白也算）是概數字或數字：「幾十」「數百」「上千」「一兩 百 ms」「3 千 塊」。
        //    這個位值屬於前面那個數，不能自己讀成 10／100／1,000（「上十」不是概數講法）。
        if magnitudeScalars.contains(first) {
            var k = b.count
            while k > 0, b[k - 1] == " " || b[k - 1] == "\u{00A0}" || b[k - 1] == "\u{3000}" { k -= 1 }
            if k > 0 {
                let p = b[k - 1]
                if p == "幾" || p == "數" || (p == "上" && first != "十") || numeralScalars.contains(p) || ("0"..."9").contains(p) { return true }
            }
        }
        let hasMagnitude = r.contains(where: { magnitudeScalars.contains($0) })
        // N1「三、四十」：頓號前一個數字、後面帶位值＝兩個數一起講的概數（「第一、五千塊」是清單，不算）。
        if hasMagnitude, b.count >= 2, b[b.count - 1] == "、", spokenDigitScalars.contains(b[b.count - 2]),
           b.count < 3 || b[b.count - 3] != "第" { return true }
        // N1「一兩萬」「三四十」「兩三百」：兩個數字連著講再接位值＝概數。
        if hasMagnitude,
           zip(r, r.dropFirst()).contains(where: { spokenDigitScalars.contains($0) && spokenDigitScalars.contains($1) }) { return true }
        // N3 星期幾的數字不跟後面的數字黏在一起：「禮拜五十萬」「星期三十分鐘」「一週五十個小時」分不出來，不轉。
        if weekdayMerges(run, before: before) { return true }
        // N5 共用位值的範圍：「三到五萬」「一千到兩千萬」「三十到五十萬」只讀得出一半＝整段不讀。
        if let start = rangeNeighbour(Array(b.reversed()), forward: false), sharesMagnitude(start: Array(start.reversed()), end: r) { return true }
        if let end = rangeNeighbour(Array(after.unicodeScalars), forward: true), sharesMagnitude(start: r, end: end) { return true }
        // T4（FX-6）小數＋千：「一點五千」可以是 1,500，也可以是「差一點」＋5,000；「三點五千米」也一樣。前面緊接「數字＋點」、
        //    這段是「數字＋千…」＝整段照講的留著，不轉成一半（以前「一點5,000元」）。萬交給小數規則 9（一點五萬＝15,000）。
        //    小數點後面不會念「兩」：「三點兩千塊」只有鐘點＋2,000 一種讀法，照舊轉。
        //    百也一樣（FX-8 D3）：「一點五百元」可以是 150 元，也可以是「一點」＋500 元；以前轉成一半「一點500元」。
        if let m = r.firstIndex(where: { magnitudeScalars.contains($0) }), m > 0, r[m] == "千" || r[m] == "百",
           r[..<m].allSatisfy({ decimalDigitScalars.contains($0) }),
           b.count >= 2, b[b.count - 1] == "點" || b[b.count - 1] == "点",
           numeralScalars.contains(b[b.count - 2]) || ("0"..."9").contains(b[b.count - 2]) { return true }
        return false
    }

    /// 這段數字的第一個字是緊跟在「禮拜／星期／週／周」後面的星期幾，而且後面還接著數字。
    /// 後面接的是百／千／萬／億（「這週三千塊」「禮拜五千塊」）不算：單獨的千塊不是一種講法，那是一週 3,000、5,000。
    static func weekdayMerges(_ run: String, before: String) -> Bool {
        let r = Array(run.unicodeScalars)
        guard r.count >= 2, "一二三四五六".unicodeScalars.contains(r[0]), "零〇一二三四五六七八九十兩".unicodeScalars.contains(r[1]) else { return false }
        let b = Array(before.unicodeScalars)
        // 「礼拜」（簡體）也是星期（FX-8 D1：以前「礼拜四二點半」→「礼拜42:30」）。
        return ["禮拜", "礼拜", "星期", "週", "周"].contains { b.suffix($0.unicodeScalars.count).elementsEqual($0.unicodeScalars) }
    }

    /// FX-11 E4：這段鐘點數字的第一個字緊跟在「第」後面＝那個字是序數（第一、第二…），不是鐘點的一部分
    ///（「第一三點開會」→「第一3:00開會」，以前「第13:00開會」）。第二個字是「十」不算：「第二十點」多半就是 20 點，照舊。
    static func ordinalMerges(_ run: String, before: String) -> Bool {
        let r = Array(run.unicodeScalars)
        guard r.count >= 2, "一二三四五六七八九".unicodeScalars.contains(r[0]),
              "零〇一二三四五六七八九兩".unicodeScalars.contains(r[1]) else { return false }
        return before.unicodeScalars.last == "第"
    }

    /// 「N點」前面是這些＝那個「N點」是鐘點（下午三點五萬塊＝下午三點＋50,000塊），金額規則照舊只讀後面的金額。
    private static let decimalAmountClockContext = try! NSRegularExpression(pattern: "(?:早上|上午|中午|下午|晚上|凌晨|傍晚|半夜|深夜|午夜|清晨|週末|周末|早|晚|夜|(?:禮拜|礼拜|星期|週|周)[一二三四五六天日]?|第)$")
    /// 緊鄰數值前的明確金額詞；只認有限詞尾，不在整句搜尋金額字眼。
    private static let decimalAmountExplicitContext = try! NSRegularExpression(pattern: "(?:金額|預算|價格)(?:是|為)?$")
    /// 「一點」前面是這些＝「一點」可以是「一些」（還差一點、便宜一點、多一點）或「這一點」（FX-6 / FX-11 E3），照舊。
    /// 「有」不單獨表示比較（只有／有／還有一點零五萬元），交給小數規則整段讀。
    private static let decimalAmountComparativeOne = Set("差宜多少貴這这那給给早晚快慢好高低大小".unicodeScalars)
    /// 金額單位後緊接改口講整點（三點五萬塊，不對，四點）＝前面的「N點」是鐘點。
    /// 只越過限定標點／語助詞與「其實」，不跳過新主語（「元。開會不是四點」「元，開會不是四點」）。
    private static let decimalAmountHourCorrection = try! NSRegularExpression(pattern: "^[ \\u00A0]?(?:元|塊(?:錢)?|圓|dollars?)[，,、。.!！？?；;：: 啊呀喔哦吧啦呢\\u00A0\\r\\n\\t]*(?:(?:其實|其实)[，,、。.!！？?；;：: 啊呀喔哦吧啦呢\\u00A0\\r\\n\\t]*)?(?:不對|不对|不是|我是說|應該是|應該說)[，,、。.!！？?；;：: 啊呀喔哦吧啦呢\\u00A0\\r\\n\\t]*(?:[零〇一二兩三四五六七八九十]{1,3}點(?![點零〇一二三四五六七八九十百千萬億兩0-9])|[0-9]{1,2}(?::[0-9]{2}|點))")

    /// FX-11：金額規則（5）抓到的「五萬」「零五萬」「二億」其實是小數「一點五萬」「兩點零五萬」的後半段（以前讀成「一點50,000塊」、
    /// 「兩點50,000塊」，零也不見）→ 回 true，金額規則不動，小數規則 9 整段讀成 15,000塊／20,500塊，跟沒有單位時一樣。
    /// 只在規則 9 真的會整段讀的時候才讓（不然金額規則照舊）；下面這些照舊（同 base）：
    /// ・小數點後面只有一個「一」（三點一萬塊、這一點一萬塊）：「一萬」是一般的金額講法，可以是鐘點／「這一點」＋10,000（FX-6 pin）。
    /// ・「N點」前面是時段、星期幾、第：那是鐘點或序數。
    /// ・整數部分是單獨的「一」、前面是比較／指示的字（還差一點、再便宜一點、這一點）：「一點」可以是「一些」（「差不多」不算）。
    /// ・後面的改口講的是整點：前面的「N點」是鐘點。
    /// ・整數部分是兩個數字連著講（一兩點二萬塊、三四點三萬元）：不是一個確定的數。
    static func isDecimalWanYiTail(_ run: String, before: String, after: String) -> Bool {
        let r = Array(run.unicodeScalars)
        guard r.count >= 2, r.count <= 4, let mag = r.last, mag == "萬" || mag == "億" else { return false }
        let fraction = r.dropLast()
        guard fraction.allSatisfy({ decimalDigitScalars.contains($0) }), !(fraction.count == 1 && fraction.first == "一") else { return false }
        let b = Array(before.unicodeScalars)
        guard let point = b.last, point == "點" else { return false }
        var k = b.count - 1
        while k > 0, numeralScalars.contains(b[k - 1]) { k -= 1 }
        let wholeScalars = b[k..<(b.count - 1)]
        guard !wholeScalars.isEmpty, wholeScalars.count <= 5 else { return false }
        if k > 0, ("0"..."9").contains(b[k - 1]) { return false }
        // 整數部分兩個數字連著講（一兩點、三四點）＝概數或兩個鐘點，不是一個數。
        if zip(wholeScalars, wholeScalars.dropFirst()).contains(where: { spokenDigitScalars.contains($0) && spokenDigitScalars.contains($1) }) { return false }
        let whole = String(String.UnicodeScalarView(wholeScalars))
        let head = String(String.UnicodeScalarView(b[..<k]))
        let headRange = NSRange(head.startIndex..., in: head)
        if decimalAmountClockContext.firstMatch(in: head, range: headRange) != nil { return false }
        if whole == "一", let c = head.unicodeScalars.last, decimalAmountComparativeOne.contains(c), !head.hasSuffix("差不多") { return false }
        // 前導零／〇或緊鄰金額詞是明確小數證據；後句只講整點不能把它拆回鐘點＋金額。
        let hasDecimalAmountEvidence = fraction.first == "零" || fraction.first == "〇"
            || decimalAmountExplicitContext.firstMatch(in: head, range: headRange) != nil
        if !hasDecimalAmountEvidence,
           decimalAmountHourCorrection.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil { return false }
        // 規則 9 讀得出來才讓：整數讀得出、不是概數／範圍那些整段照講的。
        guard chineseToInt(whole) != nil else { return false }
        return !leavesSpoken(whole, before: head, after: "點" + run + after)
    }

    /// 從數字旁邊往外讀：空白、「到／至／～」、空白，再接一段數字 → 回傳那段數字（由近到遠的順序）。
    /// 往前讀時呼叫端先把前文倒過來（`forward` = false）。往後讀時「5 萬」這種阿拉伯數字＋空白＋萬／億當成一段。
    private static func rangeNeighbour(_ s: [Unicode.Scalar], forward: Bool) -> [Unicode.Scalar]? {
        var i = 0
        while i < s.count, s[i] == " " { i += 1 }
        guard i < s.count, rangeMarkScalars.contains(s[i]) else { return nil }
        i += 1
        while i < s.count, s[i] == " " { i += 1 }
        var j = i
        while j < s.count, rangeRunScalars.contains(s[j]) { j += 1 }
        if forward, j > i, j + 1 < s.count, s[j] == " ", s[j + 1] == "萬" || s[j + 1] == "億", s[j - 1].isASCII { j += 2 }
        var run = Array(s[i..<j])
        while let x = run.first, x == "." || x == "," { run.removeFirst() }
        while let x = run.last, x == "." || x == "," { run.removeLast() }
        return run.isEmpty ? nil : run
    }

    /// 「三」到「五萬」、「一千」到「兩千萬」：起點跟終點的係數同一種講法、而且比係數小 ＝ 共用終點的位值。
    /// 「五千到一萬」（5,000 比 1 大）、「兩千到三萬」不是。起點自己有萬／億也不是。
    private static func sharesMagnitude(start: [Unicode.Scalar], end: [Unicode.Scalar]) -> Bool {
        guard let last = end.last, magnitudeScalars.contains(last),
              !start.contains("萬"), !start.contains("億") else { return false }
        var coefficient = Array(end.dropLast())
        while coefficient.last == " " { coefficient.removeLast() }
        guard let a = rangeValue(start), let c = rangeValue(coefficient) else { return false }
        return a > 0 && a < c
    }

    /// 阿拉伯數字（可有千分位、一個小數點）或中文數字的值；兩種混在一起或讀不出來＝nil。
    private static func rangeValue(_ s: [Unicode.Scalar]) -> Double? {
        let t = s.filter { $0 != "," }
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0.isASCII }) {
            let parts = String(String.UnicodeScalarView(t)).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, parts.allSatisfy({ $0.count <= 15 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  !(parts[0].isEmpty && (parts.count == 1 || parts[1].isEmpty)) else { return nil }
            let whole = Double(Int(parts[0]) ?? 0)
            guard parts.count == 2, !parts[1].isEmpty, let f = Int(parts[1]) else { return whole }
            return whole + Double(f) / pow(10, Double(parts[1].count))
        }
        guard !t.contains(where: { $0.isASCII }) else { return nil }
        return chineseToInt(colloquial(String(String.UnicodeScalarView(t)))).map(Double.init)
    }

    /// 口語省略單位：「兩千五」＝2500、「三萬五」＝35000、「一百二」＝120（最後一個數字跟在單位後面、中間沒有零）。
    /// 「千六」「百五」（前面沒講一）也是：1,600、150（FX-2 v2 N4；舊版讀成 1,006）。
    static func colloquial(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= 3 || (chars.count == 2 && (chars[0] == "千" || chars[0] == "百")),
              let last = chars.last, "一二兩三四五六七八九".contains(last) else { return s }
        switch chars[chars.count - 2] {
        case "百": return s + "十"
        case "千": return s + "百"
        case "萬": return s + "千"
        case "億": return s + "千萬"
        default: return s
        }
    }

    static func applyRegex(_ text: String, pattern: String, transform: ([String]) -> String) -> String {
        replaceMatches(text, pattern: pattern) { groups, _ in transform(groups) }
    }

    /// 前後文各給這麼多個 UTF-16 單位（Kotlin 版同）。
    static let regexContextWindow = 24

    /// 同 `applyRegex`，另外把這一段緊鄰的前文、後文（同一步的輸入、各最多 `regexContextWindow` 個 UTF-16 單位）交給 transform。
    static func applyRegex(_ text: String, pattern: String, transform: ([String], String, String) -> String) -> String {
        let nsText = text as NSString
        return replaceMatches(text, pattern: pattern) { groups, range in
            let start = max(0, range.location - regexContextWindow), end = NSMaxRange(range)
            let before = nsText.substring(with: NSRange(location: start, length: range.location - start))
            let after = nsText.substring(with: NSRange(location: end, length: min(nsText.length, end + regexContextWindow) - end))
            return transform(groups, before, after)
        }
    }

    private static func replaceMatches(_ text: String, pattern: String, transform: ([String], NSRange) -> String) -> String {
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
            let replacement = transform(groups, match.range)
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
    /// - 「第一 X 第二 X 第三 X」 → 整串符合條列規則（`ordinalList`）才換行＋編號；不符合整句原樣
    /// - 「首先 X 其次 X 最後 X」 → 換行
    /// - 「接下來 X 然後 X 最後 X」 → 換行
    static let verbalListCues = ["首先", "其次", "再次", "然後", "接下來", "最後"]

    /// 條列：以「句」為單位判斷（2026-09-19 改規則）。
    /// 舊版整段計數：口語長文講兩次「然後」或「最後…最後的時程」就被切在句子中間
    /// （「確認\n最後的時程」）。現在一句裡要有兩種以上**不同**的 cue 才換行，
    /// 且 cue 後面緊接「的」不算（「最後的」是形容，不是條列）。
    /// 序數串（第一…第N）只有整串符合條列規則才動（2026-10-22 W2-6 第三輪，取代前兩輪的特例）：`numbered` 時改成
    /// 「1. 」編號清單（引言結尾改「：」、清單後面的句子另起一行），否則只在每個「第N」前面換行；
    /// 不符合就整句原樣——不編號也不切行（「我們要的是第二版不是第三版」不再被切成三行）。
    public static func normalizeListCues(_ text: String, numbered: Bool = false) -> String {
        var out = ""
        var previous: String?
        var afterList = false
        for sentence in splitSentences(text) {
            var body = sentence
            let newline = body.last == "\n" ? "\n" : ""
            if !newline.isEmpty { body.removeLast() }
            if afterList, !out.isEmpty, out.last != "\n" {
                // 編號清單後面的句子另起一行（「…\n3. 寫報告\n明天再說。」）。
                out += "\n"
                body = String(body.drop(while: { $0 == " " || $0 == "\t" }))
            }
            afterList = false
            if let list = ordinalList(body, previous: previous) {
                if numbered {
                    var lines: [String] = []
                    if list.prefix.contains(where: { $0.isLetter || $0.isNumber }) {
                        lines.append(listIntro(list.prefix))
                    } else if !out.isEmpty, out.last != "\n" {
                        out += "\n"
                    }
                    lines += list.bodies.enumerated().map { "\($0.offset + 1). " + trimListItem($0.element) }
                    out += lines.joined(separator: "\n") + newline
                    afterList = true
                } else {
                    var piece = list.prefix
                    for segment in list.segments {
                        if let last = (out + piece).last, last != "\n" { piece += "\n" }
                        piece += segment
                    }
                    out += piece + newline
                }
            } else {
                out += listifyVerbalCues(body) + newline
            }
            previous = sentence
        }
        return out
    }

    static func listifyVerbalCues(_ sentence: String) -> String {
        let distinct = verbalListCues.filter { cue in
            var searchRange = sentence.startIndex..<sentence.endIndex
            while let r = sentence.range(of: cue, range: searchRange) {
                if r.upperBound == sentence.endIndex || sentence[r.upperBound] != "的" { return true }
                searchRange = r.upperBound..<sentence.endIndex
            }
            return false
        }.count
        guard distinct >= 2 else { return sentence }
        return applyRegex(sentence, pattern: "(首先|其次|再次|然後|接下來|最後)(?!的)(.{1,40}?)(?=首先|其次|再次|然後|接下來|最後|[。！？!?]|$)") { groups in
            "\n\(groups[1])\(groups[2])"
        }
    }

    /// 序數：「第」＋中文數字。
    static let ordinalCuePattern = "第[一二三四五六七八九十]{1,3}"
    /// 「第N」後面緊接這些（或空白）＝明確的序號（第一，響度／第一：…）。
    static let ordinalSeparators: Set<Character> = ["，", ",", "、", "：", ":"]
    /// 「第N」後面接這些＝明確的序號，一起拿掉（第一個是…／第二點是…／第三就是…）；單獨的「是」另外處理。
    static let ordinalCopulas = ["個是", "个是", "點是", "点是", "項是", "项是", "步是", "件是", "就是"]
    /// 「是」開頭的詞（FX-7 L5）：「第一是非題」「第一個是否要延期」的「是」是詞的一部分，不是繫詞，留著。
    static let ordinalShiWords = ["是非", "是否", "是不是"]
    /// 「是」開頭的詞（`ordinalShiWords`）；「是非常…」的「是」還是繫詞（第一是非常重要的事）。
    static func startsWithShiWord(_ text: Substring) -> Bool {
        ordinalShiWords.contains(where: { text.hasPrefix($0) }) && !text.hasPrefix("是非常")
    }
    /// 「第N」後面接量詞＝序數名詞片語（第一軌、第一次、第一名、第一小節…），不是條列。一組固定的字（封閉詞類）。
    static let ordinalMeasureWords: [String] = ["小節", "小节", "聲道", "声道", "回合"] + (
        "軌轨台遍支個个次首張张件項项點点步章節节段位名天週周年輪轮場场集拍層层樓楼號号種种款顆颗則则筆笔趟口套組组隻條条把本部版"
        + "月日期屆届頁页代季批類类級级階阶篇份題题道句行排列局盤盘課课站棒線线任世的手波家間间塊块封堂班棟栋輛辆杯碗秒分時时人印關关圈冊册卷幕案例招式型"
    ).map(String.init)
    /// 引言講的數量：數量＋件事／件事情／樣／樣東西／項／個步驟／個重點，或中文數量＋點（阿拉伯數字＋點多半是鐘點，不算）。
    static let ordinalCountPattern = "(?<![第0-9一二三四五六七八九十兩百])(?:([兩二三四五六七八九十]|10|[2-9])(?:件事情|件事|樣東西|樣|項|個步驟|個重點)|([兩二三四五六七八九十])點)"
    /// 引言沒講數量、但明講接下來是清單。
    static let ordinalIntroWords = ["以下", "如下", "清單"]
    /// (B) 「第N」後面直接接內容時，這一項要用這些動作動詞開頭才算條列（2026-10-22 W2-6 第四輪：封閉詞類，取代「主詞記號」的猜法）。
    /// 不在表上的（小提琴、順位、志願、男高音、吉他…）＝「第N＋名詞」，整串不編號。量詞表優先：排、關也是量詞，「第三排／第一關」不算動作。
    /// Kotlin `Normalizer.ordinalListVerbs` 是同一份（GoldenExportTests 匯出 ordinal-list-verbs.json，Kotlin GoldenTest 逐字比對）。
    public static let ordinalListVerbs: [String] = [
        "買", "回", "寫", "交", "做", "改", "加", "刪", "寄", "送", "帶", "排", "繳", "洗", "煮", "倒", "拿", "找", "問", "練", "讀", "修",
        "開", "關", "去", "收", "錄", "準備", "更新", "匯出", "匯入", "確認", "檢查", "整理", "補錄", "重錄", "重做", "重開", "重新",
        "上傳", "下載", "安裝", "測試", "聯絡", "通知", "預約", "處理", "安排", "提醒", "規劃", "設定", "備份",
        // 簡體
        "买", "写", "删", "带", "缴", "问", "练", "读", "开", "关", "录", "准备", "汇出", "汇入", "确认", "检查", "补录", "重录", "重开",
        "上传", "下载", "安装", "测试", "联络", "预约", "处理", "规划", "备份",
    ]
    /// 用表上的動詞開頭、其實是名詞的詞（第一交響曲、第一錄音室、第一做法）：不算動作。動詞後面緊接「的」（第一買的、第一寫的歌）也不算。
    public static let ordinalListVerbNouns: [String] = ["交響", "交响", "錄音室", "录音室", "練習曲", "练习曲", "做法", "寫法", "写法", "加法", "修正案"]
    /// (A) 「第N」前面要是子句開頭：句首、這些分隔（含空白、換行），或清單引言本身（`ordinalIntroEndPattern`）。
    static let ordinalClauseDelimiters: Set<Character> = ["，", ",", "、", "：", ":", "；", ";", "。", " ", "\t", "\n", "\r", "\r\n"]
    /// (A) 緊接在第一個「第N」前面的清單引言：…清單是／清單／以下／如下／N件事／N樣／N項／N個步驟／N個重點／N點。
    static let ordinalIntroEndPattern = "(?:清單是|清单是|清單|清单|以下|如下|" + ordinalCountPattern + ")$"
    /// 清單項目結尾一律拿掉的標點（2026-10-22 修正：每一項同一套，不管是哪一條規則出的清單）。
    static let listItemTrailers: Set<Character> = ["，", ",", "、", "；", ";", "：", ":", "。", " ", "\t"]

    /// 一句裡的序數串是不是條列（2026-10-22 W2-6 第三輪保守規則；第四輪加 (A) 子句開頭、(B) 改成封閉動詞表）。
    /// 句子裡所有的「第N」依序是 1、2、…、k（k ≥ 2），每一項都有內容，而且每一項都過下面三關，才回傳引言（第一個「第N」前面）、
    /// 每一項的原文與拿掉「第N」之後的內容；有一項不過就回 nil，整句原樣（不編號也不切行）。
    /// (A) 子句開頭：「第N」前面是句首、分隔（，,、：:；;。空白、換行），或清單引言本身（`ordinalIntroEndPattern`）。
    ///     「安全第一，速度第二」「他拿了第一」的「第N」收在子句結尾，不是序號。
    /// (B) 「第N」後面緊接分隔（，、：: 或空白）或「是／個是／點是／項是／步是／件是／就是」；或直接接內容、而且內容用
    ///     `ordinalListVerbs` 的動作動詞開頭（不是 `ordinalListVerbNouns`、動詞後面不是「的」），這種串還要有引言：
    ///     引言（這句第一個「第N」前面；那裡沒有字就看前一句）的最後一個子句講了數量（N件事／N樣／N點／N個步驟／N項／N個重點）
    ///     而且 N 等於項數，或講了「以下／如下／清單」。
    /// (C) 「第N」後面接量詞（`ordinalMeasureWords`：第一軌、第一次、第一名、第三排…）＝序數名詞片語，不是序號。
    static func ordinalList(_ sentence: String, previous: String?) -> (prefix: String, segments: [String], bodies: [String])? {
        guard sentence.contains("第"), let re = try? NSRegularExpression(pattern: ordinalCuePattern) else { return nil }
        let ns = sentence as NSString
        let cues = re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard cues.count >= 2 else { return nil }
        var segments: [String] = []
        var items: [(value: Int, body: String?, direct: Bool)] = []
        for (index, cue) in cues.enumerated() {
            let end = index + 1 < cues.count ? cues[index + 1].location : ns.length
            let segment = ns.substring(with: NSRange(location: cue.location, length: end - cue.location))
            guard let item = parseOrdinalLine(segment), item.value == index + 1, item.body != nil else { return nil }
            // (A) 第二項起：前一項的最後一個字要是分隔。
            if index > 0, let last = segments[index - 1].last, !ordinalClauseDelimiters.contains(last) { return nil }
            segments.append(segment)
            items.append(item)
        }
        let prefix = ns.substring(to: cues[0].location)
        // (A) 第一項：句首、分隔，或緊接在清單引言後面。
        if let last = prefix.last, !ordinalClauseDelimiters.contains(last),
           prefix.range(of: ordinalIntroEndPattern, options: .regularExpression) == nil { return nil }
        if items.contains(where: \.direct) {
            let intro = prefix.contains(where: { $0.isLetter || $0.isNumber }) ? prefix : (previous ?? "")
            guard let count = ordinalListIntroCount(intro), count == 0 || count == cues.count,
                  items.allSatisfy({ !$0.direct || isVerbLedItem($0.body ?? "") }) else { return nil }
        }
        return (prefix, segments, items.map { $0.body ?? "" })
    }

    /// 一項的序數（第N）與拿掉序數後的內容；不是「第N」開頭回 nil。
    /// 後面接量詞時內容是 nil（整串不編號）；`direct`＝「第N」後面直接接內容（沒有分隔、空白，也不是「是」），要過 (B) 的關。
    /// 「是」拿掉，「是非／是否／是不是」的「是」留著（`ordinalShiWords`：意思會變、會少一個字；FX-7 L5）；
    /// 「第一是是非題」只拿掉一個「是」。「個是／點是／就是…」後面接這種詞時只拿掉「個／點／就…」。
    static func parseOrdinalLine(_ line: String) -> (value: Int, body: String?, direct: Bool)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "第" else { return nil }
        let afterDi = trimmed.dropFirst()
        let numeral = afterDi.prefix(while: { "一二三四五六七八九十".contains($0) })
        guard !numeral.isEmpty, numeral.count <= 3, let value = chineseToInt(String(numeral)), value >= 1 else { return nil }
        let afterNumeral = afterDi.dropFirst(numeral.count)
        let spaced = afterNumeral.first == " " || afterNumeral.first == "\t"
        var rest = afterNumeral.drop(while: { $0 == " " || $0 == "\t" })
        var direct = false
        if let copula = ordinalCopulas.first(where: { rest.hasPrefix($0) }) {
            let shi = rest.dropFirst(copula.count - 1)
            rest = startsWithShiWord(shi) ? shi : rest.dropFirst(copula.count)
        } else if rest.first == "是" {
            if !startsWithShiWord(rest) { rest = rest.dropFirst() }
        } else if let next = rest.first, ordinalSeparators.contains(next) {
            // 「第一，響度」：分隔在下面一起拿掉。
        } else if ordinalMeasureWords.contains(where: { rest.hasPrefix($0) }) {
            return (value, nil, false)
        } else if !spaced {
            direct = true
        }
        var body = String(rest.drop(while: { "，,、：: \t".contains($0) }))
        while let last = body.last, "，,、；;：: \t".contains(last) { body.removeLast() }
        return (value, trimListItem(body).isEmpty ? nil : body, direct)
    }

    /// 引言最後一個子句講的數量（`ordinalCountPattern`，有好幾個取最後一個）；只講「以下／如下／清單」回 0；都沒有回 nil。
    static func ordinalListIntroCount(_ intro: String) -> Int? {
        var clause = intro.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n，,、：:；;。！？!?"))
        if let cut = clause.lastIndex(where: { "，,、；;：:".contains($0) }) { clause = String(clause[clause.index(after: cut)...]) }
        guard let re = try? NSRegularExpression(pattern: ordinalCountPattern) else { return nil }
        let ns = clause as NSString
        if let m = re.matches(in: clause, range: NSRange(location: 0, length: ns.length)).last {
            let group = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            return enumerationCounts[ns.substring(with: group)]
        }
        return ordinalIntroWords.contains(where: { clause.contains($0) }) ? 0 : nil
    }

    /// 「第N」後面直接接的內容是不是一個動作（買牛奶、更新Pro Tools）：用 `ordinalListVerbs` 的動詞開頭（取最長的），
    /// 不是 `ordinalListVerbNouns` 的名詞，動詞後面也不是「的」。
    static func isVerbLedItem(_ body: String) -> Bool {
        if ordinalListVerbNouns.contains(where: { body.hasPrefix($0) }) { return false }
        guard let verb = ordinalListVerbs.filter({ body.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return false }
        return !body.dropFirst(verb.count).hasPrefix("的")
    }

    /// 清單一項：結尾的「，、；：。」與空白拿掉。
    static func trimListItem(_ item: String) -> String {
        var s = Substring(item)
        while let last = s.last, listItemTrailers.contains(last) { s = s.dropLast() }
        return String(s)
    }

    /// 清單前面那一行（引言）：結尾的逗號／頓號／冒號換成「：」，沒有標點就補「：」；已經收在句號問號等就原樣。
    static func listIntro(_ line: String) -> String {
        var body = line
        while let last = body.last, last == " " || last == "\t" { body.removeLast() }
        guard let last = body.last else { return line }
        if "，,、：:".contains(last) {
            body.removeLast()
            return body.isEmpty ? line : body + "："
        }
        if "。！？!?；;」』”\"）)….".contains(last) { return line }
        return body + "："
    }

    /// 明講數量的頓號列舉 → 編號清單（2026-10-22 W2-6 ls03：「幫我準備四樣東西，播放器、耳機、線材、還有轉接頭」；同日修正誤判與吃字）。
    /// 只在：數量（兩／二…十、2…10）＋ 樣／件／個／點／項（可再接 東西／事情／事／重點）緊接逗號或冒號，後面是頓號隔開、
    /// 項數剛好等於那個數量的列舉、每項 ≤ 12 字，而且列舉講完這句就結束（後面只剩「，」「、」「。」）。另外：
    /// ・數量前面是「第」（第二個＝序數）或「這／那／每／哪」（這兩個＝指稱）→ 不是在數。
    /// ・項目是人（你、我、他…）→ 是在約人，不是列東西；「N點」前面有時間詞（明天／下午／約／到／說…）或已經轉成數字（3點）→ 是鐘點。
    /// ・「N點」要緊接在明講列重點的動詞後面（有／注意／講／提／列／補充／以下…）或後面接「重點」（三點重點）才是在數重點；
    ///   「三點，小明、小華、小美集合」「大家三點，A組、B組、C組」＝約時間，不動（2026-10-22 第二輪）。
    /// ・最後一項要跟前面幾項一樣是「一個東西」：比最長的那項長兩個單位以上（黑的很好看、C比較好、雞蛋已經放冰箱），
    ///   或只長一個單位但帶著講事情的字（小的各一個、C好）＝列舉後面接著講話，不動（2026-10-22 第二輪：不再靠一張動詞清單）。
    ///   單位：中文一個字一個、英文字／數字一串一個（回email＝2、Galaxy＝1）。
    /// ・只有兩項時，要明講是在列（有／注意／準備／買／帶／講 ＋ 兩樣東西／兩件事／兩項／兩點）。
    /// ・最後一項開頭的「還有／以及」拿掉；單字的「和／跟」不拿（和弦、和聲、和牛、跟拍是一個詞）。
    /// 數量對不上、沒有數量、項目太長、列舉後面還有話、句尾是問號驚嘆號＝原樣。已經有編號清單的文字不再動。
    static let countedEnumerationPattern = "^(.*?(?<![零〇一二三四五六七八九十百千萬億兩0-9第這这那每哪])(兩|二|三|四|五|六|七|八|九|十|10|[2-9])(樣|件|個|點|項)(東西|事情|事|重點)?)[ \\t]*[，,：:][ \\t]*([^，,。！？!?：:；;\\n]+)$"
    static let enumerationCounts: [String: Int] = ["兩": 2, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
                                                   "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "10": 10]
    static let enumerationLastLeads = ["還有", "以及"]
    static let enumerationPeople: Set<String> = ["你", "妳", "您", "我", "他", "她", "它", "你們", "妳們", "我們", "他們", "她們", "大家", "自己"]
    static let enumerationClockContext = ["今天", "明天", "後天", "昨天", "今晚", "早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "約", "到", "說"]
    static let enumerationPredicates = ["都", "各", "再", "也", "就", "你們", "我們", "他們", "負責", "去", "來", "要", "會", "一起", "記得"]
    static let explicitListUnits: Set<String> = ["樣東西", "件事", "件事情", "項", "點", "個重點"]
    static let explicitListVerbs = ["有", "注意", "準備", "買", "帶", "講", "需要"]
    /// 「N點」前面要是這些（可再接「了」）才是在數重點。
    static let pointListVerbs = ["有", "注意", "講", "提", "列", "補充", "強調", "分享", "說明", "歸納", "整理", "包括", "包含", "分成", "分為", "以下", "需要"]
    /// 最後一項只多一個單位時，結尾是這些＝接著在講事情（C好、小美來了）。
    static let enumerationRunOnEnds: Set<Character> = ["好", "讚", "棒", "對", "錯", "行", "來", "去", "走", "到", "了", "吧", "啊", "喔", "呢", "嗎", "啦", "耶", "欸", "嘛", "囉"]

    /// 列舉一項的長度（單位）：中文等一個字一個，英文字母／數字連成一串算一個，空白不算。
    static func itemUnits(_ item: String) -> Int {
        var units = 0
        var inWord = false
        for scalar in item.unicodeScalars {
            let v = scalar.value
            let word = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            if word {
                if !inWord { units += 1 }
                inWord = true
                continue
            }
            inWord = false
            if v == 0x20 || v == 0x09 || v == 0x3000 { continue }
            units += 1
        }
        return units
    }

    static func numberCountedEnumerations(_ text: String) -> String {
        guard text.contains("、"), !hasNumberedLine(text) else { return text }
        let sentences = splitSentences(text)
        var changed = false
        var out = ""
        for (index, sentence) in sentences.enumerated() {
            guard let list = countedEnumerationList(sentence) else { out += sentence; continue }
            changed = true
            out += list + (index == sentences.count - 1 ? "" : "\n")
        }
        return changed ? out : text
    }

    static func countedEnumerationList(_ sentence: String) -> String? {
        guard sentence.contains("、"), let re = try? NSRegularExpression(pattern: countedEnumerationPattern) else { return nil }
        var body = Substring(sentence)
        while let last = body.last, "，,、。.".contains(last) || last.isWhitespace { body = body.dropLast() }
        let s = String(body)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let count = ns.substring(with: m.range(at: 2))
        guard let n = enumerationCounts[count] else { return nil }
        let unit = ns.substring(with: m.range(at: 3))
        let unitPhrase = unit + (m.range(at: 4).location == NSNotFound ? "" : ns.substring(with: m.range(at: 4)))
        let beforeCount = ns.substring(to: m.range(at: 2).location)
        // 只修半形空白與 tab（Kotlin 版 trimSpaces 同一套）。
        let spaces = CharacterSet(charactersIn: " \t")
        var items = ns.substring(with: m.range(at: 5)).components(separatedBy: "、")
            .map { $0.trimmingCharacters(in: spaces) }
        guard items.count == n else { return nil }
        if let lead = enumerationLastLeads.first(where: { items[n - 1].hasPrefix($0) }) {
            items[n - 1] = String(items[n - 1].dropFirst(lead.count)).trimmingCharacters(in: spaces)
        }
        items = items.map(trimListItem)
        guard items.allSatisfy({ !$0.isEmpty && $0.count <= 12 }) else { return nil }
        if items.contains(where: { enumerationPeople.contains($0) }) { return nil }
        if unit == "點" {
            if count.first?.isASCII == true { return nil }
            let near = String(beforeCount.suffix(4))
            if enumerationClockContext.contains(where: { near.contains($0) }) { return nil }
            var verb = beforeCount
            if verb.hasSuffix("了") { verb.removeLast() }
            guard unitPhrase == "點重點" || pointListVerbs.contains(where: { verb.hasSuffix($0) }) else { return nil }
        }
        let last = items[n - 1]
        let longest = items.dropLast().map(itemUnits).max() ?? 0
        let lastUnits = itemUnits(last)
        if lastUnits >= longest + 2 { return nil }
        if lastUnits == longest + 1,
           enumerationPredicates.contains(where: { last.contains($0) }) || last.last.map(enumerationRunOnEnds.contains) == true { return nil }
        if n < 3 {
            var verb = beforeCount
            if verb.hasSuffix("了") { verb.removeLast() }
            guard explicitListUnits.contains(unitPhrase), explicitListVerbs.contains(where: { verb.hasSuffix($0) }) else { return nil }
        }
        return ns.substring(with: m.range(at: 1)) + "：" + items.enumerated().map { "\n\($0.offset + 1). \($0.element)" }.joined()
    }

    /// 有一行是「1. 」這種編號開頭。
    static func hasNumberedLine(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            line.range(of: "^[ \\t]*[0-9]+\\. ", options: .regularExpression) != nil
        }
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

    static let paragraphOpeners = ["另外", "還有", "再來", "再者", "接下來", "接著", "此外", "至於", "關於", "對了", "順便", "最後",
                                   "總之", "總而言之", "整體來說", "整體而言", "總結", "結論是", "首先", "其次", "第二", "第三", "第四", "第五",
                                   "Also", "Another", "Finally", "By the way", "Anyway", "Overall", "In summary"]
    static let paragraphClosers = ["謝謝", "感謝", "麻煩", "不好意思", "辛苦了", "Thanks", "Thank you"]
    static let paragraphWeakOpeners = ["不過", "但是", "可是", "然而", "However", "But"]

    /// 句中的段落轉折詞（2026-10-22 W2-6，Typeless 對打 lp01／lp02／lp04）：前面是逗號（子句開頭）、後面不是「的」，
    /// 在逗號後面切成一個單位；真的在這裡分段時，那個逗號改成句號。「我另外買了一個」「要另外談」前面不是逗號，不切。
    /// 當限定詞／形容用的不算（2026-10-22 修正）：另外一個／另外兩個／另外半…（另一個）、最後一天／最後半小時／最後面／最後還是（最後的…）、
    /// 對了一半（答對一半）；後面接指示詞／幾也一樣（第二輪）：另外那個版本、最後這段副歌、最後那段、最後幾個音。
    /// 「接著」（第三輪，lp03 Typeless 在「接著選曲」前分段）：「緊接著」「我接著說」前面不是逗號，不切。
    static let clauseOpenerPattern = "(?<=[，,])(?:首先|接著|另外(?![一兩二三四五六七八九十個个半這这那哪幾几些])|對了(?![嗎吗吧呢]|一半)|總之|最後(?![一兩二三四五六七八九十半面個个\\d這这那哪幾几些]|還是|还是)|第[一二三四五六七八九十]{1,3}個?部分)(?!的)"
    /// 轉述別人的話（「老師一直強調，首先要把耳朵練好」「他在信裡面寫，首先…」「老闆告訴我們，另外…」）：
    /// 逗號後面到這句結束都是引文，裡面的轉折詞一個都不切（2026-10-22 第二輪：動詞補齊、引文後面的也不切）。
    /// 動詞後面可以再接一個人（告訴我們、問你）。
    static let reportedSpeechVerbs = ["強調", "說", "講", "寫", "問", "提到", "提過", "表示", "提醒", "交代", "告訴", "建議", "要求",
                                      "認為", "覺得", "回答", "回覆", "指出", "規定"]
    static let reportedSpeechListeners = ["我們", "你們", "他們", "她們", "大家", "我", "你", "妳", "他", "她"]

    /// 逗號前面這段是不是收在轉述動詞（可再接一個人）。
    static func endsWithReportedSpeech(_ clause: String) -> Bool {
        var t = clause.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if let who = reportedSpeechListeners.first(where: { t.hasSuffix($0) }) {
            let without = String(t.dropLast(who.count))
            if reportedSpeechVerbs.contains(where: { without.hasSuffix($0) }) { t = without }
        }
        return reportedSpeechVerbs.contains(where: { t.hasSuffix($0) })
    }
    /// 開始列舉的轉折：前面那句是開場白（「這次案子分成三個部分」「關於版權這件事我要多講幾句」），短短一句也自成一段。
    static let sequenceOpeners = ["首先", "第一個部分", "第一部分"]

    /// 一句在句中轉折詞前面切開（逗號留在前一段）；沒有就整句一個。
    static func splitAtClauseOpeners(_ sentence: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: clauseOpenerPattern) else { return [sentence] }
        let ns = sentence as NSString
        var parts: [String] = []
        var start = 0
        for m in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) where m.range.location > start {
            let beforeComma = ns.substring(with: NSRange(location: start, length: m.range.location - 1 - start))
            if endsWithReportedSpeech(beforeComma) { break }
            parts.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location
        }
        parts.append(ns.substring(from: start))
        return parts
    }

    /// 段落收在句中逗號（下一段從句中轉折詞開始）→ 逗號改句號，這一句再照句尾語氣調一次（「…會來嗎，另外」→「…會來嗎？」）。
    /// 逗號前面是英文字母或數字（「…with the band,另外」）→ 用英文句點「.」（2026-10-22 修正）。
    static func closeParagraph(_ paragraph: String) -> String {
        let t = paragraph.trimmingCharacters(in: .whitespaces)
        guard let last = t.last, last == "，" || last == "," else { return t }
        let body = String(t.dropLast())
        let end = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).last
        let stop = end.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? "." : "。"
        var sentences = splitSentences(body + stop)
        guard let final = sentences.popLast() else { return t }
        return sentences.joined() + SentenceMood.retune(final)
    }

    /// 有換行的結果（編號清單、分段）：最後吊著的「，」「、」拿掉（2026-10-22 修正）。單行的照舊留給 SentenceMood.finish
    ///（它看到換行就整段不動），兩條路的結果一樣：整段不會收在逗號。
    static func dropDanglingEndOfLines(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        var body = Substring(text)
        var trailing = ""
        while let last = body.last, last.isWhitespace { trailing = String(last) + trailing; body = body.dropLast() }
        guard let last = body.last, "，、".contains(last) else { return text }
        let without = body.dropLast()
        guard without.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        return String(without) + trailing
    }

    /// 英文為主的文字（英文字數比中文字多）：分段門檻用字數算（2026-10-22 修正：三句 17 個字的英文短信被切成三段）。
    static func latinWordCount(_ text: String) -> Int {
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let letter = (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
            if letter && !inWord { words += 1 }
            inWord = letter
        }
        return words
    }

    static func cjkCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
    }

    /// 英文為主的長文至少要這麼多字（英文字＋中文字）才分段。
    static let latinParagraphMinimumWords = 60

    /// 長文分段（2026-09-19）：只在沒有換行、至少 3 個單位且 100 字以上時動，切點都在句界或句中轉折詞前的逗號。
    /// ・轉折開頭（另外／還有／對了／總之…）且目前這段已 ≥ 20 字 → 新段；目前這段本身也是轉折詞開頭的，≥ 10 字就分
    /// ・開始列舉（首先／第一個部分）前面那段 ≥ 6 字就自成一段（開場白，2026-10-22 W2-6）
    /// ・弱轉折（不過／但是…）要目前這段 ≥ 40 字
    /// ・結尾致謝（謝謝／不好意思…）自成一段
    /// ・一段超過 120 字，下一句就開新段
    /// ・開頭的招呼（「老師你好，」）單獨一行
    /// ・轉折詞有兩個以上（講話本身有結構）時，80 字以上就分（2026-10-22 W2-6 lp04 96 字，Typeless 分成 4 段）
    /// ・英文為主（英文字數比中文字多）：用字數算，英文字＋中文字 ≥ 60 才分（2026-10-22 修正：三句的英文短信不切）
    /// 句首的「然後」「那」後面接轉折詞時照樣算，而且新段開頭的這個「然後／那」拿掉（「然後關於預算」→「關於預算」）。
    public static func paragraphize(_ text: String) -> String {
        guard !text.contains("\n") else { return text }

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

        // 單位＝句子，句子裡再從句中轉折詞前面切開（soft）。
        var units: [(text: String, soft: Bool)] = splitSentences(text).flatMap { sentence in
            splitAtClauseOpeners(sentence).enumerated().map { (text: $0.element, soft: $0.offset > 0) }
        }
        let openers = units.dropFirst().filter { $0.soft || starts($0.text, with: paragraphOpeners) }.count
        let latinWords = latinWordCount(text), cjk = cjkCount(text)
        let long = latinWords > cjk
            ? latinWords + cjk >= latinParagraphMinimumWords
            : text.count >= 100 || (text.count >= 80 && openers >= 2)
        guard units.count >= 3, long else { return text }

        var greeting: String?
        if let first = units.first?.text,
           let m = first.range(of: "^[^，,。！？]{0,10}(你好|您好|哈囉|嗨|早安|午安|晚安)[，,]", options: .regularExpression) {
            greeting = String(first[m]).trimmingCharacters(in: .whitespaces)
            let rest = String(first[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { units.removeFirst() } else { units[0].text = rest }
        }

        var paragraphs: [String] = []
        var current = ""
        // 目前這段本身是從轉折詞開始的（另外…、對了…）：講話一路用轉折詞分節，下一個轉折詞 ≥ 10 字就分（lp02「另外…吸音棉。」18 字）。
        var currentOpened = false
        for unit in units {
            let sentence = unit.text
            let length = current.trimmingCharacters(in: .whitespaces).count
            let opener = unit.soft || starts(sentence, with: paragraphOpeners)
            let sequence = starts(sentence, with: sequenceOpeners)
            let breakHere = length > 0 && (
                (sequence && length >= 6)
                || (opener && length >= (currentOpened ? 10 : 20))
                || (starts(sentence, with: paragraphClosers) && length >= 20)
                || (starts(sentence, with: paragraphWeakOpeners) && length >= 40)
                || length >= 120)
            if breakHere || length == 0 { currentOpened = opener || sequence }
            if breakHere {
                paragraphs.append(closeParagraph(current))
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
        // 中文後面的刪節號（... 或 …）→「……」；不先處理的話第一個點會被當句號變成「但是。..」（2026-10-20 Pixel）。
        out = applyRegex(out, pattern: "([\\u4E00-\\u9FFF])(?:\\.{2,}|…+)") { groups in groups[1] + "……" }
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
        return latinPunctuationInChinese(out)
    }

    /// 英文字／數字後面的半形 , ; ! ? 在中文句子裡 → 全形（2026-10-22：Groq Whisper 幾乎每句都有「Utuvo Type,在手機」「Session?」，
    /// Typeless 44 句裡貼著中文的半形標點是 0）。
    /// ・後面接中文字：「Tim,大家好」→「Tim，大家好」，標點前後的空白一起拿掉。
    /// ・有中文的那一行：行尾的 ? !（「重開一個Session?」）、下一行之前的行尾 , 也轉。
    /// 「.」「:」一律不碰（3.5、v0.2.1、3:30、2:1）；數字中間的千分位逗號（1,250）、沒有中文的英文行不動。
    static func latinPunctuationInChinese(_ text: String) -> String {
        let fullWidth: [String: String] = [",": "，", ";": "；", "!": "！", "?": "？"]
        let inline = applyRegex(text, pattern: "([A-Za-z0-9%)\\]])[ \\t]*([,;!?])[ \\t]*(?=[\\u4E00-\\u9FFF])") { groups in
            groups[1] + (fullWidth[groups[2]] ?? groups[2])
        }
        let lines = inline.components(separatedBy: "\n")
        return lines.enumerated().map { index, line -> String in
            guard line.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return line }
            var out = applyRegex(line, pattern: "([A-Za-z0-9])[ \\t]*([?!])[ \\t]*$") { groups in
                groups[1] + (fullWidth[groups[2]] ?? groups[2])
            }
            if index < lines.count - 1 {
                out = applyRegex(out, pattern: "([A-Za-z0-9])[ \\t]*,[ \\t]*$") { groups in groups[1] + "，" }
            }
            return out
        }.joined(separator: "\n")
    }

    public static func collapseWhitespace(_ text: String) -> String {
        // 把多個空白（含換行以外的）壓成單一；
        // 但保留使用者／list cue 階段已加入的換行。
        // 連續換行最多留兩個（一個空行＝分段）：分好段的結果再整理一次，段落不能被併掉（2026-10-22 修正：normalize 要冪等）。
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        var newlines = 0
        for ch in text {
            if ch == " " || ch == "\t" {
                if !lastWasSpace && newlines == 0 {
                    out.append(" ")
                }
                lastWasSpace = true
            } else if ch == "\n" {
                if newlines < 2 {
                    out.append("\n")
                }
                lastWasSpace = false
                newlines += 1
            } else {
                out.append(ch)
                lastWasSpace = false
                newlines = 0
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
