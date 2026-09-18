import Foundation

/// 選字候選：`readingCount` 是它從緩衝區開頭吃掉幾個音節。
public struct ZhuyinCandidate: Equatable, Sendable {
    public let text: String
    public let readingCount: Int

    public init(text: String, readingCount: Int) {
        self.text = text
        self.readingCount = readingCount
    }
}

/// 注音輸入引擎（純 Foundation，不碰 UIKit）。
///
/// 緩衝區＝已完成的音節 `readings`＋正在組的音節 `composing`。
/// 整句轉換用 Viterbi（DAG 最長路徑）走「讀音網格」：每個起點最多延伸 8 個音節，
/// 節點分數取該讀音在詞庫中的最高分，路徑分數為節點分數相加（log 機率相加＝機率相乘）。
/// 這個作法的概念參考小麥注音的 Gramambular（MIT），程式碼為本專案自行撰寫。
///
/// 執行緒：所有狀態都由內部鎖保護，可以跨 actor 傳遞；實務上由鍵盤主執行緒單獨使用即可。
public final class ZhuyinEngine: @unchecked Sendable {
    /// 候選數上限。
    public static let candidateLimit = 60
    /// 多字詞候選最多佔幾格，保證單字候選一定排得進來。
    public static let phraseCandidateLimit = 30

    public let lexicon: ZhuyinLexicon

    private let lock = NSLock()
    private var _readings: [String] = []
    private var _ids: [UInt16] = []
    private var composer = ZhuyinComposer()
    private var cachedWalk: (ids: [UInt16], text: String)?

    public init?(dataURL: URL) {
        guard let lexicon = ZhuyinLexicon(url: dataURL) else { return nil }
        self.lexicon = lexicon
    }

