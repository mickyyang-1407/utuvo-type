import Foundation
import UTUVOTypeCore

/// 鍵盤用的注音工作階段：包住 UTUVOTypeCore 的 ZhuyinEngine（小麥注音詞庫、mmap，不整包讀進記憶體）。
/// 詞庫第一次切到注音時才打開；打不開（檔案壞了）就退回「注音符號原樣送出」，至少不會打不出字。
@MainActor
final class ZhuyinSession {
    private lazy var engine: ZhuyinEngine? = Bundle.main.url(forResource: "zhuyin", withExtension: "dat").flatMap(ZhuyinEngine.init(dataURL:))
    private var fallback: [Character] = []
    private var shownCandidates: [ZhuyinCandidate] = []

    var isEmpty: Bool { engine?.isEmpty ?? fallback.isEmpty }
    /// 還有打到一半、沒標聲調的音。
    var hasComposing: Bool { engine.map { !$0.composing.isEmpty } ?? !fallback.isEmpty }
    var preedit: String { engine?.preedit ?? String(fallback) }

    /// 句首候選（去掉跟整串轉換一樣的那一個，候選列第一格已經是它）。
    var candidates: [String] {
        guard let engine, !engine.isEmpty else { shownCandidates = []; return [] }
        shownCandidates = engine.candidates
        return shownCandidates.map(\.text)
    }

    func type(_ symbol: Character) {
        if let engine { engine.type(symbol) } else { fallback.append(symbol) }
    }

    func space() { engine?.space() }

    func backspace() -> Bool {
        if let engine { return engine.backspace() }
        guard !fallback.isEmpty else { return false }
        fallback.removeLast()
        return true
    }

    /// 候選列的第 index 個（跟 `candidates` 同一份）。
    func select(at index: Int) -> String {
        guard let engine, shownCandidates.indices.contains(index) else { return commitAll() }
        return engine.select(shownCandidates[index])
    }

    func commitAll() -> String {
        if let engine { return engine.commitAll() }
        defer { fallback.removeAll() }
        return String(fallback)
    }
}
