import XCTest
@testable import UTUVOTypeiOS

/// 歷史頁分日／搜尋（對齊 Typeless 歷史）的純邏輯。
final class HistoryGroupingTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        c.locale = Locale(identifier: "zh_TW")
        return c
    }()
    private let locale = Locale(identifier: "zh_TW")

    /// 2026-09-17 12:00 台北。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 12))!
    }

    private func record(_ text: String, daysAgo: Int, hour: Int = 10, starred: Bool = false, raw: String? = nil) -> DictationRecord {
        let base = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
        return DictationRecord(date: date, raw: raw ?? text, cleaned: text, starred: starred)
    }

    // MARK: - 分日

    func testSectionsGroupByDayNewestFirst() {
        let records = [
            record("三天前", daysAgo: 3),
            record("今天早", daysAgo: 0, hour: 8),
            record("昨天", daysAgo: 1),
            record("今天晚", daysAgo: 0, hour: 20),
        ]
        let sections = HistoryGrouping.sections(records, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(sections.map(\.title), ["今天", "昨天", "9月14日 週一"])
        XCTAssertEqual(sections[0].records.map(\.cleaned), ["今天晚", "今天早"], "同一天內最新的在前")
    }

    func testDayTitleIncludesYearOnlyWhenDifferentYear() {
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!
        XCTAssertEqual(HistoryGrouping.dayTitle(for: lastYear, now: now, calendar: calendar, locale: locale), "2025年12月31日 週三")
        let sameYear = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        XCTAssertEqual(HistoryGrouping.dayTitle(for: sameYear, now: now, calendar: calendar, locale: locale), "1月5日 週一")
    }

    /// 午夜前後兩筆要落在不同日；同一天 00:00 與 23:59 要在同一日。
    func testMidnightBoundary() {
        let lateYesterday = record("昨晚", daysAgo: 1, hour: 23)
        let earlyToday = record("今早", daysAgo: 0, hour: 0)
        let sections = HistoryGrouping.sections([lateYesterday, earlyToday], now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "今天")
        XCTAssertEqual(sections[1].title, "昨天")
    }

    func testEmptyInputGivesNoSections() {
        XCTAssertTrue(HistoryGrouping.sections([], now: now, calendar: calendar, locale: locale).isEmpty)
    }

    // MARK: - 搜尋

    func testEmptyQueryKeepsEverything() {
        let records = [record("甲", daysAgo: 0), record("乙", daysAgo: 1)]
        XCTAssertEqual(HistoryGrouping.filter(records, query: "").count, 2)
        XCTAssertEqual(HistoryGrouping.filter(records, query: "   ").count, 2, "只有空白＝沒在搜")
    }

    func testQueryMatchesCleanedOrRawCaseInsensitive() {
        let records = [
            record("Meeting at three", daysAgo: 0),
            record("清理後沒有這個字", daysAgo: 0, raw: "嗯 原始有 Keyword 在這"),
            record("完全不相干", daysAgo: 0),
        ]
        XCTAssertEqual(HistoryGrouping.filter(records, query: "MEETING").map(\.cleaned), ["Meeting at three"])
        XCTAssertEqual(HistoryGrouping.filter(records, query: "keyword").map(\.cleaned), ["清理後沒有這個字"], "raw 也要搜得到")
    }

    func testMultipleTermsMustAllMatch() {
        let records = [
            record("明天下午三點開會", daysAgo: 0),
            record("明天早上", daysAgo: 0),
            record("下午三點", daysAgo: 0),
        ]
        XCTAssertEqual(HistoryGrouping.filter(records, query: "明天 三點").map(\.cleaned), ["明天下午三點開會"])
    }

    func testFullWidthAndHalfWidthMatch() {
        let records = [record("ＡＢＣ 全形", daysAgo: 0)]
        XCTAssertEqual(HistoryGrouping.filter(records, query: "abc").count, 1)
    }

    func testStarredOnlyFilter() {
        let records = [record("星", daysAgo: 0, starred: true), record("無", daysAgo: 0)]
        XCTAssertEqual(HistoryGrouping.filter(records, query: "", starredOnly: true).map(\.cleaned), ["星"])
        XCTAssertEqual(HistoryGrouping.filter(records, query: "無", starredOnly: true).count, 0, "星標＋搜尋要同時成立")
    }

    // MARK: - 改寫紀錄

    func testEditRecordFactoryAndFlag() {
        let r = DictationRecord.edit(instruction: "改成正式一點", result: "敬啟者", source: .app)
        XCTAssertEqual(r.raw, "改：改成正式一點")
        XCTAssertEqual(r.cleaned, "敬啟者")
        XCTAssertTrue(r.isEdit)
        XCTAssertFalse(DictationRecord(raw: "普通", cleaned: "普通").isEdit)
    }
}
