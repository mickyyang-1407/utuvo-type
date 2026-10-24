import Foundation

/// 個人字典跨裝置同步（2026-09-20 產品決定：iPhone↔Mac 走 iCloud，Android 用匯出／匯入檔）。
///
/// 每一筆都記「最後改動時間」，刪除留墓碑（output = nil），兩份合併時同一個詞「最後改的贏」——
/// 所以 A 機刪掉、B 機沒動，同步後兩邊都刪；兩邊都改了，留比較晚的那個。
/// 匯出檔也是這個格式（Android／iPhone／Mac 互通），檔案裡的墓碑讓刪除也能帶過去。
public struct DictionarySync: Equatable, Sendable {
    /// 詞是使用者自己加的，還是從修改學到、自動加進來的（2026-10-22 delivery-learning-4，同 Kotlin `DictionarySync.Source`）。
    /// 檔案裡的字串跟 Android 一樣是 "MANUAL"／"AUTO"；舊檔沒有這個欄位、或看不懂的值，一律當手動。
    public enum Source: String, Sendable, CaseIterable {
        case manual = "MANUAL"
        case auto = "AUTO"

        /// 同 Kotlin `Source.parse`：只有 "AUTO" 是自動，其他（含缺欄位）都是手動。
        public static func parse(_ raw: String?) -> Source { raw == Source.auto.rawValue ? .auto : .manual }
    }

    public struct Entry: Equatable, Sendable, Codable {
        /// nil＝已刪除（墓碑）。
        public var output: String?
        /// 秒（Unix epoch）。
        public var at: Double
        /// 手動／自動。檔案裡缺欄位＝手動；寫檔時只寫「自動」，手動的不寫（舊版 Mac／iPhone 讀到的檔案跟以前一模一樣，
        /// Android 讀缺欄位也是手動）。
        public var source: Source
        public init(output: String?, at: Double) { self.init(output: output, at: at, source: .manual) }
        public init(output: String?, at: Double, source: Source) { self.output = output; self.at = at; self.source = source }

