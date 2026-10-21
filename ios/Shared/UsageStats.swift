import Foundation
import os

/// 跨 process 儲存層的失敗要留下痕跡：debug build 進 Console，release 走 OSLog。
/// 刻意不用 `print`——鍵盤 extension 的 stdout 不一定有人在收。
enum UsageLog {
    private static let logger = Logger(subsystem: "com.utuvo.type", category: "storage")

    static func write(_ message: String) {
        #if DEBUG
        NSLog("[utuvo.type] %@", message)
        #endif
        logger.error("\(message, privacy: .public)")
    }
}

/// `NSFileCoordinator` 的 closure 不是 escaping、也不能跨 concurrency domain，
/// 所以用它把泛型值帶出來（closure 內寫、外面讀）。
final class LockedBox<T>: @unchecked Sendable {
    var value: T?
}

/// 儲存寫入的**序列背景佇列**。history.json／usage-daily.json 的讀-改-寫都是同步的
/// （測試與呼叫端都依賴寫完就讀得到），所以把它整包丟到背景，而不是改 `append` 的語意。
///
/// 2026-10-13 修補：鍵盤 extension 在定稿時同步寫檔，會卡住鍵盤的主執行緒；
/// 主 app 的定稿／歷史頁載入也是。序列佇列＝跨 process 的寫入不會互相插隊。
enum StorageIO {
    static let queue = DispatchQueue(label: "utuvo.type.ios.storage.write", qos: .utility)

    static func write(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }
}

// MARK: - 字數

