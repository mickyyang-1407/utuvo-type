import Foundation
import XCTest
@testable import UTUVOTypeCore

/// Android（Kotlin）移植的「標準答案」：把一批輸入丟進 Swift 核心，輸出寫成 JSON，
/// Kotlin 版的測試逐條比對。平常跳過；`UTUVO_GOLDEN_OUT=<資料夾>` 才執行。
///
/// 語料不手抄：從現有測試檔的字串常數與 benchmarks/cases.jsonl 自動抽，Swift 這邊加測試，
/// 標準答案下次重匯就跟著長。
final class GoldenExportTests: XCTestCase {

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.repo.appendingPathComponent("Tests/UTUVOTypeCoreTests/\(name)"), encoding: .utf8)
    }

    /// 抽出第一個捕捉群組、去重、保留出現順序。
    private func captures(_ pattern: String, in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let s = String(text[r]).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    private func write(_ value: Any, _ name: String, to dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: dir.appendingPathComponent(name))
        print("golden:", name)
    }

    func testExportGolden() throws {
        guard let out = ProcessInfo.processInfo.environment["UTUVO_GOLDEN_OUT"] else {
            throw XCTSkip("只在設了 UTUVO_GOLDEN_OUT 時匯出")
        }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 文字整理：benchmark 題目＋Normalizer／TaiwanPhrases 測試裡的字串
        var inputs: [String] = []
        let cases = try String(contentsOf: Self.repo.appendingPathComponent("benchmarks/cases.jsonl"), encoding: .utf8)
        for line in cases.split(separator: "\n") where !line.isEmpty {
            if let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let t = obj["transcript"] as? String { inputs.append(t) }
        }
        inputs += captures(#"normalize\("((?:[^"\\]|\\.)*)"\)"#, in: try source("NormalizerTests.swift"))
        inputs += captures(#"apply\("((?:[^"\\]|\\.)*)"\)"#, in: try source("TaiwanPhrasesTests.swift"))
        // 字典邊界：語音辨識把英文黏在中文上（中文是邊界）vs 更長的拼音詞（不換）
        inputs += ["我在用pik播放器", "utuvo的新版", "我抓到pika了", "看apik這個字", "Atmos混音"]
        // 長文分段／逐句條列（2026-09-19）
        inputs += [ParagraphTests.meeting, ParagraphTests.email, ParagraphTests.review]
        inputs += captures(#"normalize\("((?:[^"\\]|\\.)*)"\)"#, in: try source("ParagraphTests.swift"))
        inputs = Array(NSOrderedSet(array: inputs)) as! [String]
        let dict = ["pik": "Pik", "utuvo": "UTUVO", "Atmos": "Atmos"]
        let plain = Normalizer(), withDict = Normalizer(options: NormalizerOptions(dictionary: dict))
        try write(inputs.map { t -> [String: Any] in
            let a = plain.normalize(t), b = withDict.normalize(t)
            return ["input": t, "taiwan": TaiwanPhrases.apply(t),
                    "cleaned": a.cleaned, "steps": a.appliedSteps,
                    "cleanedWithDictionary": b.cleaned]
        }, "normalizer.json", to: dir)
        try write(dict, "normalizer-dictionary.json", to: dir)

        // 注音：測試裡 typeAll(…, "鍵序") 的鍵序
        let zhuyinURL = Self.repo.appendingPathComponent("ios/Keyboard/Resources/zhuyin.dat")
        let zlex = try XCTUnwrap(ZhuyinLexicon(url: zhuyinURL))
        // 測試裡的鍵序＋一批常用詞（空白＝一聲）。輸入不必是真詞：答案是 Swift 當下的輸出。
        let extra = ["ㄊㄞˊㄅㄟˇ", "ㄓㄨㄥ ㄨㄣˊ", "ㄐㄧㄣ ㄊㄧㄢ ", "ㄇㄧㄥˊㄊㄧㄢ ", "ㄒㄧㄝˋㄒㄧㄝˋ", "ㄉㄨㄟˋㄅㄨˋㄑㄧˇ",
                     "ㄨㄛˇㄞˋㄋㄧˇ", "ㄊㄧㄢ ㄑㄧˋ", "ㄉㄧㄢˋㄋㄠˇ", "ㄕㄡˇㄐㄧ ", "ㄧㄣ ㄩㄝˋ", "ㄏㄨㄣˋㄧㄣ ",
                     "ㄌㄨˋㄧㄣ ㄕˋ", "ㄇㄨˇㄉㄞˋ", "ㄦˇㄐㄧ ", "ㄎㄜˋㄏㄨˋ", "ㄒㄩㄝˊㄕㄥ ", "ㄌㄠˇㄕ ",
                     "ㄆㄥˊㄧㄡˇ", "ㄍㄨㄥ ㄙ ", "ㄏㄨㄟˋㄧˋ", "ㄕˊㄐㄧㄢ ", "ㄒㄧㄚˋㄨˇ", "ㄗㄠˇㄕㄤˋ",
                     "ㄨㄢˇㄈㄢˋ", "ㄎㄚ ㄈㄟ ", "ㄊㄞˊㄨㄢ ", "ㄍㄠ ㄒㄩㄥˊ", "ㄒㄧㄣ ㄓㄨˊ", "ㄙㄨㄥˋ",
                     "ㄅㄚ", "ㄇㄚ ", "ㄋㄧˇㄏㄠˇㄇㄚ˙", "ㄓ ㄉㄠˋ", "ㄎㄜˇㄧˇ", "ㄅㄨˋㄒㄧㄥˊ",
                     "ㄧ ㄉㄧㄢˇ", "ㄒㄧㄤˋㄇㄨˋ", "ㄏㄜˊㄗㄨㄛˋ", "ㄐㄧˋㄉㄜ˙", "ㄉㄞˋ", "ㄧㄥˋㄆㄢˊ"]
        let zkeys = Array(NSOrderedSet(array: captures(#"typeAll\(\w+, "([^"]+)"\)"#, in: try source("ZhuyinTests.swift")) + extra)) as! [String]
        try write(zkeys.map { keys -> [String: Any] in
            let e = ZhuyinEngine(lexicon: zlex)
            for ch in keys { if ch == " " { e.space() } else { e.type(ch) } }
            return ["keys": keys, "preedit": e.preedit, "composing": e.composing,
                    "candidates": e.candidates.prefix(12).map(\.text), "commitAll": e.commitAll()]
        }, "zhuyin.json", to: dir)

        // 拼音（簡＋繁）：測試裡出現過的拼音字串
        for (file, dat, name) in [("PinyinTests.swift", "pinyin.dat", "pinyin.json"),
                                  ("PinyinHantTests.swift", "pinyin-hant.dat", "pinyin-hant.json")] {
            let lex = try XCTUnwrap(PinyinLexicon(url: Self.repo.appendingPathComponent("ios/Keyboard/Resources/\(dat)")))
            let keys = captures(#""([a-z']{2,})""#, in: try source(file))
            try write(keys.map { k -> [String: Any] in
                let e = PinyinEngine(lexicon: lex)
                for ch in k { e.type(ch) }
                return ["keys": k, "preedit": e.preedit, "segmentation": e.bestSegmentation,
                        "candidates": e.candidates.prefix(12).map { ["text": $0.text, "consumed": $0.consumed] },
                        "commitAll": e.commitAll()]
            }, name, to: dir)
        }
    }
}
