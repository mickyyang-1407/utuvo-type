import AppKit
import UTUVOTypeCore

/// 修改學習判斷「全大寫的字是強調常用字（IMPORTANT），還是品牌縮寫（UTUVO）」用（2026-10-22 修補）。
/// core 內建的常用字表（SCOWL 10＋20 級）之外，再問系統的英文拼字字典：demo、invoice 這類不在前兩級、但還是一般英文的字也算常用。
/// 使用者自己在系統「學過」的字（hasLearnedWord）不算常用字——那是他自己的專名。沒有英文字典時保守當常用字（不自動加）。
@MainActor
enum EnglishSpelling {
    static func isCommonWord(_ word: String) -> Bool {
        if EditLearning.isCommonEnglishWord(word) { return true }
        let checker = NSSpellChecker.shared
        let lower = word.lowercased()
        let forms = [lower, lower.capitalized]
        if ([word] + forms).contains(where: checker.hasLearnedWord) { return false }
        guard checker.availableLanguages.contains(where: { $0.hasPrefix("en") }) else { return true }
        return forms.contains { form in
            checker.checkSpelling(of: form, startingAt: 0, language: "en", wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
