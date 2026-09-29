import Foundation

/// 英文鍵盤建議列的純邏輯（不碰 UIKit）：找出游標前正在打的字、合併各來源的建議、配合使用者的大小寫。
/// 拼字檢查與補完的來源（iOS 的 UITextChecker）由鍵盤那一層提供，這裡只負責排序與去重，方便在 macOS 上測。
public enum EnglishSuggestions {
    /// 建議列最多幾格。
    public static let defaultLimit = 8

    /// 可以組成「一個字」的字元：ASCII 字母，以及夾在字母中間的撇號（don't、it's）。
    public static func isWordCharacter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter || c == "'" || c == "’"
    }

    /// 游標前正在打的那個字（結尾連續的字母；開頭的撇號不算）。游標前是空白、標點、數字時回空字串。
    public static func currentWord(before text: String?) -> String {
        guard let text else { return "" }
        let word = text.reversed().prefix { isWordCharacter($0) }
        return String(String(word.reversed()).drop { $0 == "'" || $0 == "’" })
    }

    /// 合併建議：
    /// 1. 使用者自己的詞（個人字典、聯絡人姓名、文字替換）裡以這個字開頭的——最懂使用者；
    /// 2. 拼錯時：拼字建議（guesses）優先，否則補完（completions）優先；
    /// 3. 去掉跟打的字一模一樣（不分大小寫）的、重複的；
    /// 4. 依使用者打的大小寫調整（Hel → Hello、HEL → HELLO）；使用者詞保留原本的寫法（iPhone、McBopomofo）。
    public static func merge(word: String, isMisspelled: Bool, completions: [String], guesses: [String],
                             userTerms: [String], limit: Int = defaultLimit) -> [String] {
        guard !word.isEmpty, limit > 0 else { return [] }
        let lower = word.lowercased()
        var out: [String] = []
        var seen: Set<String> = [lower]
        func add(_ s: String, keepCase: Bool) {
            guard out.count < limit, !s.isEmpty else { return }
            let shown = keepCase ? s : matchCase(s, to: word)
            if seen.insert(shown.lowercased()).inserted { out.append(shown) }
        }
        for t in userWords(matching: lower, in: userTerms) { add(t, keepCase: true) }
        let (first, second) = isMisspelled ? (guesses, completions) : (completions, guesses)
        for s in first { add(s, keepCase: false) }
        for s in second { add(s, keepCase: false) }
        return out
    }

    /// 使用者詞庫裡以 `prefix`（小寫）開頭、而且比它長的字。多字詞拆成單字比對（「Dolby Atmos」→ Dolby、Atmos）。
    static func userWords(matching prefix: String, in terms: [String]) -> [String] {
        var out: [String] = []
        for term in terms {
            for w in term.split(whereSeparator: { !isWordCharacter($0) }) {
                let s = String(w)
                if s.count > prefix.count, s.lowercased().hasPrefix(prefix), s.allSatisfy(isWordCharacter) {
                    out.append(s)
                }
            }
        }
        return out
    }

    /// 依使用者打的樣子調整大小寫：全大寫（兩個字母以上）→ 全大寫；首字大寫 → 首字大寫；其他照建議原樣。
    public static func matchCase(_ suggestion: String, to typed: String) -> String {
        guard let first = typed.first, first.isUppercase else { return suggestion }
        if typed.count > 1, typed.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return suggestion.uppercased() }
        return suggestion.prefix(1).uppercased() + suggestion.dropFirst()
    }
}
