import XCTest
@testable import UTUVOTypeiOS

/// 工單 ios-A：使用數據、歷史保留期限、字典分頁的新邏輯測試。
/// 純函式（字數、連續天數、熱圖、保留篩選）＋ DailyUsageStore 的讀-改-寫合併。
final class UsageStatsTests: XCTestCase {

    // MARK: - 工具

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 固定時區的 Calendar（跨時區日界測試用；不跟著模擬器／手機設定走）。
    private func calendar(tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = 1   // 星期日
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0,
                      tz: String = "Asia/Taipei") -> Date {
        var c = calendar(tz: tz)
        c.timeZone = TimeZone(identifier: tz)!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 字數計算

    func testWordCountChinesePerCharacter() {
        XCTAssertEqual(UsageText.wordCount("今天天氣很好"), 6, "中文逐字算")
        XCTAssertEqual(UsageText.wordCount(""), 0)
        XCTAssertEqual(UsageText.wordCount("，。！？"), 0, "標點不算字")
    }

    func testWordCountLatinSplitsOnWhitespace() {
        XCTAssertEqual(UsageText.wordCount("hello world"), 2)
        XCTAssertEqual(UsageText.wordCount("hello, world!"), 2, "標點斷詞")
        XCTAssertEqual(UsageText.wordCount("  hello   world  "), 2, "多重空白算同一個分隔")
    }

    func testWordCountMixedChineseLatin() {
        // 2 個中文字 + hello world（2 個詞）
        XCTAssertEqual(UsageText.wordCount("你好 hello world"), 4)
    }

    func testWordCountJapaneseAndKorean() {
        XCTAssertEqual(UsageText.wordCount("こんにちは"), 5, "假名逐字算")
        XCTAssertEqual(UsageText.wordCount("안녕하세요"), 5, "韓文逐字算")
    }

    func testUsageInsightsWordCountMatchesNewSingleSource() {
        // 舊的首頁條跟新的每日計數不能各算各的（工單：數字要一致）。
        XCTAssertEqual(UsageInsights.wordCount("你好 hello"), UsageText.wordCount("你好 hello"))
    }

    // MARK: - 每日計數（讀-改-寫合併）

    func testDailyUsageAccumulatesSameDay() {
        let store = DailyUsageStore(directory: makeTempDirectory(), calendar: calendar(tz: "Asia/Taipei"))
        let day = date(2026, 10, 13)
        store.record(words: 10, seconds: 5, at: day)
        store.record(words: 7, seconds: 3, at: day.addingTimeInterval(3600))

        let all = store.load()
        XCTAssertEqual(all.count, 1, "同一天要合併成一筆")
        XCTAssertEqual(all[0].words, 17)
        XCTAssertEqual(all[0].seconds, 8)
        XCTAssertEqual(all[0].sessions, 2)
    }

    func testDailyUsageSeparateDays() {
        let store = DailyUsageStore(directory: makeTempDirectory(), calendar: calendar(tz: "Asia/Taipei"))
        store.record(words: 10, seconds: 5, at: date(2026, 10, 12))
        store.record(words: 4, seconds: 2, at: date(2026, 10, 13))
        XCTAssertEqual(store.load().count, 2)
    }

    func testDailyUsageExclusiveAccessMergesInsteadOfOverwriting() {
        // 鍵盤與主 app 是兩個 process，讀-改-寫必須經檔案鎖才不會互相蓋掉。
        let dir = makeTempDirectory()
        let cal = calendar(tz: "Asia/Taipei")
        let day = date(2026, 10, 13)
        DailyUsageStore(directory: dir, calendar: cal).recordExclusive(words: 5, seconds: 2, at: day)
        DailyUsageStore(directory: dir, calendar: cal).recordExclusive(words: 3, seconds: 1, at: day)

        let all = DailyUsageStore(directory: dir, calendar: cal).load()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].words, 8, "兩次都要算進去，後一次不能覆蓋前一次")
        XCTAssertEqual(all[0].sessions, 2)
    }

    func testDailyUsageEmptyOnMissingFile() {
        let store = DailyUsageStore(directory: makeTempDirectory())
        XCTAssertEqual(store.load().count, 0, "沒有檔案時回空，不要炸")
    }

    func testDailyUsageNegativeSecondsClampedToZero() {
        let store = DailyUsageStore(directory: makeTempDirectory())
        store.record(words: 1, seconds: -3)
        XCTAssertEqual(store.load()[0].seconds, 0)
    }

    // MARK: - 日界（跨時區）

    func testDayKeyUsesLocalTimezoneBoundary() {
        // 同一瞬間：UTC 2026-10-13 23:30 → 台北 10-14 07:30、紐約 10-13 19:30。
        let instant = date(2026, 10, 13, 23, 30, tz: "UTC")
        let taipei = UsageDay.string(from: instant, calendar: calendar(tz: "Asia/Taipei"))
        let newYork = UsageDay.string(from: instant, calendar: calendar(tz: "America/New_York"))
        XCTAssertEqual(taipei, "2026-10-14")
        XCTAssertEqual(newYork, "2026-10-13", "換時區就是換日，同一瞬間兩個日子")
    }

    func testRecordUsesConfiguredCalendarForDayKey() {
        let dir = makeTempDirectory()
        let instant = date(2026, 10, 13, 23, 30, tz: "UTC")
        DailyUsageStore(directory: dir, calendar: calendar(tz: "Asia/Taipei")).record(words: 1, seconds: 1, at: instant)
        DailyUsageStore(directory: dir, calendar: calendar(tz: "America/New_York")).record(words: 2, seconds: 1, at: instant)

        let days = DailyUsageStore(directory: dir).load().map(\.day).sorted()
        XCTAssertEqual(days, ["2026-10-13", "2026-10-14"], "同一瞬間在兩個時區算兩個日子的用量")
    }

    func testUsageDayRoundTripHonoursCalendarTimezone() {
        // 「2026-10-14」在台北要解析成台北的午夜（UTC 10-13 16:00），不是 UTC 午夜。
        let key = "2026-10-14"
        let taipeiMidnight = date(2026, 10, 14, 0, tz: "Asia/Taipei")
        let nyMidnight = date(2026, 10, 14, 0, tz: "America/New_York")
        let parsed = UsageDay.date(from: key, calendar: calendar(tz: "Asia/Taipei"))
        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0, taipeiMidnight.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotEqual(parsed?.timeIntervalSince1970, nyMidnight.timeIntervalSince1970,
                          "同一個日期字串在兩個時區要解析成不同的瞬間（相差 12 小時）")
    }

    // MARK: - 彙總

    func testSummaryAggregates() {
        let s = UsageCalculator.summary(for: [
            DailyUsage(day: "2026-10-11", words: 100, seconds: 60, sessions: 2),
            DailyUsage(day: "2026-10-12", words: 50, seconds: 30, sessions: 1),
        ])
        XCTAssertEqual(s.totalWords, 150)
        XCTAssertEqual(s.sessions, 3)
        XCTAssertEqual(s.totalSeconds, 90)
        XCTAssertEqual(s.activeDays, 2)
        XCTAssertEqual(s.wordsPerMinute ?? 0, 100, accuracy: 0.001, "150 字 / 1.5 分 = 100 WPM")
    }

    func testSummaryEmptyHasNoWPM() {
        let s = UsageCalculator.summary(for: [])
        XCTAssertNil(s.wordsPerMinute, "沒有時長就不算 WPM")
        XCTAssertEqual(s.minutesSaved, 0)
        XCTAssertEqual(s.currentStreak, 0)
        XCTAssertEqual(s.longestStreak, 0)
    }

    func testMinutesSavedUsesTyping40WPMAndFloorsAtZero() {
        // 40 字，打字要 1 分鐘；說話只花 0.2 分鐘 → 省 0.8 分鐘。
        let good = UsageCalculator.summary(for: [DailyUsage(day: "2026-10-13", words: 40, seconds: 12, sessions: 1)])
        XCTAssertEqual(good.minutesSaved, 0.8, accuracy: 0.0001)
        // 說得比打字還慢（講了 2 分鐘才出 40 字，打字只要 1 分鐘）→ 省下來是 0，不是負數。
        let slow = UsageCalculator.summary(for: [DailyUsage(day: "2026-10-13", words: 40, seconds: 120, sessions: 1)])
        XCTAssertEqual(slow.minutesSaved, 0, "下限 0")
    }

    func testZeroSecondsDoesNotCountAsWPM() {
        let s = UsageCalculator.summary(for: [DailyUsage(day: "2026-10-13", words: 40, seconds: 0, sessions: 1)])
        XCTAssertNil(s.wordsPerMinute, "沒時長的次數不算進平均速度")
        XCTAssertEqual(s.totalWords, 40, "但字數還是要算")
    }

    // MARK: - 連續天數

    func testStreakConsecutiveDaysEndingToday() {
        let cal = calendar(tz: "Asia/Taipei")
        let now = date(2026, 10, 13, 10)
        let r = UsageCalculator.streaks(daySet: ["2026-10-11", "2026-10-12", "2026-10-13"],
                                         now: now, calendar: cal)
        XCTAssertEqual(r.current, 3)
        XCTAssertEqual(r.longest, 3)
    }

    func testStreakAllowsTodayBeingUnused() {
        // 今天還沒講話不算斷（很多人晚上才用）。
        let cal = calendar(tz: "Asia/Taipei")
        let now = date(2026, 10, 13, 8)
        let r = UsageCalculator.streaks(daySet: ["2026-10-11", "2026-10-12"], now: now, calendar: cal)
        XCTAssertEqual(r.current, 2, "昨天以前是連續的，今天沒用不該斷")
    }

    func testStreakBrokenByGap() {
        let cal = calendar(tz: "Asia/Taipei")
        let now = date(2026, 10, 13, 10)
        let r = UsageCalculator.streaks(daySet: ["2026-10-05", "2026-10-10", "2026-10-11", "2026-10-13"], now: now, calendar: cal)
        XCTAssertEqual(r.current, 1, "只有今天算，中間斷了")
        XCTAssertEqual(r.longest, 2, "10/10–10/11 是兩天")
    }

    func testStreakLongestAcrossMonthBoundary() {
        let cal = calendar(tz: "Asia/Taipei")
        let now = date(2026, 11, 2, 10)
        let r = UsageCalculator.streaks(daySet: ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"], now: now, calendar: cal)
        XCTAssertEqual(r.current, 4, "跨月要算連續")
        XCTAssertEqual(r.longest, 4)
    }

    func testStreakAcrossTimezoneDayBoundary() {
        // 台北 10/14 01:00、紐約 10/13 13:00 是同一瞬間；日界不同，連續計算要各按當地日界。
        let instant = date(2026, 10, 14, 1, tz: "Asia/Taipei")
        let taipei = UsageCalculator.streaks(
            daySet: ["2026-10-13", "2026-10-14"], now: instant, calendar: calendar(tz: "Asia/Taipei"))
        XCTAssertEqual(taipei.current, 2)
        let newYork = UsageCalculator.streaks(
            daySet: ["2026-10-12", "2026-10-13"], now: instant, calendar: calendar(tz: "America/New_York"))
        XCTAssertEqual(newYork.current, 2, "在紐約看是 10/13 當天，連續兩天")
    }

    func testStreakEmptyIsZero() {
        XCTAssertEqual(UsageCalculator.streaks(daySet: [], now: Date()).current, 0)
        XCTAssertEqual(UsageCalculator.streaks(daySet: [], now: Date()).longest, 0)
    }

    func testZeroCountDayDoesNotCountAsActive() {
        let all = [DailyUsage(day: "2026-10-13", words: 0, seconds: 0, sessions: 0)]
        XCTAssertEqual(UsageCalculator.activeDaySet(all).count, 0, "全 0 的日子不算活躍")
    }

    // MARK: - 熱圖

    func testHeatmapHas26WeeksOf7Days() {
        let cal = calendar(tz: "Asia/Taipei")
        let columns = ActivityHeatmap.cells(for: [], now: date(2026, 10, 14, 10), calendar: cal)
        XCTAssertEqual(columns.count, 26)
        XCTAssertTrue(columns.allSatisfy { $0.count == 7 })
        XCTAssertEqual(columns.flatMap { $0 }.count, 182)
    }

    func testHeatmapWeekIsColumnDayIsRow() {
        let cal = calendar(tz: "Asia/Taipei")
        // 2026-10-14 是星期三 → 這一欄是 10/11(週日)、10/12、10/13、10/14…
        let columns = ActivityHeatmap.cells(for: [], now: date(2026, 10, 14, 10), calendar: cal)
        let last = columns[25]
        XCTAssertEqual(last[0].day, "2026-10-11", "每欄第一格是該週星期日")
        XCTAssertEqual(last[3].day, "2026-10-14")
        XCTAssertEqual(columns[24][0].day, "2026-10-04", "往前一欄是上一週")
    }

    func testHeatmapCellCountsAndLevels() {
        let daily = [
            DailyUsage(day: "2026-10-14", words: 100, seconds: 0, sessions: 1),
            DailyUsage(day: "2026-10-13", words: 25, seconds: 0, sessions: 0),
        ]
        // `now` 固定在 10/15：2026-10-13 修補後今天之後的格子標 isFuture（不畫），
        // 這裡要驗的是「有活動的日子有正確的字數與階級」，所以把「今天」釘在樣本之後。
        let leveled = ActivityHeatmap.leveled(daily, now: date(2026, 10, 15, 10))
        let cells = leveled.flatMap { $0 }
        XCTAssertEqual(cells.first { $0.day == "2026-10-14" }?.count, 101)
        XCTAssertEqual(cells.first { $0.day == "2026-10-14" }?.level, 4, "最大值＝滿階")
        XCTAssertEqual(cells.first { $0.day == "2026-10-13" }?.count, 25)
        XCTAssertLessThan(cells.first { $0.day == "2026-10-13" }?.level ?? 0, 4)
        XCTAssertTrue(cells.filter { $0.day == "2026-10-12" }.allSatisfy { $0.level == 0 }, "沒用過＝0 階")
    }

    func testHeatmapLevelThresholds() {
        XCTAssertEqual(ActivityHeatmap.level(for: 0, peak: 100), 0)
        XCTAssertEqual(ActivityHeatmap.level(for: 25, peak: 100), 1)
        XCTAssertEqual(ActivityHeatmap.level(for: 26, peak: 100), 2)
        XCTAssertEqual(ActivityHeatmap.level(for: 51, peak: 100), 3)
        XCTAssertEqual(ActivityHeatmap.level(for: 100, peak: 100), 4)
        XCTAssertEqual(ActivityHeatmap.level(for: 5, peak: 0), 1, "peak 為 0 時任何有活動都給第 1 階")
    }

    /// 2026-10-13 修補：列固定＝星期日～星期六，**不看 `calendar.firstWeekday`**。
    /// 週一開頭的地區（firstWeekday = 2）以前整張圖會錯一列。
    func testHeatmapRowsIgnoreCalendarFirstWeekday() {
        var cal = calendar(tz: "Asia/Taipei")
        cal.firstWeekday = 2   // 週一開頭的地區
        let now = date(2026, 10, 13, 15)   // 2026-10-13 是星期二
        let columns = ActivityHeatmap.cells(for: [], now: now, calendar: cal)

        // 最後一欄＝本週（週日 10/11 起），每欄第一格必須是星期日。
        let last = columns[25]
        XCTAssertEqual(last[0].day, "2026-10-11", "每欄第一格固定是該週星期日")
        XCTAssertEqual(last[1].day, "2026-10-12")
        // 星期二落在**第 2 列**（index 1）的最後一欄，不是別的列。
        XCTAssertEqual(last[2].day, "2026-10-13", "星期二＝列 index 1")
        XCTAssertEqual(columns[24][0].day, "2026-10-04", "往前一欄是上一週的星期日")

        // 逐欄檢查第一格都是星期日（`.weekday` = 1）。
        for (index, column) in columns.enumerated() {
            guard let d = UsageDay.date(from: column[0].day, calendar: cal) else {
                XCTFail("第 \(index) 欄第一格不是合法日期"); continue
            }
            XCTAssertEqual(cal.component(.weekday, from: d), 1, "第 \(index) 欄第一格必須是星期日")
        }
    }

    /// 今天之後的格子不畫（isFuture），level 一律 0。
    func testHeatmapMarksFutureDays() {
        let cal = calendar(tz: "Asia/Taipei")
        let columns = ActivityHeatmap.cells(for: [], now: date(2026, 10, 13, 15), calendar: cal)
        let cells = columns.flatMap { $0 }
        XCTAssertTrue(cells.first { $0.day == "2026-10-13" }?.isFuture == false, "今天要畫")
        for cell in cells where cell.day > "2026-10-13" {
            XCTAssertTrue(cell.isFuture, "\(cell.day) 還沒到，不該畫")
            XCTAssertEqual(cell.level, 0)
        }
        for cell in cells where cell.day <= "2026-10-13" {
            XCTAssertFalse(cell.isFuture, "\(cell.day) 已經過或就是今天")
        }
    }

    // MARK: - 錄音秒數（DictationClock）

    /// 秒數在**錄音結束那一刻**凍結；交付晚多久都不影響記錄。
    func testDictationClockFreezesAtStopNotAtDelivery() {
        var clock = DictationClock()
        let start = date(2026, 10, 13, 10, 0)
        clock.begin(at: start)
        // 按停：講了 8 秒
        clock.freeze(at: start.addingTimeInterval(8))
        // 交付：又過了 20 秒的雲端等待
        let delivered = clock.take()
        XCTAssertEqual(delivered ?? 0, 8, accuracy: 0.001, "交付要讀凍結值，不是交付當下重算")
        XCTAssertNil(clock.take(), "讀完就清空，下一段從零開始")
    }

    /// 重複 freeze 安全（早退路徑常常連呼叫兩次），而且不會被後來的時間蓋掉。
    func testDictationClockFreezeIsIdempotent() {
        var clock = DictationClock()
        let start = date(2026, 10, 13, 10, 0)
        clock.begin(at: start)
        XCTAssertEqual(clock.freeze(at: start.addingTimeInterval(5)) ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(clock.freeze(at: start.addingTimeInterval(99)) ?? 0, 5, accuracy: 0.001, "已凍結就不再被蓋掉")
        XCTAssertEqual(clock.take() ?? 0, 5, accuracy: 0.001)
    }

    /// 保持開啟模式：一段接一段，每段各自算自己的秒數（`begin` 清掉上一段）。
    func testDictationClockEachSegmentCountsSeparately() {
        var clock = DictationClock()
        let start = date(2026, 10, 13, 10, 0)
        clock.begin(at: start)
        clock.freeze(at: start.addingTimeInterval(3))
        XCTAssertEqual(clock.take() ?? 0, 3, accuracy: 0.001)

        // 第二段：晚 1 分鐘才開始，講 4 秒
        let second = start.addingTimeInterval(60)
        clock.begin(at: second)
        clock.freeze(at: second.addingTimeInterval(4))
        XCTAssertEqual(clock.take() ?? 0, 4, accuracy: 0.001, "第二段算自己的，不會跟第一段相加或被殘值汙染")
    }

    /// 沒開始過就 freeze → nil（＝未知，不是 0 秒）。
    func testDictationClockWithoutBeginIsUnknown() {
        var clock = DictationClock()
        XCTAssertNil(clock.freeze(at: Date()))
        XCTAssertNil(clock.take())
    }

    /// 短於 0.5 秒＝按到手滑，回 nil（＝未知，不是 0 秒）。
    func testDictationClockRejectsTooShortTake() {
        var clock = DictationClock()
        let start = date(2026, 10, 13, 10, 0)
        clock.begin(at: start)
        clock.freeze(at: start.addingTimeInterval(0.2))
        XCTAssertNil(clock.take())
        XCTAssertNil(DictationClock.elapsed(from: start, to: start.addingTimeInterval(0.4)))
        XCTAssertEqual(DictationClock.elapsed(from: start, to: start.addingTimeInterval(3)) ?? 0, 3, accuracy: 0.001)
        XCTAssertNil(DictationClock.elapsed(from: start, to: start.addingTimeInterval(-5)), "時鐘倒退不算")
    }

    // MARK: - 手動詞維持手動

    /// 2026-10-13 修補：使用者手動加過的詞，被自動學到時維持手動（不被搬到「自動」分頁）。
    func testManualEntryStaysManualWhenAutoLearned() {
        // 字典裡有、但不在自動名單裡（＝手動）→ 不要標成自動
        XCTAssertFalse(LearnedVocabulary.shouldMarkAutoLearned(source: "pik", inDictionary: true,
                                                              autoLearned: ["Atmos"]),
                       "手動加過的詞維持手動")
        // 字典裡沒有 → 這次自動學到的，照標
        XCTAssertTrue(LearnedVocabulary.shouldMarkAutoLearned(source: "Atmos", inDictionary: false,
                                                              autoLearned: []))
        // 已經是自動學到的 → 標記可重複寫（冪等），回 true 也無妨
        XCTAssertTrue(LearnedVocabulary.shouldMarkAutoLearned(source: "Atmos", inDictionary: true,
                                                              autoLearned: ["Atmos"]))
    }

    /// 忽略清單的 key 口徑：同一組修正被忽略後就不該再學回來，不同修正不連坐。
    /// （`removeFromDictionary` 本身動 App Group，真跑會汙到模擬器的真實資料，
    ///   所以這裡只釘住它依賴的純邏輯；共用同一個函式由 code review 保証。）
    func testIgnoreListKeySemantics() {
        let key = LearnedVocabulary.key(for: "pik", right: "Pik")
        XCTAssertEqual(key, LearnedVocabulary.key(for: "pik", right: "Pik"), "同一組修正同一個 key")
        XCTAssertNotEqual(key, LearnedVocabulary.key(for: "pik", right: "Pick"), "不同修正不連坐")
        XCTAssertTrue(LearnedVocabulary.shouldLearn(wrong: "pik", right: "Pik"), "沒被忽略時可以學")
    }

    // MARK: - 保留期限

    func testRetentionForeverKeepsEverything() {
        let now = date(2026, 10, 13)
        let old = DictationRecord(date: now.addingTimeInterval(-400 * 86_400), raw: "舊", cleaned: "舊")
        XCTAssertEqual(RetentionPolicy.filter([old], policy: .forever, now: now).count, 1)
    }

    func testRetentionOneDayDropsOlder() {
        let now = date(2026, 10, 13)
        let fresh = DictationRecord(date: now.addingTimeInterval(-3600), raw: "新", cleaned: "新")
        let old = DictationRecord(date: now.addingTimeInterval(-48 * 3600), raw: "舊", cleaned: "舊")
        XCTAssertEqual(RetentionPolicy.filter([fresh, old], policy: .day, now: now).map(\.raw), ["新"])
    }

    func testRetentionDropsStarredToo() {
        let now = date(2026, 10, 13)
        var starred = DictationRecord(date: now.addingTimeInterval(-48 * 3600), raw: "星號", cleaned: "星號")
        starred.starred = true
        XCTAssertEqual(RetentionPolicy.filter([starred], policy: .day, now: now).count, 0,
                       "星號不跟期限有特權（工單明講）")
    }

    func testRetentionNoneKeepsNothing() {
        let now = date(2026, 10, 13)
        let fresh = DictationRecord(date: now, raw: "剛剛", cleaned: "剛剛")
        XCTAssertEqual(RetentionPolicy.filter([fresh], policy: .none, now: now).count, 0)
    }

    func testExpiredCount() {
        let now = date(2026, 10, 13)
        // 3 筆在 24 小時內、2 筆超過 1 天。
        let records = [0, 2, 10, 30, 50].map { i in
            DictationRecord(date: now.addingTimeInterval(-Double(i) * 3600), raw: "\(i)", cleaned: "\(i)")
        }
        XCTAssertEqual(RetentionPolicy.expiredCount(records, policy: .day, now: now), 2)
        XCTAssertEqual(RetentionPolicy.expiredCount(records, policy: .forever, now: now), 0)
    }

    func testRetentionEmptyRecords() {
        XCTAssertEqual(RetentionPolicy.filter([], policy: .day).count, 0)
        XCTAssertEqual(RetentionPolicy.expiredCount([], policy: .none), 0)
    }

    // MARK: - 舊資料 decode

    func testLegacyHistoryWithoutDurationStillDecodes() {
        // 舊檔沒有 duration 欄位：decode 不能失敗，duration ＝ nil（＝未知）。
        let json = """
        [{"id":"3B2C7A6E-0000-4000-8000-000000000001","date":1760000000,"raw":"舊的","cleaned":"舊的","starred":true,"source":"keyboard"}]
        """
        let records = try? JSONDecoder().decode([DictationRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records?.count, 1)
        XCTAssertNil(records?.first?.duration)
        XCTAssertNil(records?.first?.knownDuration)
        XCTAssertEqual(records?.first?.cleaned, "舊的")
        XCTAssertEqual(records?.first?.source, .keyboard)
    }

    func testLegacyHistoryWithoutSourceDefaultsToApp() {
        let json = """
        [{"id":"3B2C7A6E-0000-4000-8000-000000000002","date":1760000000,"raw":"a","cleaned":"a"}]
        """
        let records = try? JSONDecoder().decode([DictationRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records?.first?.source, .app, "舊檔沒來源＝主 app 打的")
    }

    func testKnownDurationIgnoresZeroAndNegative() {
        var r = DictationRecord(raw: "a", cleaned: "a", duration: 0)
        XCTAssertNil(r.knownDuration, "0 秒不是有效時長")
        r.duration = -5
        XCTAssertNil(r.knownDuration)
        r.duration = 12
        XCTAssertEqual(r.knownDuration, 12)
    }

    func testLegacyHistoryFileLoadsThroughStore() {
        // 端到端：整份舊 history.json 沒有 duration／source 時，HistoryStore 還是要讀得出來。
        let dir = makeTempDirectory()
        let json = """
        [{"id":"3B2C7A6E-0000-4000-8000-000000000003","date":1760000000,"raw":"甲","cleaned":"甲"},
         {"id":"3B2C7A6E-0000-4000-8000-000000000004","date":1760000100,"raw":"乙","cleaned":"乙","source":"app","duration":8.5}]
        """
        try? Data(json.utf8).write(to: dir.appendingPathComponent("history.json"))

        let loaded = HistoryStore(directory: dir).load()
        XCTAssertEqual(loaded.count, 2, "舊檔不能整份讀不出來")
        XCTAssertNil(loaded.first { $0.raw == "甲" }?.duration)
        XCTAssertEqual(loaded.first { $0.raw == "甲" }?.source, .app)
        XCTAssertEqual(loaded.first { $0.raw == "乙" }?.duration, 8.5)
    }

    func testEmptyHistoryFileLoadsAsEmpty() {
        let dir = makeTempDirectory()
        try? Data("[]".utf8).write(to: dir.appendingPathComponent("history.json"))
        XCTAssertEqual(HistoryStore(directory: dir).load().count, 0)
    }

    // MARK: - 字典：自動來源與已忽略清單

    private let sampleEntries: [(source: String, output: String)] = [
        ("除值", "儲值"),   // 自動學到的
        ("及時", "即時"),   // 自動學到的
        ("Atmos", ""),     // 手動加的詞彙
        ("pik", "Pik"),    // 手動加的替換
    ]

    func testDictionaryTabAllKeepsEverything() {
        let all = DictionarySource.filter(sampleEntries, tab: .all, autoLearned: ["除值", "及時"], query: "")
        XCTAssertEqual(all.count, 4)
    }

    func testDictionaryTabAutoAndManualSplit() {
        let auto = DictionarySource.filter(sampleEntries, tab: .auto, autoLearned: ["除值", "及時"], query: "")
        XCTAssertEqual(Set(auto.map(\.source)), ["除值", "及時"])
        let manual = DictionarySource.filter(sampleEntries, tab: .manual, autoLearned: ["除值", "及時"], query: "")
        XCTAssertEqual(Set(manual.map(\.source)), ["Atmos", "pik"])
    }

    func testDictionaryOldDataWithoutMarkerCountsAsManual() {
        // 舊資料沒有「自動」標記 → 全部落在手動分頁（工單明講）。
        let auto = DictionarySource.filter(sampleEntries, tab: .auto, autoLearned: [], query: "")
        XCTAssertTrue(auto.isEmpty)
        let manual = DictionarySource.filter(sampleEntries, tab: .manual, autoLearned: [], query: "")
        XCTAssertEqual(manual.count, 4)
    }

    func testDictionarySearchIsImmediateAndCaseInsensitive() {
        let hit = DictionarySource.filter(sampleEntries, tab: .all, autoLearned: [], query: "ATMOS")
        XCTAssertEqual(hit.map(\.source), ["Atmos"], "大小寫不敏感")
        let byOutput = DictionarySource.filter(sampleEntries, tab: .all, autoLearned: [], query: "Pik")
        XCTAssertEqual(byOutput.map(\.source), ["pik"], "輸出也要能被搜到")
        let none = DictionarySource.filter(sampleEntries, tab: .all, autoLearned: [], query: "   ")
        XCTAssertEqual(none.count, 4, "全空白等於沒搜")
    }

    func testDictionarySearchCombinesWithTab() {
        let hit = DictionarySource.filter(sampleEntries, tab: .auto, autoLearned: ["除值", "及時"], query: "除")
        XCTAssertEqual(hit.map(\.source), ["除值"])
    }

    func testDictionaryEmptyEntriesAndEmptyQuery() {
        XCTAssertTrue(DictionarySource.filter([], tab: .all, autoLearned: ["x"], query: "y").isEmpty)
    }

    func testIgnoredPairBlocksRelearningButNotOtherPairs() {
        // 同一個錯字換成別的字是新的修正，不該被上一筆的忽略連坐。
        let key = LearnedVocabulary.key(for: "除值", right: "儲值")
        XCTAssertEqual(key, "除值\u{1}儲值")
        XCTAssertNotEqual(key, LearnedVocabulary.key(for: "除值", right: "處置"))
    }

    func testLearnedVocabularyIgnoreRoundTripInAppGroup() {
        // 忽略清單真的寫得進去、讀得回來（App Group 是單一正本）。
        let tag = String(UUID().uuidString.prefix(6))
        let wrong = "忽略\(tag)"
        let right = "對的\(tag)"
        let key = LearnedVocabulary.key(for: wrong, right: right)
        addTeardownBlock { LearnedVocabulary.unignore(key) }

        XCTAssertTrue(LearnedVocabulary.shouldLearn(wrong: wrong, right: right), "預設要能學")
        LearnedVocabulary.markIgnored(key)
        XCTAssertFalse(LearnedVocabulary.shouldLearn(wrong: wrong, right: right), "刪掉過就不能馬上學回來")
        XCTAssertTrue(LearnedVocabulary.ignored.contains(key))
        LearnedVocabulary.unignore(key)
        XCTAssertTrue(LearnedVocabulary.shouldLearn(wrong: wrong, right: right), "移除忽略就恢復")
    }
}