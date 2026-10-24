import Foundation

/// Provider-independent validation for dictation, not free-form rewriting.
/// Permit explicit self-corrections and close spellings of supplied vocabulary,
/// then use the content-preserving gate (including full numeric values).
public enum DictationPolish {
    public static func accepts(original: String, cleaned: String, terms: [String] = []) -> Bool {
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cleaned.contains("<<<"), !cleaned.contains(">>>") else { return false }
        var source = resolveCorrections(original)
        for term in terms.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count })
            where cleaned.localizedCaseInsensitiveContains(term) {
            source = replacingCloseLatinSpellings(in: source, term: term)
        }
        return CleanupFidelity.preservesContent(original: source, cleaned: cleaned)
    }

    private static let numericCorrection = try! NSRegularExpression(
        pattern: #"(?:[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?|[零〇一二三四五六七八九十百千萬万兩两]+)(?:點|点|時|时|元|塊|块|樓|楼|[kK])?[，,、\s]*(?:(?:不對|不对|不是|更正)[，,、\s]*)+(?:是|為|为)?\s*(?=[0-9零〇一二三四五六七八九十百千萬万兩两])"#)

    private static func resolveCorrections(_ text: String) -> String {
        numericCorrection.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static let latinWords = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)
    private static func latinWindows(_ text: String, wordCount: Int) -> [Range<String.Index>] {
        let ranges = latinWords.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        guard !ranges.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        for i in ranges.indices {
            for count in 1...max(1, wordCount) where i + count <= ranges.count {
                let end = i + count - 1
                let range = ranges[i].lowerBound..<ranges[end].upperBound
                // Never bridge Chinese words, punctuation or numbers to construct a name.
                if text[range].allSatisfy({ $0.isASCII && $0.isLetter || $0.isWhitespace }) { result.append(range) }
            }
        }
        return result
    }

    private static func letters(_ text: String) -> String { text.lowercased().filter { $0.isASCII && $0.isLetter } }
    private static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for (i, c) in x.enumerated() {
            var next = [i + 1]
            for (j, d) in y.enumerated() {
                next.append(min(previous[j + 1] + 1, next[j] + 1, previous[j] + (c == d ? 0 : 1)))
            }
            previous = next
        }
        return previous[y.count]
    }

    private static func close(_ candidate: String, to term: String) -> Bool {
        let a = letters(candidate), b = letters(term)
        let protected: Set<String> = ["not", "no", "never", "neither", "nor", "cannot", "can", "must", "should", "will", "would", "could", "may", "might"]
        if a != b, (candidate.lowercased().split(whereSeparator: \.isWhitespace) + term.lowercased().split(whereSeparator: \.isWhitespace))
            .contains(where: { protected.contains(String($0)) }) { return false }
        guard a.count >= 4, b.count >= 4, a.first == b.first,
              abs(a.count - b.count) <= 3 else { return false }
        return distance(a, b) <= min(3, max(1, b.count / 3))
    }

    private static func replacingCloseLatinSpellings(in text: String, term: String) -> String {
        guard term.allSatisfy({ $0.isASCII && $0.isLetter || $0.isWhitespace }) else { return text }
        let windows = latinWindows(text, wordCount: term.split(whereSeparator: \.isWhitespace).count)
        var result = text
        // Longest non-overlapping matches, working backwards to preserve String indices.
        var rightBoundary = text.endIndex
        for range in windows.sorted(by: { $0.upperBound == $1.upperBound ? $0.lowerBound < $1.lowerBound : $0.upperBound > $1.upperBound }) {
            guard range.upperBound <= rightBoundary, close(String(text[range]), to: term) else { continue }
            result.replaceSubrange(range, with: term)
            rightBoundary = range.lowerBound
        }
        return result
    }

    /// Personal vocabulary is ranked before truncation, with deterministic tie-breaking.
    /// Source spellings score the target too, so explicit dictionary replacements stay relevant.
    public static func rankedTerms(text: String?, dictionary: [String: String]) -> [String] {
        let text = text ?? "", lower = text.lowercased()
        let windows = latinWindows(text, wordCount: 4).map { String(text[$0]) }
        func score(_ term: String) -> Int {
            guard !term.isEmpty else { return 0 }
            if lower.contains(term.lowercased()) { return 1000 + term.count }
            if term.allSatisfy({ $0.isASCII && $0.isLetter || $0.isWhitespace }), windows.contains(where: { close($0, to: term) }) { return 500 }
            let chars = Array(term)
            guard chars.count > 1 else { return 0 }
            return (0..<chars.count - 1).reduce(0) { $0 + (lower.contains(String(chars[$1...$1 + 1]).lowercased()) ? 10 : 0) }
        }
        var scores: [String: Int] = [:]
        for (source, target) in dictionary {
            let priority = max(score(source), score(target))
            for term in target.isEmpty ? [source] : [target, source] where !term.isEmpty {
                scores[term] = max(scores[term] ?? 0, priority)
            }
        }
        return scores.keys.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]! }
    }
}
