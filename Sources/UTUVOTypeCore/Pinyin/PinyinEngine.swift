import Foundation

/// 選字候選：`consumed` 是它從緩衝區開頭吃掉幾個原始字元（字母＋緊跟在後的 `'` 分隔號）。
public struct PinyinCandidate: Equatable, Sendable {
    public let text: String
    public let consumed: Int

    public init(text: String, consumed: Int) {
        self.text = text
        self.consumed = consumed
    }
}

/// 簡體拼音輸入引擎（純 Foundation，不碰 UIKit）。公開介面與 `ZhuyinEngine` 同形，鍵盤可以二選一。
///
/// 緩衝區＝使用者打的原始字母（a–z）與 `'` 分隔號，還沒轉換。每次查詢時把它解析成「音節網格」：
/// - 在每個字母位置，往後 1…6 個字母若是完整音節（或 `lve`／`nve` 別名）→ 一個「完整音節」節點；
/// - 若是聲母（b p m f d t n l g k h j q x zh ch sh r z c s y w）→ 一個「縮寫」節點，代表以它開頭的任何音節；
/// - 緩衝區最後一段若只是某些音節的前綴（例 `nih` 的 `h`、`zhongg` 的 `g`、`xia` 之後的 `n`…）→ 同樣是「縮寫」節點。
/// - `'` 是強制分界（`xi'an` 只能切成 xi＋an），會併進它前面那個節點吃掉的字元數。
///
/// 整句轉換用 Viterbi（DAG 最長路徑）：每段詞覆蓋 1…4 個節點（詞庫最長 4 音節），段分數＝
/// 該段所有可能拼音中詞庫最高分（log10 機率），縮寫節點每個再扣 `partialPenalty`；段數越多、
/// 機率連乘越小，所以會自然偏好長詞與常用詞（`xian` → 先，`xi'an` → 西安）。
/// 完全無法解析的字元以原字母墊過去（每字 −99），所以 preedit 永遠涵蓋整個緩衝區。
///
/// 縮寫支援範圍：任意節點都可以是聲母縮寫（`nh` → 你好、`zg` → 中国、`zgr` → 中国人、`bjdx` → 北京大学），
/// 最後一個節點可以是任何未打完的音節前綴（`nih` → 你好）。中間的未打完韻母（例 `zhonguo` 的 `zhon`）不支援。
///
/// 執行緒：所有狀態都由內部鎖保護，可以跨 actor 傳遞；實務上由鍵盤主執行緒單獨使用即可。
public final class PinyinEngine: @unchecked Sendable {
    /// 候選數上限。
    public static let candidateLimit = 60
    /// 多字詞候選最多佔幾格，保證單字候選一定排得進來。
    public static let phraseCandidateLimit = 30
    /// 緩衝區最多幾個字元（字母＋分隔號）；超過時 `type` 回 false。限制 Viterbi 最壞成本。
    public static let maximumBufferLength = 64
    /// 每個縮寫／未打完音節節點扣的分數（log10，≈ 機率打 1/30）。
    public static let partialPenalty = 1.5
    /// 無法解析的字元每個扣的分數。
    static let rawPenalty = 99.0

    public let lexicon: PinyinLexicon

    private let lock = NSLock()
    private var raw: [UInt8] = []
    private var cached: (raw: [UInt8], analysis: Analysis)?

    public init?(dataURL: URL) {
        guard let lexicon = PinyinLexicon(url: dataURL) else { return nil }
        self.lexicon = lexicon
    }

    /// 共用同一份詞庫（例：背景載入詞庫後交給主執行緒建引擎）。
    public init(lexicon: PinyinLexicon) {
        self.lexicon = lexicon
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static let apostrophe = UInt8(ascii: "'")

    /// a–z 或 `'`。
    public static func isInputByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || b == apostrophe
    }

    // MARK: - 狀態

    /// 還沒轉換的原始字母（含使用者打的 `'`）。
    public var composing: String { locked { String(decoding: raw, as: UTF8.self) } }

    public var isEmpty: Bool { locked { raw.isEmpty } }

    // MARK: - 輸入

