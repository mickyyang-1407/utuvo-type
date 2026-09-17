import XCTest
@testable import UTUVOTypeCore

final class FixturesTests: XCTestCase {

    func testParseValidLine() throws {
        let raw = #"{"id":"a","category":"short-dictation","transcript":"hi","expected":"hi","assertions":["x"]}"#
        let fixtures = try FixtureLoader.parse(raw)
        XCTAssertEqual(fixtures.count, 1)
        XCTAssertEqual(fixtures[0].id, "a")
    }

    func testParseSkipsComments() throws {
        let raw = """
        // 這是註解
        {"id":"a","category":"x","transcript":"hi","expected":"hi","assertions":[]}
        """
        let fixtures = try FixtureLoader.parse(raw)
        XCTAssertEqual(fixtures.count, 1)
    }

    func testParseRejectsMissingField() {
        let raw = #"{"id":"a","category":"x","transcript":"","expected":"hi","assertions":[]}"#
        XCTAssertThrowsError(try FixtureLoader.parse(raw))
    }

    func testParseRejectsDuplicateId() {
        let raw = """
        {"id":"a","category":"x","transcript":"hi","expected":"hi","assertions":[]}
        {"id":"a","category":"y","transcript":"hello","expected":"hello","assertions":[]}
        """
        XCTAssertThrowsError(try FixtureLoader.parse(raw))
    }

    func testLoadActualFixturesFile() throws {
        let repoRoot = TestSupport.repoRoot()
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent("benchmarks/cases.jsonl")
        let fixtures = try FixtureLoader.loadAll(from: url)
        XCTAssertEqual(fixtures.count, 30, "M0 必須恰好 30 題")

        let requiredCategories = Set(FixtureLoader.requiredCategories)
        var present = Set<String>()
        for f in fixtures { present.insert(f.category) }
        XCTAssertTrue(requiredCategories.isSubset(of: present),
                      "缺少必要 category：\(requiredCategories.subtracting(present))")

        // 每個 category 至少 3 題
        var counts: [String: Int] = [:]
        for f in fixtures { counts[f.category, default: 0] += 1 }
        for cat in requiredCategories {
            XCTAssertGreaterThanOrEqual(counts[cat] ?? 0, 3, "\(cat) 不足 3 題")
        }

        // id 唯一
        var seen = Set<String>()
        for f in fixtures {
            XCTAssertFalse(seen.contains(f.id), "duplicate id \(f.id)")
            seen.insert(f.id)
        }

        // 欄位非空
        for f in fixtures {
            XCTAssertFalse(f.id.isEmpty)
            XCTAssertFalse(f.category.isEmpty)
            XCTAssertFalse(f.transcript.isEmpty)
            XCTAssertFalse(f.expected.isEmpty)
        }
    }

    func testNoFixtureContainsForbiddenOutputTokens() throws {
        let repoRoot = TestSupport.repoRoot()
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent("benchmarks/cases.jsonl")
        let fixtures = try FixtureLoader.loadAll(from: url)
        for f in fixtures {
            for token in ["<think>", "</think>", "```", "JSON"] {
                XCTAssertFalse(f.expected.contains(token),
                               "fixture \(f.id) expected 含禁止 token: \(token)")
                XCTAssertFalse(f.transcript.contains(token),
                               "fixture \(f.id) transcript 含禁止 token: \(token)")
            }
        }
    }
}
