import SwiftUI

/// iOS「Aurora」視覺語言——參考 Dribbble 高分 AI 語音聽寫 UI（2025 趨勢）：
/// 暗色底、漸層光球、玻璃卡片、柔和光暈。全 app 共用，避免樣式散落。
enum Aurora {
    // MARK: - 顏色
    static let backgroundTop = Color(red: 0.043, green: 0.055, blue: 0.078)   // #0B0E14
    static let backgroundBottom = Color(red: 0.071, green: 0.090, blue: 0.133)
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.086)          // 品牌橘 #F97316
    /// 琥珀金＝漸層亮端，與 macOS `AppBrand.amber` 同一顆。
    /// 2026-09-11：取代原本的粉紅 #EC4899——產品決定「不用粉紅」，
    /// macOS 端 2026-08-23 已換掉，iOS 端這次補齊。
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.29)
    /// 薰衣草＝次要動畫色，對齊 macOS `AppBrand.lavender`。
    static let violet = Color(red: 0.68, green: 0.60, blue: 0.95)

    static var orbGradient: LinearGradient {
        LinearGradient(colors: [amber, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [violet, orange, amber], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - 玻璃卡片
    struct GlassCard: ViewModifier {
        var cornerRadius: CGFloat = 20
        func body(content: Content) -> some View {
            content
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
    }

    static func glass<S: View>(_ content: S) -> some View {
        content.modifier(GlassCard())
    }

    // MARK: - 背景
    /// 全域暗色漸層背景＋兩團品牌色柔光（Aurora 氛圍）。
    struct Backdrop: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [backgroundTop, backgroundBottom],
                               startPoint: .top, endPoint: .bottom)
                GeometryReader { geo in
                    Circle()
                        .fill(orange.opacity(0.14))
                        .frame(width: geo.size.width * 0.9)
                        .blur(radius: 80)
                        .position(x: geo.size.width * 0.85, y: geo.size.height * 0.12)
                    Circle()
                        .fill(violet.opacity(0.12))
                        .frame(width: geo.size.width * 0.8)
                        .blur(radius: 90)
                        .position(x: geo.size.width * 0.10, y: geo.size.height * 0.85)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// 錄音波形：TimelineView 驅動的隨機高度柱狀動畫（錄音中顯示）。
struct WaveformBars: View {
    var isRecording: Bool
    var barCount: Int = 24
    @State private var phase = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Aurora.accentGradient)
                        .frame(width: 3, height: height(index: i, time: t))
                        .animation(.easeInOut(duration: 0.08), value: t)
                }
            }
            .frame(height: 36)
        }
        .opacity(isRecording ? 1 : 0.25)
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        guard isRecording else { return 6 }
        let wave = sin(time * 6 + Double(index) * 0.7) * 0.5 + 0.5
        return 8 + wave * 26
    }
}

/// 麥克風光球：三層漸層＋錄音時呼吸脈衝光暈。
struct MicOrb: View {
    var isRecording: Bool

    var body: some View {
        ZStack {
            if isRecording {
                Circle()
                    .stroke(Aurora.orbGradient, lineWidth: 2)
                    .frame(width: 128, height: 128)
                    .scaleEffect(isRecording ? 1.25 : 1.0)
                    .opacity(isRecording ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false),
                               value: isRecording)
                Circle()
                    .fill(Aurora.orange.opacity(0.22))
                    .frame(width: 140, height: 140)
                    .blur(radius: 24)
                    .scaleEffect(isRecording ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                               value: isRecording)
            } else {
                Circle()
                    .fill(Aurora.orange.opacity(0.14))
                    .frame(width: 132, height: 132)
                    .blur(radius: 18)
            }

            Circle()
                .fill(Aurora.orbGradient)
                .frame(width: 108, height: 108)
                .shadow(color: Aurora.orange.opacity(isRecording ? 0.65 : 0.30), radius: isRecording ? 26 : 14)

            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
