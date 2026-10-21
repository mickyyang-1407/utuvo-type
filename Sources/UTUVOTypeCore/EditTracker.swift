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
    }

    /// 改動超過這個比例就當成「重寫」，不學。
    public static let maxChangedRatio = 0.3
    /// 單一修正最長幾個字（太長的是改句子，不是改錯字）。
    public static let maxTokenLength = 12

    /// - Parameters:
    ///   - inserted: Type 貼進去的文字
    ///   - current: 現在欄位裡對應位置的文字（呼叫端負責取出大致同一段）
    public static func corrections(inserted: String, current: String) -> [Correction] {
        let a = Array(inserted), b = Array(current)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }
        let ops = diff(a, b)
        let changed = ops.reduce(0) { $0 + ($1.kind == .equal ? 0 : max($1.a.count, $1.b.count)) }
        guard Double(changed) / Double(max(a.count, 1)) <= maxChangedRatio else { return [] }

        var result: [Correction] = []
        var i = 0
        while i < ops.count {
            let op = ops[i]
            guard op.kind != .equal else { i += 1; continue }
            // 合併相鄰的刪除＋新增成一組替換
            var from = op.a, to = op.b
            if i + 1 < ops.count, ops[i + 1].kind != .equal, ops[i + 1].kind != op.kind {
                from += ops[i + 1].a; to += ops[i + 1].b; i += 1
            }
            i += 1
            // 純刪除（刪贅字）或純新增（補字）不是錯字修正
            guard !from.isEmpty, !to.isEmpty else { continue }
            // 擴到完整的詞：英文往兩邊補到字母邊界；中文保持最小改動（「元山」→「圓山」只換一個字時補上鄰字成詞）
            let (f, t) = expandToWord(from: from, to: to, ops: ops, index: i - 1)
            let fs = String(f).trimmingCharacters(in: .whitespacesAndNewlines)
            let ts = String(t).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fs.isEmpty, !ts.isEmpty, fs != ts,
                  fs.count <= maxTokenLength, ts.count <= maxTokenLength,
                  !fs.allSatisfy({ $0.isPunctuation || $0.isWhitespace }),
                  !ts.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) else { continue }
            let c = Correction(from: fs, to: ts)
            if !result.contains(c) { result.append(c) }
        }
        return result
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
