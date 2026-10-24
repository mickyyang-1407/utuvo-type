import Foundation

/// Final presentation rules. Protect explicit dictionary spellings and technical
/// literals while running regional/normalizer transforms, then space CJK/Latin boundaries.
public enum TextPresentation {
    private static let literals = try! NSRegularExpression(
        pattern: #"```[\s\S]*?```|`[^`\n]+`|https?://[^\s<>，。！？；、）】》]+|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let horizontalWhitespace = try! NSRegularExpression(pattern: #"(?<=\S)[ \t]+(?=\S)"#)

    public static func format(_ text: String, dictionary: [String: String] = [:], spaceMixedScripts: Bool = true,
                              transform: (String) -> String = { $0 }) -> String {
        var protected: [Character: String] = [:]
        var reserved = Set(text)
        var next: UInt32 = 0xF0000
        func token(for value: String) -> String {
            while reserved.contains(Character(UnicodeScalar(next)!)) { next += 1 }
            let character = Character(UnicodeScalar(next)!)
            next += 1
            reserved.insert(character)
            protected[character] = value
            return String(character)
        }
        func mask(_ source: String, regex: NSRegularExpression, replacement: (String) -> String) -> String {
            var result = source
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                guard let range = Range(match.range, in: source) else { continue }
                result.replaceSubrange(range, with: token(for: replacement(String(source[range]))))
            }
            return result
        }
        // Already-canonical names are protected too. Explicit source rules take precedence.
        var entries = dictionary.mapValues { $0 }
        for (source, target) in dictionary {
            if target.isEmpty { entries[source] = source }
            else if entries[target] == nil { entries[target] = target }
        }
        let patterns = entries.keys.filter { !$0.isEmpty }.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }.map { term in
            let left = isLatinOrNumber(term.first!) ? #"(?<![A-Za-z0-9_])"# : ""
            let right = isLatinOrNumber(term.last!) ? #"(?![A-Za-z0-9_])"# : ""
            return left + NSRegularExpression.escapedPattern(for: term) + right
        }
        let dictionaryPattern = patterns.isEmpty ? nil : try? NSRegularExpression(pattern: patterns.joined(separator: "|"))
        func maskDictionary(_ source: String) -> String {
            guard let regex = dictionaryPattern else { return source }
            return mask(source, regex: regex) { entries[$0] ?? $0 }
        }
        var result = mask(text, regex: literals) { $0 }
        result = maskDictionary(result)
        result = transform(result)
        // Regional conversion may produce a dictionary key that was absent in the original.
        result = maskDictionary(result)
        result = horizontalWhitespace.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        var output = ""
        for character in result {
            let value = protected[character] ?? String(character)
            if spaceMixedScripts, let before = output.last, let after = value.first,
               (isHan(before) && isLatinOrNumber(after)) || (isLatinOrNumber(before) && isHan(after)) {
                output.append(" ")
            }
            output += value
        }
        return output
    }

    private static func isLatinOrNumber(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
    }
}