        private enum CodingKeys: String, CodingKey { case output, at, source }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            output = try c.decodeIfPresent(String.self, forKey: .output)
            at = try c.decode(Double.self, forKey: .at)
            source = Source.parse(try? c.decodeIfPresent(String.self, forKey: .source))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(output, forKey: .output)
            try c.encode(at, forKey: .at)
            if source == .auto { try c.encode(source.rawValue, forKey: .source) }
        }
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
        set(source, output, at: at, origin: .manual)
    }

    /// 同 Kotlin `set(source, output, at, origin)`：使用者手動加入一律手動；已經在字典裡的詞維持原本的來源
    /// （手動加過的詞之後又被學到，不能變成自動）；新詞、或刪掉後重新學到的才標自動。
    public mutating func set(_ source: String, _ output: String, at: Double, origin: Source) {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = entries[s]
        let mark: Source
        if origin == .manual { mark = .manual }
        else if previous == nil || previous?.output == nil { mark = .auto }
        else { mark = previous!.source }
        entries[s] = Entry(output: o.isEmpty ? s : o, at: at, source: mark)
    }

    /// 某個詞目前的來源；不在字典裡（或已刪除）回 nil。
    public func source(of term: String) -> Source? {
        guard let entry = entries[term], entry.output != nil else { return nil }
        return entry.source
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

    /// 合併：同一個詞時間較晚的贏；時間一樣時有值的贏、再比字典序，寫法也一樣時手動贏自動（讓兩邊結果一定一樣）。
    public func merged(with other: DictionarySync) -> DictionarySync {
        var out = entries
        for (s, theirs) in other.entries {
            guard let mine = out[s] else { out[s] = theirs; continue }
            if Self.wins(theirs, over: mine) { out[s] = theirs }
        }
        return DictionarySync(entries: out)
    }

    /// 全序比較（同 Kotlin `DictionarySync.wins`）：時間 → 有值 → 寫法字典序 → 來源（手動 > 自動）。
    /// 來源那一層（2026-10-22 修補）：舊版用戶端不認得 `source`，把 AUTO 讀成手動再寫回 iCloud，
    /// 兩份只差來源；沒有這層時 a.merged(b) ≠ b.merged(a)，兩台機器會互相覆寫停不下來。手動贏＝使用者的詞不會被降成自動。
    static func wins(_ a: Entry, over b: Entry) -> Bool {
        if a.at != b.at { return a.at > b.at }
        switch (a.output, b.output) {
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(x), .some(y)) where x != y: return x > y
        default: return a.source == .manual && b.source == .auto
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

    // MARK: - 純詞表匯入（2026-10-22 app-shell-6；Kotlin `DictionarySync` 同規則、同一份測試樣本）

    /// 詞表檔大小上限（對齊 Typeless 的 5 MB）。
    public static let maxWordListBytes = 5 * 1024 * 1024

    public enum WordListError: Error, Equatable { case tooLarge, noWords }

    /// 內容看起來像 JSON：去掉 BOM 和空白後第一個字是 `{` 或 `[`。看起來像 JSON 的一律走 `decode`，
    /// 壞掉的匯出檔才不會被當成詞表，把 `"format": …` 這種行當成詞加進去。
    public static func looksLikeJSON(_ data: Data) -> Bool {
        looksLikeJSON(String(decoding: data, as: UTF8.self))
    }

    public static func looksLikeJSON(_ text: String) -> Bool {
        let first = text.unicodeScalars.first { $0 != "\u{FEFF}" && !CharacterSet.whitespacesAndNewlines.contains($0) }
        return first == "{" || first == "["
    }

    /// 一行一詞的詞表（.txt、一欄 CSV）：UTF-8、去 BOM、接受 CRLF／CR；每行取第一欄（CSV 雙引號照規則解，`""` 是一個 `"`），
    /// 去前後空白、略過空行、重複的只留第一個。超過 5 MB 或一個詞都沒有就丟錯。
    public static func parseWordList(_ data: Data) throws -> [String] {
        guard data.count <= maxWordListBytes else { throw WordListError.tooLarge }
        return try parseWordList(String(decoding: data, as: UTF8.self))
    }

    public static func parseWordList(_ text: String) throws -> [String] {
        guard text.utf8.count <= maxWordListBytes else { throw WordListError.tooLarge }
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var seen = Set<String>(), words: [String] = []
        for line in body.components(separatedBy: "\n") {
            let word = firstCSVColumn(line)
            if !word.isEmpty, seen.insert(word).inserted { words.append(word) }
        }
        guard !words.isEmpty else { throw WordListError.noWords }
        return words
    }

    static func firstCSVColumn(_ line: String) -> String {
        let s = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard s.first == "\"" else {
            let end = s.firstIndex(of: ",") ?? s.count
            return String(s[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = "", i = 1
        while i < s.count {
            if s[i] == "\"" {
                guard i + 1 < s.count, s[i + 1] == "\"" else { break }
                out.append("\""); i += 2; continue
            }
            out.append(s[i]); i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 詞表裡哪些詞是新的（字典裡沒有、或之前刪掉的）。已經有的詞不動：使用者設定的輸出寫法不能被匯入蓋掉。
    public func newWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { raw in
            let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, entries[w]?.output == nil, seen.insert(w).inserted else { return nil }
            return w
        }
    }

    /// 把詞表加進字典：只加新的詞，寫法＝詞本身、時間 `at`（手動加入）。回傳真的加進去的詞。
    @discardableResult
    public mutating func addWords(_ words: [String], at: Double) -> [String] {
        let added = newWords(words)
        for w in added { set(w, w, at: at) }
        return added
    }

    /// 字典頁搜尋：聽到的字或輸出寫法含關鍵字（不分大小寫）；關鍵字全空白＝全部。
    /// 跟 iOS `DictionarySource.filter` 的搜尋同一條規則（iOS 那份在 ios/Shared、Mac 讀不到；之後 iOS 可以改用這裡）。
    /// Android 的字典頁搜尋寫在 app 層（MainSections.kt），不在 android/core，所以這裡沒有 Kotlin 對照。
    public static func search(_ entries: [(source: String, output: String)], query: String) -> [(source: String, output: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.source.localizedCaseInsensitiveContains(q) || $0.output.localizedCaseInsensitiveContains(q) }
    }

    /// 字典頁的「全部／自動／手動」分頁（2026-10-22 delivery-learning-4；同 iOS `DictionarySource.Tab` 的三個分頁）。
    public enum Tab: String, CaseIterable, Sendable { case all, auto, manual }

    /// 分頁＋搜尋：`autoTerms` 以外的一律算手動（舊資料沒有來源標記＝手動，同 iOS `DictionarySource.filter`）。
    public static func filter(_ entries: [(source: String, output: String)], tab: Tab, autoTerms: Set<String>,
                              query: String) -> [(source: String, output: String)] {
        let byTab: [(source: String, output: String)]
        switch tab {
        case .all: byTab = entries
        case .auto: byTab = entries.filter { autoTerms.contains($0.source) }
        case .manual: byTab = entries.filter { !autoTerms.contains($0.source) }
        }
        return search(byTab, query: query)
    }

    /// 目前有效、標成自動的詞（字典頁分頁與「自動」標籤用）。
    public var autoTerms: Set<String> {
        Set(entries.compactMap { $0.value.output != nil && $0.value.source == .auto ? $0.key : nil })
    }
}
