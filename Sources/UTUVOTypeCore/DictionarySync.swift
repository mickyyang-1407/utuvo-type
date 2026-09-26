import Foundation

/// 個人字典跨裝置同步（2026-09-20 產品決定：iPhone↔Mac 走 iCloud，Android 用匯出／匯入檔）。
///
/// 每一筆都記「最後改動時間」，刪除留墓碑（output = nil），兩份合併時同一個詞「最後改的贏」——
/// 所以 A 機刪掉、B 機沒動，同步後兩邊都刪；兩邊都改了，留比較晚的那個。
/// 匯出檔也是這個格式（Android／iPhone／Mac 互通），檔案裡的墓碑讓刪除也能帶過去。
public struct DictionarySync: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Codable {
        /// nil＝已刪除（墓碑）。
        public var output: String?
        /// 秒（Unix epoch）。
        public var at: Double
        public init(output: String?, at: Double) { self.output = output; self.at = at }
    }

    public static let format = "utuvo-type-dictionary"
    public static let version = 1
    /// 墓碑保留 180 天，避免無限長大；超過之後才同步回來的舊機器可能把刪掉的詞帶回來（可接受）。
    public static let tombstoneLifetime: Double = 180 * 24 * 3600

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// 從舊版只有 `{聽到: 改成}` 的字典建立（沒有時間＝0，任何有時間的改動都會蓋過它）。
    public init(plain: [String: String], at: Double = 0) {
        entries = plain.mapValues { Entry(output: $0, at: at) }
    }

    /// 目前有效的字典（給 Normalizer／辨識提示用的那份）。
    public var live: [String: String] {
        entries.compactMapValues(\.output)
    }

    public mutating func set(_ source: String, _ output: String, at: Double) {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[s] = Entry(output: o.isEmpty ? s : o, at: at)
    }

    public mutating func remove(_ source: String, at: Double) {
        guard entries[source] != nil else { return }
        entries[source] = Entry(output: nil, at: at)
    }

    /// 把本機 `{聽到: 改成}`（可能被舊程式碼直接改過）對齊到這份紀錄：
    /// 多出來的詞＝新增、少掉的＝刪除、值不同＝修改，都記成 `at`。
    public mutating func reconcile(with plain: [String: String], at: Double) {
        for (s, o) in plain where entries[s]?.output != o { entries[s] = Entry(output: o, at: at) }
        for (s, e) in entries where e.output != nil && plain[s] == nil { entries[s] = Entry(output: nil, at: at) }
    }

    /// 合併：同一個詞時間較晚的贏；時間一樣時有值的贏、再比字典序（讓兩邊結果一定一樣）。
    public func merged(with other: DictionarySync) -> DictionarySync {
        var out = entries
        for (s, theirs) in other.entries {
            guard let mine = out[s] else { out[s] = theirs; continue }
            if Self.wins(theirs, over: mine) { out[s] = theirs }
        }
        return DictionarySync(entries: out)
    }

    static func wins(_ a: Entry, over b: Entry) -> Bool {
        if a.at != b.at { return a.at > b.at }
        switch (a.output, b.output) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(x), .some(y)): return x > y
        }
    }

    /// 丟掉太舊的墓碑。
    public func pruned(now: Double) -> DictionarySync {
        DictionarySync(entries: entries.filter { $0.value.output != nil || now - $0.value.at < Self.tombstoneLifetime })
    }

    // MARK: - 檔案格式（匯出／匯入、iCloud 共用）

    private struct File: Codable {
        var format: String
        var version: Int
        var entries: [String: Entry]
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(File(format: Self.format, version: Self.version, entries: entries))) ?? Data()
    }

    public enum DecodeError: Error, Equatable { case notDictionaryFile, newerVersion(Int) }

    /// 讀匯出檔；也接受舊的純 `{聽到: 改成}` JSON（時間當 0）。
    public static func decode(_ data: Data) throws -> DictionarySync {
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            guard file.format == format else { throw DecodeError.notDictionaryFile }
            guard file.version <= version else { throw DecodeError.newerVersion(file.version) }
            return DictionarySync(entries: file.entries)
        }
        if let plain = try? JSONDecoder().decode([String: String].self, from: data) {
            return DictionarySync(plain: plain)
        }
        throw DecodeError.notDictionaryFile
    }
}
