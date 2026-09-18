import Foundation
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
enum PausePunctuator {
    /// 停頓超過這個秒數補逗號。
    static let commaGap: TimeInterval = 0.18
    /// 停頓超過這個秒數補句號。
    static let periodGap: TimeInterval = 0.65
    /// 靜音段與字交界的容許誤差（秒）。
    static let boundaryTolerance: TimeInterval = 0.12

    /// - Parameter silences: 錄音時量到的靜音段。實機辨識器的片段時間首尾相連（長度延伸到下一個字），
    ///   看不到停頓；靜音段才是真正的停頓來源（2026-09-18 實機量測）。
    static func punctuate(_ tokens: [TimedToken], silences: [SilenceInterval] = [],
                          commaGap: TimeInterval = commaGap, periodGap: TimeInterval = periodGap) -> String {
        var out = ""
        for (i, token) in tokens.enumerated() {
            let piece = token.text
            guard !piece.isEmpty else { continue }
            if i > 0, let last = out.last {
                let prev = tokens[i - 1]
                let timestampGap = token.start - (prev.start + prev.duration)
                let boundary = token.start
                let silence = silences.first {
                    $0.start <= boundary + boundaryTolerance && $0.end >= boundary - boundaryTolerance
                }?.duration ?? 0
                let gap = max(timestampGap, silence)
                let boundaryHasPunct = isPunctuation(last) || piece.first.map(isPunctuation) == true
                if !boundaryHasPunct && gap >= commaGap {
                    let latin = isLatinish(last)
                    if gap >= periodGap {
                        let question = ClauseRules.isQuestion(ClauseRules.lastClause(out))
                        out += latin ? (question ? "? " : ". ") : (question ? "？" : "。")
                    } else {
                        out += latin ? ", " : "，"
                    }
                } else if needsSpace(last, piece.first) {
                    out += " "
                }
            }
            out += piece
        }
        return ClauseRules.finish(out)
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
        if endingQuestionWords.contains(where: { clause.hasSuffix($0) }) { return true }
        if aNotA.contains(where: { clause.contains($0) }) { return true }
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
