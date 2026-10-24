import AppKit
import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// context-awareness-1（2026-10-22）：用真的 NSTextView 驗證 AXStringForRange 的行為。
/// `accessibilityString(for:)` 就是 AX 的 kAXStringForRangeParameterizedAttribute 在 AppKit 這一端的實作：
/// 範圍超出欄位就回 nil。舊算法一律請求 [loc-1000, sel+2000]，短欄位、游標在結尾都讀不到前文。
@MainActor
final class CursorContextWindowTests: XCTestCase {

    private func textView(_ text: String, cursor: Int) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.string = text
        view.setSelectedRange(NSRange(location: cursor, length: 0))
        return view
    }

    /// 舊算法（2026-10-22 前 AccessibilitySupport.boundedSurroundingText）的請求範圍。
    private func oldRange(location: Int, selection: Int) -> NSRange {
        NSRange(location: max(0, location - 1_000), length: selection + 1_000 * 2)
    }

    private func read(_ view: NSTextView) -> (before: String?, after: String?) {
        let selection = view.accessibilitySelectedTextRange()
        let windows = ContextBounds.cursorWindows(location: selection.location, selectionLength: selection.length,
                                                  count: view.accessibilityNumberOfCharacters())
        let before = view.accessibilityString(for: windows.before)
        let after = windows.after.flatMap { view.accessibilityString(for: $0) }
        return (before, after)
    }

    func testShortChatFieldCursorAtEnd() {
        let view = textView("好啊，那我們明天見", cursor: 9)
        XCTAssertNil(view.accessibilityString(for: oldRange(location: 9, selection: 0)), "舊範圍超出欄位：讀不到")
        XCTAssertEqual(read(view).before, "好啊，那我們明天見")
        XCTAssertEqual(read(view).after ?? "", "")
    }

    func testLongDocumentCursorAtEnd() {
        let text = String(repeating: "字", count: 1_499) + "尾"
        let view = textView(text, cursor: 1_500)
        XCTAssertNil(view.accessibilityString(for: oldRange(location: 1_500, selection: 0)))
        let before = read(view).before
        XCTAssertEqual(before?.count, 500)
        XCTAssertTrue(before?.hasSuffix("尾") == true, "讀到的是游標正前方那 500 字")
    }

    func testMiddleOfDocumentReadsBothSides() {
        let text = String(repeating: "前", count: 1_000) + String(repeating: "後", count: 1_000)
        let view = textView(text, cursor: 1_000)
        let (before, after) = read(view)
        XCTAssertEqual(before, String(repeating: "前", count: 500))
        XCTAssertEqual(after, String(repeating: "後", count: 200))
    }
}
