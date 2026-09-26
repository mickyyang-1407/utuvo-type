import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 同音錯字校正（2026-09-19，Micky：「很多錯別字」——除值／儲值、及時／即時、做車／坐車）。
///
/// Apple Intelligence（裝置端）找同音錯字，但**只准換同音字**：逐字對齊後，只收「同一位置、去掉聲調後拼音相同」的
/// 單字替換；模型的刪字、加字、改寫、改標點全部丟掉。講的話不會被改寫，最壞情況＝原樣。
///
/// Mac 同模型實測（18 句：12 句有同音錯、6 句正確）：兩種問法並行取聯集，修對 8/12、改錯 0、正確句誤改 0；
/// 48 段長文不引入新錯。單一問法：全文改正後逐字收 7/12，列清單 3/12。
enum HomophoneCorrector {
    /// 太短的不值得等模型。
    static let minimumLength = 6
    /// 超過就放棄校正、用原文（不讓使用者一直等）。
    static let timeout: Duration = .milliseconds(1800)

    static var isAvailable: Bool { OnDeviceAssistant.onDeviceAvailable }

    /// 只處理中文辨識語言。
    static func applies(to language: String) -> Bool { language.hasPrefix("zh") }

    // MARK: - 決定論部分（可測）

    static func pinyin(_ c: Character) -> String {
        let s = String(c).applyingTransform(.mandarinToLatin, reverse: false) ?? String(c)
        return (s.applyingTransform(.stripDiacritics, reverse: false) ?? s).lowercased()
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    /// 人稱代名詞同音（他／她／它…）：換了＝替使用者猜性別，一律不換。
    static let pronouns: Set<Character> = ["他", "她", "它", "牠", "祂", "你", "妳", "您"]

    static func isHomophone(_ a: Character, _ b: Character) -> Bool {
        a != b && isCJK(a) && isCJK(b) && !(pronouns.contains(a) && pronouns.contains(b)) && pinyin(a) == pinyin(b)
    }

    /// 從模型改過的全文裡，只收同位置的同音單字替換，套回原文。
    static func harvest(original: String, candidate: String) -> String {
        let a = Array(original), b = Array(candidate)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out = a
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let r = i < a.count && removed.contains(i), n = j < b.count && inserted.contains(j)
            if r && n {
                if isHomophone(a[i], b[j]) { out[i] = b[j] }
                i += 1; j += 1
            } else if r { i += 1 }
            else if n { j += 1 }
            else { i += 1; j += 1 }
        }
        return String(out)
    }

    /// 清單式：「錯詞→正詞」，原文裡真的有、字數相同、每個不同的字都同音才換。
    static func apply(fixes: [(wrong: String, right: String)], to text: String) -> String {
        var out = text
        for fix in fixes {
            let w = Array(fix.wrong), r = Array(fix.right)
            guard w.count >= 2, w.count == r.count, fix.wrong != fix.right, out.contains(fix.wrong),
                  zip(w, r).allSatisfy({ $0 == $1 || isHomophone($0, $1) }) else { continue }
            out = out.replacingOccurrences(of: fix.wrong, with: fix.right)
        }
        return out
    }

    // MARK: - 模型

    static let rewriteInstructions = """
    你是中文語音辨識的校對員。語音辨識常把詞聽成同音但錯誤的字（例如：除值→儲值、及時→即時、做車→坐車、在見→再見、因該→應該、以經→已經）。
    請把使用者的逐字稿改正錯字後輸出全文。只改錯字，其餘一字不動；標點照原樣。只輸出改正後的全文。
    """

    static let listInstructions = """
    你是中文語音辨識的校對員。語音辨識常把詞聽成「同音但錯誤」的字，例如：除值→儲值、及時的→即時的、做車→坐車、在見→再見、因該→應該、以經→已經、在來→再來。
    找出逐字稿中這種同音錯字。只列真的錯的詞（讀音相同、但放在句子裡意思不通），不確定就不要列。不要列標點、不要改語氣、不要改英文和數字。
    """

    /// 校正；不可用、太短、逾時、出錯都回原文。
    static func correct(_ text: String, budget: CleanupBudget? = nil) async -> String {
        guard !Task.isCancelled, text.count >= minimumLength, text.contains(where: isCJK), isAvailable else { return text }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let ownDeadline = ContinuousClock.now.advanced(by: timeout)
            let limited = CleanupBudget(deadline: min(budget?.deadline ?? ownDeadline, ownDeadline))
            return (try? await limited.run { await runModels(text) }) ?? text
        }
        #endif
        return text
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Fix {
        @Guide(description: "逐字稿裡寫錯的詞，必須原文照抄，2 到 4 個字")
        var wrong: String
        @Guide(description: "讀音完全相同、但意思正確的詞，字數跟 wrong 一樣")
        var right: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Fixes {
        @Guide(description: "同音錯字清單；沒有錯就是空的")
        var fixes: [Fix]
    }

    /// 兩種問法並行，結果取聯集（逐字收的先套，清單再補）。
    @available(iOS 26.0, macOS 26.0, *)
    private static func runModels(_ text: String) async -> String {
        async let rewritten: String? = {
            let session = LanguageModelSession(instructions: rewriteInstructions)
            return try? await session.respond(to: text, options: GenerationOptions(temperature: 0)).content
        }()
        async let listed: [(wrong: String, right: String)] = {
            let session = LanguageModelSession(instructions: listInstructions)
            let r = try? await session.respond(to: text, generating: Fixes.self, options: GenerationOptions(temperature: 0)).content
            return r?.fixes.map { ($0.wrong, $0.right) } ?? []
        }()
        var out = text
        if let candidate = await rewritten {
            out = harvest(original: text, candidate: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return apply(fixes: await listed, to: out)
    }
    #endif
}
