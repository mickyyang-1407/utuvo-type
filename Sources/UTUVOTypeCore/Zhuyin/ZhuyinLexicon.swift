import Foundation

/// 注音詞庫：以 mmap 開啟 `zhuyin.dat`（由 scripts/build-zhuyin-data.py 從小麥注音 McBopomofo 資料編出），
/// 原地二分搜尋，不把詞庫讀進 Swift 字典。
///
/// 記憶體設計（鍵盤 extension 上限約 60 MB）：
/// - 檔案用 `.alwaysMapped` 開，頁面只有被二分搜尋碰到時才進實體記憶體，可由系統隨時回收。
/// - 常駐的 Swift 物件只有音節表（約 1,400 個音節字串 → u16 ID 的字典），詞條與讀音鍵全留在檔案裡。
/// - 查詢時才把命中的詞解成 `String`。
///
/// 檔案格式見 scripts/build-zhuyin-data.py 檔頭。
public final class ZhuyinLexicon: Sendable {
    /// 小麥注音 walk 的最大跨度（Gramambular 的 kMaximumSpanLength）。
    public static let maximumPhraseLength = 8
    static let scoreScale = 2000.0

    private let data: Data
    private let syllables: [String]
    private let syllableIDs: [String: UInt16]
    private let keyCount: Int
    private let keyIndexOffset: Int
    private let recordsOffset: Int
    /// 詞條總數（僅供資訊）。
    public let entryCount: Int

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// 直接吃一份 `Data`（測試或已映射好的資料）。格式不符回 nil。
    public init?(data: Data) {
        guard data.count >= 32 else { return nil }
        func u32(_ o: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
        }
        guard data.prefix(4) == Data("UTZY".utf8), u32(4) == 1 else { return nil }
        let nsyl = u32(8), nkey = u32(12), nent = u32(16)
        let sylOff = u32(20), keyOff = u32(24), recOff = u32(28)
        let sylBlob = sylOff + 4 * (nsyl + 1)
        guard nsyl > 0, nsyl <= Int(UInt16.max) + 1,
              sylBlob <= data.count,
              keyOff + 4 * nkey <= data.count,
              recOff <= data.count else { return nil }
        var table: [String] = []
        table.reserveCapacity(nsyl)
        var ids: [String: UInt16] = [:]
        ids.reserveCapacity(nsyl)
        for i in 0..<nsyl {
            let a = sylBlob + u32(sylOff + 4 * i), b = sylBlob + u32(sylOff + 4 * (i + 1))
            guard a <= b, b <= data.count else { return nil }
            let s = String(decoding: data[a..<b], as: UTF8.self)
            table.append(s)
            ids[s] = UInt16(i)
        }
        self.data = data
        self.syllables = table
        self.syllableIDs = ids
        self.keyCount = nkey
        self.keyIndexOffset = keyOff
        self.recordsOffset = recOff
        self.entryCount = nent
    }

    // MARK: - 音節

    public var syllableCount: Int { syllables.count }

    /// 這個音節（含聲調記號，例「ㄋㄧˇ」）是否存在於詞庫。
    public func isValidSyllable(_ syllable: String) -> Bool { syllableIDs[syllable] != nil }

    public func syllableID(_ syllable: String) -> UInt16? { syllableIDs[syllable] }

    func syllable(_ id: UInt16) -> String { Int(id) < syllables.count ? syllables[Int(id)] : "" }

    func ids(_ readings: ArraySlice<String>) -> [UInt16]? {
        var out: [UInt16] = []
        out.reserveCapacity(readings.count)
        for r in readings {
            guard let id = syllableIDs[r] else { return nil }
            out.append(id)
        }
        return out
    }

    // MARK: - 查詢（字串介面）

    /// 精確讀音查詢，最佳分數在前。分數是小麥注音的 log10 機率（越大越常用）。
    public func lookup(readings: ArraySlice<String>) -> [(text: String, score: Double)] {
        guard !readings.isEmpty, let ids = ids(readings) else { return [] }
        return lookup(ids: ids[...])
    }

    /// 詞庫裡有沒有「以這段讀音開頭」的鍵（含完全相同）。用來判斷還要不要往更長的詞找。
    public func hasPhrase(withPrefix readings: ArraySlice<String>) -> Bool {
        guard !readings.isEmpty, let ids = ids(readings) else { return false }
        return hasKey(withPrefix: ids[...])
    }

    /// 不分聲調的查詢：每個沒有聲調記號的音節（例「ㄋㄧ」）展開成一聲＋ˊˇˋ˙ 五種，
    /// 合併結果、同詞取最高分、最佳在前。展開組合上限 125（三個不帶調音節），超過只取前 125 種。
    /// 有標調的音節照原樣精確比對。
    public func lookupIgnoringTone(readings: ArraySlice<String>) -> [(text: String, score: Double)] {
        guard !readings.isEmpty else { return [] }
        var combos: [[UInt16]] = [[]]
        for r in readings {
            let hasTone = r.last.map { ZhuyinComposer.toneMarks.contains($0) } ?? false
            let variants = hasTone ? [r] : [r, r + "ˊ", r + "ˇ", r + "ˋ", r + "˙"]
            let vids = variants.compactMap { syllableIDs[$0] }
            if vids.isEmpty { return [] }
            var next: [[UInt16]] = []
            for c in combos {
                for v in vids where next.count < 125 { next.append(c + [v]) }
            }
            combos = next
        }
        var best: [String: Double] = [:]
        var order: [String] = []
        for c in combos {
            for e in lookup(ids: c[...]) {
                if let old = best[e.text] {
                    if e.score > old { best[e.text] = e.score }
                } else {
                    best[e.text] = e.score
                    order.append(e.text)
                }
            }
        }
        return order.map { (text: $0, score: best[$0]!) }
            .enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map { $0.element }
    }

    // MARK: - 查詢（音節 ID 介面，引擎內部用）

    func lookup(ids: ArraySlice<UInt16>, limit: Int = .max) -> [(text: String, score: Double)] {
        data.withUnsafeBytes { raw -> [(text: String, score: Double)] in
            let i = lowerBound(raw, ids)
            guard i < keyCount, compareKey(raw, i, ids) == .equal else { return [] }
            var p = recordPointer(raw, i)
            let n = Int(raw[p])
            p += 1 + 2 * n
            let m = Int(u16(raw, p))
            p += 2
            var out: [(text: String, score: Double)] = []
            out.reserveCapacity(min(m, limit))
            for _ in 0..<min(m, limit) {
                guard p + 3 <= raw.count else { break }
                let q = Int16(bitPattern: u16(raw, p))
                let len = Int(raw[p + 2])
                p += 3
                guard p + len <= raw.count else { break }
                let text = String(decoding: UnsafeRawBufferPointer(rebasing: raw[p..<(p + len)]), as: UTF8.self)
                out.append((text: text, score: Double(q) / Self.scoreScale))
                p += len
            }
            return out
        }
    }

    /// 只取最佳一筆的分數與文字（Viterbi 用，避免把整串候選解成字串）。
    func best(ids: ArraySlice<UInt16>) -> (text: String, score: Double)? {
        lookup(ids: ids, limit: 1).first
    }

    func hasKey(withPrefix ids: ArraySlice<UInt16>) -> Bool {
        data.withUnsafeBytes { raw in
            let i = lowerBound(raw, ids)
            guard i < keyCount else { return false }
            let c = compareKey(raw, i, ids)
            return c == .equal || c == .queryIsPrefix
        }
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
