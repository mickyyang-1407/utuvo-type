import Foundation

/// Ask anything／白話解釋的回答文字（modes-6，2026-10-22）。
///
/// 模型的回答常帶 Markdown（**粗體**、# 標題、```），回答卡以前原樣顯示，按「插入」還會把 ** 和 # 貼進欄位。
/// - `inlineMarkdown`：回答卡顯示用，交給 `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)` 畫粗體；
///   只解析行內語法時標題的 # 不會被吃掉，所以標題先轉成粗體、code fence 那一行拿掉。
/// - `plain`：複製／插入用的純文字。條列保留成「- 」「1. 」，貼上時 `RichTextShape` 會另附 HTML 清單。
///
/// 只動成對、緊貼文字的記號：`2**10`、`a * b`、`#tag`、`__init__` 這類一般文字不會被改。
public enum AnswerText: Sendable {
    public static func plain(_ markdown: String) -> String {
        let lines = normalizedLines(markdown).map { line -> String in
            if let heading = headingBody(line) { return heading }
            return bulletNormalized(line)
        }
        return stripInline(lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func inlineMarkdown(_ markdown: String) -> String {
        normalizedLines(markdown).map { line -> String in
            if let heading = headingBody(line) {
                let body = heading.replacingOccurrences(of: "**", with: "")
                return body.isEmpty ? "" : "**\(body)**"
            }
            return bulletNormalized(line)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 統一換行、拿掉 code fence 那一行（```、```swift）。
    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
    }

    /// 「# 標題」～「###### 標題」（前面最多 3 個空白，# 後面要有空白）→ 標題文字。
    static func headingBody(_ line: String) -> String? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        let hashes = rest.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let after = rest.dropFirst(hashes.count)
        guard let first = after.first, first == " " || first == "\t" else { return nil }
        var body = after.trimmingCharacters(in: .whitespaces)
        // 結尾的「 ##」也是標題語法的一部分。
        while body.hasSuffix("#") { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// 「* 項目」「+ 項目」→「- 項目」（保留縮排）。
    private static func bulletNormalized(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        if rest.hasPrefix("* ") || rest.hasPrefix("+ ") { return String(indent) + "- " + String(rest.dropFirst(2)) }
        return line
    }

    private static let inlinePatterns: [(NSRegularExpression, String)] = [
        // **粗體**／__粗體__：記號緊貼文字才算（「a ** b」不動）。
        (try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), "$1"),
        // __粗體__：前後不能黏著字；整段是英數識別字（Python 的 __init__）時不動。
        (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])__(?=\S)(?![A-Za-z0-9_]+__(?![\p{L}\p{N}_]))(.+?)(?<=\S)__(?![\p{L}\p{N}_])"#), "$1"),
        // `行內程式碼`
        (try! NSRegularExpression(pattern: #"`([^`\n]+)`"#), "$1"),
    ]

    private static func stripInline(_ text: String) -> String {
        inlinePatterns.reduce(text) { current, rule in
            let range = NSRange(current.startIndex..., in: current)
            return rule.0.stringByReplacingMatches(in: current, range: range, withTemplate: rule.1)
        }
    }
}
