import XCTest
@testable import UTUVOTypeCore

/// modes-6（2026-10-22）：回答卡畫 Markdown；插入／複製的是沒有 ** 和 # 的純文字。
final class AnswerTextTests: XCTestCase {

    func testBoldAndBulletsBecomeCleanTextThatStillPastesAsAList() {
        let plain = AnswerText.plain("**A**\n- b\n- c")
        XCTAssertEqual(plain, "A\n- b\n- c")
        XCTAssertFalse(plain.contains("**"))
        XCTAssertTrue(RichTextShape.html(for: plain)?.contains("<li>b</li>") == true,
                      "條列照樣附 HTML 清單給富文字編輯器")
    }

    func testHeadingsFencesAndInlineCode() {
        let raw = "## 重點\n```swift\nlet x = 1\n```\n用 `swift build` 編譯\n### 結尾 ##"
        XCTAssertEqual(AnswerText.plain(raw), "重點\nlet x = 1\n用 swift build 編譯\n結尾")
    }

    func testStarAndPlusBulletsAreNormalized() {
        XCTAssertEqual(AnswerText.plain("* 一\n+ 二\n  * 三"), "- 一\n- 二\n  - 三")
    }

    func testUnderscoreBold() {
        XCTAssertEqual(AnswerText.plain("__重要__ 事項"), "重要 事項")
    }

    // MARK: 一般文字不能被改

    func testOrdinaryTextIsUntouched() {
        let samples = [
            "2**10 = 1024",
            "a * b * c",
            "a ** b",
            "#hashtag 不是標題",
            "snake_case_name 與 __init__ 方法",
            "1. 第一步\n2. 第二步",
            "沒有任何記號的一句話。",
        ]
        for text in samples {
            XCTAssertEqual(AnswerText.plain(text), text, text)
        }
        XCTAssertEqual(AnswerText.plain("x=__init__"), "x=__init__", "字中間的 __ 不是粗體")
    }

    func testInlineMarkdownTurnsHeadingsIntoBoldForTheCard() {
        XCTAssertEqual(AnswerText.inlineMarkdown("# 標題\n內文 **粗**\n```\ncode\n```"), "**標題**\n內文 **粗**\ncode")
        XCTAssertEqual(AnswerText.inlineMarkdown("* 項目"), "- 項目")
        XCTAssertEqual(AnswerText.inlineMarkdown("純文字"), "純文字")
    }
}
