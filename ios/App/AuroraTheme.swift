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

/// 麥克風光球：iOS 26+ 系統 Liquid Glass（橘色染色），跟 iOS 27 圖示同一種材質；
/// 錄音時外圈呼吸。不疊白色亮面反光。
struct MicOrb: View {
    var isRecording: Bool

    var body: some View {
        ZStack {
            // 錄音時的呼吸外圈：時間函數驅動，不在 body 裡寫狀態。
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRecording)) { timeline in
                let phase = isRecording ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 : 0
                Circle()
                    .stroke(Aurora.orange.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 112, height: 112)
                    .scaleEffect(1 + 0.3 * phase)
                    .opacity(isRecording ? 0.7 * (1 - phase) : 0)
            }
            orb
                .frame(width: 108, height: 108)
                .shadow(color: Aurora.orange.opacity(isRecording ? 0.40 : 0.22), radius: isRecording ? 26 : 18, y: 8)
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .frame(width: 140, height: 140)
    }

    /// iOS 27 圖示材質：同色上亮下深（差很小）、邊緣一圈細鏡面光（左上最亮往下淡）、柔和外陰影；沒有白色反光帶。
    @ViewBuilder
    private var orb: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.tint(Aurora.orange.opacity(0.88)).interactive(), in: Circle())
                .overlay(OrbMaterial.depth)
                .overlay(OrbMaterial.rim)
        } else {
            Circle()
                .fill(Aurora.orange)
                .overlay(OrbMaterial.depth)
                .overlay(OrbMaterial.rim)
        }
    }
}

/// 光球材質層（主 app 與鍵盤共用同一組參數語意）。
enum OrbMaterial {
    /// 上亮下深：頂端白 10%、底端黑 8%，看起來是體積不是反光。
    static var depth: some View {
        Circle()
            .fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.10), location: 0),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.08), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
    }

    /// 邊緣鏡面光：左上 55% 白、中段透明、右下 15% 白。
    static var rim: some View {
        Circle()
            .strokeBorder(AngularGradient(stops: [
                .init(color: .white.opacity(0.55), location: 0.0),
                .init(color: .white.opacity(0.05), location: 0.25),
                .init(color: .white.opacity(0.18), location: 0.5),
                .init(color: .white.opacity(0.05), location: 0.75),
                .init(color: .white.opacity(0.55), location: 1.0),
            ], center: .center, startAngle: .degrees(225), endAngle: .degrees(585)), lineWidth: 1.2)
            .allowsHitTesting(false)
    }
}
