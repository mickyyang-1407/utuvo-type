import SwiftUI
import UTUVOTypeCore

/// 使用數據頁（2026-10-13，對齊 Typeless 首頁的 Words dictated／Time saved／Average speed／Activity／Streak）。
/// 數字全從本機累計（UsageStats）算，不存任何文字內容。
struct InsightsView: View {
    @ObservedObject var preferences: AppPreferences
    private let weeks = 52

    var body: some View {
        let stats = preferences.usageStats
        let today = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    tile(preferences.tr("說了多少字", "Words dictated"), "\(stats.totalWords)", "text.word.spacing")
                    tile(preferences.tr("省下的時間", "Time saved"), Self.duration(stats.secondsSaved, zh: preferences.isChineseUI), "hourglass")
                    tile(preferences.tr("說話總時間", "Total dictation time"), Self.duration(stats.totalSeconds, zh: preferences.isChineseUI), "waveform")
                    tile(preferences.tr("平均速度", "Average speed"),
                         preferences.tr("\(Int(stats.averageWordsPerMinute.rounded())) 字／分", "\(Int(stats.averageWordsPerMinute.rounded())) WPM"),
                         "speedometer")
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(preferences.tr("活動", "Activity")).font(.headline)
                        Spacer()
                        Text(preferences.tr("使用 \(stats.activeDays) 天・目前連續 \(stats.currentStreak(today: today)) 天・最長 \(stats.longestStreak()) 天",
                                            "\(stats.activeDays) active days · current streak \(stats.currentStreak(today: today)) · longest \(stats.longestStreak())"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    heatmap(stats.dailyWords(endingOn: today, weeks: weeks))
                    Text(preferences.tr("省下的時間＝同樣字數用打字（每分鐘 40 字）要花的時間減掉實際說話時間。數據只存在這台 Mac，只記每天的字數與秒數，不存內容。",
                                        "Time saved = time to type the same words at 40 WPM minus time spent speaking. Stored only on this Mac as daily counts; no content."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(18)
                .popoverCard(cornerRadius: 16)
            }
            .padding(24)
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .popoverCard(cornerRadius: 14)
    }

    /// GitHub 式熱圖：每欄一週、每列星期幾；顏色深淺＝當天字數。
    private func heatmap(_ days: [(date: Date, words: Int)]) -> some View {
        let maxWords = max(1, days.map(\.words).max() ?? 1)
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return HStack(alignment: .top, spacing: 3) {
            ForEach(columns.indices, id: \.self) { c in
                VStack(spacing: 3) {
                    ForEach(columns[c].indices, id: \.self) { r in
                        let day = columns[c][r]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.shade(day.words, max: maxWords))
                            .frame(width: 12, height: 12)
                            .help("\(day.date.formatted(date: .abbreviated, time: .omitted))：\(day.words)")
                    }
                }
            }
        }
    }

    static func shade(_ words: Int, max: Int) -> Color {
        guard words > 0 else { return Color.secondary.opacity(0.12) }
        let level = Double(words) / Double(max)
        return AppBrand.accent.opacity(0.25 + 0.75 * min(1, level))
    }

    static func duration(_ seconds: Double, zh: Bool) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return zh ? "\(minutes / 60) 小時 \(minutes % 60) 分" : "\(minutes / 60) hr \(minutes % 60) min" }
        return zh ? "\(minutes) 分" : "\(minutes) min"
    }
}
