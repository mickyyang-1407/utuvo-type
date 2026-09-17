import XCTest
@testable import UTUVOTypeCore

final class PromptLoaderTests: XCTestCase {

    func testParseExtractsPlaceholdersInOrder() {
        let body = """
        你好 {{app}}
        日期 {{date}}
        再 {{app}} 一次
        """
        let template = try! PromptLoader.parseTemplate(name: "test", body: body)
        XCTAssertEqual(template.placeholders, ["app", "date"])
    }

    func testAllowsExplicitThinkProhibition() {
        let body = "只輸出文字，不要輸出分析、推理、JSON、Markdown code fence 或 <think> 標籤。"
        XCTAssertNoThrow(try PromptLoader.parseTemplate(name: "t", body: body))
    }

    func testRejectsTripleBacktick() {
        let body = "請用 ```包起來``` 程式碼"
        XCTAssertThrowsError(try PromptLoader.parseTemplate(name: "t", body: body))
    }

    func testAllowsExplicitJSONProhibition() {
        let body = "不要輸出 JSON 物件。"
        XCTAssertNoThrow(try PromptLoader.parseTemplate(name: "t", body: body))
    }

    func testRejectsUnknownPlaceholder() {
        let body = "你好 {{name}}"
        XCTAssertThrowsError(try PromptLoader.parseTemplate(name: "t", body: body))
    }

    func testFillAllPlaceholders() throws {
        let body = "app={{app}} transcript={{transcript}} selected={{selected}} dict={{dictionary}} date={{date}}"
        let template = try PromptLoader.parseTemplate(name: "t", body: body)
        let filled = try PromptLoader.fillPlaceholders(template: template, values: [
            "app": "Xcode",
            "transcript": "我今天很累",
            "selected": "",
            "dictionary": "無",
            "date": "2026-08-21"
        ])
        XCTAssertEqual(filled, "app=Xcode transcript=我今天很累 selected= dict=無 date=2026-08-21")
    }

    func testFillMissingPlaceholderThrows() {
        let body = "app={{app}} transcript={{transcript}}"
        let template = try! PromptLoader.parseTemplate(name: "t", body: body)
        XCTAssertThrowsError(try PromptLoader.fillPlaceholders(template: template, values: [
            "app": "Xcode"
        ]))
    }

    func testFillRejectsValueContainingNestedPlaceholder() {
        let body = "transcript={{transcript}}"
        let template = try! PromptLoader.parseTemplate(name: "t", body: body)
        XCTAssertThrowsError(try PromptLoader.fillPlaceholders(template: template, values: [
            "transcript": "我有 {{evil}}"
        ]))
    }

    func testFillRejectsControlCharsInValue() {
        let body = "transcript={{transcript}}"
        let template = try! PromptLoader.parseTemplate(name: "t", body: body)
        XCTAssertThrowsError(try PromptLoader.fillPlaceholders(template: template, values: [
            "transcript": "壞字\u{0001}符"
        ]))
    }

    func testLoadActualPromptTemplate() throws {
        // 預設從 repo 根目錄載入 prompts/formatter-v1.txt
        let repoRoot = TestSupport.repoRoot()
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent("prompts/formatter-v1.txt")
        let template = try PromptLoader.loadTemplate(from: url)
        XCTAssertTrue(template.placeholders.contains("transcript"))
        XCTAssertTrue(template.placeholders.contains("app"))
        XCTAssertTrue(template.placeholders.contains("dictionary"))
        XCTAssertTrue(template.placeholders.contains("selected"))
        XCTAssertTrue(template.placeholders.contains("date"))
    }
}
