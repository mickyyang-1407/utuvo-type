import XCTest
@testable import UTUVOTypeCore

/// 釘住產品的隱私宣稱：只讀選取文字與周圍一小段，而且有硬上限。
/// 2026-09-11 之前這兩個數字是 AccessibilitySupport 裡的 magic number、零測試——
/// 有人改大不會有東西變紅。
final class ContextBoundsTests: XCTestCase {

    func testSelectedTextLimitIsTwelveThousand() {
        XCTAssertEqual(ContextBounds.selectedTextLimit, 12_000,
                       "選取文字上限是對外宣稱過的數字，要改先改隱私文件")
    }

    func testSurroundingLimitsAreSmall() {
        // 2026-10-22（context-awareness-1）：1,000／2,000 → 游標前 500＋游標後 200，跟 iOS／Android 同上限。
        XCTAssertEqual(ContextBounds.beforeCursorLimit, 500)
        XCTAssertEqual(ContextBounds.afterCursorLimit, 200)
        XCTAssertEqual(ContextBounds.surroundingRadius, 500)
        XCTAssertEqual(ContextBounds.surroundingLimit, 700)
        XCTAssertLessThan(ContextBounds.surroundingLimit, ContextBounds.selectedTextLimit,
                          "周圍上下文永遠比選取文字更保守")
    }

    func testLongSelectionIsTruncatedToLimit() {
        let long = String(repeating: "字", count: 20_000)
        let bounded = ContextBounds.boundedSelectedText(long)
        XCTAssertEqual(bounded.count, ContextBounds.selectedTextLimit)
    }

    func testLongSurroundingIsTruncatedToLimit() {
        let long = String(repeating: "字", count: 20_000)
        XCTAssertEqual(ContextBounds.boundedSurroundingText(long).count, ContextBounds.surroundingLimit)
    }

    func testShortTextIsUntouched() {
        XCTAssertEqual(ContextBounds.boundedSelectedText("一小段文字"), "一小段文字")
        XCTAssertEqual(ContextBounds.boundedSurroundingText("一小段文字"), "一小段文字")
    }

    func testTextExactlyAtLimitIsUntouched() {
        let exact = String(repeating: "字", count: ContextBounds.selectedTextLimit)
        XCTAssertEqual(ContextBounds.boundedSelectedText(exact).count, ContextBounds.selectedTextLimit)
    }

    /// 中文一字＝一個 Character：上限不可以被當成 byte 數（否則實際讀到的字數只有三分之一，
    /// 或反過來讀進三倍的量）。
    func testLimitCountsCharactersNotBytes() {
        let text = String(repeating: "字", count: 100)
        XCTAssertEqual(ContextBounds.bounded(text, limit: 50).count, 50)
        XCTAssertEqual(ContextBounds.bounded(text, limit: 50).utf8.count, 150)
    }

    func testZeroLimitReadsNothing() {
        XCTAssertEqual(ContextBounds.bounded("任何東西", limit: 0), "")
    }

    // MARK: - 游標前後範圍（context-awareness-1，2026-10-22）
    //
    // 舊算法一律請求 [loc-1000, sel+2000]：超出欄位長度時 AppKit 的 AXStringForRange 回 nil，
    // 短欄位、游標在結尾這兩種最常見的情況都讀不到前文（App 測試 SmartCleanupTests 用 NSTextView 實測）。

    private func windows(_ location: Int, _ selection: Int, _ count: Int?) -> ContextBounds.CursorWindows {
        ContextBounds.cursorWindows(location: location, selectionLength: selection, count: count)
    }

    func testShortFieldCursorAtEndReadsWholeFieldBefore() {
        let w = windows(9, 0, 9)
        XCTAssertEqual(w.before, NSRange(location: 0, length: 9))
        XCTAssertEqual(w.after, NSRange(location: 9, length: 0))
    }

