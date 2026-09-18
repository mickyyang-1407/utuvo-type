import Foundation

/// 拼音音節表＋切分器（不查詞頻；詞頻加權的最佳切分在 `PinyinEngine.bestSegmentation`）。
///
/// 音節集合不寫死：直接取詞庫音節表（rime-pinyin-simp 實際出現的 415 個不帶調音節，
/// 含 ü 寫成 v 的 `lv`、`nv`，以及 `lue`／`nue`、嘆詞 `m`、`n`、`ng`、`hm`）。
/// 另外接受兩個常見打法的別名：`lve`→`lue`、`nve`→`nue`。
///
/// 音節 ID＝音節在「依字母排序」的表中的索引，所以「以某字串開頭的音節」是一段連續 ID 區間
/// （例 `zh` → zha…zhuo）。未打完的音節與聲母縮寫都用這個區間查詞庫。
public struct PinyinSyllables: Sendable {
    /// 聲母（含零聲母的 y、w）。縮寫輸入時，這些字串可以單獨代表「以它開頭的任何音節」。
    public static let initials: Set<String> = [
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
        "zh", "ch", "sh", "r", "z", "c", "s", "y", "w",
    ]
    /// 常見的 ü 打法別名 → 詞庫裡的寫法。
    public static let aliases: [String: String] = ["lve": "lue", "nve": "nue"]
    /// 最長音節的字母數（zhuang／chuang／shuang）。
    public static let maximumSyllableLength = 6

    /// 依字母排序的音節；索引＝音節 ID。
    public let all: [String]
    private let ids: [String: UInt16]
    /// 所有「某音節的前綴（含音節本身）」→ 以它開頭的音節 ID 區間。
    private let prefixRanges: [String: Range<UInt16>]

    /// `syllables` 必須是依位元組序排序、不重複的小寫音節（詞庫音節表本來就是）。
    public init(sortedSyllables syllables: [String]) {
        all = syllables
        var ids: [String: UInt16] = [:]
        var ranges: [String: Range<UInt16>] = [:]
        for (i, s) in syllables.enumerated() {
            let id = UInt16(i)
            ids[s] = id
            var prefix = ""
            for ch in s {
                prefix.append(ch)
                if let r = ranges[prefix] {
                    ranges[prefix] = min(r.lowerBound, id)..<max(r.upperBound, id + 1)
                } else {
                    ranges[prefix] = id..<(id + 1)
                }
            }
        }
        for (alias, target) in Self.aliases {
            if let id = ids[target] { ids[alias] = id }
        }
        self.ids = ids
        self.prefixRanges = ranges
    }

    public var count: Int { all.count }

    /// 完整音節（或別名）→ 音節 ID。
    public func id(_ syllable: String) -> UInt16? { ids[syllable] }

    public func isValid(_ syllable: String) -> Bool { ids[syllable] != nil }

    /// 以 `prefix` 開頭的音節 ID 區間；沒有任何音節以它開頭回 nil。
    public func range(prefix: String) -> Range<UInt16>? { prefixRanges[prefix] }

    /// 有沒有音節以這個字母開頭（i、u、v 沒有）。
    public func canStartSyllable(_ letter: Character) -> Bool { prefixRanges[String(letter)] != nil }

    // MARK: - 切分（只看音節表，不看詞頻）

    /// 把一串字母切成「全部由完整音節組成」的所有切法。`'` 是強制分界。
    /// 依音節數少的在前、同數量時前面音節長的在前（＝最長匹配優先）。
    /// 含非 a–z／`'` 字元，或怎麼切都不完整時回空陣列。最多回 `limit` 種。
    ///
    /// 例：`xian` → [[xian], [xi, an], [xia, n], [xi, a, n]]；`xi'an` → [[xi, an]]。
    public func segmentations(_ raw: String, limit: Int = 16) -> [[String]] {
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ PinyinEngine.isInputByte($0) }) else { return [] }
        var results: [[String]] = []
        let n = bytes.count
        // canFinish[i]：從 i 開始能不能完整切到結尾（先算好，避免指數回溯）
        var canFinish = [Bool](repeating: false, count: n + 1)
        canFinish[n] = true
        for i in stride(from: n - 1, through: 0, by: -1) {
            if bytes[i] == UInt8(ascii: "'") { canFinish[i] = canFinish[i + 1]; continue }
            for len in 1...Self.maximumSyllableLength where i + len <= n {
                if bytes[i..<(i + len)].contains(UInt8(ascii: "'")) { break }
                if isValid(String(decoding: bytes[i..<(i + len)], as: UTF8.self)) && canFinish[i + len] {
                    canFinish[i] = true
                    break
                }
            }
        }
        guard canFinish[0] else { return [] }
        var path: [String] = []
        // 窮舉會爆的情況很少（音節表短），但仍設上限：蒐集 limit×4 種再排序截斷
        let cap = max(limit, 1) * 4
        func dfs(_ i: Int) {
            if results.count >= cap { return }
            if i == n { results.append(path); return }
            if bytes[i] == UInt8(ascii: "'") { dfs(i + 1); return }
            for len in stride(from: min(Self.maximumSyllableLength, n - i), through: 1, by: -1) {
                if bytes[i..<(i + len)].contains(UInt8(ascii: "'")) { continue }
                let s = String(decoding: bytes[i..<(i + len)], as: UTF8.self)
                guard isValid(s), canFinish[i + len] else { continue }
                path.append(s)
                dfs(i + len)
                path.removeLast()
            }
        }
        dfs(0)
        return Array(results.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count < $1.element.count : $0.offset < $1.offset }
            .map(\.element)
            .prefix(limit))
    }
}
