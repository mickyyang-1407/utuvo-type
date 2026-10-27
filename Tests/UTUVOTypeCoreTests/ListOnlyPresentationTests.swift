import Foundation
import XCTest
import UTUVOTypeCore

final class ListOnlyPresentationTests: XCTestCase {
    func testSharedLayoutFixturesAndIdempotence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("benchmarks/list-layout-regression.json"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        for row in rows {
            let source = try XCTUnwrap(row["input"]), expected = try XCTUnwrap(row["expected"])
            let actual = OutputShape.expandingInlineNumberedList(source)
            XCTAssertEqual(actual, expected, row["id"] ?? "")
            XCTAssertEqual(OutputShape.expandingInlineNumberedList(actual), actual, row["id"] ?? "")
        }
        print("List-only shared fixtures: \(rows.count) exact outputs + idempotence; values/negation/emphasis/body spelling preserved")
    }

    func testKeyboardExceptionRequiresCompleteRenderedList() {
        XCTAssertTrue(OutputShape.hasCompleteNumberedList("帶：\n1. 耳機\n2. 腳架"))
        for value in ["1. 耳機", "1. 耳機\n3. 腳架", "1.5耳機\n2.5腳架", "第一段\n第二段"] {
            XCTAssertFalse(OutputShape.hasCompleteNumberedList(value), value)
        }
    }
}
