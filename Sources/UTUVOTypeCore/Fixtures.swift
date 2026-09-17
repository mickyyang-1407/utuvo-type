import Foundation

/// UTUVO Type — benchmark fixture loader.
///
/// 一行一題，固定 schema：id、category、transcript、expected、assertions。
/// 任何欄位缺漏都會在 verify-scaffold 階段擋下。

public struct Fixture: Sendable, Codable, Equatable {
    public var id: String
    public var category: String
    public var transcript: String
    public var expected: String
    public var assertions: [String]

    public init(
        id: String,
        category: String,
        transcript: String,
        expected: String,
        assertions: [String]
    ) {
        self.id = id
        self.category = category
        self.transcript = transcript
        self.expected = expected
        self.assertions = assertions
    }
}

public enum FixtureError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case lineParseFailed(line: Int, reason: String)
    case missingField(line: Int, field: String)
    case duplicateId(String)

    public var description: String {
        switch self {
        case .fileNotFound(let p): return "Fixture file not found: \(p)"
        case .lineParseFailed(let l, let r): return "Fixture line \(l) parse failed: \(r)"
        case .missingField(let l, let f): return "Fixture line \(l) missing field: \(f)"
        case .duplicateId(let id): return "Duplicate fixture id: \(id)"
        }
    }
}

public enum FixtureLoader: Sendable {
    /// 從 JSONL 檔載入所有 fixtures。
    /// M0 預期有 30 題，但本函式只保證 schema 正確，count 由
    /// 上層測試／benchmark 自己驗證。
    public static func loadAll(from url: URL) throws -> [Fixture] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.fileNotFound(url.path)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parse(raw)
    }

    public static func parse(_ raw: String) throws -> [Fixture] {
        var fixtures: [Fixture] = []
        var seenIDs: Set<String> = []
        var lineNumber = 0
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("//") { continue }
            guard let data = line.data(using: .utf8) else {
                throw FixtureError.lineParseFailed(line: lineNumber, reason: "not UTF-8")
            }
            let decoded: Fixture
            do {
                decoded = try JSONDecoder().decode(Fixture.self, from: data)
            } catch {
                throw FixtureError.lineParseFailed(line: lineNumber, reason: "\(error)")
            }
            for (name, value) in [
                ("id", decoded.id),
                ("category", decoded.category),
                ("transcript", decoded.transcript),
                ("expected", decoded.expected)
            ] where value.isEmpty {
                throw FixtureError.missingField(line: lineNumber, field: name)
            }
            if seenIDs.contains(decoded.id) {
                throw FixtureError.duplicateId(decoded.id)
            }
            seenIDs.insert(decoded.id)
            fixtures.append(decoded)
        }
        return fixtures
    }

    /// 標準必含的 10 個 category，benchmark 設計要求。
    public static let requiredCategories: [String] = [
        "short-dictation",
        "mixed-zh-en",
        "proper-noun",
        "self-correction",
        "list-cue",
        "todo",
        "long-paragraph",
        "meeting-notes",
        "selection-edit",
        "markdown"
    ]
}