/// 使用數據的字數口徑：中日韓（漢字、假名、韓文）逐字算 1，其餘語言以空白切詞。
/// 舊的 `UsageInsights.wordCount` 是同一套規則的私有版本，現在單一正本在這裡。
enum UsageText {
    static func wordCount(_ text: String) -> Int {
        var cjk = 0
        var latinWords = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (0x3400...0x9FFF).contains(v)
                || (0xF900...0xFAFF).contains(v)
                || (0x3040...0x30FF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
            if isCJK {
                cjk += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if !inWord { latinWords += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return cjk + latinWords
    }
}

// MARK: - 錄音秒數（純函式）

/// 一次聽寫的秒數：**錄音真正結束（按停）的那一刻**就算好、凍結在那裡，
/// 之後的交付（雲端重辨識、翻譯、App 端整理）再晚都不影響記錄。
///
/// 2026-10-13 修補：原本在交付當下才用 `Date() - startedAt` 算，
/// 把等待雲端辨識／整理的時間也算進「說了幾秒」→ WPM、省下打字時間、
/// 總聽寫時間全部虛胖。純 struct（沒有 class 狀態）所以可以直接單元測試。
struct DictationClock: Equatable, Sendable {
    /// 少於這個秒數視為「沒在錄」（按到手滑），回 nil＝未知，不是 0 秒。
    static let minimumSeconds: Double = 0.5

    private(set) var startedAt: Date?
    private(set) var frozen: Double?

    init() {}

    /// 開始新的一段錄音。**同時清掉上一段的凍結值**——
    /// 保持開啟模式下一段接一段，每段都要各自算自己的秒數。
    mutating func begin(at date: Date) {
        startedAt = date
        frozen = nil
    }

    /// 錄音結束：把這一段的秒數算出來凍結。**重複呼叫安全**（早退路徑常常連呼叫兩次），
    /// 而且已經凍結過就不會被後來的時間蓋掉。
    @discardableResult
    mutating func freeze(at date: Date) -> Double? {
        if let frozen { return frozen }
        guard let startedAt else { return nil }
        self.startedAt = nil
        let value = Self.elapsed(from: startedAt, to: date)
        frozen = value
        return value
    }

    /// 交付時讀凍結值並清空（下一段從零開始）。沒凍結過（例如一開始就出錯、沒錄到）回 nil。
    mutating func take() -> Double? {
        let value = frozen
        startedAt = nil
        frozen = nil
        return value
    }

    /// 純函式：兩點之間幾秒。倒退或短於下限 → nil（＝未知，不是 0）。
    static func elapsed(from start: Date, to end: Date, minimum: Double = DictationClock.minimumSeconds) -> Double? {
        let value = end.timeIntervalSince(start)
        guard value >= minimum else { return nil }
        return value
    }
}

// MARK: - 每日計數

/// 一天的使用量（只存數字，不存任何文字）。`day` 是**本地時區**的 yyyy-MM-dd。
struct DailyUsage: Codable, Equatable, Sendable {
    var day: String          // yyyy-MM-dd（當地日界）
    var words: Int = 0
    var seconds: Double = 0  // 錄音秒數
    var sessions: Int = 0    // 聽寫次數

    var isEmpty: Bool { words == 0 && seconds == 0 && sessions == 0 }
}

/// 本地日界工具：`yyyy-MM-dd` 字串往來都用它，跨時區測試靠注入 Calendar。
enum UsageDay {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    /// 每次現做一個 formatter：**不要**共用靜態實例再改它的 timeZone
    /// （DateFormatter 是 class，`var f = shared` 只是複製參考，兩個 process／執行緒會互相改時區）。
    static func date(from string: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone   // 日界時區＝呼叫端傳進來的，不要用建立當下的系統時區
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }

    /// 本地零點（當地日界）。日界一律用呼叫端傳入的 Calendar，所以測試可以固定時區。
    static func startOfDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}

// MARK: - 保留期限

/// 歷史紀錄保留期限。改短時會刪掉超過期限的歷史；**每日計數不受影響**（工單要求）。
enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
    case forever
    case none

    static let `default`: RetentionPolicy = .forever

    /// 介面顯示的字（逐一寫成字面值，編譯器才抽得到 Localizable.xcstrings 的 key）。
    static func label(_ policy: RetentionPolicy) -> String {
        switch policy {
        case .day: return String(localized: "24 小時")
        case .week: return String(localized: "1 週")
        case .month: return String(localized: "1 個月")
        case .year: return String(localized: "1 年")
        case .forever: return String(localized: "永遠")
        case .none: return String(localized: "不保留")
        }
    }

    /// 保留期限的截止點。**`now` 一定要從外面傳進來**（2026-10-14 修）：
    /// 這裡原本直接用 `Date()`，於是 `keeps(_:now:)`／`filter(_:policy:now:)` 上面那個
    /// `now:` 參數是死的——呼叫端傳了也沒人用。實際後果是所有截止點都綁在「函式執行的瞬間」，
    /// 而不是呼叫端宣告的時間：同一次保留期限計算裡，呼叫端算好的 `now` 與真正比對的時間相差
    /// 一段（跑得越久差越多），而且這個 API 根本沒辦法測。
    /// `UsageStatsTests.testExpiredCount` 就是這樣變成不定時炸彈：它把 `now` 固定在
    /// 2026-10-13 12:00，切點卻用真實的當下時間比，過了 10-13 當天就多算一筆過期（2 → 3）。
    func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .day: return now.addingTimeInterval(-24 * 3600)
        case .week: return now.addingTimeInterval(-7 * 24 * 3600)
        case .month: return Calendar.current.date(byAdding: .month, value: -1, to: now)
        case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .forever, .none: return nil
        }
    }

    /// 這筆紀錄要不要留。`none`＝之後不寫歷史（歷史本來就沒東西可留），回 false 讓 purge 清空。
    func keeps(_ record: DictationRecord, now: Date = Date()) -> Bool {
        guard self != .none else { return false }
        guard let cutoff = cutoff(now: now) else { return true }   // forever
        return record.date >= cutoff
    }

    /// 篩選：留下期限內的紀錄（星標不例外，跟期限走）。
    static func filter(_ records: [DictationRecord], policy: RetentionPolicy, now: Date = Date()) -> [DictationRecord] {
        records.filter { policy.keeps($0, now: now) }
    }

    /// 改期限時要刪幾筆（給確認對話框寫清楚）。
    static func expiredCount(_ records: [DictationRecord], policy: RetentionPolicy, now: Date = Date()) -> Int {
        records.count - filter(records, policy: policy, now: now).count
    }
}

