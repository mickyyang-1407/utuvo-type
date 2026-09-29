import Foundation

/// 選字候選：`readingCount` 是它從緩衝區開頭吃掉幾個音節（含還在組、沒收尾的最後一個）。
public struct ZhuyinCandidate: Equatable, Sendable {
    public let text: String
    public let readingCount: Int

    public init(text: String, readingCount: Int) {
        self.text = text
        self.readingCount = readingCount
    }
}

/// 注音輸入引擎（純 Foundation，不碰 UIKit）。
///
/// 緩衝區＝一串音節段＋正在組的音節 `composing`。音節段有兩種：
/// - **已收尾**：打了聲調鍵或空白（一聲），精確比對那一個音節。
/// - **沒收尾**：還沒打聲調就打了「放不進目前這個音節」的符號（例：打完 ㄋ 又打 ㄏ、打完 ㄋㄧ 又打 ㄏ），
///   前一個音節就被擠成一段、另起新音節。沒收尾的段比對所有相容的音節、不分聲調：
///   打到的槽位要相同，最後一個打到的槽位之後的槽位不限（ㄋ → ㄋㄧˇ、ㄋㄚˋ…；ㄋㄧ → ㄋㄧˇ、ㄋㄧㄢˊ…）。
///   所以 ㄋㄏ → 你好（簡拼）、ㄋㄧㄏㄠ → 你好（不打聲調）。
/// 正在組的音節在找候選時也當成「沒收尾」：只打了 ㄋ 就有 你、那、能… 可選。
/// 比「打出來的樣子」多延伸的音節（ㄋ → ㄋㄧˇ）扣 `partialPenalty`，跟拼音引擎的縮寫同一個值。
///
/// 整句轉換用 Viterbi（DAG 最長路徑）走「讀音網格」：每個起點最多延伸 8 個音節，
/// 節點分數取該讀音在詞庫中的最高分，路徑分數為節點分數相加（log 機率相加＝機率相乘）。
/// 這個作法的概念參考小麥注音的 Gramambular（MIT），程式碼為本專案自行撰寫。
///
/// 執行緒：所有狀態都由內部鎖保護，可以跨 actor 傳遞；實務上由鍵盤主執行緒單獨使用即可。
public final class ZhuyinEngine: @unchecked Sendable {
    /// 候選數上限。
    public static let candidateLimit = 60
    /// 多字詞候選最多佔幾格，保證單字候選一定排得進來。
    public static let phraseCandidateLimit = 30
    /// 沒收尾的音節比對到「比打出來的多幾個符號」的音節時扣的分數（log10）。與拼音縮寫同一個值。
    public static let partialPenalty = PinyinEngine.partialPenalty
    /// 查不到任何音節的段以原樣墊過去，每段扣的分數。
    static let rawPenalty = 99.0
    /// 每次列舉讀音鍵的步數上限（很多個聲母縮寫連打時限制最壞情況的每鍵時間）。
    static let walkNodeBudget = 5_000
    static let candidateNodeBudget = 20_000

    public let lexicon: ZhuyinLexicon

    /// 一個音節位置可以對到哪些音節（ID 由小到大）與各自的扣分。
    struct Node: Hashable, Sendable {
        let ids: [UInt16]
        let penalties: [Double]
        /// 查不到時原樣顯示的文字。
        let raw: String
    }

    /// 緩衝區裡的一個音節段。
    struct Segment: Equatable, Sendable {
        let node: Node
        /// true＝以聲調／空白收尾；false＝被下一個符號擠開、沒收尾。
        let isComplete: Bool
        /// 沒收尾的段保留組字器：倒退到它時回到「正在組」的狀態，可以接著改。
        let composer: ZhuyinComposer
    }

    /// 引擎狀態的快照（取消輸入時還原用）。內容不公開，只能交回同一個詞庫的引擎。
    public struct State: Equatable, Sendable {
        fileprivate let segments: [Segment]
        fileprivate let composer: ZhuyinComposer
    }

    private struct Shape {
        let consonant: Character?
        let medial: Character?
        let rime: Character?
    }

    private let lock = NSLock()
    private var segments: [Segment] = []
    private var composer = ZhuyinComposer()
    /// 音節 ID → 聲母／介音／韻母（比對沒收尾的音節用）。
    private let shapes: [Shape]
    private var partialCache: [String: Node] = [:]
    private var walkCache: [[Node]: String] = [:]

    public convenience init?(dataURL: URL) {
        guard let lexicon = ZhuyinLexicon(url: dataURL) else { return nil }
        self.init(lexicon: lexicon)
    }

