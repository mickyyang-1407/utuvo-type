import Foundation
import UTUVOTypeCore
import NaturalLanguage
@preconcurrency import AVFAudio
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 辨識結果的一個片段（SFTranscriptionSegment 的可測版本）。
struct TimedToken: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
}

/// 錄音中量到的一段靜音（秒，相對於這次辨識的第一個 buffer）。
struct SilenceInterval: Equatable, Sendable {
    let start: Double
    let duration: Double
    var end: Double { start + duration }
}

/// 一個 buffer 的音量（dBFS）與時間。
struct LevelSample: Equatable, Sendable {
    let time: Double
    let duration: Double
    let db: Float
}

/// 從音量找靜音段。門檻依這段錄音的背景噪音自動調：背景（第 10 百分位）＋12 dB，夾在 −60…−30 dBFS。
enum SilenceDetector {
    static func intervals(_ samples: [LevelSample], minDuration: Double = 0.18) -> [SilenceInterval] {
        guard samples.count >= 5 else { return [] }
        let sorted = samples.map(\.db).sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = min(-30, max(floor + 12, -60))
        var out: [SilenceInterval] = []
        var runStart: Double?
        var runEnd: Double = 0
        for sample in samples {
            if sample.db < threshold {
                if runStart == nil { runStart = sample.time }
                runEnd = sample.time + sample.duration
            } else if let start = runStart {
                if runEnd - start >= minDuration { out.append(SilenceInterval(start: start, duration: runEnd - start)) }
                runStart = nil
            }
        }
        // 句尾靜音不算斷句（後面沒字了），不收。
        return out
    }
}

/// 依講話停頓補標點（決定論、零延遲）。
/// Apple 辨識器的 addsPunctuation 很保守，常常一整段只有一個逗號（實機回報「黏成一句」）；
/// 但每個片段都有時間戳，停頓就是人講話時的斷句。
///
/// 2026-09-24 實測回報「一休息就出現句點」：停頓是在想下一個詞，不是句子講完（Typeless 不看停頓斷句）。
/// Mac 上真 SpeechTranscriber 跑「我覺得這個方案…可能還要再…想一下」：引擎原文沒有句點，
/// 舊規則（停 ≥0.65 s 補句號）產出「這個方案。可能還要再。想一下」。現在停頓最多只補逗號／問號；
/// 句號只來自引擎的語意標點與整理。
enum PausePunctuator {
    /// 停頓超過這個秒數補逗號。
    static let commaGap: TimeInterval = 0.18
    /// 停頓超過這個秒數，問句子句用整句判斷（lastClause）補問號；不再產生句號。
    static let periodGap: TimeInterval = 0.65
    /// 這一小句還不到 minClause 個字＝講話中的遲疑（「然後我剛剛…靠卡」「那個…我剛剛」），停多久都不補逗號。
    /// 例外：問句、或以語助詞收尾（「好啊…我等你」）＝一小句已經講完。
    static let minClause = 6
    /// 停頓已經很長（≥ periodGap）：一小句有 4 個字就算講完一段（「記得帶檔案…然後」）；「那個…」「你明天…」仍算遲疑。
    static let longPauseMinClause = 4
    /// 句子停在這些字＝後面一定還有話（「搭到…中正紀念堂」「還要再…想一下」）；停多久都不補標點。
    static let danglingEndings = ["到", "在", "去", "從", "往", "跟", "和", "與", "把", "被", "給", "對", "向", "換成", "前往", "搭", "坐", "還有", "因為", "如果", "而且", "但是", "所以", "然後", "就是",
                                  "再", "很", "最", "比較", "一個", "這個", "那個", "可能", "應該", "已經", "正在", "先", "都", "也", "還", "的"]
    /// 靜音段與字交界的容許誤差（秒）。
    static let boundaryTolerance: TimeInterval = 0.12

