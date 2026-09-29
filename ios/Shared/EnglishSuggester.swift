import UIKit
import UTUVOTypeCore

/// 英文鍵盤建議列的資料來源：iOS 內建拼字字典（UITextChecker，完全在裝置上、不連網）的補完與拼字建議，
/// 加上使用者自己的詞（個人字典、iPhone 文字替換、聯絡人姓名）。排序與大小寫規則在 `EnglishSuggestions`（Core）。
@MainActor
final class EnglishSuggester {
    private lazy var checker = UITextChecker()
    private lazy var language: String? = {
        let all = UITextChecker.availableLanguages
        return all.first { $0 == "en_US" } ?? all.first { $0.hasPrefix("en") }
    }()
    private var cachedUserTerms: [String]?

    /// 個人字典或系統詞彙可能變了（鍵盤重新出現時呼叫）。
    func reloadUserTerms() { cachedUserTerms = nil }

    private var userTerms: [String] {
        if let cachedUserTerms { return cachedUserTerms }
        let terms = VocabularyPacks.personalTerms() + LearnedVocabulary.lexicon
        cachedUserTerms = terms
        return terms
    }

    /// `word`：游標前正在打的字（見 `EnglishSuggestions.currentWord`）。空字串或沒有英文字典時回空陣列。
    func suggestions(for word: String, limit: Int = EnglishSuggestions.defaultLimit) -> [String] {
        guard !word.isEmpty, let language else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let completions = checker.completions(forPartialWordRange: range, in: word, language: language) ?? []
        let misspelled = word.count > 1 && checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0,
                                                                         wrap: false, language: language).location != NSNotFound
        let guesses = misspelled ? (checker.guesses(forWordRange: range, in: word, language: language) ?? []) : []
        return EnglishSuggestions.merge(word: word, isMisspelled: misspelled,
                                        completions: Array(completions.prefix(limit * 2)),
                                        guesses: Array(guesses.prefix(limit)),
                                        userTerms: userTerms, limit: limit)
    }
}