    /// 打一個字母（a–z）或分隔號 `'`。回傳 false＝沒有被接受：
    /// - 非 a–z／`'` 的字元（大寫、數字、標點交給鍵盤自己處理）；
    /// - 在音節開頭打 i、u、v（沒有任何音節以它們開頭）；
    /// - 緩衝區空的時候打 `'`，或連打兩個 `'`；
    /// - 緩衝區已滿 `maximumBufferLength`。
    @discardableResult
    public func type(_ letter: Character) -> Bool {
        locked {
            guard let b = letter.asciiValue, Self.isInputByte(b), raw.count < Self.maximumBufferLength else { return false }
            let atSegmentStart = raw.isEmpty || raw.last == Self.apostrophe
            if b == Self.apostrophe {
                guard !atSegmentStart else { return false }
            } else if atSegmentStart {
                guard lexicon.syllables.canStartSyllable(letter) else { return false }
            }
            raw.append(b)
            return true
        }
    }

    /// 倒退：刪最後一個字元（字母或 `'`）。空的回 false。
    @discardableResult
    public func backspace() -> Bool {
        locked {
            guard !raw.isEmpty else { return false }
            raw.removeLast()
            return true
        }
    }

    public func reset() {
        locked { raw.removeAll() }
    }

    // MARK: - 轉換

    /// 整個緩衝區的最佳轉換結果；無法解析的字元以原字母顯示。
    public var preedit: String {
        locked { analysis().walk.map(\.text).joined() }
    }

    /// 最佳轉換路徑的音節切分（縮寫節點照打的字母顯示，例 `nih` → ["ni", "h"]）。
    public var bestSegmentation: [String] {
        locked { analysis().walk.flatMap(\.pieces) }
    }

    /// 不動引擎狀態，回傳任意字串以詞頻加權的最佳切分（例 `xian` → ["xian"]、`xi'an` → ["xi", "an"]）。
    /// 含非 a–z／`'` 字元回空陣列。
    public func segment(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy(Self.isInputByte) else { return [] }
        return locked { Analysis(raw: bytes, lexicon: lexicon).walk.flatMap(\.pieces) }
    }

    /// 緩衝區開頭的候選：先依覆蓋的原始字元數由多到少，同覆蓋內分數高的在前；含單字。
    /// 只列「剩下的字母還能繼續切成音節」的切法（例 `nihao` 不會出現只吃掉 `n` 的候選）。
    /// 多字詞最多 `phraseCandidateLimit` 個，總數上限 `candidateLimit`。
    public var candidates: [PinyinCandidate] {
        locked { analysis().candidates(lexicon: lexicon) }
    }

    /// 選一個候選：從緩衝區開頭移除它吃掉的字元（連同緊跟著的 `'`），回傳要送出的文字。
    /// `consumed` 超過目前緩衝區長度（候選已過期）時不動緩衝區、回空字串。
    public func select(_ candidate: PinyinCandidate) -> String {
        locked {
            guard candidate.consumed > 0, candidate.consumed <= raw.count else { return "" }
            raw.removeFirst(candidate.consumed)
            while raw.first == Self.apostrophe { raw.removeFirst() }
            return candidate.text
        }
    }

    /// 整句送出並清空（無法解析的字元原樣附上，不丟使用者打的字）。
    public func commitAll() -> String {
        locked {
            let text = analysis().walk.map(\.text).joined()
            raw.removeAll()
            return text
        }
    }

    /// 呼叫端須持有鎖。
    private func analysis() -> Analysis {
        if let c = cached, c.raw == raw { return c.analysis }
        let a = Analysis(raw: raw, lexicon: lexicon)
        cached = (raw, a)
        return a
    }
}

// MARK: - 音節網格與 Viterbi

extension PinyinEngine {
    /// 網格上的一個節點：原始字元 [start, end)，`next`＝跳過緊跟著的 `'` 之後的位置。
    struct Token {
        let end: Int
        let next: Int
        let range: Range<UInt16>
        let partial: Bool
        let letters: String
    }

    /// 最佳路徑的一段：一個詞（或一個無法解析的字元）。
    struct Segment {
        let text: String
        let pieces: [String]
    }