    /// - Parameter silences: 錄音時量到的靜音段。實機辨識器的片段時間首尾相連（長度延伸到下一個字），
    ///   看不到停頓；靜音段才是真正的停頓來源（2026-09-18 實機量測）。
    static func punctuate(_ rawTokens: [TimedToken], silences: [SilenceInterval] = [],
                          commaGap: TimeInterval = commaGap, periodGap: TimeInterval = periodGap) -> String {
        let tokens = dropMidWordPunctuation(rawTokens)
        var out = ""
        // 新引擎的片段幾乎是一個字一段：停頓落在詞中間（「然…後」）不能斷。先斷詞，只准在詞界補標點（2026-09-19 實機「然，後」）。
        let wordStarts = wordStartOffsets(tokens.map(\.text).joined())
        var offset = 0
        /// 語助詞前的停頓先記著（「儲值…了今天」）：斷點挪到語助詞後面，不是丟掉（2026-09-19 實機「就除值了今天，又說」）。
        var deferredGap: TimeInterval?
        for (i, token) in tokens.enumerated() {
            let piece = token.text
            let tokenOffset = offset
            offset += piece.count
            guard !piece.isEmpty else { continue }
            if i > 0, let last = out.last {
                let prev = tokens[i - 1]
                let timestampGap = token.start - (prev.start + prev.duration)
                let boundary = token.start
                let silence = silences.first {
                    $0.start <= boundary + boundaryTolerance && $0.end >= boundary - boundaryTolerance
                }?.duration ?? 0
                var gap = max(timestampGap, silence)
                if let deferred = deferredGap, !isParticleOnly(piece) { gap = max(gap, deferred); deferredGap = nil }
                if isParticleOnly(piece), gap >= commaGap { deferredGap = max(deferredGap ?? 0, gap) }
                let boundaryHasPunct = isPunctuation(last) || piece.first.map(isPunctuation) == true
                // 句尾語助詞（了／啦／吧…）是前一句的尾巴：前面停頓再久也不補，標點留到它後面的下一個停頓（2026-09-19 實機「學校，了」）。
                // 英文片段本來就是整個字：英文前後一律算詞界；中文靠斷詞。
                let latinEdge = isLatinish(last) || (piece.first.map(isLatinish) ?? false)
                let atWordBoundary = latinEdge || wordStarts.contains(tokenOffset) || piece.first?.isWhitespace == true
                // 遲疑：這一小句還短（停多久都一樣）。但問句子句（「會不會扣分」）、語助詞收尾（「好啊」）後面的停頓照樣斷。
                let subclause = ClauseRules.lastSubclause(out)
                let particleEnded = subclause.last.map { Normalizer.sentenceParticles.contains($0) } ?? false
                let needed = gap >= periodGap ? longPauseMinClause : minClause
                let hesitation = clauseLength(subclause) < needed && !ClauseRules.isQuestion(subclause) && !particleEnded
                // 數字中間不斷（「7:4…2」）；停在「到／再／換成…」這種後面一定還有話的字＝在想下一個詞（「搭到…中正紀念堂」）。
                let inNumber = (last.isNumber || last == ":" || last == ".") && (piece.first?.isNumber ?? false)
                let dangling = danglingEndings.contains(where: { out.hasSuffix($0) })
                if !boundaryHasPunct && gap >= commaGap && !isParticleOnly(piece) && atWordBoundary && !hesitation && !inNumber && !dangling {
                    // 英文標點只給純英文的句子；中文句尾剛好是英文字（「交 ADM」）照樣用全形（2026-09-19 新引擎實測「DMBWF,」）。
                    let latin = isLatinish(last) && !containsCJK(out)
                    if gap >= periodGap {
                        // 長停頓也只補逗號；問句（整句判斷）才補問號。
                        let question = ClauseRules.isQuestion(ClauseRules.lastClause(out))
                        out += latin ? (question ? "? " : ", ") : (question ? "？" : "，")
                    } else {
                        // 短停頓但這一小句「收在問句」（「…檔案嗎」「會不會扣分」）→ 問號。
                        // 句中有「怎麼」但話還沒講完（「那我們要怎麼樣設計可以讓…」）不算（2026-09-20 實機「可以讓？使用者」）。
                        let question = ClauseRules.endsAsQuestion(ClauseRules.lastSubclause(out))
                        out += latin ? (question ? "? " : ", ") : (question ? "？" : "，")
                    }
                } else if !inNumber, needsSpace(last, piece.first) {
                    out += " "
                }
            }
            out += piece
        }
        return ClauseRules.finish(dropHesitationPeriods(out))
    }

