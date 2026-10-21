import Foundation

/// 自動學字典（2026-09-19，對齊 Chatterfly「語音輸入後修改的詞自動記住」）。
///
/// 只學一種情況：剛用語音貼上一段字，接著用本鍵盤**刪掉幾個字、再打回同樣字數、而且讀音相同**的字
/// （除值→儲值、及時→即時）＝辨識錯字，記成字典替換。刪「明天」打「後天」是改主意，讀音不同＝不學；
/// 刪掉的字不在剛聽寫的那段裡＝不學；只刪一個字不學（「在→再」套全域會誤傷「在家」）。
struct CorrectionLearner {
    /// 語音貼上後多久內的修改才算（之後就是一般編輯）。
    static let window: TimeInterval = 90
    static let maxLength = 6

    private(set) var dictated = ""
    private var dictatedAt: Date?
    private(set) var deleted = ""
    private(set) var typed = ""

    mutating func dictationInserted(_ text: String, at now: Date = Date()) {
        dictated = text; dictatedAt = now; deleted = ""; typed = ""
    }

    private func active(_ now: Date) -> Bool {
        guard let dictatedAt, !dictated.isEmpty else { return false }
        return now.timeIntervalSince(dictatedAt) <= Self.window
    }

    /// 刪掉游標前一個字之前呼叫（`charBefore`＝即將被刪的字）。
    mutating func willDelete(_ charBefore: Character?, at now: Date = Date()) {
        guard active(now) else { return }
        if !typed.isEmpty { typed.removeLast(); return }     // 刪的是自己剛打的
        guard let c = charBefore, !c.isWhitespace else { return }
        deleted = String(c) + deleted
        if deleted.count > Self.maxLength * 2 { deleted = ""; typed = "" }   // 刪一大段＝重寫，不是修字
    }

    /// 用鍵盤送出文字後呼叫。打回的字數跟刪掉的一樣就結算；回傳學到的一組。
    mutating func didType(_ text: String, at now: Date = Date()) -> (wrong: String, right: String)? {
        guard active(now), !deleted.isEmpty else { return nil }
        typed += text
        guard typed.count >= deleted.count else { return nil }
        defer { deleted = ""; typed = "" }
        return Self.evaluate(deleted: deleted, typed: typed, dictated: dictated)
    }

    static func evaluate(deleted: String, typed: String, dictated: String) -> (wrong: String, right: String)? {
        let d = deleted.trimmingCharacters(in: .whitespaces), r = typed.trimmingCharacters(in: .whitespaces)
        guard d != r, d.count == r.count, (2...maxLength).contains(d.count), dictated.contains(d) else { return nil }
        guard zip(d, r).allSatisfy({ $0 == $1 || HomophoneCorrector.isHomophone($0, $1) }) else { return nil }
        return (d, r)
    }
}

/// 字典項目的來源分頁（全部／自動加入／手動加入）與搜尋過濾。純函式，可測。
enum DictionarySource {
    enum Tab: String, CaseIterable, Sendable {
        case all, auto, manual
    }

    /// 分頁＋即時搜尋（來源或輸出含關鍵字，大小寫不敏感）。
    /// **舊資料沒有「自動」標記的一律算手動**——`autoLearned` 是自動來源的單一正本。
    static func filter(_ entries: [(source: String, output: String)],
                       tab: Tab,
                       autoLearned: Set<String>,
                       query: String) -> [(source: String, output: String)] {
        let byTab: [(source: String, output: String)]
        switch tab {
        case .all: byTab = entries
        case .auto: byTab = entries.filter { autoLearned.contains($0.source) }
        case .manual: byTab = entries.filter { !autoLearned.contains($0.source) }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return byTab }
        return byTab.filter {
            $0.source.localizedCaseInsensitiveContains(q) || $0.output.localizedCaseInsensitiveContains(q)
        }
    }
}