    /// 對一份原始緩衝區的完整解析（網格＋最佳路徑）。不可變，快取在引擎裡。
    struct Analysis {
        let count: Int
        let start: Int
        /// tokens[i]：從位置 i 開始的節點。
        let tokens: [[Token]]
        let walk: [Segment]
        let maxLength: Int

        init(raw: [UInt8], lexicon: PinyinLexicon) {
            let n = raw.count
            count = n
            maxLength = lexicon.maximumPhraseLength
            func skip(_ i: Int) -> Int {
                var j = i
                while j < n && raw[j] == PinyinEngine.apostrophe { j += 1 }
                return j
            }
            start = skip(0)
            let syl = lexicon.syllables
            var tokens = [[Token]](repeating: [], count: n + 1)
            for i in 0..<n where raw[i] != PinyinEngine.apostrophe {
                for len in 1...PinyinSyllables.maximumSyllableLength where i + len <= n {
                    if raw[i + len - 1] == PinyinEngine.apostrophe { break }
                    let s = String(decoding: raw[i..<(i + len)], as: UTF8.self)
                    let next = skip(i + len)
                    let id = syl.id(s)
                    let prefixRange = syl.range(prefix: s)
                    if id == nil && prefixRange == nil { break }   // 不再是任何音節的開頭
                    if let id {
                        tokens[i].append(Token(end: i + len, next: next, range: id..<(id + 1), partial: false, letters: s))
                    }
                    if let r = prefixRange, r.count > 1 || id == nil,
                       PinyinSyllables.initials.contains(s) || i + len == n {
                        tokens[i].append(Token(end: i + len, next: next, range: r, partial: true, letters: s))
                    }
                }
                // 這個位置能讀出更長的完整音節時，較短的縮寫不算（`women` 的 w、`xian` 的 x、`zhong` 的 z／zh），
                // 否則每個全拼字串都會多出一堆「聲母＋剩下字母」的怪切法。
                let longestExact = tokens[i].lazy.filter { !$0.partial }.map { $0.end - i }.max() ?? 0
                tokens[i].removeAll { $0.partial && $0.end - i < longestExact }
            }
            self.tokens = tokens
            walk = Self.viterbi(raw: raw, start: start, tokens: tokens, lexicon: lexicon, skip: skip)
        }

        private static func viterbi(raw: [UInt8], start: Int, tokens: [[Token]], lexicon: PinyinLexicon,
                                    skip: (Int) -> Int) -> [Segment] {
            let n = raw.count
            guard start < n else { return [] }
            let maxLen = lexicon.maximumPhraseLength
            var best = [Double](repeating: -.infinity, count: n + 1)
            var back = [(from: Int, seg: Segment)?](repeating: nil, count: n + 1)
            best[start] = 0
            var ranges: [Range<UInt16>] = []
            var pieces: [String] = []
            for i in start..<n where best[i] > -.infinity && raw[i] != PinyinEngine.apostrophe {
                // 從 i 出發、覆蓋 1…maxLen 個節點的所有詞
                func extend(_ pos: Int, _ penalty: Double) {
                    for t in tokens[pos] {
                        ranges.append(t.range)
                        pieces.append(t.letters)
                        defer { ranges.removeLast(); pieces.removeLast() }
                        guard lexicon.hasKey(withPrefix: ranges[...]) else { continue }
                        let p = penalty - (t.partial ? PinyinEngine.partialPenalty : 0)
                        if let top = lexicon.best(ranges: ranges[...]) {
                            let score = best[i] + top.score + p
                            if score > best[t.next] {
                                best[t.next] = score
                                back[t.next] = (i, Segment(text: top.text, pieces: pieces))
                            }
                        }
                        if ranges.count < maxLen { extend(t.next, p) }
                    }
                }
                extend(i, 0)
                // 墊底：這個字元原樣輸出（連同緊跟的 '）
                let j = skip(i + 1)
                let score = best[i] - PinyinEngine.rawPenalty
                if score > best[j] {
                    best[j] = score
                    let s = String(decoding: raw[i..<j], as: UTF8.self)
                    back[j] = (i, Segment(text: s, pieces: [String(decoding: raw[i..<(i + 1)], as: UTF8.self)]))
                }
            }
            var out: [Segment] = []
            var pos = n
            while pos > start, let b = back[pos] {
                out.append(b.seg)
                pos = b.from
            }
            return out.reversed()
        }

