import XCTest
@testable import UTUVOTypeCore

final class TextPresentationTests: XCTestCase {
    func testMixedSpacingPreservesLatinTokensAndLineBreaks() {
        XCTAssertEqual(TextPresentation.format("使用ChatGPT和iOS26\n共有3個API。"), "使用 ChatGPT 和 iOS26\n共有 3 個 API。")
        XCTAssertEqual(TextPresentation.format("使用  API  測試"), "使用 API 測試")
    }
    func testTechnicalLiteralsAreNotEditedInside() {
        let email = "test" + "@example.com"
        let input = "請看https://example.com/中文?q=API，寄給\(email)或用`foo中文Bar`。"
        XCTAssertEqual(TextPresentation.format(input), "請看 https://example.com/中文?q=API，寄給 \(email) 或用`foo中文Bar`。")
    }
    func testDictionaryWinsAndDoesNotCascade() {
        let value = TextPresentation.format("請用foo和Bar，專名，afoo", dictionary: ["foo": "Bar", "Bar": "Baz", "專名": "臺灣3D"]) { text in
            text.replacingOccurrences(of: "臺", with: "台")
        }
        XCTAssertEqual(value, "請用 Bar 和 Baz，臺灣3D，afoo")
    }
    func testDictionaryOutputSurvivesNumberAndWhitespaceNormalization() {
        let result = TextPresentation.format("使用品牌。", dictionary: ["品牌": "Project  X 三點"]) {
            Normalizer(options: .init(dictionary: [:], latinTerms: [])).normalize($0).cleaned
        }
        XCTAssertEqual(result, "使用 Project  X 三點。")
    }
    func testVocabularyOnlyEntryIsPreserved() {
        XCTAssertEqual(TextPresentation.format("我在臺灣大學", dictionary: ["臺灣大學": ""]) { $0.replacingOccurrences(of: "臺", with: "台") }, "我在臺灣大學")
    }
}
