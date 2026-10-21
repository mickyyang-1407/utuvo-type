import XCTest
@testable import UTUVOTypeCore

/// 2026-10-13 對齊 Typeless：使用數據、富文字條列、網頁脈絡與敏感網站。
final class TypelessParityTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: - UsageStats

    func testWordCountMixesChineseCharactersAndEnglishWords() {
        XCTAssertEqual(UsageStats.wordCount("我想後天寄"), 5)
        XCTAssertEqual(UsageStats.wordCount("確認 Atmos 的交付規格。"), 2 + 1 + 5)
        XCTAssertEqual(UsageStats.wordCount("don't send the e-mail, OK?"), 5)
        XCTAssertEqual(UsageStats.wordCount("，。！？ ... "), 0)
    }

    func testRecordAccumulatesPerDayAndIgnoresEmpty() {
        var s = UsageStats()
        s.record(text: "你好", seconds: 2, on: day(2026, 10, 13), calendar: calendar)
        s.record(text: "再見了", seconds: 3, on: day(2026, 10, 13, hour: 23), calendar: calendar)
        s.record(text: "。", seconds: 9, on: day(2026, 10, 13), calendar: calendar)
        XCTAssertEqual(s.days["2026-10-13"], .init(words: 5, seconds: 5, sessions: 2))
        XCTAssertEqual(s.totalWords, 5)
        XCTAssertEqual(s.averageWordsPerMinute, 60, accuracy: 0.001)
    }

    func testTimeSavedNeverNegativeAndUsesFortyWPM() {
        var s = UsageStats()
        s.record(text: String(repeating: "字", count: 80), seconds: 30, on: day(2026, 10, 1), calendar: calendar)
        XCTAssertEqual(s.secondsSaved, 120 - 30, accuracy: 0.001)   // 80 字 ÷ 40 字/分 = 2 分鐘
        var slow = UsageStats()
        slow.record(text: "字", seconds: 600, on: day(2026, 10, 1), calendar: calendar)
        XCTAssertEqual(slow.secondsSaved, 0)
    }

    func testStreaks() {
        var s = UsageStats()
        for d in [1, 2, 3, 5, 6, 12, 13] { s.record(text: "字", seconds: 1, on: day(2026, 10, d), calendar: calendar) }
        XCTAssertEqual(s.longestStreak(calendar: calendar), 3)
        XCTAssertEqual(s.currentStreak(today: day(2026, 10, 13), calendar: calendar), 2)
        XCTAssertEqual(s.currentStreak(today: day(2026, 10, 14), calendar: calendar), 2, "今天還沒講話不歸零")
        XCTAssertEqual(s.currentStreak(today: day(2026, 10, 15), calendar: calendar), 0)
        XCTAssertEqual(s.activeDays, 7)
    }

    func testHeatmapEndsTodayAndHasWholeWeeks() {
        var s = UsageStats()
        s.record(text: "你好", seconds: 1, on: day(2026, 10, 13), calendar: calendar)
        let cells = s.dailyWords(endingOn: day(2026, 10, 13), weeks: 2, calendar: calendar)
        XCTAssertEqual(cells.count, 14)
        XCTAssertEqual(cells.last?.words, 2)
        XCTAssertEqual(cells.first?.words, 0)
    }

    func testStatsRoundTripJSONWithoutContent() throws {
        var s = UsageStats()
        s.record(text: "秘密內容不能存", seconds: 1, on: day(2026, 10, 13), calendar: calendar)
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        XCTAssertFalse(json.contains("秘密"), "只存數字，不存文字")
        XCTAssertEqual(try JSONDecoder().decode(UsageStats.self, from: Data(json.utf8)), s)
    }

    // MARK: - RichTextShape

    func testPlainSentenceHasNoHTML() {
        XCTAssertNil(RichTextShape.html(for: "我想後天寄，然後記得帶硬碟跟耳機"))
        XCTAssertNil(RichTextShape.html(for: "第一段。\n\n第二段。"))
        XCTAssertNil(RichTextShape.html(for: "3.5 公斤很重\n1.0 版再說"), "小數不是條列")
    }

    func testNumberedListBecomesOrderedListWithParagraphs() {
        let html = RichTextShape.html(for: "明天要做三件事：\n\n1. 寄母帶給客戶。\n2. 確認 Atmos 的交付規格。\n3. 跟 Pro Tools 的 session 備份。")
        XCTAssertEqual(html, "<meta charset=\"utf-8\"><p>明天要做三件事：</p><ol><li>寄母帶給客戶。</li><li>確認 Atmos 的交付規格。</li><li>跟 Pro Tools 的 session 備份。</li></ol>")
    }

    func testBulletsChineseNumeralsAndEscaping() {
        XCTAssertEqual(RichTextShape.html(for: "- A <b>\n- B & C"),
                       "<meta charset=\"utf-8\"><ul><li>A &lt;b&gt;</li><li>B &amp; C</li></ul>")
        XCTAssertEqual(RichTextShape.html(for: "1、買牛奶\n2、繳電費"),
                       "<meta charset=\"utf-8\"><ol><li>買牛奶</li><li>繳電費</li></ol>")
    }

    // MARK: - 網頁脈絡

    func testPageLocationDropsQueryCredentialsAndNonWeb() {
        // 帳密段在執行時組，免得原始碼裡出現像憑證的字面（HygieneTests 會擋）。
        let withCredentials = "https://" + ["u", "p"].joined(separator: ":") + "@Mail.Google.com/mail/u/0/?q=x#inbox"
        XCTAssertEqual(ContextBounds.pageLocation(from: withCredentials), "mail.google.com/mail/u/0/")
        XCTAssertEqual(ContextBounds.pageLocation(from: "https://www.notion.so/"), "www.notion.so")
        XCTAssertNil(ContextBounds.pageLocation(from: "file:///Users/me/secret.txt"))
        XCTAssertNil(ContextBounds.pageLocation(from: "not a url"))
        let long = "https://a.com/" + String(repeating: "p", count: 500)
        XCTAssertEqual(ContextBounds.pageLocation(from: long)?.count, ContextBounds.pageLocationLimit)
    }

    func testBlockedSitesMatchDomainAndSubdomainsOnly() {
        let list = ["paypal.com", "https://accounts.google.com/"]
        XCTAssertTrue(ContextBounds.isBlocked(pageLocation: "www.paypal.com/checkout", blockedSites: list))
        XCTAssertTrue(ContextBounds.isBlocked(pageLocation: "accounts.google.com/signin", blockedSites: list))
        XCTAssertFalse(ContextBounds.isBlocked(pageLocation: "notpaypal.com/x", blockedSites: list))
        XCTAssertFalse(ContextBounds.isBlocked(pageLocation: "mail.google.com/mail", blockedSites: list))
        XCTAssertFalse(ContextBounds.isBlocked(pageLocation: nil, blockedSites: list))
        // luna-review r4：清單項目含路徑也擋整個網域
        XCTAssertTrue(ContextBounds.isBlocked(pageLocation: "mail.google.com/mail/u/1", blockedSites: ["https://mail.google.com/mail/u/0/"]))
        // 不確定的情況：有清單就偏向擋；非瀏覽器的 Electron 網頁不擋
        XCTAssertTrue(ContextBounds.shouldBlock(.unknown, isBrowser: false, blockedSites: list))
        XCTAssertFalse(ContextBounds.shouldBlock(.unknown, isBrowser: true, blockedSites: []))
        XCTAssertTrue(ContextBounds.shouldBlock(.webArea(url: "chrome-extension://abc/popup.html"), isBrowser: true, blockedSites: list))
        XCTAssertTrue(ContextBounds.shouldBlock(.webArea(url: nil), isBrowser: true, blockedSites: list))
        XCTAssertFalse(ContextBounds.shouldBlock(.webArea(url: "app://slack/client"), isBrowser: false, blockedSites: list))
        XCTAssertFalse(ContextBounds.shouldBlock(.webArea(url: "https://mail.google.com/mail"), isBrowser: true, blockedSites: list))
        XCTAssertTrue(ContextBounds.shouldBlock(.webArea(url: "https://www.paypal.com/x?y=1"), isBrowser: true, blockedSites: list))
        XCTAssertFalse(ContextBounds.shouldBlock(.notWeb, isBrowser: true, blockedSites: list))
        XCTAssertTrue(ContextBounds.isBrowser(bundleIdentifier: "company.thebrowser.Browser"))
        XCTAssertFalse(ContextBounds.isBrowser(bundleIdentifier: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(ContextBounds.defaultBlockedSites.contains("1password.com"))
    }

    func testPromptSummaryIncludesNewFields() {
        let c = LimitedAppContext(appName: "Chrome", windowTitle: "Inbox", pageLocation: "mail.google.com/mail", fieldPlaceholder: "Reply")
        XCTAssertTrue(c.promptSummary.contains("page=mail.google.com/mail"))
        XCTAssertTrue(c.promptSummary.contains("window=Inbox"))
        XCTAssertTrue(c.promptSummary.contains("placeholder=Reply"))
    }
}
