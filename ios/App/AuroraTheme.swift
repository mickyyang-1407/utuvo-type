import SwiftUI

/// iOS 視覺：與 macOS 同一套品牌（橘→琥珀金、薰衣草），iOS 26 起走 Liquid Glass，深淺色都有。
/// 玻璃只用在浮在內容上的卡片／膠囊；底下鋪柔和色團讓玻璃有東西折射（與 macOS AmbientBackdrop 同一組色）。
enum Aurora {
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.086)   // 品牌橘 #F97316
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.29)         // 琥珀金（漸層亮端）
    static let violet = Color(red: 0.68, green: 0.60, blue: 0.95)       // 薰衣草（次要動畫色）
    static let mint = Color(red: 0.42, green: 0.75, blue: 0.52)

    static var orbGradient: LinearGradient {
        LinearGradient(colors: [amber, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [violet, orange, amber], startPoint: .leading, endPoint: .trailing)
    }

    /// 全域底：淡色＝奶油底＋琥珀／薰衣草色團；深色＝暖炭底同一組色團。靜態、不動畫。
    struct Backdrop: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            let dark = scheme == .dark
            ZStack {
                (dark ? Color(red: 0.118, green: 0.102, blue: 0.086) : Color(red: 1.0, green: 0.973, blue: 0.945))
                GeometryReader { geo in
                    Circle()
                        .fill(Aurora.amber.opacity(dark ? 0.20 : 0.42))
                        .frame(width: geo.size.width * 1.1)
                        .blur(radius: 90)
                        .position(x: geo.size.width * 0.15, y: geo.size.height * 0.08)
                    Circle()
                        .fill(Aurora.orange.opacity(dark ? 0.14 : 0.20))
                        .frame(width: geo.size.width * 0.9)
                        .blur(radius: 90)
                        .position(x: geo.size.width * 0.95, y: geo.size.height * 0.30)
                    Circle()
                        .fill(Aurora.violet.opacity(dark ? 0.16 : 0.30))
                        .frame(width: geo.size.width * 0.9)
                        .blur(radius: 100)
                        .position(x: geo.size.width * 0.85, y: geo.size.height * 0.85)
                }
                .drawingGroup()
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// 卡片：iOS 26 Liquid Glass；以下 material。
    @ViewBuilder
    func auroraGlass(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            let glass: Glass = (tint.map { Glass.regular.tint($0) } ?? .regular).interactive(interactive)
            self.glassEffect(glass, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    /// 內容卡片（不用玻璃，跟 macOS 一樣：內容層用半透明填色，玻璃留給控制層）。
    func auroraCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(AuroraCard(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func auroraProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func auroraGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct AuroraCard: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(16)
            .background(shape.fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55)))
            .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.8), lineWidth: 1))
    }
}

/// 錄音波形：TimelineView 驅動（純時間函數，不在 body 裡寫狀態）。
struct WaveformBars: View {
    var isRecording: Bool
    var barCount: Int = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Aurora.accentGradient)
                        .frame(width: 3, height: height(index: i, time: t))
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

/// 麥克風光球：品牌漸層＋錄音時呼吸光暈。
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
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isRecording)
                Circle()
                    .fill(Aurora.orange.opacity(0.22))
                    .frame(width: 140, height: 140)
                    .blur(radius: 24)
                    .scaleEffect(isRecording ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: isRecording)
            } else {
                Circle()
                    .fill(Aurora.orange.opacity(0.14))
                    .frame(width: 132, height: 132)
                    .blur(radius: 18)
            }

            Circle()
                .fill(Aurora.orbGradient)
                .frame(width: 108, height: 108)
                .overlay(
                    Circle().fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                )
                .shadow(color: Aurora.orange.opacity(isRecording ? 0.65 : 0.30), radius: isRecording ? 26 : 14)

            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
