import Foundation

/// 貼上之後的「修改追蹤」一回合（2026-10-22 delivery-learning-3，對齊 Typeless 的 switch_input_box／clear_input_box／
/// press_enter／track_timeout 四種結算時機）。純狀態機：不讀畫面、不看時鐘，時間由呼叫端帶進來。
///
/// 以前 Mac 只在 20 秒後（或下一次聽寫開始時）讀一次欄位。聊天 App（訊息、Slack、LINE）裡使用者改完名字幾秒內就按 Enter 送出，
/// 20 秒後欄位是空的，什麼都學不到。現在：
/// - 呼叫端每次按鍵後（防抖 ≥150 ms）讀一次欄位交給 `snapshot`；這裡記住「最後一份還找得到剛貼那段」的內容。
/// - 結算時機：按 Return、欄位被清空（或剛貼那段整個不見了）、焦點換到別處、閒置 15 秒（每次按鍵重算）、最長 60 秒、
///   下一次聽寫開始。
/// - 結算用的是最後那份快照，但**快照之後又有按鍵**（例如打完最後一個字立刻按 Enter，防抖還沒讀到）就放棄不學：
///   那份快照可能是改到一半的樣子，學到「Utuvo→UTUV」比什麼都不學更糟。
public struct EditSession: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// 拿這兩段交給 `EditTracker.learnableCorrections(inserted:current:)`。
        case evaluate(original: String, edited: String)
        /// 結束、不學（沒改、看不到、快照不可靠、密碼欄位）。
        case abandon
    }

    /// 最後一次按鍵後閒置多久就結算。
    public static let idleTimeout: Double = 15
    /// 一回合最長多久（之後的修改不算）。
    public static let hardCap: Double = 60
    /// 按鍵後至少等這麼久才讀欄位（呼叫端用）。
    public static let readDebounce: Double = 0.15
    /// 上一次讀欄位超過這麼久，就不再每次按鍵都讀（慢的 App 不能被拖到打字卡頓；呼叫端用）。
    public static let slowReadLimit: Double = 0.05

    public let inserted: String
    public let startedAt: Double
    /// 貼上後的游標位置（UTF-16），給 `locate` 挑候選。
    public var expectedEnd: Int?
    public private(set) var lastSlice: String?
    public private(set) var lastSliceAt: Double?
    public private(set) var lastKeyAt: Double?
    public private(set) var outcome: Outcome?

    public init(inserted: String, at: Double) {
        self.inserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = at
    }

    public var isFinished: Bool { outcome != nil }

    /// 下一次該檢查「閒置／最長時間」的時間點。
    public var deadline: Double {
        min(max(startedAt, lastKeyAt ?? startedAt) + Self.idleTimeout, startedAt + Self.hardCap)
    }

    /// 欄位目前的全文（`nil`＝讀不到，忽略）。找得到剛貼那段就記下來；欄位清空或那段不見了就結算。
    @discardableResult
    public mutating func snapshot(_ value: String?, at: Double) -> Outcome? {
        guard !isFinished, let value else { return nil }
        if value.contains(inserted) {
            record(inserted, at: at)
            return nil
        }
        if let slice = Self.locate(inserted, in: value, expectedEnd: expectedEnd) ?? Self.wholeField(value, inserted: inserted) {
            record(slice, at: at)
            return nil
        }
        return finish()   // 清空（送出後）或剛貼那段整個不見了：用上一份快照
    }

    /// 錨點找不到時（改的正好是開頭或結尾那幾個字：「Utuvo Type 很好」→「UTUVO Type 很好」），
    /// 聊天欄位裡通常只有剛貼的那一段：整個欄位跟剛貼的文字長度相近、而且改動量在 `EditTracker` 會學的範圍內，就用整個欄位。
    static func wholeField(_ value: String, inserted: String) -> String? {
        let field = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty, !inserted.isEmpty else { return nil }
        let ratio = Double(field.count) / Double(inserted.count)
        guard ratio >= 0.6, ratio <= 1.5 else { return nil }
        let changed = EditTracker.replacementChangedCount(inserted: inserted, current: field)
        guard Double(changed) / Double(max(inserted.count, EditTracker.minRatioDenominator)) <= EditTracker.maxChangedRatio else { return nil }
        return field
    }

    /// 全域鍵盤監看看到的按鍵。Return＝送出／換行：用到目前為止的快照結算（這顆 Return 本身不算「快照之後的按鍵」）。
    @discardableResult
    public mutating func keyDown(isReturn: Bool, at: Double) -> Outcome? {
        guard !isFinished else { return nil }
        if isReturn { return finish() }
        lastKeyAt = max(lastKeyAt ?? at, at)
        return nil
    }

    /// 焦點換到別的欄位或別的 App。
    @discardableResult
    public mutating func focusChanged() -> Outcome? {
        guard !isFinished else { return nil }
        return finish()
    }

    /// 閒置 15 秒或滿 60 秒就結算（呼叫端先讀一次欄位交給 `snapshot`，再呼叫這裡）。
    @discardableResult
    public mutating func tick(at: Double) -> Outcome? {
        guard !isFinished, at >= deadline else { return nil }
        return finish()
    }

    /// 下一次聽寫開始、或呼叫端要收掉這一回合。
    @discardableResult
    public mutating func end() -> Outcome {
        if let outcome { return outcome }
        return finish()
    }

    /// 密碼欄位：一個字都不比對。
    @discardableResult
    public mutating func secureField() -> Outcome {
        if let outcome { return outcome }
        outcome = .abandon
        return .abandon
    }

    private mutating func record(_ slice: String, at: Double) {
        lastSlice = slice
        lastSliceAt = at
    }

    private mutating func finish() -> Outcome {
        if let outcome { return outcome }
        let result: Outcome
        if let slice = lastSlice, let sliceAt = lastSliceAt, slice != inserted,
           lastKeyAt.map({ sliceAt > $0 }) ?? true,
           // 輸入法組字到一半的快照（中文被換成 yuan／ㄩㄢˊ）不可靠，整回合不學（2026-10-22 修補）。
           !EditTracker.looksLikeComposition(inserted: inserted, current: slice) {
            result = .evaluate(original: inserted, edited: slice)
        } else {
            result = .abandon
        }
        outcome = result
        return result
    }

    /// 用剛才貼的文字開頭、結尾各幾個字當錨點，在欄位裡找出所有候選段落。
    /// 有貼上當下的游標位置：挑結尾最靠近它的（使用者後來在前面改字也只偏幾個字）；
    /// 沒有游標位置：只有唯一候選才用。分不出來就放棄不猜（luna-review r1／r2）。
    /// （原本在 App 的 `EditWatcher.locate`，搬進 core 讓狀態機用同一份；App 那邊改成轉呼叫這裡。）
    public static func locate(_ inserted: String, in value: String, expectedEnd: Int? = nil) -> String? {
        let anchor = min(4, max(1, inserted.count / 4))
        let head = String(inserted.prefix(anchor)), tail = String(inserted.suffix(anchor))
        var candidates: [(slice: String, end: Int)] = []
        var searchStart = value.startIndex
        while candidates.count < 20, let headRange = value.range(of: head, range: searchStart..<value.endIndex) {
            let rest = value[headRange.lowerBound...]
            var tailSearch = rest.startIndex
            while let tailRange = rest.range(of: tail, range: tailSearch..<rest.endIndex) {
                let slice = String(value[headRange.lowerBound..<tailRange.upperBound])
                let ratio = Double(slice.count) / Double(max(1, inserted.count))
                if ratio > 1.5 { break }
                if ratio >= 0.6 {
                    let end = value.utf16.distance(from: value.utf16.startIndex, to: tailRange.upperBound)
                    candidates.append((slice, end))
                    break
                }
                tailSearch = tailRange.upperBound
            }
            searchStart = value.index(after: headRange.lowerBound)
        }
        guard !candidates.isEmpty else { return nil }
        guard let expectedEnd else { return candidates.count == 1 ? candidates[0].slice : nil }
        let tolerance = max(8, inserted.utf16.count / 2)
        let near = candidates.map { ($0.slice, abs($0.end - expectedEnd)) }
            .filter { $0.1 <= tolerance }
            .sorted { $0.1 < $1.1 }
        guard let best = near.first else { return nil }
        if near.count > 1, near[1].1 == best.1, near[1].0 != best.0 { return nil }
        return best.0
    }
}
