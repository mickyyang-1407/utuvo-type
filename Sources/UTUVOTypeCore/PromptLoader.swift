import Foundation

/// UTUVO Type — prompt loader.
///
/// 設計紀律：
/// 1. template 必須來自檔案，不能由 caller 拼接後塞進來（避免 injection）。
/// 2. placeholder 是白名單制：只允許 `{{transcript}}`、`{{app}}`、
///    `{{dictionary}}`、`{{selected}}`、`{{date}}`。其他 `{{...}}` 必須
///    全部被填滿，否則拋錯。
/// 3. 不允許把 caller 控制的值塞進 system prompt；只有 transcript
///    等已定義欄位會被替換。
    /// 4. 對 template 做 structural-token 掃描：真正的 code fence 會讓
    ///    formatter 把結果包成不可直接貼上的區塊，因此拒絕；「不要輸出
    ///    JSON／<think>」這類政策文字本身必須允許出現在 prompt 裡。

public enum PromptLoaderError: Error, CustomStringConvertible {
    case forbiddenTokenInTemplate(String)
    case unfilledPlaceholder(String)
    case unknownPlaceholder(String)
    case unsafeValue(name: String, reason: String)
    case templateNotFound(String)

    public var description: String {
        switch self {
        case .forbiddenTokenInTemplate(let t):
            return "Forbidden token in prompt template: \(t)"
        case .unfilledPlaceholder(let p):
            return "Unfilled placeholder: \(p)"
        case .unknownPlaceholder(let p):
            return "Unknown placeholder name: \(p)"
        case .unsafeValue(let n, let r):
            return "Unsafe value for placeholder \(n): \(r)"
        case .templateNotFound(let p):
            return "Prompt template not found: \(p)"
        }
    }
}

public struct PromptTemplate: Sendable, Equatable {
    public let name: String
    public let body: String
    public let placeholders: [String]

    public init(name: String, body: String) {
        self.name = name
        self.body = body
        // 抽出所有 {{xxx}}，順序照出現先後。
        var found: [String] = []
        var i = body.startIndex
        while i < body.endIndex {
            if body[i...].hasPrefix("{{") {
                if let close = body.range(of: "}}", range: i..<body.endIndex) {
                    let contentStart = body.index(i, offsetBy: 2)
                    let name = String(body[contentStart..<close.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty && !found.contains(name) {
                        found.append(name)
                    }
                    i = close.upperBound
                    continue
                }
            }
            i = body.index(after: i)
        }
        self.placeholders = found
    }
}

public enum PromptLoader: Sendable {
    /// 白名單：可被替換的 placeholder。順序在文件裡有定義，
    /// 改動必須同步更新 `prompts/formatter-v1.txt`。
    public static let allowedPlaceholders: Set<String> = [
        "transcript", "app", "dictionary", "selected", "date"
    ]

    /// template 禁止包含的 token。出現就拒載，避免「我以為是
    /// 中文 formatter 結果被換成 reasoning 模式」之類的悲劇。
    public static let forbiddenTokens: [String] = ["```"]

    /// 從檔案載入 template 並驗證。
    public static func loadTemplate(from url: URL) throws -> PromptTemplate {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PromptLoaderError.templateNotFound(url.path)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parseTemplate(name: url.lastPathComponent, body: raw)
    }

    public static func parseTemplate(name: String, body: String) throws -> PromptTemplate {
        for token in forbiddenTokens where body.contains(token) {
            throw PromptLoaderError.forbiddenTokenInTemplate(token)
        }
        let template = PromptTemplate(name: name, body: body)
        for p in template.placeholders where !allowedPlaceholders.contains(p) {
            throw PromptLoaderError.unknownPlaceholder(p)
        }
        return template
    }

    /// 替換 placeholder。所有 placeholder 都必須填，缺一就錯。
    /// 值若包含控制字元／明顯 injection 痕跡，也會被擋下來。
    public static func fillPlaceholders(
        template: PromptTemplate,
        values: [String: String]
    ) throws -> String {
        var out = template.body
        let pattern = "\\{\\{\\s*([a-zA-Z0-9_-]+)\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw PromptLoaderError.forbiddenTokenInTemplate("(regex compile)")
        }
        let range = NSRange(out.startIndex..<out.endIndex, in: out)
        let matches = regex.matches(in: out, range: range)
        guard !matches.isEmpty else {
            return out
        }
        var resolved: [(NSRange, String)] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let keyRange = m.range(at: 1)
            let fullRange = m.range(at: 0)
            let key = (out as NSString).substring(with: keyRange)
            guard let value = values[key] else {
                throw PromptLoaderError.unfilledPlaceholder(key)
            }
            try assertValueSafe(name: key, value: value)
            resolved.append((fullRange, value))
        }
        // 由後往前替換避免 range 漂移。
        for (r, replacement) in resolved.reversed() {
            guard let range = Range(r, in: out) else {
                throw PromptLoaderError.forbiddenTokenInTemplate("invalid placeholder range")
            }
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    /// 值的衛生檢查：禁止 NUL、控制字元、明顯的 prompt injection 痕跡。
    static func assertValueSafe(name: String, value: String) throws {
        if value.contains("\0") {
            throw PromptLoaderError.unsafeValue(name: name, reason: "contains NUL")
        }
        for ch in value.unicodeScalars {
            // 控制字元（除了 \n 跟 \t）。
            if ch.value < 0x20 && ch.value != 0x09 && ch.value != 0x0A {
                throw PromptLoaderError.unsafeValue(name: name, reason: "control char")
            }
            if (0x7F...0x9F).contains(ch.value) {
                throw PromptLoaderError.unsafeValue(name: name, reason: "DEL/C1 control")
            }
        }
        // 不准值裡出現新的 {{，避免在替換後再被二次展開。
        if value.contains("{{") || value.contains("}}") {
            throw PromptLoaderError.unsafeValue(name: name, reason: "nested placeholder")
        }
    }
}