    func testLongDocumentCursorAtEndReadsLast500() {
        let w = windows(1_500, 0, 1_500)
        XCTAssertEqual(w.before, NSRange(location: 1_000, length: 500))
        XCTAssertEqual(w.after, NSRange(location: 1_500, length: 0))
    }

    func testMiddleOfLongDocumentReads500Before200After() {
        let w = windows(2_500, 0, 5_000)
        XCTAssertEqual(w.before, NSRange(location: 2_000, length: 500))
        XCTAssertEqual(w.after, NSRange(location: 2_500, length: 200))
    }

    func testSelectionIsSkippedForAfterWindow() {
        let w = windows(100, 20, 1_000)
        XCTAssertEqual(w.before, NSRange(location: 0, length: 100))
        XCTAssertEqual(w.after, NSRange(location: 120, length: 200), "游標後從選取結尾開始，不重送選取文字")
    }

    func testUnknownCountStillReadsBeforeButNotAfter() {
        let w = windows(800, 0, nil)
        XCTAssertEqual(w.before, NSRange(location: 300, length: 500), "拿不到欄位總長度也要讀游標前")
        XCTAssertNil(w.after, "拿不到總長度就不送游標後（不是整段放棄）")
    }

    func testWindowsNeverExceedTheField() {
        for count in [0, 1, 9, 199, 200, 499, 500, 501, 700, 5_000] {
            for location in [0, 1, count / 2, max(0, count - 1), count, count + 50] {
                for selection in [0, 3] {
                    let w = windows(location, selection, count)
                    XCTAssertGreaterThanOrEqual(w.before.location, 0)
                    XCTAssertLessThanOrEqual(NSMaxRange(w.before), count, "before 超出欄位 count=\(count) loc=\(location)")
                    XCTAssertLessThanOrEqual(w.before.length, ContextBounds.beforeCursorLimit)
                    if let after = w.after {
                        XCTAssertLessThanOrEqual(NSMaxRange(after), count, "after 超出欄位 count=\(count) loc=\(location)")
                        XCTAssertLessThanOrEqual(after.length, ContextBounds.afterCursorLimit)
                    }
                }
            }
        }
    }

    func testCursorAtStartHasEmptyBefore() {
        let w = windows(0, 0, 50)
        XCTAssertEqual(w.before, NSRange(location: 0, length: 0))
        XCTAssertEqual(w.after, NSRange(location: 0, length: 50))
    }

    func testSelectionPastEndHasNoAfter() {
        XCTAssertNil(windows(10, 5, 12).after, "選取結尾超出欄位（AX 回報不一致）就不讀游標後")
    }

    func testClampKeepsTheEndNearestTheCursor() {
        let before = "頭" + String(repeating: "中", count: 600) + "尾"
        let clamped = ContextBounds.clampBeforeCursor(before)
        XCTAssertEqual(clamped.count, 500)
        XCTAssertTrue(clamped.hasSuffix("尾"), "游標前留最靠近游標的那一端")
        XCTAssertFalse(clamped.contains("頭"))

        let after = "頭" + String(repeating: "中", count: 300) + "尾"
        let clampedAfter = ContextBounds.clampAfterCursor(after)
        XCTAssertEqual(clampedAfter.count, 200)
        XCTAssertTrue(clampedAfter.hasPrefix("頭"), "游標後留緊接游標的那一端")
        XCTAssertFalse(clampedAfter.contains("尾"))

        XCTAssertEqual(ContextBounds.clampBeforeCursor(nil), "")
        XCTAssertEqual(ContextBounds.clampAfterCursor("  短句  "), "短句")
    }

    func testAfterCursorAppearsInPromptSummary() {
        let context = LimitedAppContext(surroundingText: "前文", textAfterCursor: "後文")
        XCTAssertTrue(context.promptSummary.contains("surrounding=前文"))
        XCTAssertTrue(context.promptSummary.contains("after=後文"))
        XCTAssertFalse(LimitedAppContext(surroundingText: "前文").promptSummary.contains("after="))
    }
}
