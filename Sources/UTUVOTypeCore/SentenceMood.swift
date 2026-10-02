import Foundation

/// 句尾語氣（2026-10-02 Micky：「不要每個句子或最後都用句點，偶爾可以有問號、驚嘆號……一直使用句點會顯得很 AI」）。
///
/// 辨識器與整理模型幾乎每句都收在「。」。這裡看句子本身的意思改句尾：
/// - 問句 → 「？」：句尾「嗎／呢」、正反問（是不是、有沒有、要不要……）、疑問詞（什麼、怎麼、為什麼……）、附加問（對吧、是吧）。
///   疑問詞被包在陳述裡（「我不知道他為什麼要這樣」「問他幾點到」）、或是「什麼都可以」這種任指，不算問句。
/// - 感嘆 → 「！」：「太……了」「好棒」「天啊」「恭喜」「加油」「謝謝你」「哈哈」等明確的感嘆。
/// - 拿不準就維持句號（錯放一個問號比多一個句號更難看）。只改「。」結尾的句子，已經是 ？／！ 的不動。
/// - [finish]：再把最後一句的「。」拿掉（整段沒有換行時；有分段的長文照文件習慣保留）。
public enum SentenceMood {

    /// 本機整理最後一步、以及智慧整理（雲端／裝置端模型）回來之後都走這裡。
    public static func finish(_ text: String) -> String {
        dropFinalPeriod(apply(text))
    }

    /// 只改句尾語氣，不動最後的句號。
    public static func apply(_ text: String) -> String {
        guard text.contains("。") || text.contains(".") else { return text }
        var out = ""
        for sentence in Normalizer.splitSentences(text) {
            out += retune(sentence)
        }
        return out
    }

    /// 最後一句的句號拿掉（只拿「。」；問號、驚嘆號、英文句點不動）。有換行＝分段長文，照原樣。
    public static func dropFinalPeriod(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        var body = Substring(text)
        var trailing = ""
        while let last = body.last, last.isWhitespace { trailing = String(last) + trailing; body = body.dropLast() }
        guard body.last == "。" else { return text }
        let without = body.dropLast()
        // 整段只剩標點或空字串就別動（「。」本身是使用者唸的「句號」之類）。
        guard without.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        return String(without) + trailing
    }

    /// 接著上一段聽寫：最後一句的句號被拿掉了，下一段又緊接在它後面（游標沒動、輸入框沒清空）時，
    /// 先把句號補回去，免得兩段黏成一句（「我到了」＋「你在哪？」→「我到了你在哪？」）。
    /// - `before`：游標前的文字（拿不到就傳 nil → 不補，寧可少一個句號也不要亂插）。
    /// - `previous`：上一次插入的文字（這一個輸入框、這一段 session）。
    /// 回傳要先插的前綴：「。」或空字串。只補中文句號——英文句點本來就不會被拿掉。
    public static func continuationPrefix(before: String?, previous: String?) -> String {
        guard let before, let previous, !previous.isEmpty else { return "" }
        let trimmedBefore = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard trimmedBefore.hasSuffix(previous), let last = previous.last else { return "" }
        // 上一段結尾已經是標點（？！。…）或英數字 → 不補。
        guard isCJKLetter(last) else { return "" }
        return "。"
    }

