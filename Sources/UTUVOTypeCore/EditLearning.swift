import Foundation

/// 從修改學到的「原字→改後」要怎麼進字典（2026-10-22 asr-vocab-4、delivery-learning-4；同日依 verifier 修補收緊）。
///
/// 個人字典的條目是「聽到→改成」的全文硬替換（`Normalizer.applyDictionary`：區分大小寫、整個詞、整段文字），
/// 還會經 iCloud 同步到 iPhone。使用者一般的改內容（今天→明天、三點→四點）如果直接寫進去，就變成永久的改寫規則。
/// 所以不經確認就寫進字典的只有兩種，其他都只留建議（使用者按「加入」才進字典）：
///
/// 1. **硬替換**（原字→改後）：讀音／拼法過得了關的辨識錯字。
///    - 中文：2–6 字、字數一樣、每個不同的字都同音而且不是語意關鍵字
///      （`MandarinReading.isHomophoneSubstitution`：否定、數字、人稱、買賣——同一份規則，不另寫），
///      **而且至少改了兩個字**。只改一個字（在→再、的→得、美→梅）的 key 是補了鄰字湊出來的，
///      「在說→再說」學進去之後「他們還在說」會被改成「還再說」；手機的 CorrectionLearner 也只學使用者自己改的 ≥2 字。
///    - 英文：改後的詞是「詞庫包的詞」或「寫法像品牌」（見下），而且把它放進 `LatinNameFixer` 的詞表，
///      它自己就會把原字修成改後的詞（距離或骨架在 costLimit 內）。只差大小寫的不做硬替換。
/// 2. **詞彙模式**（只當辨識提示、不做替換）：只差大小寫的品牌寫法（Utuvo→UTUVO、iphone→iPhone），
///    或中文音譯改成英文詞（派森→Python），改後的詞同樣要是詞庫包的詞或寫法像品牌。寫成「聽到＝改後的詞、輸出留空」。
///
/// 「寫法像品牌」：某個英文字中間有大寫（iPhone、ChatGPT、MiniMax），或是整個大寫、而且小寫不是常用英文字（UTUVO、DAMI；
/// IMPORTANT、URGENT 不算）。兩個普通英文字／名字互換（Stephen→Steven、meeting→workshop、invoice→receipt）、
/// 強調用的大寫、片語改標題大寫（project plan→Project Plan）都只留建議。
public enum EditLearning {
    public enum Decision: Equatable, Sendable {
        /// 自動加「from → to」硬替換。
        case replacement(from: String, to: String)
        /// 自動加詞彙模式條目（聽到＝這個詞、輸出留空）。
        case vocabulary(String)
        /// 不自動加，只留建議。
        case suggestion
    }

    /// 中文同音字修正的字數範圍（同 iOS `CorrectionLearner.evaluate` 的 2…6：單字「在→再」全域替換會誤傷「在家」）。
    public static let homophoneLengths = 2...6
    /// 中文硬替換至少要改幾個字（2026-10-22 修補）：只改一個字的不自動加。
    public static let minChangedCharacters = 2

    /// - Parameters:
    ///   - knownTerms: 開著的詞庫包的英文詞（App 傳內建詞＋各包 seed）；改成這些詞的拼法／大小寫修正可以自動加。
    ///   - isCommonWord: 英文字（原本的大小寫）是不是常用字，判斷全大寫是品牌縮寫還是強調；App 另外接系統拼字字典。
    public static func decide(_ correction: EditTracker.Correction, knownTerms: Set<String> = [],
                              isCommonWord: (String) -> Bool = isCommonEnglishWord) -> Decision {
        let from = correction.from, to = correction.to
        if isHomophoneFix(from: from, to: to) {
            return changedCharacters(from: from, to: to) >= minChangedCharacters ? .replacement(from: from, to: to) : .suggestion
        }
        guard (from + to).contains(where: EditTracker.isLatin) else { return .suggestion }
        guard correction.isAutoAddEligible, isVocabularyTerm(to),
              knownTerms.contains(to) || hasBrandCasing(to, isCommonWord: isCommonWord) else { return .suggestion }
        if correction.caseOnly || isTransliteration(from) { return .vocabulary(to) }
        if isLatinNameFix(from: from, to: to), !isOrdinaryEnglish(from) { return .replacement(from: from, to: to) }
        return .suggestion   // 英文換成另一個英文（meeting→Zoom）：不是拼法修正
    }