    /// 引擎自己也會在遲疑的停頓插句號（2026-09-24 Mac 真 SpeechTranscriber：「你明天。有空嗎」）。
    /// 句中的「。」前面那一小句太短、又不是問句或語助詞收尾＝講到一半停下來想，拿掉。句尾的句號不動。
    static func dropHesitationPeriods(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        for (k, c) in chars.enumerated() {
            if c == "。", k + 1 < chars.count, !chars[(k + 1)...].allSatisfy({ $0.isWhitespace || isPunctuation($0) }) {
                let subclause = ClauseRules.lastSubclause(out).trimmingCharacters(in: .whitespaces)
                let particleEnded = subclause.last.map { Normalizer.sentenceParticles.contains($0) } ?? false
                if !subclause.isEmpty, clauseLength(subclause) < minClause, !particleEnded, !ClauseRules.isQuestion(subclause) {
                    continue
                }
            }
            out.append(c)
        }
        return out
    }

    /// 詞開頭的字元位移（以 Character 計）。斷詞器用系統內建（NaturalLanguage，裝置端）。
    static func wordStartOffsets(_ text: String) -> Set<Int> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.traditionalChinese)
        var starts: Set<Int> = [0]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            starts.insert(text.distance(from: text.startIndex, to: range.upperBound))
            return true
        }
        return starts
    }

    /// 這一小句有幾個字（中文一字一個、英數一個詞一個）。
    static func clauseLength(_ s: String) -> Int {
        var n = 0; var inWord = false
        for c in s {
            if isLatinish(c) { if !inWord { n += 1; inWord = true } }
            else { inWord = false; if !c.isWhitespace && !isPunctuation(c) { n += 1 } }
        }
        return n
    }

    /// 新引擎自己會把句號／逗號插在詞中間（「原。山站」，2026-09-19）：前後都是中文、而且拿掉標點後那個位置不是詞界 → 拿掉。
    static func dropMidWordPunctuation(_ tokens: [TimedToken]) -> [TimedToken] {
        let marks: Set<Character> = ["，", "。", ",", "."]
        var flat: [(ch: Character, token: Int)] = []
        for (i, t) in tokens.enumerated() { for c in t.text { flat.append((c, i)) } }
        guard flat.contains(where: { marks.contains($0.ch) }) else { return tokens }
        let stripped = String(flat.filter { !marks.contains($0.ch) }.map(\.ch))
        let starts = wordStartOffsets(stripped)
        var keep = [Bool](repeating: true, count: flat.count)
        var strippedOffset = 0
        for (k, item) in flat.enumerated() {
            if marks.contains(item.ch) {
                let prev = k > 0 ? flat[k - 1].ch : nil, next = k + 1 < flat.count ? flat[k + 1].ch : nil
                let splitsStation = k + 2 < flat.count && flat[k + 2].ch == "站"      // 「原。山站」：站名最後一個字被切開
                if let prev, let next, containsCJK(String(prev)), containsCJK(String(next)),
                   !starts.contains(strippedOffset) || splitsStation {
                    keep[k] = false
                }
            } else {
                strippedOffset += 1
            }
        }
        var texts = [String](repeating: "", count: tokens.count)
        for (k, item) in flat.enumerated() where keep[k] { texts[item.token].append(item.ch) }
        return tokens.enumerated().map { TimedToken(text: texts[$0.offset], start: $0.element.start, duration: $0.element.duration) }
    }

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    static func isParticleOnly(_ piece: String) -> Bool {
        let t = piece.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 2 && t.allSatisfy { Normalizer.sentenceParticles.contains($0) }
    }

    static func isPunctuation(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
    }

    static func isLatinish(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func needsSpace(_ left: Character, _ right: Character?) -> Bool {
        guard let right, !left.isWhitespace, !right.isWhitespace else { return false }
        return isLatinish(left) && isLatinish(right)
    }

}

