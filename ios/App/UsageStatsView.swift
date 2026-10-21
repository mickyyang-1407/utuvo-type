import SwiftUI

/// 首頁的「使用數據」卡：總字數／平均說話速度／省下時間／總聽寫時間＋26 週活動熱圖＋連續天數。
/// 數字來源是每日計數（`DailyUsageStore`），不是歷史紀錄——刪歷史數字不會掉。
struct UsageStatsView: View {
    let daily: [DailyUsage]
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("使用數據")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)

            HStack(spacing: 0) {
                stat(value: "\(summary.totalWords)", label: String(localized: "講了幾個字"))
                Divider().frame(height: 34)
                stat(value: wpmText, label: String(localized: "平均說話速度"))
                Divider().frame(height: 34)
                stat(value: durationText(summary.totalDictationMinutes), label: String(localized: "總聽寫時間"))
            }

            HStack(spacing: 0) {
                stat(value: durationText(summary.minutesSaved), label: String(localized: "省下的時間"))
                Divider().frame(height: 34)
                stat(value: "\(summary.activeDays)", label: String(localized: "活躍天數"))
                Divider().frame(height: 34)
                stat(value: streakText, label: String(localized: "目前連續"))
            }

            heatmap
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, -2)
    }

    // MARK: - 數字

    private var wpmText: String {
        guard let wpm = summary.wordsPerMinute else { return String(localized: "—") }
        return String(localized: "\(Int(wpm.rounded())) 字／分")
    }

    private var streakText: String {
        if summary.currentStreak == 0 { return String(localized: "—") }
        return String(localized: "\(summary.currentStreak) 天")
    }

    /// 分鐘 → 人看的字串（<1 分鐘講「不到 1 分鐘」，之後整數分、再來是小時）。
    private func durationText(_ minutes: Double) -> String {
        if minutes < 1 { return String(localized: "<1 分") }
        if minutes < 60 { return String(localized: "\(Int(minutes.rounded())) 分") }
        return String(localized: "\(String(format: "%.1f", minutes / 60)) 時")
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 熱圖

    /// 熱圖的 7 列固定是**星期日～星期六**（`ActivityHeatmap.cells` 這樣排），
    /// 所以標籤要照同樣的順序取 `veryShortWeekdaySymbols`（index 0 就是星期日）。
    /// 隔一列標一次，跟著系統語言——寫死中文的話英文介面會混進「日 二 四 六」。
    /// 英文的單字母縮寫會撞（Tue／Thu 都是 T、Sun／Sat 都是 S），撞了就改用三字母縮寫。
    private static let weekdayLabels: [String] = {
        let calendar = Calendar.current
        let shown = [0, 2, 4, 6]
        let veryShort = calendar.veryShortWeekdaySymbols          // index 0 是週日
        let symbols = Set(shown.map { veryShort[$0] }).count == shown.count ? veryShort : calendar.shortWeekdaySymbols
        return (0..<7).map { shown.contains($0) ? symbols[$0] : "" }
    }()

    private var heatmap: some View {
        let columns = ActivityHeatmap.leveled(daily)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                // 週為欄、日為列；左邊標星期，讓 7 列看得出是星期。
                // 星期縮寫跟著系統語言（Calendar 的 veryShortWeekdaySymbols），不寫死中文。
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .frame(height: 9)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 3) {
                                ForEach(column) { cell in
                                    // 今天之後的日子還沒到：不畫格子（否則看起來像「那天沒活動」）。
                                    if cell.isFuture {
                                        Color.clear.frame(width: 9, height: 9)
                                    } else {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(color(for: cell.level))
                                            .frame(width: 9, height: 9)
                                            .accessibilityLabel(Text(String(localized: "\(cell.day)：\(cell.count)")))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("少")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: level))
                        .frame(width: 9, height: 9)
                }
                Text("多")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "最長連續 \(summary.longestStreak) 天"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 5 階顏色：0＝空，1…4 從淡到濃（跟 GitHub 熱圖同樣的讀感）。
    private func color(for level: Int) -> Color {
        switch level {
        case 0: return Aurora.orange.opacity(0.08)
        case 1: return Aurora.orange.opacity(0.28)
        case 2: return Aurora.orange.opacity(0.50)
        case 3: return Aurora.orange.opacity(0.75)
        default: return Aurora.orange
        }
    }
}