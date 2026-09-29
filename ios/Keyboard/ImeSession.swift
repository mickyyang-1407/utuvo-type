import Foundation
import UTUVOTypeCore

/// 鍵盤用的中文輸入工作階段：注音（小麥注音詞庫）、簡體拼音（rime-pinyin-simp）、繁體拼音（小麥注音轉拼音）。
/// 兩個引擎 API 形狀相同。詞庫第一次用到才打開（mmap，不整包讀進記憶體）；打不開就退回「原樣送出」，至少不會打不出字。
///
/// 取消（onUndo）時的快照：注音存引擎自己的 `ZhuyinEngine.State`（0.2.5 起緩衝區有「沒收尾的音節」，
/// 重打一次按鍵不一定能還原成同一個切分），拼音／fallback 存 composing，restore 用同樣的字元序列重打回去。
/// 不在 wrapper 多記 mutable key history——那樣會跟 engine 的解析後 buffer 脫節
/// （zhuyin backspace 一次刪整個音節、select 只吃前綴、space 在拼音無效等都是源頭不一致的原因）。
///
/// 選字／送出之後的聯想詞（你好 → 嗎）：注音與繁體拼音用小麥注音的聯想詞表，簡體拼音用 rime 推導的同規則表。
@MainActor
final class ImeSession {
    /// 候選列約 168 pt 寬、可以左右捲。0.2.5 起注音邊打邊出候選（簡拼 ㄋㄏ 一次對到幾百個詞），
    /// 八格不夠放到常用詞（你好 在 ㄋㄏ 排第十幾）；二十格仍只解碼看得到附近的候選。
    static let keyboardCandidateLimit = 20

    enum Kind { case zhuyin, pinyin, pinyinHant }
    let kind: Kind

    private lazy var zhuyin: ZhuyinEngine? = kind == .zhuyin
        ? Self.dataURL("zhuyin").flatMap(ZhuyinEngine.init(dataURL:)) : nil
    private lazy var pinyin: PinyinEngine? = kind == .zhuyin
        ? nil : Self.dataURL(kind == .pinyin ? "pinyin" : "pinyin-hant").flatMap(PinyinEngine.init(dataURL:))
    private lazy var associations: PhraseAssociations? = Self.dataURL(kind == .pinyin ? "assoc-hans" : "assoc-hant")
        .flatMap(PhraseAssociations.init(url:))
    private var fallback: [Character] = []
    private var shownZhuyin: [ZhuyinCandidate] = []
    private var shownPinyin: [PinyinCandidate] = []

    init(kind: Kind) { self.kind = kind }

    private static func dataURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "dat")
    }

    var isEmpty: Bool { zhuyin?.isEmpty ?? pinyin?.isEmpty ?? fallback.isEmpty }
    /// 還有打到一半、沒標聲調的音（注音用；拼音沒有聲調，空白一律送出最佳轉換）。
    var hasComposing: Bool {
        if let zhuyin { return !zhuyin.composing.isEmpty }
        if pinyin != nil { return false }
        return !fallback.isEmpty
    }
    var preedit: String { zhuyin?.preedit ?? pinyin?.preedit ?? String(fallback) }
    /// 整串送出時的文字（候選列第 0 格）。注音簡拼時輸入框顯示打的符號（preedit），送出的是轉換結果。
    var conversion: String { zhuyin?.conversion ?? pinyin?.preedit ?? String(fallback) }

    /// 剛送出 `text` 之後可以接的聯想詞（只回要接著插入的部分）。
    func associations(after text: String) -> [String] {
        associations?.continuations(after: text, limit: Self.keyboardCandidateLimit) ?? []
    }

    /// 句首候選；候選列第 0 格之後照這個順序。
    var candidates: [String] {
        if let zhuyin {
            shownZhuyin = zhuyin.isEmpty ? [] : zhuyin.candidates(limit: Self.keyboardCandidateLimit)
            return shownZhuyin.map(\.text)
        }
        if let pinyin {
            shownPinyin = pinyin.isEmpty ? [] : pinyin.candidates(limit: Self.keyboardCandidateLimit)
            return shownPinyin.map(\.text)
        }
        return []
    }

    /// 引擎狀態的快照。注音存引擎的 State；拼音／fallback 只存 composing，restore 直接重打
    /// composing／chars（這兩個本來就是使用者原始輸入）。
    struct Snapshot: Equatable {
        let zhuyin: ZhuyinEngine.State?
        let composing: String
        let fallback: [Character]

        init(zhuyin: ZhuyinEngine.State? = nil, composing: String = "", fallback: [Character] = []) {
            self.zhuyin = zhuyin
            self.composing = composing
            self.fallback = fallback
        }
    }

    func snapshot() -> Snapshot {
        if let zhuyin {
            return Snapshot(zhuyin: zhuyin.state)
        }
        if pinyin != nil {
            return Snapshot(composing: pinyin?.composing ?? "")
        }
        return Snapshot(fallback: fallback)
    }

    /// 還原到 snapshot 的狀態。先 reset 兩個引擎與 wrapper 內部累積，注音直接放回 State，拼音 replay composing。
    /// 引擎對相同輸入具確定性，所以 preedit／候選會自然跟原來一致。
    func restore(_ s: Snapshot) {
        zhuyin?.reset()
        pinyin?.reset()
        fallback.removeAll()
        shownZhuyin.removeAll()
        shownPinyin.removeAll()

        if let zhuyin {
            if let state = s.zhuyin { zhuyin.restore(state) }
        } else if let pinyin {
            for ch in s.composing { _ = pinyin.type(ch) }
        } else {
            fallback.append(contentsOf: s.fallback)
        }
    }

    @discardableResult
    func type(_ key: Character) -> Bool {
        if let zhuyin { return zhuyin.type(key) }
        if let pinyin { return pinyin.type(key) }
        fallback.append(key)
        return true
    }

    /// 注音專屬：空白＝以一聲收尾正在組的音節。回 false（簡拼、沒打聲調、只有聲母）時呼叫端改成整串送出。
    /// 拼音走 commitAll，不走這條。
    @discardableResult
    func space() -> Bool { zhuyin?.space() ?? false }

    @discardableResult
    func backspace() -> Bool {
        if let zhuyin { return zhuyin.backspace() }
        if let pinyin { return pinyin.backspace() }
        guard !fallback.isEmpty else { return false }
        fallback.removeLast()
        return true
    }

    func select(at index: Int) -> String {
        if let zhuyin, shownZhuyin.indices.contains(index) { return zhuyin.select(shownZhuyin[index]) }
        if let pinyin, shownPinyin.indices.contains(index) { return pinyin.select(shownPinyin[index]) }
        return commitAll()
    }

    func commitAll() -> String {
        if let zhuyin { return zhuyin.commitAll() }
        if let pinyin { return pinyin.commitAll() }
        defer { fallback.removeAll() }
        return String(fallback)
    }

    /// 把引擎與 wrapper 的暫存全部清掉（已組好的音節、組到一半的字符、cached 候選）。
    /// 呼叫端負責同步處理宿主端的 marked text（呼叫 clearOwnedMarkedText 之前 reset，
    /// 否則 syncOwnedMarkedText 還會把舊 preedit 寫回去）。
    func reset() {
        zhuyin?.reset()
        pinyin?.reset()
        fallback.removeAll()
        shownZhuyin.removeAll()
        shownPinyin.removeAll()
    }
}