/// 自動學到的字典詞（標記用：設定頁顯示「自動」、可刪）＋iPhone 文字替換／聯絡人姓名（只當辨識提示）。
enum LearnedVocabulary {
    static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard }
    static let autoKey = "utuvo.type.dictionary.autoLearned"
    static let lexiconKey = "utuvo.type.lexicon.supplementary"

    static var autoLearned: Set<String> { Set(defaults.stringArray(forKey: autoKey) ?? []) }

    static func markAutoLearned(_ source: String) {
        var s = autoLearned; s.insert(source); defaults.set(Array(s), forKey: autoKey)
    }

    static func unmark(_ source: String) {
        var s = autoLearned; s.remove(source); defaults.set(Array(s), forKey: autoKey)
    }

    /// 鍵盤從 UILexicon 讀到的詞（文字替換的展開詞、聯絡人姓名），過濾後存起來給主 app 當辨識提示。
    static func storeLexicon(_ phrases: [String]) {
        var seen = Set<String>(); var out: [String] = []
        for p in phrases {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...20).contains(t.count), !t.contains("\n"), seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == 200 { break }
        }
        defaults.set(out, forKey: lexiconKey)
    }

    static var lexicon: [String] { defaults.stringArray(forKey: lexiconKey) ?? [] }

    // MARK: - 已忽略（使用者手動刪掉自動學到的詞）

    static let ignoredKey = "utuvo.type.dictionary.ignoredAuto"

    /// 使用者按「刪」刪掉的自動詞。同一組修正（錯字→對字）之後不該馬上又被學回來。
    static var ignored: Set<String> { Set(defaults.stringArray(forKey: ignoredKey) ?? []) }

    static func markIgnored(_ source: String) {
        var s = ignored; s.insert(source); defaults.set(Array(s), forKey: ignoredKey)
    }

    static func unignore(_ source: String) {
        var s = ignored; s.remove(source); defaults.set(Array(s), forKey: ignoredKey)
    }

    /// 這組修正現在該不該學進字典。
    static func shouldLearn(wrong: String, right: String) -> Bool {
        !ignored.contains(key(for: wrong, right: right))
    }

    /// 這次自動學到的詞，要不要順便標成「自動學到的」。
    ///
    /// 2026-10-13 修補：使用者**手動**加過的詞（字典裡有、但不在 autoLearned 名單裡＝
    /// 字典頁的「手動」分頁），被語音同音字自動學到時會被 `markAutoLearned` 搬到「自動」分頁，
    /// 使用者加的詞就消失在那裡了。手動的要維持手動。
    /// 純函式（把兩個集合當參數）所以可以直接測。
    static func shouldMarkAutoLearned(source: String, inDictionary: Bool, autoLearned: Set<String>) -> Bool {
        // 已經是自動學到的 → 標記本來就在（回 false＝不必重複寫，結果一樣）。
        // 字典裡有但不在自動名單 → 手動詞，維持手動。
        if inDictionary { return autoLearned.contains(source) }
        return true
    }

    /// 從字典刪掉一個詞，並把「已忽略」清單同步好。**唯一正本**——
    /// 字典瀏覽頁與設定頁都走這裡；原本設定頁只做 `removeTerm`，
    /// 刪掉自動詞不會記進忽略清單，同一組修正一下就被學回來。
    /// 呼叫端負責 `DictionaryCloud.sync()`。
    static func removeFromDictionary(_ source: String) {
        let output = DictionaryStore.shared.dictionary[source] ?? ""
        let wasAuto = autoLearned.contains(source)
        DictionaryStore.shared.removeTerm(source: source)
        unmark(source)
        if wasAuto { markIgnored(key(for: source, right: output)) }
    }

    /// 忽略清單用「錯字→對字」當 key：同一個錯字換成別的字是新的修正，不該被連坐。
    static func key(for wrong: String, right: String) -> String {
        wrong + "\u{1}" + right
    }
}
