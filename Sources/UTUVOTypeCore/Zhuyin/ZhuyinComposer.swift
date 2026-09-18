import Foundation

/// 注音單一音節的組字器（標準大千排列的符號集）。
///
/// 一個音節＝聲母（ㄅ…ㄙ，可省）＋介音（ㄧㄨㄩ，可省）＋韻母（ㄚ…ㄦ，可省）＋聲調。
/// 行為：
/// - 同一個槽再打一次＝取代該槽（例：打了 ㄅ 再打 ㄆ → ㄆ），順序無關（先打韻母再補聲母也行）。
/// - 聲調鍵（ˊˇˋ˙）或空白鍵（一聲，不標記）把音節收尾；收尾由 `ZhuyinEngine` 驗證過詞庫後才生效。
/// - 本型別只管槽位，不查詞庫。
public struct ZhuyinComposer: Equatable, Sendable {
    public enum Slot: Sendable, Equatable {
        case consonant, medial, rime, tone
    }

    public static let consonants: Set<Character> = Set("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ")
    public static let medials: Set<Character> = Set("ㄧㄨㄩ")
    public static let rimes: Set<Character> = Set("ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ")
    /// 二、三、四、輕聲。一聲不標記；「ˉ」也當一聲收尾（有些鍵盤會送出這個符號）。
    public static let toneMarks: Set<Character> = Set("ˊˇˋ˙")
    public static let firstToneMark: Character = "ˉ"

    public private(set) var consonant: Character?
    public private(set) var medial: Character?
    public private(set) var rime: Character?

    public init() {}

    /// 這個符號屬於哪個槽；不是注音符號回 nil。
    public static func slot(of symbol: Character) -> Slot? {
        if consonants.contains(symbol) { return .consonant }
        if medials.contains(symbol) { return .medial }
        if rimes.contains(symbol) { return .rime }
        if toneMarks.contains(symbol) || symbol == firstToneMark { return .tone }
        return nil
    }

    public var isEmpty: Bool { consonant == nil && medial == nil && rime == nil }

    /// 目前已打的符號（聲母＋介音＋韻母，依標準順序）。
    public var composing: String {
        var s = ""
        if let c = consonant { s.append(c) }
        if let m = medial { s.append(m) }
        if let r = rime { s.append(r) }
        return s
    }

    /// 放入聲母／介音／韻母；同槽已有就取代。聲調與非注音符號回 false（聲調由 `syllable(tone:)` 處理）。
    @discardableResult
    public mutating func insert(_ symbol: Character) -> Bool {
        switch Self.slot(of: symbol) {
        case .consonant: consonant = symbol
        case .medial: medial = symbol
        case .rime: rime = symbol
        case .tone, nil: return false
        }
        return true
    }

    /// 以指定聲調組出完整音節字串（一聲傳 nil 或「ˉ」）。空的回 nil。不會清空槽位。
    public func syllable(tone: Character?) -> String? {
        guard !isEmpty else { return nil }
        var s = composing
        if let t = tone, t != Self.firstToneMark {
            guard Self.toneMarks.contains(t) else { return nil }
            s.append(t)
        }
        return s
    }

    /// 刪最後一個符號（韻母 → 介音 → 聲母）。空的回 false。
    @discardableResult
    public mutating func backspace() -> Bool {
        if rime != nil { rime = nil; return true }
        if medial != nil { medial = nil; return true }
        if consonant != nil { consonant = nil; return true }
        return false
    }

    public mutating func clear() {
        consonant = nil
        medial = nil
        rime = nil
    }
}