    static func isCJKLetter(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    // MARK: - 單句

    static func retune(_ sentence: String) -> String {
        // 拆出：句子本體＋句尾的「。」或英文「.」（後面可能還有空白）。
        var body = Substring(sentence)
        var tail = ""
        while let last = body.last, last.isWhitespace { tail = String(last) + tail; body = body.dropLast() }
        guard let mark = body.last, mark == "。" || mark == "." else { return sentence }
        let core = String(body.dropLast())
        if mark == "." {
            // 英文句點：只有英文問句才換（中文句子裡的半形句點交給 normalizePunctuation）。
            return isEnglishQuestion(core) ? core + "?" + tail : sentence
        }
        if isQuestion(core) { return core + "？" + tail }
        if isExclamation(core) { return core + "！" + tail }
        return sentence
    }

    // MARK: - 問句

    /// 疑問詞被包在陳述裡：前面有這些動詞時，整句是陳述（「我不知道他為什麼要這樣」）。
    private static let subjects: Set<String> = ["你", "妳", "您", "他", "她", "它", "我", "我們", "我们", "你們", "你们",
                                                "他們", "他们", "她們", "大家", "這個", "这个", "那個", "那个", "這", "那"]
    private static let concessives = ["不管", "無論", "无论", "不論", "不论", "隨便", "随便", "任何"]
    private static let embedders = ["知道", "曉得", "明白", "清楚", "看得出", "跟你說", "跟他說", "跟妳說", "告訴你", "看你", "看他", "看妳", "看大家", "看情況", "不確定", "不曉得", "想知道", "看看", "問問", "問他", "問她", "問你", "問一下",
                                    "確認", "決定", "考慮", "記得", "忘了", "告訴", "說明", "解釋", "查一下", "討論", "研究", "了解"]
    private static let interrogatives = ["什麼", "什么", "怎麼", "怎么", "為什麼", "为什么", "為何", "哪裡", "哪里", "哪個", "哪个",
                                         "哪些", "哪一", "誰", "谁", "多少", "幾點", "几点", "幾個", "几个", "幾天", "几天", "如何", "何時", "多久", "多大", "多遠"]
    private static let aNotA = ["是不是", "有沒有", "有没有", "要不要", "會不會", "会不会", "能不能", "可不可以", "對不對", "对不对",
                                "好不好", "行不行", "可以嗎", "可以吗", "是否", "還是不", "去不去", "來不來", "来不来"]

    static func isQuestion(_ core: String) -> Bool {
        let s = core.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        // 最後一個子句（逗號後）才決定語氣：「我明天會到，你呢」→ 問；「你問什麼，我都回答」不是。
        let clause = lastClause(s)
        // 句尾「嗎／吗」：一定是問句。
        // 句尾「嗎／吗」：一定是問句（「我想問問你可以嗎」也是在問）。
        if clause.hasSuffix("嗎") || clause.hasSuffix("吗") { return true }
        // 附加問。
        if clause.hasSuffix("對吧") || clause.hasSuffix("对吧") || clause.hasSuffix("是吧") || clause.hasSuffix("好嗎") { return true }
        // 「你呢」「那他呢」這種短追問；長句裡的「呢」多半是語氣（「我還在等呢」）。
        if clause.hasSuffix("呢") {
            // 只有「你呢／那他呢／我們呢／這個呢」這種代名詞追問；「我還在等呢」是語氣。
            if clause.range(of: "^(那|那麼|那么)?(你|妳|您|我|他|她|它|你們|你们|我們|我们|他們|他们|這個|这个|那個|那个|這邊|那邊)呢$",
                            options: .regularExpression) != nil { return true }
            return containsInterrogative(clause) && !isEmbedded(clause)
        }
        // 讓步句：「不管他怎麼說」「無論如何」「隨便挑哪一個」都不是在問（review 10-02 實測誤判）。
        if concessives.contains(where: { clause.contains($0) }) { return false }
        // 正反問：要在句子後段（後面最多 6 個字）——「你明天是不是要上課」是問；
        // 「這是不是事實大家心裡有數」是陳述（正反詞當主語從句）。
        if let r = aNotA.compactMap({ clause.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            if isEmbedded(clause, before: r.lowerBound) { return false }
            return clause[r.upperBound...].count <= 6
        }
        // 疑問詞：只有在句首（前面最多兩個字的主語：「你幾點到」「為什麼他還沒回信」）或句尾
        //（後面最多三個字：「這個多少錢」「混音怎麼樣」）才算。夾在中間的多半不是在問：
        //「我過幾天會寄給妳」「多少有點褪色」（review 實測誤判）。
        guard !isEmbedded(clause), !isIndefinite(clause) else { return false }
        let chars = Array(clause)
        for q in interrogatives {
            var search = clause.startIndex..<clause.endIndex
            while let r = clause.range(of: q, range: search) {
                // 句首＝前面什麼都沒有，或正好是主語（「你幾點到」）；「我過幾天會寄給妳」的「我過」不是主語。
                let prefix = String(clause[clause.startIndex..<r.lowerBound])
                let after = chars.count - clause.distance(from: clause.startIndex, to: r.upperBound)
                if prefix.isEmpty || subjects.contains(prefix) || after <= 3 { return true }
                search = r.upperBound..<clause.endIndex
            }
        }
        return false
    }

    private static func lastClause(_ s: String) -> String {
        let breakers: Set<Character> = ["，", ",", "；", ";", "：", ":"]
        if let i = s.lastIndex(where: { breakers.contains($0) }) {
            let rest = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return s
    }

    private static func containsInterrogative(_ s: String) -> Bool {
        interrogatives.contains { s.contains($0) }
    }

    /// 疑問詞（或指定位置）前面出現「不知道／問問／看看……」＝間接問句，整句是陳述。
    private static func isEmbedded(_ s: String, before limit: String.Index? = nil) -> Bool {
        let firstQ = limit ?? interrogatives.compactMap { s.range(of: $0)?.lowerBound }.min() ?? s.endIndex
        let head = s[s.startIndex..<firstQ]
        return embedders.contains { head.contains($0) }
    }

    /// 任指：「什麼都可以」「誰都知道」「多少也好」「怎麼樣都行」。
    private static func isIndefinite(_ s: String) -> Bool {
        s.range(of: "(什麼|什么|誰|谁|哪裡|哪里|哪個|哪个|怎麼樣|怎么样|多少|幾個|几个)[^，,。]{0,4}(都|也)", options: .regularExpression) != nil
    }

    // MARK: - 感嘆

    private static let exclamations = ["好棒", "超棒", "太棒", "好厲害", "太厲害", "好可愛", "太可愛", "天啊", "天哪", "我的天",
                                       "恭喜", "加油", "太好了", "好開心", "太開心", "好感動", "謝謝你", "謝謝大家", "感謝大家",
                                       "哈哈", "生日快樂", "新年快樂", "辛苦了", "好好吃", "好好喝", "真的假的", "不會吧"]

    static func isExclamation(_ core: String) -> Bool {
        let clause = lastClause(core.trimmingCharacters(in: .whitespaces))
        if exclamations.contains(where: { clause.contains($0) }) { return true }
        // 「太……了」：太熱了、太誇張了（不含否定「不太……了」：「我不太記得了」是陳述）。
        if clause.range(of: "(?<!不)太[^，,。！？]{1,6}了(啦|吧|啊)?$", options: .regularExpression) != nil { return true }
        // 「好……喔／啊」：好漂亮喔、好累啊（短句才算，長句的「好」多半是程度副詞）。
        if clause.count <= 10, clause.range(of: "^.{0,3}好[^，,。]{1,4}(喔|哦|啊|呀)$", options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - 英文

    private static let englishQuestionStarts = ["what", "why", "how", "when", "where", "who", "which", "can", "could", "would",
                                                "will", "do", "does", "did", "is", "are", "should", "may", "shall", "have", "has"]

    static func isEnglishQuestion(_ core: String) -> Bool {
        let trimmed = core.trimmingCharacters(in: .whitespaces)
        // 整句要是英文（夾中文的句子交給中文規則）。
        guard !trimmed.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return false }
        let first = trimmed.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map { $0.lowercased() } ?? ""
        return englishQuestionStarts.contains(first)
    }
}