    /// 原字是一般英文（2026-10-22 wave2 整合，verify2:mac-learning2）：每個字都是常用英文字（`CommonEnglishWords`，
    /// 跟 LatinNameFixer 的常用字護欄同一份），而且只有一個字、或有小寫開頭的字（phone、linked in、face book）。
    /// 字典是全文硬替換，linked in→LinkedIn 學進去之後「the files are linked in the doc」也會被改掉，所以只留建議。
    /// 每個字都大寫開頭的片語（Dummy Music）多半是聽錯的名字，照舊可以硬替換。
    static func isOrdinaryEnglish(_ from: String) -> Bool {
        let words = from.split(whereSeparator: { !EditTracker.isLatin($0) }).map(String.init)
        guard !words.isEmpty, words.allSatisfy(LatinNameFixer.isCommonEnglishWord) else { return false }
        return words.count == 1 || words.contains { $0.first?.isLowercase == true }
    }

    /// 兩段字有幾個位置不一樣（字數不同時，多出來的也算）。
    public static func changedCharacters(from: String, to: String) -> Int {
        let a = Array(from), b = Array(to)
        return zip(a, b).filter { $0 != $1 }.count + abs(a.count - b.count)
    }

    /// 中文：字數一樣（2–6）、全是漢字、每個不同的字都是同音而且不在語意關鍵字清單裡。
    public static func isHomophoneFix(from: String, to: String) -> Bool {
        let a = Array(from), b = Array(to)
        guard from != to, a.count == b.count, homophoneLengths.contains(a.count),
              a.allSatisfy(MandarinReading.isCJK), b.allSatisfy(MandarinReading.isCJK) else { return false }
        return zip(a, b).allSatisfy { $0 == $1 || MandarinReading.isHomophoneSubstitution($0, $1) }
    }

    /// 英文：只認識改後這一個詞的 `LatinNameFixer`，會不會自己把原字修成它（Protus→Pro Tools、Dummy Music→DAMI music）。
    public static func isLatinNameFix(from: String, to: String) -> Bool {
        from != to && LatinNameFixer.fix(from, terms: [to]) == to
    }

    /// 改後的詞能不能當英文專名（`LatinNameFixer` 收得進詞表：至少兩個字、只有英文字母／數字／空白／-／.、不是常用英文字）。
    public static func isVocabularyTerm(_ term: String) -> Bool {
        !LatinNameFixer.Table(terms: [term]).isEmpty
    }

    /// 寫法像品牌：某個英文字中間有大寫（iPhone、ChatGPT、MiniMax），或整個大寫、而且小寫不是常用字（UTUVO、DAMI）。
    /// 只有字首大寫（Steven、Project Plan、Atmos）不算；全大寫的常用字（IMPORTANT、OK）是強調，也不算。
    public static func hasBrandCasing(_ term: String, isCommonWord: (String) -> Bool = isCommonEnglishWord) -> Bool {
        term.split(whereSeparator: { !EditTracker.isLatin($0) }).contains { token in
            let letters = token.filter(\.isLetter)
            guard letters.count >= 2 else { return false }
            if letters.allSatisfy(\.isUppercase) { return !isCommonWord(String(token)) }
            return letters.dropFirst().contains(where: \.isUppercase)
        }
    }

    /// 常用英文字（不分大小寫）：repo 英文詞表的 SCOWL 10＋20 級（`EnglishCommonWords`），加上 `LatinNameFixer.commonWords`。
    public static func isCommonEnglishWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        return EnglishCommonWords.contains(lower) || LatinNameFixer.commonWords.contains(LatinNameFixer.fold(lower))
    }

    /// 原字是中文音譯（派森→Python）：只有漢字和空白。
    static func isTransliteration(_ from: String) -> Bool {
        from.contains(where: MandarinReading.isCJK) && from.allSatisfy { MandarinReading.isCJK($0) || $0.isWhitespace }
    }
}
