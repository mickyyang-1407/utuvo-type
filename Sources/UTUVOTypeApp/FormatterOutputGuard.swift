import Foundation
import UTUVOTypeCore

enum FormatterOutputGuard {
    static func sanitize(_ raw: String, source: String, mode: FormatterMode) -> String? {
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }

        while let start = output.range(of: "<think>"),
              let end = output.range(of: "</think>", range: start.upperBound ..< output.endIndex) {
            output.removeSubrange(start.lowerBound ..< end.upperBound)
        }
        output = output
            .replacingOccurrences(of: "```markdown", with: "")
            .replacingOccurrences(of: "```text", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }

        // 單項條列＝不是條列；規則與測試住在 Core 的 OutputShape。
        output = OutputShape.stripLoneBullet(output)

        let firstLine = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? output
        let assistantPrefixes = [
            "好的，", "好的。", "當然，", "當然。", "以下是", "以下為",
            "我已經", "我已", "希望這", "有需要我", "如果你需要"
        ]
        if assistantPrefixes.contains(where: { firstLine.hasPrefix($0) }) {
            return nil
        }

        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != .editSelection,
           normalizedSource.count > 12,
           !hasMeaningfulOverlap(output, source: normalizedSource) {
            return nil
        }
        return output
    }

    private static func hasMeaningfulOverlap(_ output: String, source: String) -> Bool {
        let sourceTerms = ngrams(in: source, length: 2)
        guard !sourceTerms.isEmpty else { return true }
        let outputTerms = ngrams(in: output, length: 2)
        let overlap = sourceTerms.intersection(outputTerms).count
        return overlap >= 1 || outputTerms.count <= 2
    }

    private static func ngrams(in text: String, length: Int) -> Set<String> {
        let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count >= length else { return [] }
        return Set((0 ... characters.count - length).map { index in
            String(characters[index ..< index + length])
        })
    }
}