// MARK: - 統計計算（純函式）

/// 首頁顯示的彙總數字。
struct UsageSummary: Equatable, Sendable {
    var totalWords: Int = 0
    var totalSeconds: Double = 0
    var sessions: Int = 0
    var activeDays: Int = 0
    var currentStreak: Int = 0
    var longestStreak: Int = 0

    /// 平均說話速度（WPM）。沒時長的次數不算進來（工單）。
    var wordsPerMinute: Double? {
        guard totalSeconds > 0 else { return nil }
        return Double(totalWords) / (totalSeconds / 60)
    }

    /// 省下多少時間：打字 40 WPM 的耗時 − 實際說話時間，下限 0（與 Mac 版口徑一致）。
    /// 用 40 而不是純字數比例，是因為中文逐字打字遠慢於 WPM 換算的直線速度。
    var minutesSaved: Double {
        let typingMinutes = Double(totalWords) / 40.0
        let spokenMinutes = totalSeconds / 60.0
        return max(0, typingMinutes - spokenMinutes)
    }

    var totalDictationMinutes: Double { totalSeconds / 60 }
}

/// 首頁數字的計算。純函式：吃每日計數、吐彙總，沒有 IO 沒有 UI，可以直接測。
enum UsageCalculator {
    static let typingWPM = 40.0

    static func summary(for daily: [DailyUsage]) -> UsageSummary {
        var s = UsageSummary()
        for d in daily {
            s.totalWords += d.words
            s.totalSeconds += d.seconds
            s.sessions += d.sessions
        }
        let days = activeDaySet(daily)
        s.activeDays = days.count
        (s.currentStreak, s.longestStreak) = streaks(daySet: days)
        return s
    }

    /// 有使用過的本地日期字串集合（sessions 或字數任一大於 0）。
    static func activeDaySet(_ daily: [DailyUsage]) -> Set<String> {
        Set(daily.filter { !$0.isEmpty }.map(\.day))
    }

    /// 目前連續天數與最長連續天數。
    /// 連續天數以**本地時區日界**計算：以 `now` 所在的那一天（或前一個有使用的日子）往回數。
    /// 今天還沒講話不算斷（很多人是晚上才用），所以從今天或昨天起算，取有使用的那個較晚者。
    static func streaks(daySet: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> (current: Int, longest: Int) {
        guard !daySet.isEmpty else { return (0, 0) }
        let today = UsageDay.string(from: now, calendar: calendar)
        let yesterday = UsageDay.string(from: calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)

        var current = 0
        var cursor: Date
        if daySet.contains(today) {
            cursor = now
        } else if daySet.contains(yesterday) {
            cursor = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        } else {
            return (0, longestRun(daySet, calendar: calendar))
        }
        while daySet.contains(UsageDay.string(from: cursor, calendar: calendar)) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return (current, max(longestRun(daySet, calendar: calendar), current))
    }

    /// 最長連續天數：把日期字串依 yyyy-MM-dd 字典序排（等同時間序）後掃描。
    static func longestRun(_ daySet: Set<String>, calendar: Calendar = .current) -> Int {
        let sorted = daySet.sorted()
        var best = 0, run = 0
        var prev: Date?
        for day in sorted {
            guard let d = UsageDay.date(from: day, calendar: calendar) else { run = 0; prev = nil; continue }
            if let p = prev, let next = calendar.date(byAdding: .day, value: 1, to: p), calendar.isDate(next, inSameDayAs: d) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            prev = d
        }
        return best
    }
}

/// 活動熱圖的一格。`level` 0…4（0＝沒活動）。`isFuture`＝今天還沒到，**不畫**。
struct HeatmapCell: Equatable, Sendable, Identifiable {
    var day: String
    var count: Int
    var level: Int
    /// 今天之後的日子。畫下去會看起來像「那天沒活動」，其實是還沒到。
    var isFuture: Bool = false
    var id: String { day }
}

/// 熱圖資料：最近 26 週，**週為欄、日為列**（7 列，星期日在上），一週 7 格、共 182 格。
enum ActivityHeatmap {
    static let weeks = 26

