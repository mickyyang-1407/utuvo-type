import Foundation

/// 聯想詞：選完字（或整句送出）之後，建議「接下來最可能的那一段」（例：你好 → 嗎；好 → 像、的…）。
///
/// 資料由 scripts/build-association-data.py 編出：繁體＝小麥注音自己的 associated-phrases-v2.txt，
/// 簡體＝rime-pinyin-simp 套同一條規則。分數是原詞庫的 log10 機率，同一段前文下分數越高越常接。
/// 跟詞庫一樣以 `.alwaysMapped` 開檔、原地二分搜尋，常駐記憶體只有這個物件本身。
public final class PhraseAssociations: Sendable {
    static let headerSize = 20
    static let scoreScale = 2000.0
    /// 前文最多看幾個字（詞表最長的詞也不過十來字，前文再長也不會有命中）。
    public static let maximumContextLength = 4
    /// 一段前文最多掃幾筆（最常見的單字約 100 筆；上限只防呆，確保每次查詢時間有界）。
    static let scanLimit = 2_000

    private let data: Data
    private let count: Int
    private let indexOffset: Int
    private let recordsOffset: Int

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// 格式不符回 nil。
    public init?(data: Data) {
        guard data.count >= Self.headerSize, data.prefix(4) == Data("UTAS".utf8) else { return nil }
        func u32(_ o: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
        }
        guard u32(4) == 1 else { return nil }
        let n = u32(8), idx = u32(12), rec = u32(16)
        guard idx + 4 * n <= data.count, rec <= data.count,
              n == 0 || rec + u32(idx + 4 * (n - 1)) + 3 <= data.count else { return nil }
        self.data = data
        self.count = n
        self.indexOffset = idx
        self.recordsOffset = rec
    }

    /// 詞數（僅供資訊）。
    public var phraseCount: Int { count }

    /// 以 `text` 結尾的前文可以接什麼。先用最長的前文（最多 `maximumContextLength` 字）找，
    /// 再用較短的前文補滿；同一段接續只出現一次。回傳的是「要接著插入的字」，不含前文本身。
    public func continuations(after text: String, limit: Int) -> [String] {
        guard limit > 0, !text.isEmpty else { return [] }
        let chars = Array(text.suffix(Self.maximumContextLength))
        var out: [String] = []
        var seen = Set<String>()
        for length in stride(from: chars.count, through: 1, by: -1) where out.count < limit {
            let context = String(chars[(chars.count - length)...])
            for s in continuations(ofPrefix: context) where out.count < limit && seen.insert(s).inserted {
                out.append(s)
            }
        }
        return out
    }

    /// 所有以 `prefix` 開頭且比它長的詞，去掉開頭後依分數由高到低（同分照詞表順序）。
    func continuations(ofPrefix prefix: String) -> [String] {
        let q = Array(prefix.utf8)
        return data.withUnsafeBytes { raw -> [String] in
            var lo = 0, hi = count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if compare(raw, mid, q) < 0 { lo = mid + 1 } else { hi = mid }
            }
            var hits: [(text: String, score: Int16, order: Int)] = []
            var i = lo
            while i < count && hits.count < Self.scanLimit {
                let p = record(raw, i)
                let len = Int(raw[p + 2])
                guard len >= q.count, p + 3 + len <= raw.count,
                      q.indices.allSatisfy({ raw[p + 3 + $0] == q[$0] }) else { break }
                if len > q.count {
                    let rest = UnsafeRawBufferPointer(rebasing: raw[(p + 3 + q.count)..<(p + 3 + len)])
                    let score = Int16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt16.self)))
                    hits.append((String(decoding: rest, as: UTF8.self), score, i))
                }
                i += 1
            }
            return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.text)
        }
    }

    @inline(__always)
    private func record(_ raw: UnsafeRawBufferPointer, _ i: Int) -> Int {
        recordsOffset + Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: indexOffset + 4 * i, as: UInt32.self)))
    }

    /// 第 i 筆詞與查詢的位元組序比較（<0＝詞較小）。
    private func compare(_ raw: UnsafeRawBufferPointer, _ i: Int, _ q: [UInt8]) -> Int {
        let p = record(raw, i)
        let len = Int(raw[p + 2])
        let n = min(len, q.count)
        for j in 0..<n {
            let a = raw[p + 3 + j], b = q[j]
            if a != b { return a < b ? -1 : 1 }
        }
        return len - q.count
    }
}
