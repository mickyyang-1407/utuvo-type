import Foundation

/// 辨識提示詞要送哪一種字形（fx-hints，2026-10-22）。Android core `HintScript` 同一份。
public enum HintScript: String, Sendable, Equatable {
    /// 照原樣送（非中文聽寫）。
    case asIs
    /// 台灣繁體：只有簡體寫的個人詞才轉；已經是繁體、或兩邊通用的詞原樣送。
    case traditional
    /// 簡體：有繁體專用字的詞轉簡體（內建包是台灣繁體，簡體輸出時不該把辨識器往繁體拉）。
    case simplified
}

/// 一個詞是簡體還是繁體寫的（辨識提示詞用；Android core `HanScript` 同一條規則、同一份字表）。
///
/// 以前提示詞整串跑 ICU Hans-Hant，但它對已經是繁體的字不是冪等的：兩邊通用的字（杰 干 岩 庄 范 于 后）
/// 會被改成別的字——周杰倫→周傑倫、干擾→乾擾、奇岩站→奇巖站、于美人→於美人、后里→後里，提示詞反而把辨識器
/// 帶去錯的人名、地名。現在只看詞裡有沒有「只在簡體出現的字」（码 请 伦）與「只在繁體出現的字」（倫 擾 頭）：
/// 字表在 `HanScriptData`（OpenCC 產生，見 scripts/build-han-script.py）。
public enum HanScript {
    static let simplifiedOnly: Set<Unicode.Scalar> = scalars(HanScriptData.simplifiedOnly)
    static let traditionalOnly: Set<Unicode.Scalar> = scalars(HanScriptData.traditionalOnly)

    private static func scalars(_ text: String) -> Set<Unicode.Scalar> {
        Set(text.unicodeScalars.filter { !$0.properties.isWhitespace })
    }

    /// 有沒有只在簡體出現的字（邀请码 的 请 码）。
    public static func hasSimplifiedOnly(_ term: String) -> Bool {
        term.unicodeScalars.contains(where: simplifiedOnly.contains)
    }

    /// 有沒有只在繁體出現的字（周杰倫 的 倫、頭前庄站 的 頭）。
    public static func hasTraditionalOnly(_ term: String) -> Bool {
        term.unicodeScalars.contains(where: traditionalOnly.contains)
    }

    /// 簡體寫的詞：有簡體專用字、而且沒有繁體專用字（邀请码、周杰伦）。
    /// 繁體（周杰倫、干擾）、兩邊通用（奇岩站、于美人、后里）、繁簡混寫的都不算——那些照使用者打的送。
    public static func isSimplified(_ term: String) -> Bool {
        hasSimplifiedOnly(term) && !hasTraditionalOnly(term)
    }

    /// 個人字典的詞：traditional 只轉簡體寫的詞（`toTraditional` 要按詞轉，Mac／Android 傳 OpenCC TraditionalFixer）；
    /// simplified 只轉有繁體專用字的詞。
    public static func personalHint(_ term: String, script: HintScript,
                                    toTraditional: (String) -> String, toSimplified: (String) -> String) -> String {
        switch script {
        case .asIs: return term
        case .traditional: return isSimplified(term) ? toTraditional(term) : term
        case .simplified: return hasTraditionalOnly(term) ? toSimplified(term) : term
        }
    }

    /// 內建包與 catalog 種子（台灣繁體精選）：繁體不動；簡體輸出時有繁體專用字的才轉簡體。
    public static func curatedHint(_ term: String, script: HintScript, toSimplified: (String) -> String) -> String {
        script == .simplified && hasTraditionalOnly(term) ? toSimplified(term) : term
    }

    /// ICU 簡轉繁（整串）。只拿來轉 `isSimplified` 的詞；Mac App 用 OpenCC（按詞）蓋掉這個預設。
    public static func icuTraditional(_ term: String) -> String {
        term.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? term
    }

    /// ICU 繁轉簡（同 Mac 雲端辨識簡體輸出、Android 簡體變體的轉法）。
    public static func icuSimplified(_ term: String) -> String {
        term.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? term
    }
}
