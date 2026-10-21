import Foundation

/// 單字讀音（不計聲調的拼音）與「這兩個字算不算同音錯字」——全平台的單一正本。
///
/// iOS 的 `HomophoneCorrector`（ios/Shared）與 `CleanupFidelity`（這個 package）都要判定同音，
/// 但 `HomophoneCorrector` 在 app target、這個檔在 UTUVOTypeCore target，方向相反引用不了；
/// 所以正本放 package，`HomophoneCorrector` 反過來呼叫這裡，兩邊不再各寫一份讀音。
public enum MandarinReading {
    public static func pinyin(_ character: Character) -> String {
        let text = String(character)
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        return (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
    }

    public static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }
    }

    /// 人稱代名詞同音（他／她／它…）：換了＝替使用者猜性別或禮貌程度，一律不換。
    public static let pronouns: Set<Character> = ["他", "她", "它", "牠", "祂", "你", "妳", "您"]

    /// 語意關鍵字：讀音再像也不能算錯字修正——否定、數字（含數量級）、人稱代名詞、
    /// 反義同音字（否定詞互換＝語意翻轉；億→意＝數值差一個數量級；買→賣＝原意相反）。
    public static let neverSubstituted: Set<Character> = [
        "不", "沒", "没", "別", "别", "未", "無", "无", "勿",
        "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
        "百", "千", "萬", "万", "億", "亿", "兆", "拾", "佰", "仟", "兩", "两",
        "我", "你", "妳", "您", "他", "她", "它", "牠", "祂", "咱",
        "買", "买", "賣", "卖"
    ]

    /// 刻意**不**擋的取捨：權利→權力、期中→期終這類兩字詞的同音混淆，正是語音辨識
    /// 最常見的錯字，判斷要交給模型。把它列進來會連真正的修正一起擋掉，所以擋在
    /// 「同音替換預算」那一層（見 `CleanupFidelity`），不擋在字級清單這一層。

    /// 兩個不同的漢字讀音相同（不計聲調）。讀音取不到就回 false，不猜。
    public static func isHomophone(_ a: Character, _ b: Character) -> Bool {
        guard a != b, isCJK(a), isCJK(b) else { return false }
        let reading = pinyin(a)
        return !reading.isEmpty && reading == pinyin(b)
    }

    /// 忠實度把關用的版本：同音**而且**不在語意關鍵字清單裡，才算「語音辨識錯字修正」。
    public static func isHomophoneSubstitution(_ source: Character, _ output: Character) -> Bool {
        isHomophoneSubstitution(source, output, pinyin(source), pinyin(output))
    }

    /// 判定本體；讀音由呼叫端帶進來，讓逐字比對可以快取、不要每個位元重轉一次拼音。
    static func isHomophoneSubstitution(
        _ source: Character,
        _ output: Character,
        _ sourceReading: String,
        _ outputReading: String
    ) -> Bool {
        source != output
            && isCJK(source) && isCJK(output)
            && !neverSubstituted.contains(source) && !neverSubstituted.contains(output)
            && !sourceReading.isEmpty
            && sourceReading == outputReading
    }
}