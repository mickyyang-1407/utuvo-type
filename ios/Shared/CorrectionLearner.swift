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
}
