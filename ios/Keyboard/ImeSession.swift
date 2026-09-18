import Foundation
import UTUVOTypeCore

/// 鍵盤用的中文輸入工作階段：注音（小麥注音詞庫）、簡體拼音（rime-pinyin-simp）、繁體拼音（小麥注音轉拼音）。
/// 兩個引擎 API 形狀相同。詞庫第一次用到才打開（mmap，不整包讀進記憶體）；打不開就退回「原樣送出」，至少不會打不出字。
@MainActor
final class ImeSession {
    enum Kind { case zhuyin, pinyin, pinyinHant }
    let kind: Kind

    private lazy var zhuyin: ZhuyinEngine? = kind == .zhuyin
        ? Self.dataURL("zhuyin").flatMap(ZhuyinEngine.init(dataURL:)) : nil
    private lazy var pinyin: PinyinEngine? = kind == .zhuyin
        ? nil : Self.dataURL(kind == .pinyin ? "pinyin" : "pinyin-hant").flatMap(PinyinEngine.init(dataURL:))
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

    /// 句首候選；候選列第 0 格之後照這個順序。
    var candidates: [String] {
        if let zhuyin {
            shownZhuyin = zhuyin.isEmpty ? [] : zhuyin.candidates
            return shownZhuyin.map(\.text)
        }
        if let pinyin {
            shownPinyin = pinyin.isEmpty ? [] : pinyin.candidates
            return shownPinyin.map(\.text)
        }
        return []
    }

    func type(_ key: Character) {
        if let zhuyin { zhuyin.type(key) } else if let pinyin { pinyin.type(key) } else { fallback.append(key) }
    }

    func space() { zhuyin?.space() }

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
}