    static func cells(for daily: [DailyUsage], now: Date = Date(), calendar: Calendar = .current,
                      weeks: Int = ActivityHeatmap.weeks) -> [[HeatmapCell]] {
        let counts = Dictionary(uniqueKeysWithValues: daily.filter { !$0.isEmpty }.map { ($0.day, $0.words + $0.sessions) })
        // 以「本週星期日」當最後一欄的週日，往前推 weeks-1 週。起始日不一定是今天，
        // 熱圖要對齊到完整週，否則最後一欄長短不一。
        //
        // 列固定＝**星期日～星期六**（`.weekday` 裡 1 就是星期日），
        // 跟 `UsageStatsView` 的列標籤一致。這裡**不使用 `calendar.firstWeekday`**——
        // 那是「當地慣例的週首」，在週一開頭的地區會讓整張圖錯一列。
        let weekday = calendar.component(.weekday, from: now)
        let daysSinceSunday = (weekday - 1 + 7) % 7
        let lastSunday = calendar.date(byAdding: .day, value: -daysSinceSunday, to: now) ?? now
        let firstSunday = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: lastSunday) ?? lastSunday
        let todayKey = UsageDay.string(from: now, calendar: calendar)

        var columns: [[HeatmapCell]] = []
        columns.reserveCapacity(weeks)
        for w in 0..<weeks {
            var column: [HeatmapCell] = []
            column.reserveCapacity(7)
            for d in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: 7 * w + d, to: firstSunday) else {
                    column.append(HeatmapCell(day: "", count: 0, level: 0)); continue
                }
                let key = UsageDay.string(from: date, calendar: calendar)
                // 今天之後的格子是未來：標起來讓 UI 不要畫（畫了像「那天沒活動」）。
                guard key <= todayKey else {
                    column.append(HeatmapCell(day: key, count: 0, level: 0, isFuture: true)); continue
                }
                let n = counts[key] ?? 0
                column.append(HeatmapCell(day: key, count: n, level: level(for: n)))
            }
            columns.append(column)
        }
        return columns
    }

    /// 5 階顏色：以「有活動的日子的最大值」為滿格，取 1/4、1/2、3/4 為界。
    static func level(for value: Int, peak: Int = 1) -> Int {
        guard value > 0 else { return 0 }
        guard peak > 0 else { return 1 }
        let ratio = Double(value) / Double(peak)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.50 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    /// 依實際最大值分級（給 UI 呼叫）。`now` 可注入，測試才不會跟著牆上時鐘跑。
    static func leveled(_ daily: [DailyUsage], now: Date = Date()) -> [[HeatmapCell]] {
        let peak = daily.filter { !$0.isEmpty }.map { $0.words + $0.sessions }.max() ?? 0
        return cells(for: daily, now: now).map { column in
            column.map { HeatmapCell(day: $0.day, count: $0.count,
                                     level: $0.isFuture ? 0 : level(for: $0.count, peak: peak),
                                     isFuture: $0.isFuture) }
        }
    }
}

// MARK: - 每日計數儲存（App Group，跨 process 安全）

/// 每日使用計數的儲存。App Group 檔案，**不受歷史 500 筆上限影響、刪歷史也不影響**。
/// 鍵盤與主 app 是兩個 process，讀-改-寫要用檔案鎖（`NSFileCoordinator`）包起來，
/// 否則兩邊同時寫會互相覆蓋（後寫的整份蓋掉先寫的增量）。
final class DailyUsageStore: @unchecked Sendable {
    static let shared = DailyUsageStore()
    static let fileName = "usage-daily.json"

    private let fileURL: URL?
    private let queue = DispatchQueue(label: "utuvo.type.ios.usage.daily")
    private let calendar: Calendar