        /// 緩衝區開頭的候選。
        func candidates(lexicon: PinyinLexicon) -> [PinyinCandidate] {
            let n = count
            guard start < n else { return [] }
            // 只保留「之後還能繼續切下去」的節點：先求從開頭可達的最遠位置 E，再反向求能走到 E 的位置
            var reach = [Bool](repeating: false, count: n + 1)
            reach[start] = true
            var far = start
            for i in start..<n where reach[i] {
                for t in tokens[i] {
                    reach[t.next] = true
                    far = max(far, t.next)
                }
            }
            var viable = [Bool](repeating: false, count: n + 1)
            viable[far] = true
            for i in stride(from: far - 1, through: start, by: -1) {
                viable[i] = tokens[i].contains { $0.next <= far && viable[$0.next] }
            }

            struct Hit { let text: String; let consumed: Int; let score: Double; let isPhrase: Bool; let order: Int }
            var hits: [Hit] = []
            var index: [String: Int] = [:]   // "consumed|text" → hits 位置（去重、留最高分）
            var ranges: [Range<UInt16>] = []
            func extend(_ pos: Int, _ penalty: Double) {
                for t in tokens[pos] where t.next <= far && viable[t.next] {
                    ranges.append(t.range)
                    defer { ranges.removeLast() }
                    guard lexicon.hasKey(withPrefix: ranges[...]) else { continue }
                    let p = penalty - (t.partial ? PinyinEngine.partialPenalty : 0)
                    let isPhrase = ranges.count > 1
                    let limit = isPhrase ? PinyinEngine.phraseCandidateLimit : PinyinEngine.candidateLimit
                    for e in lexicon.lookup(ranges: ranges[...], limit: limit) {
                        let key = "\(t.next)|\(e.text)"
                        let s = e.score + p
                        if let k = index[key] {
                            if s > hits[k].score {
                                hits[k] = Hit(text: e.text, consumed: t.next, score: s, isPhrase: isPhrase, order: hits[k].order)
                            }
                        } else {
                            index[key] = hits.count
                            hits.append(Hit(text: e.text, consumed: t.next, score: s, isPhrase: isPhrase, order: hits.count))
                        }
                    }
                    if ranges.count < maxLength { extend(t.next, p) }
                }
            }
            extend(start, 0)

            func ordered(_ a: Hit, _ b: Hit) -> Bool {
                if a.consumed != b.consumed { return a.consumed > b.consumed }
                if a.score != b.score { return a.score > b.score }
                return a.order < b.order
            }
            let phrases = Array(hits.filter(\.isPhrase).sorted(by: ordered).prefix(PinyinEngine.phraseCandidateLimit))
            // 單字：每種覆蓋長度先保證一份配額，再依整體順序補滿。否則 `xian` 的 169 個單字
            // 會把 `xi`（西、希…）整層擠出上限。
            let singles = hits.filter { !$0.isPhrase }.sorted(by: ordered)
            let room = PinyinEngine.candidateLimit - phrases.count
            let levels = Set(singles.map(\.consumed)).count
            var picked: [Hit] = []
            var rest: [Hit] = []
            if levels > 0 {
                let quota = max(8, room / levels)
                var used: [Int: Int] = [:]
                for h in singles {
                    if used[h.consumed, default: 0] < quota {
                        used[h.consumed, default: 0] += 1
                        picked.append(h)
                    } else {
                        rest.append(h)
                    }
                }
            }
            let chosenSingles = (picked.sorted(by: ordered).prefix(room) + rest).prefix(room)
            return (phrases + chosenSingles).sorted(by: ordered)
                .prefix(PinyinEngine.candidateLimit)
                .map { PinyinCandidate(text: $0.text, consumed: $0.consumed) }
        }
    }
}