    /// 共用同一份詞庫（例：背景載入詞庫後交給主執行緒建引擎）。
    public init(lexicon: ZhuyinLexicon) {
        self.lexicon = lexicon
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 狀態

    /// 已完成的音節（例：["ㄋㄧˇ", "ㄏㄠˇ"]）。
    public var readings: [String] { locked { _readings } }

    /// 正在組的音節符號（尚未收尾）。
    public var composing: String { locked { composer.composing } }

    public var isEmpty: Bool { locked { _readings.isEmpty && composer.isEmpty } }

    // MARK: - 輸入

    /// 打一個注音符號或聲調記號。
    /// - 聲母／介音／韻母：放進對應槽（同槽取代）。
    /// - 聲調（ˊˇˋ˙，或「ˉ」＝一聲）：把正在組的音節收尾；組出的音節不在詞庫裡（例「ㄅˋ」）就拒絕、保留原狀。
    /// - 回傳 false＝這個符號沒有被接受（非注音符號、空的時候打聲調、不合法音節）。
    @discardableResult
    public func type(_ symbol: Character) -> Bool {
        locked {
            guard let slot = ZhuyinComposer.slot(of: symbol) else { return false }
            if slot == .tone {
                return completeSyllable(tone: symbol)
            }
            return composer.insert(symbol)
        }
    }

    /// 空白鍵：把正在組的音節以一聲收尾。沒有正在組的音節時什麼都不做、回 false（交給呼叫端決定：選字或送空白）。
    /// 一聲音節不在詞庫裡時也回 false 並保留原狀。
    @discardableResult
    public func space() -> Bool {
        locked { completeSyllable(tone: nil) }
    }

    private func completeSyllable(tone: Character?) -> Bool {
        guard let s = composer.syllable(tone: tone), let id = lexicon.syllableID(s) else { return false }
        _readings.append(s)
        _ids.append(id)
        composer.clear()
        return true
    }

    /// 倒退：先刪正在組的最後一個符號；沒有就刪最後一個完成的音節。整個緩衝區是空的回 false。
    @discardableResult
    public func backspace() -> Bool {
        locked {
            if composer.backspace() { return true }
            guard !_readings.isEmpty else { return false }
            _readings.removeLast()
            _ids.removeLast()
            return true
        }
    }

    public func reset() {
        locked { resetLocked() }
    }

    private func resetLocked() {
        _readings.removeAll()
        _ids.removeAll()
        composer.clear()
    }

    // MARK: - 轉換

    /// 整個緩衝區的最佳轉換結果＋尾端尚未收尾的注音符號。
    public var preedit: String {
        locked { walk(_ids) + composer.composing }
    }

    /// 緩衝區開頭的候選：先列最長的詞（覆蓋 readings[0..<k]，k 由大到小），同長度內分數高的在前；含單字。
    /// 多字詞最多 `phraseCandidateLimit` 個，總數上限 `candidateLimit`。
    public var candidates: [ZhuyinCandidate] {
        locked {
            guard !_ids.isEmpty else { return [] }
            var phrases: [ZhuyinCandidate] = []
            var singles: [ZhuyinCandidate] = []
            let maxLen = min(ZhuyinLexicon.maximumPhraseLength, _ids.count)
            for k in stride(from: maxLen, through: 1, by: -1) {
                let slice = _ids[0..<k]
                if k > 1 {
                    guard phrases.count < Self.phraseCandidateLimit else { continue }
                    for e in lexicon.lookup(ids: slice, limit: Self.phraseCandidateLimit - phrases.count) {
                        phrases.append(ZhuyinCandidate(text: e.text, readingCount: k))
                    }
                } else {
                    for e in lexicon.lookup(ids: slice, limit: Self.candidateLimit) {
                        singles.append(ZhuyinCandidate(text: e.text, readingCount: 1))
                    }
                }
            }
            return Array((phrases + singles).prefix(Self.candidateLimit))
        }
    }

    /// 選一個候選：從緩衝區開頭移除它涵蓋的音節，回傳要送出的文字。
    /// `readingCount` 超過目前音節數（候選已過期）時不動緩衝區、回空字串。
    public func select(_ candidate: ZhuyinCandidate) -> String {
        locked {
            guard candidate.readingCount > 0, candidate.readingCount <= _readings.count else { return "" }
            _readings.removeFirst(candidate.readingCount)
            _ids.removeFirst(candidate.readingCount)
            return candidate.text
        }
    }

    /// 整句送出並清空。尾端還在組的音節：若以一聲收尾是合法音節就一起轉換，
    /// 否則原樣附上注音符號（不丟使用者打的字）。
    public func commitAll() -> String {
        locked {
            var ids = _ids
            var tail = ""
            if let s = composer.syllable(tone: nil) {
                if let id = lexicon.syllableID(s) { ids.append(id) } else { tail = composer.composing }
            }
            let text = walk(ids) + tail
            resetLocked()
            return text
        }
    }

    // MARK: - Viterbi

    /// 在讀音網格上找分數最高的切分，回傳串起來的文字。呼叫端須持有鎖。
    private func walk(_ ids: [UInt16]) -> String {
        if ids.isEmpty { return "" }
        if let c = cachedWalk, c.ids == ids { return c.text }
        let n = ids.count
        // best[i]：走到位置 i 的最高累積分數；back[i]：最後一段的起點與文字
        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [(from: Int, text: String)](repeating: (0, ""), count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i] > -.infinity {
            let maxLen = min(ZhuyinLexicon.maximumPhraseLength, n - i)
            var hit = false
            for len in 1...maxLen {
                let slice = ids[i..<(i + len)]
                if len > 1 && !lexicon.hasKey(withPrefix: slice) { break }
                guard let top = lexicon.best(ids: slice) else { continue }
                hit = hit || len == 1
                let score = best[i] + top.score
                if score > best[i + len] {
                    best[i + len] = score
                    back[i + len] = (i, top.text)
                }
            }
            // 音節本身沒有單字（理論上不會發生：收尾時已驗證音節存在）→ 以注音原樣墊過去
            if !hit && best[i] - 99 > best[i + 1] {
                best[i + 1] = best[i] - 99
                back[i + 1] = (i, lexicon.syllable(ids[i]))
            }
        }
        var parts: [String] = []
        var pos = n
        while pos > 0 {
            parts.append(back[pos].text)
            pos = back[pos].from
        }
        let text = parts.reversed().joined()
        cachedWalk = (ids, text)
        return text
    }
}
