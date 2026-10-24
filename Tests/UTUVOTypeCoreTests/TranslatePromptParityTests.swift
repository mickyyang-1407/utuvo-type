import XCTest
@testable import UTUVOTypeCore

/// modes-1（2026-10-22）：Mac 語音翻譯用跟 iOS／Android 同一句翻譯提示詞。
/// 正本在 `TranslatePrompt`；iOS／Android 那兩份不在這張票能改的範圍，所以讀檔逐字比對——
/// 任何一邊改了字，這裡就紅。
final class TranslatePromptParityTests: XCTestCase {
    private let zh = "\u{1}ZH\u{1}"
    private let en = "\u{1}EN\u{1}"

    private func read(_ relative: String) throws -> String {
        try String(contentsOfFile: TestSupport.repoRoot() + "/" + relative, encoding: .utf8)
    }

    private var core: String { TranslatePrompt.system(targetZh: zh, targetEn: en) }

    func testMatchesIOSOnDeviceAssistant() throws {
        let source = try read("ios/Shared/OnDeviceAssistant.swift")
        let line = try XCTUnwrap(source.components(separatedBy: "\n")
            .first { $0.contains("let system = \"你是翻譯引擎") }, "iOS 翻譯提示詞那一行不見了")
        let literal = try XCTUnwrap(line.components(separatedBy: "let system = \"").last?
            .components(separatedBy: "\"").first)
        let ios = literal.replacingOccurrences(of: "\\(target.zh)", with: zh)
            .replacingOccurrences(of: "\\(target.en)", with: en)
        XCTAssertEqual(core, ios)
    }

    func testMatchesAndroidAssistant() throws {
        let source = try read("android/app/src/main/kotlin/com/utuvo/type/Assistant.kt")
        let lines = source.components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex { $0.contains("fun translateSystem(targetZh: String, targetEn: String)") },
                                  "Android translateSystem 不見了")
        let literal = try XCTUnwrap(lines[index + 1].components(separatedBy: "\"").dropFirst().first)
        let android = literal.replacingOccurrences(of: "$targetZh", with: zh)
            .replacingOccurrences(of: "$targetEn", with: en)
        XCTAssertEqual(core, android)
    }

    func testFillsNamesAndCleansOutput() {
        XCTAssertEqual(TranslatePrompt.system(targetZh: "英文", targetEn: "English"),
                       "你是翻譯引擎。把使用者的文字翻成英文（English），只輸出翻譯本身，不要解釋、不要引號。")
        XCTAssertEqual(TranslatePrompt.cleanOutput("```\nHello there\n```\n"), "Hello there")
        XCTAssertEqual(TranslatePrompt.cleanOutput("  Hi  "), "Hi")
    }
}