/// 不靠停頓的斷句規則（2026-09-18 產品決定：標點再優化）。都是保守規則，寧可少補不要補錯。
enum ClauseRules {
    /// 這一小句「收在問句」：句尾是嗎／呢／疑問詞，或正反問就在最後幾個字。句中出現疑問詞但後面還接著話＝不算。
    static func endsAsQuestion(_ rawClause: String) -> Bool {
        let clause = rawClause.trimmingCharacters(in: .whitespaces)
        guard isQuestion(clause) else { return false }
        if clause.hasSuffix("嗎") || clause.hasSuffix("吗") || clause.hasSuffix("呢") { return true }
        if endingQuestionWords.contains(where: { clause.hasSuffix($0) }) { return true }
        let tail = String(clause.suffix(6))
        return aNotA.contains(where: { tail.contains($0) }) || clause.first.map { $0.isASCII } == true
    }

    /// 最後一個標點（含逗號、頓號）之後的那一小句。
    static func lastSubclause(_ s: String) -> String {
        let marks: Set<Character> = ["。", "？", "！", ".", "?", "!", "，", ",", "、", "；", ";", "："]
        guard let i = s.lastIndex(where: { marks.contains($0) }) else { return s }
        return String(s[s.index(after: i)...])
    }

    /// 最後一個句號／問號／驚嘆號之後的那一句（逗號不算斷句）。
    static func lastClause(_ s: String) -> String {
        let enders: Set<Character> = ["。", "？", "！", ".", "?", "!"]
        guard let i = s.lastIndex(where: { enders.contains($0) }) else { return s }
        return String(s[s.index(after: i)...])
    }

    /// 正反問：出現在句中也是問句（「你可不可以拍給我看」）。
    static let aNotA = ["是不是", "要不要", "可不可以", "能不能", "會不會", "有沒有", "好不好", "對不對", "行不行", "想不想", "去不去", "來不來", "在不在", "知不知道",
                        // 簡體
                        "会不会", "有没有", "对不对", "来不来"]
    /// 句尾是這些＝問句（「你要吃什麼」「在哪裡」「幾點」）。
    static let endingQuestionWords = ["什麼", "甚麼", "為什麼", "怎麼", "怎麼辦", "怎麼樣", "怎樣", "如何", "哪裡", "哪邊", "哪個", "哪些", "誰", "多少", "多久", "幾點", "幾個", "幾天", "幾次", "為何",
                                       // 簡體
                                       "什么", "为什么", "怎么", "怎么办", "怎么样", "哪里", "哪边", "哪个", "谁", "几点", "几个", "几天", "几次", "为何"]
    /// 問句裡的疑問詞（配合句尾「呢」）。
    static let questionWords = ["什麼", "甚麼", "怎麼", "為什麼", "哪", "誰", "幾", "多少", "多久", "如何",
                                 "什么", "怎么", "为什么", "谁", "几"]
    /// 這些開頭是「轉述」不是發問（「我不知道他是不是要來」）。
    static let embedMarkers = ["我不知道", "不知道", "不確定", "不曉得", "我在想", "看看", "問問", "不管",
                                "不确定", "不晓得", "问问"]
    /// 出現在正反問（有沒有／要不要…）前面＝轉述別人的問題，不是發問。
    static let reportMarkers = ["問到", "問說", "問我", "問他", "問她", "問你", "問了", "想知道", "確認", "看一下", "查一下", "不知道", "不確定", "不曉得",
                                "问到", "问说", "问我", "问他", "问了", "确认"]
    static let englishQuestionStarts = ["what", "why", "how", "when", "where", "who", "which", "can", "could", "do", "does", "did", "is", "are", "was", "were", "will", "would", "should", "shall", "may", "have", "has"]

