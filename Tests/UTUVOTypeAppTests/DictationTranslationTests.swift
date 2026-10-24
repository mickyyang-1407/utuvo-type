import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// modes-1（2026-10-22）：Mac 語音翻譯的路線選擇（純函式）。
final class DictationTranslationTests: XCTestCase {

    func testCloudOnlyWhenCleanupEnabledAndKeyPresent() {
        XCTAssertEqual(DictationTranslation.engines(cleanupEnabled: true, hasKey: true, localEditorUsable: false),
                       [.cloud, .system])
        XCTAssertEqual(DictationTranslation.engines(cleanupEnabled: false, hasKey: true, localEditorUsable: false),
                       [.system], "智慧整理沒開：只有 key 不算同意把聽寫送出去")
        XCTAssertEqual(DictationTranslation.engines(cleanupEnabled: true, hasKey: false, localEditorUsable: true),
                       [.system, .localEditor])
        XCTAssertEqual(DictationTranslation.engines(cleanupEnabled: true, hasKey: true, localEditorUsable: true),
                       [.cloud, .system, .localEditor])
    }

    func testLocalEditorUsableOnlyWhenTheModelIsReallyThere() {
        let bundled = "/Applications/UTUVO Type.app/Contents/Resources/runtime/utuvo-type-editor.py"
        XCTAssertFalse(DictationTranslation.localEditorUsable(command: "  ", bundledWrapperPath: bundled, bundledModelExists: true))
        XCTAssertFalse(DictationTranslation.localEditorUsable(command: bundled, bundledWrapperPath: bundled, bundledModelExists: false),
                       "安裝程式不下載 editor 模型：內建 wrapper 在、模型不在＝不能用")
        XCTAssertTrue(DictationTranslation.localEditorUsable(command: bundled, bundledWrapperPath: bundled, bundledModelExists: true))
        XCTAssertTrue(DictationTranslation.localEditorUsable(command: "/usr/local/bin/my-editor", bundledWrapperPath: bundled,
                                                             bundledModelExists: false), "使用者自己設定的 command 照用")
        XCTAssertTrue(DictationTranslation.localEditorUsable(command: "/usr/local/bin/my-editor", bundledWrapperPath: nil,
                                                             bundledModelExists: false))
    }

    /// 送進共用提示詞的語言名稱要跟 iOS 翻譯清單（ios/Shared/TranslationService.swift）同一份。
    func testPromptNamesMatchIOSTargets() throws {
        let source = try String(contentsOfFile: repoRoot() + "/ios/Shared/TranslationService.swift", encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"\("([A-Za-z-]+)", "([^"]+)", "([^"]+)"\)"#)
        var ios: [String: (String, String)] = [:]
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let field = { (i: Int) in String(source[Range(match.range(at: i), in: source)!]) }
            ios[field(1)] = (field(2), field(3))
        }
        XCTAssertFalse(ios.isEmpty, "iOS 翻譯清單讀不到")
        for target in TranslationTarget.allCases where target != .off {
            let names = DictationTranslation.promptNames(target)
            let expected = try XCTUnwrap(ios[target.rawValue], "iOS 沒有 \(target.rawValue)")
            XCTAssertEqual(names.zh, expected.0, target.rawValue)
            XCTAssertEqual(names.en, expected.1, target.rawValue)
        }
    }

    func testSystemTranslatorSourceLanguage() {
        XCTAssertNil(SystemTranslator.sourceLanguage(forTranscription: "auto"), "自動偵測不知道來源語言")
        XCTAssertEqual(SystemTranslator.sourceLanguage(forTranscription: "zh-TW"), "zh-Hant")
        XCTAssertEqual(SystemTranslator.sourceLanguage(forTranscription: "zh-HK"), "zh-Hant")
        XCTAssertEqual(SystemTranslator.sourceLanguage(forTranscription: "zh-CN"), "zh-Hans")
        XCTAssertEqual(SystemTranslator.sourceLanguage(forTranscription: "en-US"), "en")
        XCTAssertEqual(SystemTranslator.sourceLanguage(forTranscription: "ja"), "ja")
    }

    private func repoRoot() -> String {
        var probe = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: probe.appendingPathComponent("Package.swift").path) { return probe.path }
            probe.deleteLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }
}
