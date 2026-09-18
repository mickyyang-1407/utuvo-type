import Foundation

/// 簡體拼音詞庫：以 mmap 開啟 `pinyin.dat`（由 scripts/build-pinyin-data.py 從 rime-pinyin-simp 編出），
/// 原地二分搜尋，不把詞庫讀進 Swift 字典。
///
/// 記憶體設計（鍵盤 extension 上限約 60 MB）：
/// - 檔案用 `.alwaysMapped` 開，頁面只有被二分搜尋碰到時才進實體記憶體，可由系統隨時回收。
/// - 常駐的 Swift 物件只有音節表（415 個音節＋它們的前綴區間），詞條與拼音鍵全留在檔案裡。
/// - 查詢時才把命中的詞解成 `String`。
///
/// 查詢單位是「每個音節位置一段 ID 區間」：完整音節＝長度 1 的區間，
/// 未打完的音節或聲母縮寫（例 `h`、`zh`）＝以它開頭的所有音節。
/// 檔案格式見 scripts/build-pinyin-data.py 檔頭。
public final class PinyinLexicon: Sendable {
    static let scoreScale = 2000.0
    static let headerSize = 40

    private let data: Data
    /// 音節表（音節 ID ↔ 字串、前綴區間）。
    public let syllables: PinyinSyllables
    private let keyCount: Int
    private let keyIndexOffset: Int
    private let recordsOffset: Int
    /// 最長的詞有幾個音節（本詞庫＝4）。
    public let maximumPhraseLength: Int
    /// 詞條總數（僅供資訊）。
    public let entryCount: Int

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// 直接吃一份 `Data`（測試或已映射好的資料）。格式不符回 nil。
    public init?(data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        func u32(_ o: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
        }
        guard data.prefix(4) == Data("UTPY".utf8), u32(4) == 1 else { return nil }
        let nsyl = u32(8), nkey = u32(12), nent = u32(16)
        let sylOff = u32(20), keyOff = u32(24), recOff = u32(28), maxLen = u32(32)
        let sylBlob = sylOff + 4 * (nsyl + 1)
        guard nsyl > 0, nsyl <= Int(UInt16.max),
              maxLen >= 1, maxLen <= 255,
              sylBlob <= data.count,
              keyOff + 4 * nkey <= data.count,
              recOff <= data.count,
              nkey == 0 || recOff + u32(keyOff + 4 * (nkey - 1)) < data.count else { return nil }
        var table: [String] = []
        table.reserveCapacity(nsyl)
        for i in 0..<nsyl {
            let a = sylBlob + u32(sylOff + 4 * i), b = sylBlob + u32(sylOff + 4 * (i + 1))
            guard a <= b, b <= data.count else { return nil }
            let s = String(decoding: data[a..<b], as: UTF8.self)
            // 音節表必須是排好序的小寫字母，前綴區間才會連續
            guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }),
                  table.last.map({ $0 < s }) ?? true else { return nil }
            table.append(s)
        }
        self.data = data
        self.syllables = PinyinSyllables(sortedSyllables: table)
        self.keyCount = nkey
        self.keyIndexOffset = keyOff
        self.recordsOffset = recOff
        self.maximumPhraseLength = maxLen
        self.entryCount = nent
    }

    public var syllableCount: Int { syllables.count }

    // MARK: - 查詢（字串介面）

    /// 精確拼音查詢（完整音節，例 ["ni", "hao"]），最佳分數在前。分數是 log10 機率（越大越常用）。
    public func lookup(syllables list: [String]) -> [(text: String, score: Double)] {
        var ranges: [Range<UInt16>] = []
        for s in list {
            guard let id = syllables.id(s) else { return [] }
            ranges.append(id..<(id + 1))
        }
        return lookup(ranges: ranges[...])
    }

    /// 每個位置可以是完整音節或前綴（例 ["ni", "h"]、["zh", "g"]）：前綴代表以它開頭的所有音節。
    /// 各鍵的詞合併後依分數排序。這是縮寫／未打完音節的查詢。
    public func lookup(prefixes list: [String], limit: Int = .max) -> [(text: String, score: Double)] {
        var ranges: [Range<UInt16>] = []
        for s in list {
            guard let r = syllables.range(prefix: s) else { return [] }
            ranges.append(r)
        }
        return lookup(ranges: ranges[...], limit: limit)
    }

    // MARK: - 查詢（音節 ID 區間介面，引擎內部用）

    /// 所有「長度剛好等於區間數、第 k 個音節落在第 k 個區間」的鍵的詞，合併後依分數由高到低
    /// （同分保留鍵序與鍵內順序）。先只讀分數排序，最後才把前 `limit` 筆解成字串。
    func lookup(ranges: ArraySlice<Range<UInt16>>, limit: Int = .max) -> [(text: String, score: Double)] {
        guard !ranges.isEmpty, limit > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [(text: String, score: Double)] in
            var hits: [(q: Int16, offset: Int, len: Int)] = []
            visitKeys(raw, ranges, exactLength: true) { i in
                var p = recordPointer(raw, i)
                let n = Int(raw[p])
                p += 1 + 2 * n
                let m = Int(u16(raw, p))
                p += 2
                // 鍵內已依分數排序：同一把鍵只有前 limit 筆可能擠進合併後的前 limit
                for _ in 0..<min(m, limit) {
                    guard p + 3 <= raw.count else { break }
                    let q = Int16(bitPattern: u16(raw, p))
                    let len = Int(raw[p + 2])
                    guard p + 3 + len <= raw.count else { break }
                    hits.append((q, p + 3, len))
                    p += 3 + len
                }
                return true
            }
            let top: [(q: Int16, offset: Int, len: Int)]
            if hits.count > 1 {
                top = Array(hits.enumerated()
                    .sorted { $0.element.q != $1.element.q ? $0.element.q > $1.element.q : $0.offset < $1.offset }
                    .prefix(limit)
                    .map(\.element))
            } else {
                top = hits
            }
            return top.map { h in
                (text: String(decoding: UnsafeRawBufferPointer(rebasing: raw[h.offset..<(h.offset + h.len)]), as: UTF8.self),
                 score: Double(h.q) / Self.scoreScale)
            }
        }
    }

    /// 只取最佳一筆（Viterbi 用）：各鍵的第一筆就是該鍵最高分，只比第一筆。
    func best(ranges: ArraySlice<Range<UInt16>>) -> (text: String, score: Double)? {
        guard !ranges.isEmpty else { return nil }
        return data.withUnsafeBytes { raw -> (text: String, score: Double)? in
            var bestQ = Int16.min, bestOffset = -1, bestLen = 0
            visitKeys(raw, ranges, exactLength: true) { i in
                var p = recordPointer(raw, i)
                let n = Int(raw[p])
                p += 1 + 2 * n
                guard u16(raw, p) > 0, p + 5 <= raw.count else { return true }
                p += 2
                let q = Int16(bitPattern: u16(raw, p))
                let len = Int(raw[p + 2])
                if (bestOffset < 0 || q > bestQ), p + 3 + len <= raw.count {
                    bestQ = q; bestOffset = p + 3; bestLen = len
                }
                return true
            }
            guard bestOffset >= 0 else { return nil }
            return (text: String(decoding: UnsafeRawBufferPointer(rebasing: raw[bestOffset..<(bestOffset + bestLen)]), as: UTF8.self),
                    score: Double(bestQ) / Self.scoreScale)
        }
    }

    /// 詞庫裡有沒有「前幾個音節落在這些區間」的鍵（含長度剛好相等）。用來判斷還要不要往更長的詞找。
    func hasKey(withPrefix ranges: ArraySlice<Range<UInt16>>) -> Bool {
        guard !ranges.isEmpty else { return true }
        return data.withUnsafeBytes { raw in
            var found = false
            visitKeys(raw, ranges, exactLength: false) { _ in
                found = true
                return false
            }
            return found
        }
    }

    // MARK: - 區間走訪

    /// 走訪所有符合區間序列的鍵（`exactLength`＝鍵長必須等於區間數；否則只要以它們開頭）。
    /// body 回 false＝停止。
    ///
    /// 作法：逐層縮小。前綴已固定為 `prefix` 時，第 k 層區間 [lo, hi) 對應的鍵是
    /// [lowerBound(prefix+[lo]), lowerBound(prefix+[hi])) 這一段（鍵依 ID 序列字典序排序）。
    /// 段落空＝剪枝；段落小（≤ 48 把鍵）直接線性檢查剩下的區間；否則逐一展開這層的 ID。
    private func visitKeys(_ raw: UnsafeRawBufferPointer, _ ranges: ArraySlice<Range<UInt16>>,
                           exactLength: Bool, _ body: (Int) -> Bool) {
        var prefix: [UInt16] = []
        prefix.reserveCapacity(ranges.count)
        _ = visitLevel(raw, &prefix, ranges, exactLength, body)
    }

    /// 回 false＝body 要求停止。
    private func visitLevel(_ raw: UnsafeRawBufferPointer, _ prefix: inout [UInt16],
                            _ rest: ArraySlice<Range<UInt16>>, _ exactLength: Bool,
                            _ body: (Int) -> Bool) -> Bool {
        guard let r = rest.first else {
            // 前綴已完全固定
            let i = lowerBound(raw, prefix[...])
            guard i < keyCount else { return true }
            let c = compareKey(raw, i, prefix[...])
            if c == .equal || (!exactLength && c == .queryIsPrefix) { return body(i) }
            return true
        }
        prefix.append(r.lowerBound)
        let a = lowerBound(raw, prefix[...])
        prefix[prefix.count - 1] = r.upperBound
        let b = r.upperBound == UInt16.max ? keyCount : lowerBound(raw, prefix[...])
        prefix.removeLast()
        if a >= b { return true }

        if r.count == 1 {
            prefix.append(r.lowerBound)
            defer { prefix.removeLast() }
            return visitLevel(raw, &prefix, rest.dropFirst(), exactLength, body)
        }
        if b - a <= 48 {
            let depth = prefix.count
            let total = depth + rest.count
            for i in a..<b {
                let p = recordPointer(raw, i)
                let n = Int(raw[p])
                if exactLength ? n != total : n < total { continue }
                var ok = true
                var k = depth
                for rr in rest {
                    let id = u16(raw, p + 1 + 2 * k)
                    if !rr.contains(id) { ok = false; break }
                    k += 1
                }
                if ok && !body(i) { return false }
            }
            return true
        }
        for id in r {
            prefix.append(id)
            let go = visitLevel(raw, &prefix, rest.dropFirst(), exactLength, body)
            prefix.removeLast()
            if !go { return false }
        }
        return true
    }

    // MARK: - 低階讀取

    private enum KeyOrder { case less, equal, greater, queryIsPrefix }

    @inline(__always)
    private func u16(_ raw: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
    }

    @inline(__always)
    private func recordPointer(_ raw: UnsafeRawBufferPointer, _ i: Int) -> Int {
        recordsOffset + Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: keyIndexOffset + 4 * i, as: UInt32.self)))
    }

    /// 第 i 把鍵相對於查詢的順序（鍵 < 查詢＝.less）。鍵比查詢長且以查詢開頭＝.queryIsPrefix（排序上算 greater）。
    private func compareKey(_ raw: UnsafeRawBufferPointer, _ i: Int, _ q: ArraySlice<UInt16>) -> KeyOrder {
        let p = recordPointer(raw, i)
        let n = Int(raw[p])
        var j = 0
        var qi = q.startIndex
        while j < n && qi < q.endIndex {
            let k = u16(raw, p + 1 + 2 * j)
            let v = q[qi]
            if k < v { return .less }
            if k > v { return .greater }
            j += 1
            qi += 1
        }
        if j == n && qi == q.endIndex { return .equal }
        if j == n { return .less }          // 鍵是查詢的前綴 → 鍵較小
        return .queryIsPrefix               // 查詢是鍵的前綴 → 鍵較大
    }

    /// 第一把 >= 查詢的鍵。
    private func lowerBound(_ raw: UnsafeRawBufferPointer, _ q: ArraySlice<UInt16>) -> Int {
        var lo = 0, hi = keyCount
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareKey(raw, mid, q) == .less { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