    static func isQuestion(_ rawClause: String) -> Bool {
        let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,、")))
        guard !clause.isEmpty else { return false }
        if let first = clause.split(separator: " ").first, first.allSatisfy({ $0.isASCII }) {
            let word = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return englishQuestionStarts.contains(word)
        }
        // 轉述開頭（允許前面有主詞，例如「我不確定…」「他不知道…」）：不是發問。
        let head = String(clause.prefix(5))
        if embedMarkers.contains(where: { head.contains($0) }) { return false }
        // 「為什麼／怎麼」當疑問詞：句中出現就是問句（「不怎麼好」是陳述，排除前面有「不」）。
        for word in ["為什麼", "为什么", "為何", "为何"] where clause.contains(word) { return true }
        for word in ["怎麼", "怎么"] {
            if let r = clause.range(of: word), r.lowerBound == clause.startIndex || clause[clause.index(before: r.lowerBound)] != "不" { return true }
        }
        if clause.hasSuffix("嗎") || clause.hasSuffix("吗") { return true }
        if (clause.hasSuffix("麼") || clause.hasSuffix("么")),
           !["這麼", "那麼", "多麼", "这么", "那么", "多么"].contains(where: { clause.hasSuffix($0) }) { return true }
        if endingQuestionWords.contains(where: { clause.hasSuffix($0) }) {
            // 「我試了幾次」「去過幾天」：了／過／好＋幾＝「好幾」，是陳述不是問（2026-09-19 新引擎實測）。
            if let r = clause.range(of: "幾", options: .backwards), r.lowerBound > clause.startIndex,
               ["了", "過", "好", "过"].contains(clause[clause.index(before: r.lowerBound)]),
               !["你", "妳", "您"].contains(where: { clause.contains($0) }) { return false }   // 「你試了幾次」還是問句
            return true
        }
        if let hit = aNotA.compactMap({ clause.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            // 轉述：「他們問到之後有沒有可能…」「我想確認要不要…」＝不是在發問。
            let before = clause[..<hit.lowerBound]
            if reportMarkers.contains(where: { before.contains($0) }) { return false }
            return true
        }
        if clause.hasSuffix("呢") {
            // 「你呢」「那我呢」這種短句，或句中有疑問詞：問句；「還在做呢」：陳述。
            return clause.count <= 4 || questionWords.contains(where: { clause.contains($0) })
        }
        return false
    }

    /// 轉折／因果詞前面補逗號：前面同一句已經至少 6 個字、而且前一個字不是黏著用法。
    static let connectors = ["但是", "可是", "所以", "然後", "而且", "因為", "如果", "雖然", "結果", "只是",
                              "然后", "因为", "虽然", "结果"]
    /// 前一個字是這些就不斷（「就是因為」「的結果」「不只是」「並且而且」）。
    static let gluedBefore: Set<Character> = ["是", "就", "正", "都", "也", "只", "才", "並", "還", "的", "不", "，", "、", "并", "还"]

    static func connectorCommas(_ s: String) -> String {
        var chars = Array(s)
        var i = 0
        var sinceBreak = 0
        let breakers: Set<Character> = ["。", "？", "！", "，", "、", ".", "?", "!", ",", "；", ";", "：", ":", "\n"]
        while i < chars.count {
            if breakers.contains(chars[i]) { sinceBreak = 0; i += 1; continue }
            if sinceBreak >= 6, i > 0, !gluedBefore.contains(chars[i - 1]),
               let hit = connectors.first(where: { word in
                   let w = Array(word)
                   return i + w.count <= chars.count && Array(chars[i..<(i + w.count)]) == w
               }) {
                chars.insert("，", at: i)
                i += 1 + hit.count
                sinceBreak = hit.count
                continue
            }
            if !chars[i].isWhitespace { sinceBreak += 1 }
            i += 1
        }
        return String(chars)
    }

    /// 最後整理：補轉折逗號；最後一句是問句而且沒有句末標點就補問號。
    static func finish(_ s: String) -> String {
        var out = connectorCommas(s)
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !PausePunctuator.isPunctuation(last) else { return out }
        if isQuestion(lastClause(trimmed)) {
            out = trimmed + (PausePunctuator.isLatinish(last) ? "?" : "？")
        }
        return out
    }
}

/// Apple Intelligence 只補標點：輸出必須跟輸入「逐字相同」（去掉標點、空白、大小寫後），否則丟掉不用。
/// 模型可以斷句，但不准改任何一個字——改字是聽寫最不能接受的錯。
enum PunctuationGuard {
    static func preservesText(original: String, candidate: String) -> Bool {
        let a = skeleton(original), b = skeleton(candidate)
        guard !a.isEmpty else { return false }
        return a == b
    }

    static func skeleton(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace && !PausePunctuator.isPunctuation($0) })
    }
}

