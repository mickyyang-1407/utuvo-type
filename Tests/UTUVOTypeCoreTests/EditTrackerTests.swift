import XCTest
@testable import UTUVOTypeCore

/// 插入後追蹤使用者修改（2026-10-13 對齊 Typeless）。
final class EditTrackerTests: XCTestCase {
    private func pairs(_ a: String, _ b: String) -> [String] {
        EditTracker.corrections(inserted: a, current: b).map { "\($0.from)→\($0.to)" }
    }

    func testChineseHomophoneFixesBecomeTwoCharacterWords() {
        XCTAssertEqual(pairs("我搭到元山站以後再換車，悠悠卡記得先除值",
                             "我搭到圓山站以後再換車，悠遊卡記得先儲值"),
                       ["元山→圓山", "悠卡→遊卡", "除值→儲值"])
    }

    func testEnglishFixExpandsToWholeWord() {
        XCTAssertEqual(pairs("跟 Pro Tool 的 session 備份", "跟 Pro Tools 的 session 備份"), [],
                       "純補字（加 s）不是錯字替換，不學")
        XCTAssertEqual(pairs("確認 Atmus 的交付規格", "確認 Atmos 的交付規格"), ["Atmus→Atmos"])
    }

    func testLargeRewriteIsNotTracked() {
        XCTAssertEqual(pairs("明天下午三點在公司見", "改成後天早上十點線上開會好了"), [])
    }

    func testPureDeletionAndUnchangedAreNotTracked() {
        XCTAssertEqual(pairs("嗯我們明天見", "我們明天見"), [])
        XCTAssertEqual(pairs("一模一樣", "一模一樣"), [])
        XCTAssertEqual(pairs("", "x"), [])
    }

    func testPunctuationOnlyChangesIgnored() {
        XCTAssertEqual(pairs("好的，明天見。", "好的！明天見？"), [])
    }
}
