import Foundation

/// 修正新辨識引擎（SpeechTranscriber）的繁中：它的繁體是逐字硬轉的（2026-09-19 實測 25 句 21 句錯：
/// 回家→迴家、頭髮→頭發、干擾→幹擾、颱風→臺風、系統→係統、周圍→週圍、皇后→皇後、游泳→遊泳…）。
///
/// 做法＝OpenCC（Apache-2.0）同一條路：先轉回簡體（t2s，多對一、不會錯），再**按詞**轉台灣繁體（s2tw）。
/// 同一組 25 句轉完只剩辨識本身聽錯的；48 段正確原文轉一圈只剩台灣正式寫法差異，
/// 那幾個改回日常寫法（臺→台、瞭解→了解、儘量→盡量、絃→弦）。字典由 scripts/build-opencc.py 產生。
final class TraditionalFixer: @unchecked Sendable {
    static let shared = TraditionalFixer()

    /// 字典資料夾（測試／Mac 驗證程式可以指到別處）。
    nonisolated(unsafe) static var directory: URL? = Bundle.main.url(forResource: "OpenCC", withExtension: nil)
        ?? Bundle.main.resourceURL

    private struct Dict {
        let map: [String: String]
        let maxLength: Int
    }

    private let lock = NSLock()
    private var loaded: (t2s: [[Dict]], s2tw: [[Dict]])?

    /// 日常寫法（OpenCC s2tw 給的是台灣正式用字）。
    static let everyday: [(String, String)] = [("瞭解", "了解"), ("儘量", "盡量"), ("臺", "台"), ("絃", "弦")]

    /// 轉換；字典讀不到就原樣回傳。
    func fix(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }), let dicts = load() else { return text }
        var out = convert(convert(text, dicts.t2s), dicts.s2tw)
        for (formal, daily) in Self.everyday { out = out.replacingOccurrences(of: formal, with: daily) }
        return out
    }

    /// 片段逐一修（停頓補標點要用片段）：整串一起轉（才有上下文），字數沒變就照原本長度切回去；變了就原樣。
    func fix(tokens: [TimedToken], extra: (String) -> String = { $0 }) -> [TimedToken] {
        let joined = tokens.map(\.text).joined()
        let fixed = Array(extra(fix(joined)))
        guard fixed.count == joined.count else { return tokens }
        var i = 0
        return tokens.map { t in
            let n = t.text.count
            defer { i += n }
            return TimedToken(text: String(fixed[i..<(i + n)]), start: t.start, duration: t.duration)
        }
    }

    // MARK: - OpenCC 最長匹配

    private func convert(_ text: String, _ chain: [[Dict]]) -> String {
        var current = text
        for group in chain {
            let chars = Array(current)
            let maxLength = group.map(\.maxLength).max() ?? 1
            var out = ""
            var i = 0
            while i < chars.count {
                var matched = false
                var length = min(maxLength, chars.count - i)
                while length >= 1 && !matched {
                    let key = String(chars[i..<(i + length)])
                    for dict in group {
                        if let value = dict.map[key] {
                            out += value
                            i += length
                            matched = true
                            break
                        }
                    }
                    length -= 1
                }
                if !matched { out.append(chars[i]); i += 1 }
            }
            current = out
        }
        return current
    }

    private func load() -> (t2s: [[Dict]], s2tw: [[Dict]])? {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard let dir = Self.directory else { return nil }
        func read(_ name: String) -> Dict? {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name + ".txt"), encoding: .utf8) else { return nil }
            var map: [String: String] = [:]
            var maxLength = 1
            for line in text.split(separator: "\n") {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let key = String(line[..<tab])
                map[key] = String(line[line.index(after: tab)...])
                maxLength = max(maxLength, key.count)
            }
            return map.isEmpty ? nil : Dict(map: map, maxLength: maxLength)
        }
        guard let tsp = read("TSPhrases"), let tsc = read("TSCharacters"), let stp = read("STPhrases"),
              let stc = read("STCharacters"), let twv = read("TWVariants") else { return nil }
        let result = (t2s: [[tsp, tsc]], s2tw: [[stp, stc], [twv]])
        loaded = result
        return result
    }
}