/// Apple Intelligence 補標點（裝置端）。錄音一開始就預熱；有時間上限，逾時就用停頓版。
@MainActor
final class AIPunctuator {
    static let shared = AIPunctuator()
    private var sessionBox: AnyObject?

    static let instructions = """
    你是標點校正器。使用者給你一段語音辨識的逐字稿，請只加入或調整標點符號與斷句，\
    讓它讀起來自然。絕對不可以新增、刪除、替換或重排任何文字、數字、英文字母。\
    保留原本的語言與用字。只輸出校正後的文字，不要解釋、不要引號。
    """

    var isAvailable: Bool { OnDeviceAssistant.onDeviceAvailable }

    /// 短句靠停頓斷句就夠，不值得等模型。
    static let minimumLength = 20

    /// 預設關閉（2026-09-18 實機量測）：預熱後一次 0.89 s，但對已經用停頓斷好句的長句，
    /// 輸出與輸入完全相同——多等將近 1 秒卻沒有改善。之後若換更好的模型再重量、再決定開不開。
    static let refineEnabled = false

    func prewarm() {
        #if canImport(FoundationModels)
        guard Self.refineEnabled, #available(iOS 26.0, *), isAvailable else { return }
        let session = currentSession()
        session.prewarm()
        #endif
    }

    /// 回傳通過把關的結果；不可用、逾時、改了字都回 nil。
    func refine(_ text: String, timeout: Duration = .milliseconds(1800)) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable, text.count >= Self.minimumLength else { return nil }
        let session = currentSession()
        let gate = OnceGate()
        let candidate: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task { @MainActor in
                let response = try? await session.respond(to: text, options: GenerationOptions(samplingMode: .greedy))
                if gate.claim() { cont.resume(returning: response?.content) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() { cont.resume(returning: nil) }
            }
        }
        // 每次都用新的 session（避免上一段內容進入 context）；下一次會重新預熱。
        sessionBox = nil
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return PunctuationGuard.preservesText(original: text, candidate: trimmed) ? trimmed : nil
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func currentSession() -> LanguageModelSession {
        if let existing = sessionBox as? LanguageModelSession { return existing }
        let session = LanguageModelSession(instructions: Self.instructions)
        sessionBox = session
        return session
    }
    #endif
}

/// 錄音中每個 buffer 的音量紀錄（音訊執行緒寫、主執行緒讀）。只記這次辨識的，換下一次就清空。
final class LevelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [LevelSample] = []
    private var elapsed: Double = 0
    private var latestDB: Float = -120
    private var latestAt: Double = 0
    private var sink: VoiceLevelChannel?

    func reset() {
        lock.lock(); samples.removeAll(keepingCapacity: true); elapsed = 0; latestAt = 0; lock.unlock()
    }

    /// 光球用：每個 buffer 的音量同時寫進跨程序通道（鍵盤光球讀）。nil＝不寫。
    func setLiveSink(_ channel: VoiceLevelChannel?) {
        lock.lock(); let old = sink; sink = channel; lock.unlock()
        if channel == nil { old?.clear() }
    }

    /// 同程序的光球讀最新音量；超過 VoiceLevelChannel.maxAge 沒更新＝沒在錄，回 nil。
    func latest(now: Double = CFAbsoluteTimeGetCurrent()) -> Float? {
        lock.lock(); defer { lock.unlock() }
        let age = now - latestAt
        return age >= 0 && age <= VoiceLevelChannel.maxAge ? latestDB : nil
    }

    /// 音訊執行緒呼叫：算這個 buffer 的 RMS（第一聲道）。
    func record(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.sampleRate > 0, let data = buffer.floatChannelData?[0] else { return }
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        let rms = (sum / Float(frames)).squareRoot()
        let db = 20 * log10(rms + 1e-9)
        let duration = Double(frames) / buffer.format.sampleRate
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        samples.append(LevelSample(time: elapsed, duration: duration, db: db))
        elapsed += duration
        latestDB = db
        latestAt = now
        let live = sink
        lock.unlock()
        live?.write(db: db, at: now)
    }

    var snapshot: [LevelSample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

/// 先到先贏的一次性閘門（逾時與結果競賽用；不用 TaskGroup——它會等所有子任務結束，逾時等於沒設）。
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
