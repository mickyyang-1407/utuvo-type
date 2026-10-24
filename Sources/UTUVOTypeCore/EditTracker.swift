import Foundation

/// 插入後追蹤使用者修改（2026-10-13，對齊 Typeless trackEditResult）：
/// 貼上後過一陣子再看那段文字，使用者只改了幾個詞（例如「元山」→「圓山」、「Pro tool」→「Pro Tools」），
/// 就把「原字 → 改後」當成字典建議；大改（重寫、刪掉大半）不追蹤，避免學到錯的東西。
///
/// 純函式：只比對兩段字串，不讀畫面。
public enum EditTracker: Sendable {
    public struct Correction: Equatable, Hashable, Codable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }

        /// 只差大小寫（tool→Tool、Session→session、Utuvo→UTUVO）。計算屬性：不進 Codable，舊的建議清單照樣讀得回來。
        public var caseOnly: Bool { from != to && from.lowercased() == to.lowercased() }

        /// 能不能不經使用者確認就加進字典（2026-10-22 delivery-learning-v2）。
        /// 字典是「區分大小寫、整個詞、全文」替換（Normalizer.applyDictionary）：接受 tool→Tool 之後每個 tool 都會被改掉。
        /// 所以只差大小寫、而且改後是全小寫或只有字首大寫的（tool→Tool、Session→session）只留作建議；
        /// 改後有兩個以上大寫字母、或大寫不在字首（Utuvo→UTUVO、iphone→iPhone）是品牌寫法，可以自動加。
        public var isAutoAddEligible: Bool {
            guard caseOnly else { return true }
            let uppercase = to.filter(\.isUppercase)
            if uppercase.isEmpty { return false }
            if uppercase.count == 1, to.first(where: \.isLetter)?.isUppercase == true { return false }
            return true
        }
    }

    /// 改動超過這個比例就當成「重寫」，不學。
    public static let maxChangedRatio = 0.3
    /// 單一修正最長幾個字（太長的是改句子，不是改錯字）。
    public static let maxTokenLength = 12
    /// 算改動比例時分母至少這麼多字（2026-10-22 delivery-learning-v1）：聊天訊息常常只有十幾個字，
    /// 改一個專名（Utuvo→UTUVO）就超過三成，以前短訊息永遠學不到。
    public static let minRatioDenominator = 24
    /// 英文修正最多涵蓋幾個詞（Dummy Music→DAMI music 是兩個）；更多就是改句子。
    public static let maxLatinTokens = 3

    /// - Parameters:
    ///   - inserted: Type 貼進去的文字
    ///   - current: 現在欄位裡對應位置的文字（呼叫端負責取出大致同一段）
    public static func corrections(inserted: String, current: String) -> [Correction] {
        corrections(inserted: inserted, current: current, chineseKeys: .neighbour)
    }

    /// 學字典用的版本（Mac 修改追蹤的正式路徑，2026-10-22 修補）：跟 `corrections` 一樣，只差中文單字修改的 key 怎麼取。
    /// `corrections` 會補下一個字湊成兩個字（「明天跟小美吃飯」改「梅」→「美吃→梅吃」，學進去是亂的）；
    /// 這裡改用系統斷詞（Foundation `.byWords`）找出改後那段裡「包含這次修改的那個詞」當 key（→「小美→小梅」）。
    /// 那個詞只有一個字（「再｜說」）、跨到別的修改、或不全是中文，就不學——寧可漏學，不借不相干的鄰字。
    public static func learnableCorrections(inserted: String, current: String) -> [Correction] {
        corrections(inserted: inserted, current: current, chineseKeys: .wholeWord)
    }

    /// 中文單字修改的 key：`.neighbour`＝補前後一個字（舊行為，建議清單相容）；`.wholeWord`＝斷詞後的整個詞。
    enum ChineseKeys { case neighbour, wholeWord }

    static func corrections(inserted: String, current: String, chineseKeys: ChineseKeys) -> [Correction] {
        let a = Array(inserted), b = Array(current)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }
        let ops = diff(a, b)
        let latinGroups = latinTokenGroups(a, b)
        guard Double(replacementChangedCount(ops, latinGroups: latinGroups)) / Double(max(a.count, minRatioDenominator))
                <= maxChangedRatio else { return [] }

        // 每個 op 在兩段文字裡的起點（英文修正要對回整個詞用）。
        var aStart: [Int] = [], bStart: [Int] = []
        var pa = 0, pb = 0
        for op in ops { aStart.append(pa); bStart.append(pb); pa += op.a.count; pb += op.b.count }

        var result: [Correction] = []
        var words: [Range<Int>]?   // 改後那段的斷詞，用到才算
        func add(_ f: [Character], _ t: [Character]) {
            let fs = String(f).trimmingCharacters(in: .whitespacesAndNewlines)
            let ts = String(t).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fs.isEmpty, !ts.isEmpty, fs != ts,
                  fs.count <= maxTokenLength, ts.count <= maxTokenLength,
                  !fs.allSatisfy({ $0.isPunctuation || $0.isWhitespace }),
                  !ts.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) else { return }
            let c = Correction(from: fs, to: ts)
            if !result.contains(c) { result.append(c) }
        }
        var i = 0
        while i < ops.count {
            let op = ops[i]
            guard op.kind != .equal else { i += 1; continue }
            let first = i
            // 合併相鄰的刪除＋新增成一組替換
            var from = op.a, to = op.b
            if i + 1 < ops.count, ops[i + 1].kind != .equal, ops[i + 1].kind != op.kind {
                from += ops[i + 1].a; to += ops[i + 1].b; i += 1
            }
            i += 1
            // 純刪除（刪贅字）或純新增（補字）不是錯字修正
            guard !from.isEmpty, !to.isEmpty else { continue }
            // 只改標點／空白（，→！、空格→-）不是錯字修正（以前靠改動比例擋掉，分母放寬後要明確擋）
            let isPunctuationOrSpace: (Character) -> Bool = { $0.isPunctuation || $0.isWhitespace }
            guard !(from.allSatisfy(isPunctuationOrSpace) && to.allSatisfy(isPunctuationOrSpace)) else { continue }
            if (from + to).contains(where: isLatin) {
                // 英文：以「整個詞」重新比對（2026-10-22 delivery-learning-v2）。字元層級會把 Music 的 M 對到 DAMI 的 M，
                // 拼出「Dummy M→DAM」這種碎片；改用詞層級的差異，涵蓋這組替換的那幾個詞整段當成一組修正。
                let aRange = aStart[first] ..< aStart[first] + from.count
                let bRange = bStart[first] ..< bStart[first] + to.count
                for g in latinGroups where g.a.overlaps(aRange) || g.b.overlaps(bRange) {
                    add(Array(a[g.a]), Array(b[g.b]))
                }
                continue
            }
            if chineseKeys == .wholeWord, from.count == 1 || to.count == 1 {
                if words == nil { words = wordRanges(current) }
                let before = first > 0 && ops[first - 1].kind == .equal ? ops[first - 1].a.count : 0
                let after = i < ops.count && ops[i].kind == .equal ? ops[i].a.count : 0
                if let (f, t) = wholeWordKey(a: a, b: b, aStart: aStart[first], bStart: bStart[first],
                                             fromCount: from.count, toCount: to.count,
                                             before: before, after: after, words: words!) {
                    add(f, t)
                }
                continue
            }
            // 中文保持最小改動（「元山」→「圓山」只換一個字時補上鄰字成詞）
            let (f, t) = expandToWord(from: from, to: to, ops: ops, index: i - 1)
            add(f, t)
        }
        return result
    }

    /// 斷詞（Foundation `.byWords`，中文用系統詞典）：每個詞在字串裡的字元（Character）範圍。
    static func wordRanges(_ text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var lastIndex = text.startIndex, lastOffset = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            let lower = lastOffset + text.distance(from: lastIndex, to: range.lowerBound)
            out.append(lower ..< lower + text.distance(from: range.lowerBound, to: range.upperBound))
            lastIndex = range.lowerBound
            lastOffset = lower
        }
        return out
    }

    /// 中文單字修改的整詞 key：改後那段的 `b[bStart..<bStart+toCount]` 落在哪個詞裡，就用那個詞（兩字以上、全中文），
    /// 原字取同一段位置。詞往外延伸的部分必須都在前後沒改的字裡（`before`／`after` 是緊鄰的相同區塊長度）。
    static func wholeWordKey(a: [Character], b: [Character], aStart: Int, bStart: Int, fromCount: Int, toCount: Int,
                             before: Int, after: Int, words: [Range<Int>]) -> ([Character], [Character])? {
        guard toCount > 0, fromCount > 0 else { return nil }
        let run = bStart ..< bStart + toCount
        guard let word = words.first(where: { $0.lowerBound <= run.lowerBound && $0.upperBound >= run.upperBound }),
              word.count >= 2, word.count <= maxTokenLength,
              b[word].allSatisfy(MandarinReading.isCJK) else { return nil }
        let pre = run.lowerBound - word.lowerBound, post = word.upperBound - run.upperBound
        guard pre <= before, post <= after, aStart - pre >= 0, aStart + fromCount + post <= a.count else { return nil }
        let f = Array(a[(aStart - pre) ..< (aStart + fromCount + post)])
        guard f.allSatisfy(MandarinReading.isCJK) else { return nil }
        return (f, Array(b[word]))
    }

    /// 學字典用的改動字數：相鄰的刪除＋新增是同一組替換，算 max(刪, 增) 一次（Utuvo→UTUVO 算 4 不是 8）；
    /// 落在同一個英文詞組裡的幾段改動也算同一組（Dummy Music→DAMI music 字元比對會切成兩段）。
    /// `changedCount`（EditWatcher 找段落用）維持原本的算法，不受影響。
    public static func replacementChangedCount(inserted: String, current: String) -> Int {
        let a = Array(inserted), b = Array(current)
        return replacementChangedCount(diff(a, b), latinGroups: latinTokenGroups(a, b))
    }

    static func replacementChangedCount(_ ops: [Op], latinGroups: [TokenGroup]) -> Int {
        var total = 0
        var merged = Array(repeating: (removed: 0, added: 0), count: latinGroups.count)
        var pa = 0, pb = 0
        var run: (a: Int, b: Int, removed: Int, added: Int)?
        func close() {
            guard let r = run else { return }
            run = nil
            let aRange = r.a ..< r.a + r.removed, bRange = r.b ..< r.b + r.added
            if let k = latinGroups.firstIndex(where: { $0.a.overlaps(aRange) || $0.b.overlaps(bRange) }) {
                merged[k].removed += r.removed; merged[k].added += r.added
            } else {
                total += max(r.removed, r.added)
            }
        }
        for op in ops {
            if op.kind == .equal {
                close()
            } else {
                if run == nil { run = (pa, pb, 0, 0) }
                run!.removed += op.a.count; run!.added += op.b.count
            }
            pa += op.a.count; pb += op.b.count
        }
        close()
        return merged.reduce(total) { $0 + max($1.removed, $1.added) }
    }

    /// 快照看起來是中文輸入法組字到一半（2026-10-22 修補）：有一段中文被換成只有小寫英文字母（拼音 `yuan`）
    /// 或注音符號（`ㄩㄢˊ`）。輸入法還沒選字時，標記文字（marked text）就直接出現在欄位的值裡；
    /// 拿這種快照結算會學到「元→yuan」。呼叫端看到就整回合放棄。
    public static func looksLikeComposition(inserted: String, current: String) -> Bool {
        let a = Array(inserted), b = Array(current)
        guard a.count * b.count <= 4_000_000 else { return false }
        let ops = diff(a, b)
        var i = 0
        while i < ops.count {
            guard ops[i].kind != .equal else { i += 1; continue }
            var from = ops[i].a, to = ops[i].b
            if i + 1 < ops.count, ops[i + 1].kind != .equal, ops[i + 1].kind != ops[i].kind {
                from += ops[i + 1].a; to += ops[i + 1].b; i += 1
            }
            i += 1
            if from.contains(where: MandarinReading.isCJK), isCompositionRun(to) { return true }
        }
        return false
    }

    /// 只有小寫英文字母（拼音，可夾音節分隔的 ' 或空白）、或只有注音符號與聲調。
    static func isCompositionRun(_ s: [Character]) -> Bool {
        let core = s.filter { $0 != " " && $0 != "'" && $0 != "’" }
        guard !core.isEmpty else { return false }
        let pinyin = core.allSatisfy { $0.isASCII && $0.isLowercase }
        let zhuyin = core.allSatisfy { c in
            c.unicodeScalars.allSatisfy { (0x3100...0x312F).contains($0.value) || (0x31A0...0x31BF).contains($0.value)
                || ["\u{02CA}", "\u{02C7}", "\u{02CB}", "\u{02D9}"].contains($0) }
        }
        return pinyin || zhuyin
    }

    /// 兩段文字差了幾個字（字元層級，刪＋改＋增）；App 端找「欄位裡哪一段是剛才貼的」用。
    public static func changedCount(_ a: String, _ b: String) -> Int {
        diff(Array(a), Array(b)).reduce(0) { $0 + ($1.kind == .equal ? 0 : max($1.a.count, $1.b.count)) }
    }

    // MARK: - diff（字元層級 LCS；欄位文字很短，O(n·m) 夠用，上限保護）

    struct Op: Equatable { enum Kind { case equal, delete, insert }; var kind: Kind; var a: [Character]; var b: [Character] }

    static func diff(_ a: [Character], _ b: [Character]) -> [Op] {
        guard a.count * b.count <= 4_000_000 else { return [Op(kind: .delete, a: a, b: []), Op(kind: .insert, a: [], b: b)] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [Op] = []
        func push(_ kind: Op.Kind, _ ca: Character?, _ cb: Character?) {
            if let last = ops.last, last.kind == kind {
                if let ca { ops[ops.count - 1].a.append(ca) }
                if let cb { ops[ops.count - 1].b.append(cb) }
            } else {
                ops.append(Op(kind: kind, a: ca.map { [$0] } ?? [], b: cb.map { [$0] } ?? []))
            }
        }
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { push(.equal, a[i], b[j]); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { push(.delete, a[i], nil); i += 1 }
            else { push(.insert, nil, b[j]); j += 1 }
        }
        while i < a.count { push(.delete, a[i], nil); i += 1 }
        while j < b.count { push(.insert, nil, b[j]); j += 1 }
        return ops
    }

    // MARK: - 英文詞層級比對（delivery-learning-v2）

    static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 詞層級差異的一組：兩段文字裡各自的字元範圍（從第一個詞開頭到最後一個詞結尾，中間的空白照原文）。
    struct TokenGroup: Equatable { var a: Range<Int>; var b: Range<Int> }

    /// 切詞：連續的英文字母／數字是一個詞，空白是分隔，其他字（中文、標點）一個字一個詞。
    static func tokens(_ s: [Character]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < s.count {
            if s[i].isWhitespace { i += 1; continue }
            var j = i + 1
            if isLatin(s[i]) { while j < s.count, isLatin(s[j]) { j += 1 } }
            out.append(i ..< j)
            i = j
        }
        return out
    }

    /// 含英文的詞層級替換組（中文仍走字元層級）。
    static func latinTokenGroups(_ a: [Character], _ b: [Character]) -> [TokenGroup] {
        guard a.contains(where: isLatin) || b.contains(where: isLatin) else { return [] }
        return tokenGroups(a, b).filter { a[$0.a].contains(where: isLatin) || b[$0.b].contains(where: isLatin) }
    }

    /// 詞層級 LCS，回傳兩邊都有詞、而且最多 `maxLatinTokens` 個詞的替換組（純增／純刪、太長的不算修正）。
    static func tokenGroups(_ a: [Character], _ b: [Character]) -> [TokenGroup] {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty, ta.count * tb.count <= 4_000_000 else { return [] }
        let wa = ta.map { a[$0] }, wb = tb.map { b[$0] }
        var dp = Array(repeating: Array(repeating: 0, count: tb.count + 1), count: ta.count + 1)
        for i in stride(from: ta.count - 1, through: 0, by: -1) {
            for j in stride(from: tb.count - 1, through: 0, by: -1) {
                dp[i][j] = wa[i] == wb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var groups: [TokenGroup] = []
        var i = 0, j = 0
        var groupA: Range<Int>? = nil, groupB: Range<Int>? = nil   // 目前這組的詞索引
        func flush() {
            defer { groupA = nil; groupB = nil }
            guard let ga = groupA, let gb = groupB, !ga.isEmpty, !gb.isEmpty,
                  ga.count <= maxLatinTokens, gb.count <= maxLatinTokens else { return }
            groups.append(TokenGroup(a: ta[ga.lowerBound].lowerBound ..< ta[ga.upperBound - 1].upperBound,
                                     b: tb[gb.lowerBound].lowerBound ..< tb[gb.upperBound - 1].upperBound))
        }
        while i < ta.count || j < tb.count {
            if i < ta.count, j < tb.count, wa[i] == wb[j] {
                flush(); i += 1; j += 1
                continue
            }
            if groupA == nil { groupA = i ..< i; groupB = j ..< j }
            if j >= tb.count || (i < ta.count && dp[i + 1][j] >= dp[i][j + 1]) {
                groupA = groupA!.lowerBound ..< i + 1; i += 1
            } else {
                groupB = groupB!.lowerBound ..< j + 1; j += 1
            }
        }
        flush()
        return groups
    }

    /// 英文：把替換擴成完整的詞（相鄰相同的字母一起帶上）；中文單字替換：帶上前後各一個相同的字，變成詞。
    static func expandToWord(from: [Character], to: [Character], ops: [Op], index: Int) -> ([Character], [Character]) {
        var f = from, t = to
        // 找這組替換前後的 equal 區塊
        var k = index
        while k >= 0, ops[k].kind != .equal { k -= 1 }
        let before = k >= 0 ? ops[k].a : []
        var m = index + 1
        while m < ops.count, ops[m].kind != .equal { m += 1 }
        let after = m < ops.count ? ops[m].a : []
        let isLatin: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if (f + t).contains(where: isLatin) {
            var pre: [Character] = []
            for c in before.reversed() { if isLatin(c) { pre.insert(c, at: 0) } else { break } }
            var post: [Character] = []
            for c in after { if isLatin(c) { post.append(c) } else { break } }
            f = pre + f + post; t = pre + t + post
        } else if f.count == 1 || t.count == 1 {
            // 中文單字替換：帶上後一個字成詞（「元」→「圓」＋「山」＝「元山」→「圓山」；「悠卡」→「遊卡」也修得到「悠悠卡」）；
            // 在句尾就帶前一個字。標點不帶。
            if let next = after.first, next.isLetter {
                f.append(next); t.append(next)
            } else if let prev = before.last, prev.isLetter {
                f.insert(prev, at: 0); t.insert(prev, at: 0)
            }
        }
        return (f, t)
    }
}