    /// 共用同一份詞庫（例：背景載入詞庫後交給主執行緒建引擎）。
    public init(lexicon: ZhuyinLexicon) {
        self.lexicon = lexicon
        shapes = (0..<lexicon.syllableCount).map { id in
            var c = ZhuyinComposer()
            for ch in lexicon.syllable(UInt16(id)) { c.insert(ch) }
            return Shape(consonant: c.consonant, medial: c.medial, rime: c.rime)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 狀態

    /// 緩衝區裡的音節段（例：["ㄋㄧˇ", "ㄏㄠˇ"]；沒收尾的段照打的樣子，例 ["ㄋ"]）。不含正在組的音節。
    public var readings: [String] { locked { segments.map(\.node.raw) } }

    /// 正在組的音節符號（尚未收尾）。
    public var composing: String { locked { composer.composing } }

    public var isEmpty: Bool { locked { segments.isEmpty && composer.isEmpty } }

    /// 緩衝區裡有沒收尾的音節段（簡拼或沒打聲調）。這時空白鍵不當一聲，而是送出整句。
    public var hasUncompletedSyllables: Bool { locked { segments.contains { !$0.isComplete } } }

    public var state: State { locked { State(segments: segments, composer: composer) } }

    public func restore(_ state: State) {
        locked {
            segments = state.segments
            composer = state.composer
        }
    }

    // MARK: - 輸入

    /// 打一個注音符號或聲調記號。
    /// - 聲母／介音／韻母：放進正在組的音節。那個槽已經有了、或比它後面的槽已經有了（例：已有 ㄋ 再打 ㄏ、
    ///   已有 ㄠ 再打 ㄧ），就把正在組的音節擠成「沒收尾」的一段，另起一個新音節。
    /// - 聲調（ˊˇˋ˙，或「ˉ」＝一聲）：把正在組的音節收尾；組出的音節不在詞庫裡（例「ㄅˋ」）就拒絕、保留原狀。
    /// - 回傳 false＝這個符號沒有被接受（非注音符號、空的時候打聲調、不合法音節）。
    @discardableResult
    public func type(_ symbol: Character) -> Bool {
        locked {
            guard let slot = ZhuyinComposer.slot(of: symbol) else { return false }
            if slot == .tone {
                return completeSyllable(tone: symbol)
            }
            if startsNewSyllable(slot) {
                segments.append(Segment(node: partialNode(composer), isComplete: false, composer: composer))
                composer.clear()
            }
            return composer.insert(symbol)
        }
    }

    private func startsNewSyllable(_ slot: ZhuyinComposer.Slot) -> Bool {
        switch slot {
        case .consonant: return !composer.isEmpty
        case .medial: return composer.medial != nil || composer.rime != nil
        case .rime: return composer.rime != nil
        case .tone: return false
        }
    }

    /// 空白鍵：把正在組的音節以一聲收尾。以下情況什麼都不做、回 false（交給呼叫端：送出整句或送空白）：
    /// 沒有正在組的音節、一聲音節不在詞庫裡或只對到注音符號本身（例 ㄋ）、
    /// 緩衝區裡有沒收尾的音節（簡拼／沒打聲調時空白＝送出）。
    @discardableResult
    public func space() -> Bool {
        locked {
            guard !segments.contains(where: { !$0.isComplete }) else { return false }
            return completeSyllable(tone: nil)
        }
    }

    private func completeSyllable(tone: Character?) -> Bool {
        guard let s = composer.syllable(tone: tone), let id = lexicon.syllableID(s) else { return false }
        // 只有聲母的一聲（例「ㄋ」）在詞庫裡唯一的詞就是注音符號本身：空白鍵不收成它，交給呼叫端送出最佳猜測
        if tone == nil, lexicon.lookup(ids: [id][...], limit: 1).first?.text == s { return false }
        segments.append(Segment(node: Node(ids: [id], penalties: [0], raw: s), isComplete: true, composer: ZhuyinComposer()))
        composer.clear()
        return true
    }

    /// 倒退：先刪正在組的最後一個符號；沒有就刪最後一個音節段。刪到正在組的音節空了、前一段又沒收尾，
    /// 就把那一段拿回來繼續組（ㄋㄏ 倒退一次 → 正在組 ㄋ）。整個緩衝區是空的回 false。
    @discardableResult
    public func backspace() -> Bool {
        locked {
            if composer.backspace() {
                reopenTrailingPartial()
                return true
            }
            guard !segments.isEmpty else { return false }
            segments.removeLast()
            reopenTrailingPartial()
            return true
        }
    }

    /// 不變式：正在組的音節是空的時候，最後一段一定是已收尾的。
    private func reopenTrailingPartial() {
        guard composer.isEmpty, let last = segments.last, !last.isComplete else { return }
        composer = last.composer
        segments.removeLast()
    }

    public func reset() {
        locked { resetLocked() }
    }

    private func resetLocked() {
        segments.removeAll()
        composer.clear()
    }

    // MARK: - 轉換

    /// 宿主輸入框裡顯示的組字：已收尾的音節顯示轉換結果，沒收尾的段與正在組的符號照打的樣子顯示
    /// （簡拼時看得到自己打了什麼；要送出什麼看 `conversion`）。
    public var preedit: String {
        locked {
            var out = ""
            var run: [Node] = []
            for s in segments {
                if s.isComplete {
                    run.append(s.node)
                } else {
                    out += walk(run) + s.node.raw
                    run.removeAll()
                }
            }
            return out + walk(run) + composer.composing
        }
    }

    /// 整句送出時的文字（＝`commitAll()` 會回傳的）：所有音節段一起轉換，正在組的音節當沒收尾的音節一起猜。
    public var conversion: String { locked { walk(commitLattice()) } }

    /// 緩衝區開頭的候選（正在組的音節也算一個位置）：先列最長的詞（覆蓋 k 個位置，k 由大到小），
    /// 同長度內分數高的在前；含單字。多字詞最多 `phraseCandidateLimit` 個（且不超過顯示數的四分之三），
    /// 總數上限 `candidateLimit`。
    public var candidates: [ZhuyinCandidate] { candidates(limit: Self.candidateLimit) }

    /// 只計算呼叫端實際要顯示的候選數。完整上限保留給需要完整候選清單的呼叫端，鍵盤則只需要前幾格。
    public func candidates(limit requestedLimit: Int) -> [ZhuyinCandidate] {
        locked {
            let limit = min(max(requestedLimit, 0), Self.candidateLimit)
            var nodes = segments.map(\.node)
            if !composer.isEmpty { nodes.append(partialNode(composer)) }
            guard !nodes.isEmpty, limit > 0 else { return [] }

            struct KeyHit { let key: Int; let length: Int; let penalty: Double; let top: Double }
            var byLength: [Int: [KeyHit]] = [:]
            lexicon.forEachKey(matching: nodes.map(\.ids), maxLength: ZhuyinLexicon.maximumPhraseLength,
                               nodeBudget: Self.candidateNodeBudget) { key, path, top in
                var penalty = 0.0
                for (d, j) in path.enumerated() { penalty += nodes[d].penalties[j] }
                byLength[path.count, default: []].append(KeyHit(key: key, length: path.count, penalty: penalty, top: top))
            }

            /// 同一個長度裡分數最高的 `need` 個詞（跨讀音去重、留最高分）。依鍵的最佳分數由高到低讀，
            /// 已經湊滿且下一把鍵的最佳分數贏不了第 need 名就停，不把每把鍵的詞都解成字串。
            func best(_ hits: [KeyHit], need: Int) -> [String] {
                guard need > 0 else { return [] }
                var score: [String: Double] = [:]
                var order: [String] = []
                var nth = -Double.infinity
                for h in hits.sorted(by: { $0.top - $0.penalty > $1.top - $1.penalty }) {
                    if order.count >= need && h.top - h.penalty <= nth { break }
                    for e in lexicon.entries(atKeyIndex: h.key, limit: need) {
                        let s = e.score - h.penalty
                        if order.count >= need && s <= nth { break }
                        if let old = score[e.text] {
                            if s > old { score[e.text] = s }
                        } else {
                            score[e.text] = s
                            order.append(e.text)
                        }
                    }
                    if order.count >= need {
                        nth = order.map { score[$0]! }.sorted(by: >)[need - 1]
                    }
                }
                return order.enumerated()
                    .sorted { score[$0.element]! != score[$1.element]! ? score[$0.element]! > score[$1.element]! : $0.offset < $1.offset }
                    .prefix(need)
                    .map(\.element)
            }

            var phrases: [ZhuyinCandidate] = []
            // 多字詞最多佔四分之三：簡拼時兩個聲母就對得到幾百個詞，不留位置的話單字會整個被擠掉
            let phraseLimit = min(Self.phraseCandidateLimit, max(1, limit * 3 / 4))
            for k in byLength.keys.sorted(by: >) where k > 1 {
                for text in best(byLength[k]!, need: phraseLimit - phrases.count) {
                    phrases.append(ZhuyinCandidate(text: text, readingCount: k))
                }
            }
            let singles = best(byLength[1] ?? [], need: limit).map { ZhuyinCandidate(text: $0, readingCount: 1) }
            return Array((phrases + singles).prefix(limit))
        }
    }

    /// 選一個候選：從緩衝區開頭移除它涵蓋的音節（涵蓋到正在組的音節就連它一起清掉），回傳要送出的文字。
    /// `readingCount` 超過目前的位置數（候選已過期）時不動緩衝區、回空字串。
    public func select(_ candidate: ZhuyinCandidate) -> String {
        locked {
            let total = segments.count + (composer.isEmpty ? 0 : 1)
            guard candidate.readingCount > 0, candidate.readingCount <= total else { return "" }
            if candidate.readingCount > segments.count {
                segments.removeAll()
                composer.clear()
            } else {
                segments.removeFirst(candidate.readingCount)
                reopenTrailingPartial()
            }
            return candidate.text
        }
    }

    /// 整句送出並清空，回傳值與 `conversion` 相同。
    public func commitAll() -> String {
        locked {
            let text = walk(commitLattice())
            resetLocked()
            return text
        }
    }

    /// 呼叫端須持有鎖。正在組的音節一律當「沒收尾」：只差聲調的不扣分，所以一聲（例 ㄊㄧㄢ → 天）
    /// 照樣選得到，其他聲調（ㄏㄠ → 好）也選得到，由詞頻決定。
    private func commitLattice() -> [Node] {
        var nodes = segments.map(\.node)
        if !composer.isEmpty { nodes.append(partialNode(composer)) }
        return nodes
    }

    /// 沒收尾的音節可以對到的所有音節。呼叫端須持有鎖。
    /// 打到的最後一個槽位（含）之前的槽位要完全相同，之後的槽位不限；聲調不限。
    /// 槽位完全相同（只差聲調）的不扣分，多延伸的扣 `partialPenalty`。
    private func partialNode(_ c: ZhuyinComposer) -> Node {
        let raw = c.composing
        if let hit = partialCache[raw] { return hit }
        // 最後一個打到的槽位：之前（含）的槽位要完全相同，之後的不限
        let last = c.rime != nil ? 2 : (c.medial != nil ? 1 : 0)
        var ids: [UInt16] = []
        var penalties: [Double] = []
        for id in shapes.indices {
            let shape = shapes[id]
            guard shape.consonant == c.consonant,
                  last < 1 || shape.medial == c.medial,
                  last < 2 || shape.rime == c.rime else { continue }
            ids.append(UInt16(id))
            let exact = shape.medial == c.medial && shape.rime == c.rime
            penalties.append(exact ? 0 : Self.partialPenalty)
        }
        let node = Node(ids: ids, penalties: penalties, raw: raw)
        if partialCache.count > 256 { partialCache.removeAll() }
        partialCache[raw] = node
        return node
    }

    // MARK: - Viterbi

    /// 在讀音網格上找分數最高的切分，回傳串起來的文字。呼叫端須持有鎖。
    private func walk(_ nodes: [Node]) -> String {
        if nodes.isEmpty { return "" }
        if let hit = walkCache[nodes] { return hit }
        let n = nodes.count
        enum Piece { case key(Int), raw(String) }
        // best[i]：走到位置 i 的最高累積分數；back[i]：最後一段的起點與內容
        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [(from: Int, piece: Piece)](repeating: (0, .raw("")), count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i] > -.infinity {
            var hit = false
            let sets = nodes[i...].map(\.ids)
            lexicon.forEachKey(matching: sets, maxLength: ZhuyinLexicon.maximumPhraseLength,
                               nodeBudget: Self.walkNodeBudget) { key, path, top in
                var score = best[i] + top
                for (d, j) in path.enumerated() { score -= nodes[i + d].penalties[j] }
                if path.count == 1 { hit = true }
                if score > best[i + path.count] {
                    best[i + path.count] = score
                    back[i + path.count] = (i, .key(key))
                }
            }
            // 這個位置對不到任何單字（沒收尾的段組不出音節，例 ㄅㄩ）→ 以注音原樣墊過去
            if !hit && best[i] - Self.rawPenalty > best[i + 1] {
                best[i + 1] = best[i] - Self.rawPenalty
                back[i + 1] = (i, .raw(nodes[i].raw))
            }
        }
        var parts: [String] = []
        var pos = n
        while pos > 0 {
            switch back[pos].piece {
            case .key(let key): parts.append(lexicon.entries(atKeyIndex: key, limit: 1).first?.text ?? "")
            case .raw(let s): parts.append(s)
            }
            pos = back[pos].from
        }
        let text = parts.reversed().joined()
        if walkCache.count > 32 { walkCache.removeAll() }
        walkCache[nodes] = text
        return text
    }
}