    /// - Parameters:
    ///   - directory: 直接指定資料夾（測試用）。
    ///   - defaults: `utuvo.type.ios.usageDir` 覆寫路徑。
    ///   - calendar: 日界用的時區（測試可固定）。
    init(directory: URL? = nil, defaults: UserDefaults? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        if let directory {
            self.fileURL = directory.appendingPathComponent(Self.fileName)
        } else if let defaults, let dir = defaults.url(forKey: "utuvo.type.ios.usageDir") {
            self.fileURL = dir.appendingPathComponent(Self.fileName)
        } else if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.utuvo.type") {
            self.fileURL = container.appendingPathComponent(Self.fileName)
        } else {
            self.fileURL = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true
            ).appendingPathComponent(Self.fileName)
        }
    }

    func load() -> [DailyUsage] {
        queue.sync { read() }
    }

    /// 記一次聽寫完成。words＝整理後的字數，seconds＝錄音秒數（0 表示未知）。
    /// 同一天多次聽寫是累加，不是覆蓋。
    func record(words: Int, seconds: Double, at date: Date = Date()) {
        queue.sync {
            var all = read()
            let key = UsageDay.string(from: date, calendar: calendar)
            if let idx = all.firstIndex(where: { $0.day == key }) {
                all[idx].words += words
                all[idx].seconds += max(0, seconds)
                all[idx].sessions += 1
            } else {
                all.append(DailyUsage(day: key, words: words, seconds: max(0, seconds), sessions: 1))
            }
            write(all)
        }
    }

    /// 清掉全部每日計數（設定頁的「清除使用數據」用；歷史不動）。
    func reset() {
        queue.sync { write([]) }
    }

    /// 直接寫入整份每日計數（**只有 DEBUG 截圖／測試用**；正式路徑一律走 record）。
    func seed(_ all: [DailyUsage]) {
        queue.sync { write(all) }
    }

    // MARK: 檔案 I/O（queue 內呼叫）

    private func read() -> [DailyUsage] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DailyUsage].self, from: data) else { return [] }
        return decoded
    }

    private func write(_ all: [DailyUsage]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 跨 process 讀-改-寫：外面包一層檔案協調鎖，鍵盤與主 app 同時記也不會互相蓋掉。
    /// 測試直接呼叫它驗證「兩次 record 都進得去」。
    ///
    /// 協調失敗**不會**退回無鎖寫入：無鎖寫正是要防的那種互相覆蓋，只是把「整份被蓋掉」
    /// 換成「不知道哪一次被蓋掉」。失敗就記 log 並放棄這一次寫入。
    func withExclusiveAccess<T>(_ body: (inout [DailyUsage]) -> T) -> T? {
        guard let url = fileURL else { return nil }
        // coordinator 不會為了還不存在的檔案建立目錄／檔案，先確保它存在，否則閉包可能不觸發。
        ensureParentDirectoryExists()
        if !FileManager.default.fileExists(atPath: url.path) {
            // 放一個空陣列當基檔，讓 coordinator 有一個真實檔案可以鎖。
            try? Data("[]".utf8).write(to: url, options: .atomic)
        }

        var coordinationError: NSError?
        let box = LockedBox<T>()
        var ran = false
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { _ in
            ran = true
            box.value = queue.sync { () -> T in
                var all = read()
                let value = body(&all)
                write(all)
                return value
            }
        }
        if ran, let value = box.value { return value }
        UsageLog.write("DailyUsageStore: 拿不到檔案協調鎖，這次計數沒有寫入（error=\(coordinationError?.localizedDescription ?? "closure 未觸發")）")
        return nil
    }

    private func ensureParentDirectoryExists() {
        guard let dir = fileURL?.deletingLastPathComponent() else { return }
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 透過檔案鎖記一次（跨 process 安全的主路徑）。
    func recordExclusive(words: Int, seconds: Double, at date: Date = Date()) {
        withExclusiveAccess { all in
            let key = UsageDay.string(from: date, calendar: calendar)
            if let idx = all.firstIndex(where: { $0.day == key }) {
                all[idx].words += words
                all[idx].seconds += max(0, seconds)
                all[idx].sessions += 1
            } else {
                all.append(DailyUsage(day: key, words: words, seconds: max(0, seconds), sessions: 1))
            }
        }
    }
}