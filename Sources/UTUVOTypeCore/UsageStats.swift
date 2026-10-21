import Foundation

/// 使用數據（2026-10-13，對齊 Typeless「Words dictated／Time saved／Average speed／Activity／Streak」）。
///
/// 只存每天的累計數字（字數、說話秒數、次數），**不存任何文字內容**；歷史紀錄有筆數上限會被刪，
/// 所以數據另外累計，不從歷史回算。全部在這台電腦本機。
public struct UsageStats: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        /// 中文以字計、英數以詞計（跟一般「字數」直覺一致）。
        public var words: Int
        public var seconds: Double
        public var sessions: Int

        public init(words: Int = 0, seconds: Double = 0, sessions: Int = 0) {
            self.words = words
            self.seconds = seconds
            self.sessions = sessions
        }
    }

    /// key＝當地日期 "yyyy-MM-dd"。
    public var days: [String: Day]

    public init(days: [String: Day] = [:]) {
        self.days = days
    }

    /// 打字基準速度（每分鐘字數）：拿來算「省下的時間」。
    /// 中文一般鍵盤輸入約每分鐘 40 字、英文約 40 詞——同一個數字，兩邊都偏保守。
    public static let typingWordsPerMinute: Double = 40

    // MARK: - 記錄

    public mutating func record(text: String, seconds: Double, on date: Date, calendar: Calendar = .current) {
        let words = Self.wordCount(text)
        guard words > 0 else { return }
        let key = Self.dayKey(date, calendar: calendar)
        var day = days[key] ?? Day()
        day.words += words
        day.seconds += max(0, seconds)
        day.sessions += 1
        days[key] = day
    }

    /// 中日韓文字每個字算 1、其他連續英數算 1 詞；標點與空白不算。
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inLatinWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inLatinWord { count += 1; inLatinWord = true }
            } else if scalar == "'" || scalar == "’" || scalar == "-" {
                continue   // don't, e-mail：詞內符號不切詞
            } else {
                inLatinWord = false
            }
        }
        return count
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF,
             0x3040...0x309F, 0x30A0...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - 彙總

    public var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    public var totalSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }
    public var totalSessions: Int { days.values.reduce(0) { $0 + $1.sessions } }
    public var activeDays: Int { days.values.filter { $0.sessions > 0 }.count }

    /// 平均說話速度（每分鐘字數）；沒資料回 0。
    public var averageWordsPerMinute: Double {
        totalSeconds > 0 ? Double(totalWords) / (totalSeconds / 60) : 0
    }

    /// 省下的時間（秒）＝同樣字數用打字要花的時間 − 實際說話時間；不會是負數。
    public var secondsSaved: Double {
        max(0, Double(totalWords) / Self.typingWordsPerMinute * 60 - totalSeconds)
    }

    /// 連續使用天數：今天或昨天有用才算「目前」連續（今天還沒講話不會把昨天以前的連續歸零）。
    public func currentStreak(today: Date, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: today)
        if days[Self.dayKey(day, calendar: calendar)] == nil {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                  days[Self.dayKey(yesterday, calendar: calendar)] != nil else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days[Self.dayKey(day, calendar: calendar)] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    public func longestStreak(calendar: Calendar = .current) -> Int {
        let dates = days.keys.compactMap { Self.date(fromKey: $0, calendar: calendar) }.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for date in dates {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    /// 熱圖用：最近 `weeks` 週每天的字數（由舊到新，最後一格是今天）。
    public func dailyWords(endingOn today: Date, weeks: Int, calendar: Calendar = .current) -> [(date: Date, words: Int)] {
        let end = calendar.startOfDay(for: today)
        let count = max(1, weeks * 7)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            return (date, days[Self.dayKey(date, calendar: calendar)]?.words ?? 0)
        }
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
