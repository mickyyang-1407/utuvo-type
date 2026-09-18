import Foundation

/// 歷史頁的一個「日」區段（Typeless 歷史分日）。
struct HistorySection: Equatable, Identifiable, Sendable {
    let day: Date
    let title: String
    let records: [DictationRecord]
    var id: Date { day }
}

/// 歷史頁的純邏輯：搜尋過濾、依日分組、日期標題。無 UI、可測。
enum HistoryGrouping {
    /// 搜尋：不分大小寫、不分全半形／重音；空白切成多個詞，每個詞都要命中（raw 或 cleaned）。
    /// `starredOnly`＝只留星標。
    static func filter(_ records: [DictationRecord], query: String, starredOnly: Bool = false) -> [DictationRecord] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return records.filter { record in
            if starredOnly && !record.starred { return false }
            guard !terms.isEmpty else { return true }
            return terms.allSatisfy { term in
                record.cleaned.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
                    || record.raw.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }

    /// 星期名跟著介面語言走：简中介面用 zh_CN（周一），其餘維持 zh_TW（週一）。
    static var displayLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first == "zh-Hans" ? "zh_CN" : "zh_TW")
    }

    /// 依日分組，最新的一天在前；同一天內最新的在前。
    static func sections(
        _ records: [DictationRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = HistoryGrouping.displayLocale
    ) -> [HistorySection] {
        var buckets: [Date: [DictationRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            buckets[day, default: []].append(record)
        }
        return buckets.keys.sorted(by: >).map { day in
            HistorySection(
                day: day,
                title: dayTitle(for: day, now: now, calendar: calendar, locale: locale),
                records: buckets[day]!.sorted { $0.date > $1.date }
            )
        }
    }

    /// 今天／昨天／同年「9月15日 週一」／跨年「2025年12月31日 週三」。
    static func dayTitle(
        for day: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale = HistoryGrouping.displayLocale
    ) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return String(localized: "今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "昨天")
        }
        // zh_TW 的 FormatStyle 會出「9/14（週一）」；歷史頁要的是「9月14日 週一」，自己組。
        var cal = calendar
        cal.locale = locale
        let comps = cal.dateComponents([.year, .month, .day, .weekday], from: day)
        guard let year = comps.year, let month = comps.month, let dayOfMonth = comps.day, let weekday = comps.weekday else {
            return day.formatted(date: .abbreviated, time: .omitted)
        }
        let weekdayName = cal.shortWeekdaySymbols[weekday - 1]
        let sameYear = year == cal.component(.year, from: today)
        return (sameYear ? "" : "\(year)年") + "\(month)月\(dayOfMonth)日 \(weekdayName)"
    }
}

extension DictationRecord {
    /// 「說出要怎麼改」的歷史紀錄：raw 記使用者講的指示（帶前綴），cleaned 記改寫結果。
    /// 鍵盤與主 app 共用同一個工廠，格式不會漂。
    static let editPrefix = "改："

    static func edit(instruction: String, result: String, source: Source) -> DictationRecord {
        DictationRecord(raw: editPrefix + instruction, cleaned: result, source: source)
    }

    var isEdit: Bool { raw.hasPrefix(Self.editPrefix) }
}
