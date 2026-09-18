import SwiftUI

/// iOS 視覺：與 macOS 同一套品牌色（橘→琥珀金、薰衣草），走 iOS 26／27 的做法——
/// 內容層是實心、安靜的卡片；Liquid Glass 只給控制層（tab bar、按鈕）；顏色與光交給光球。
enum Aurora {
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.086)   // 品牌橘 #F97316
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.29)         // 琥珀金
    static let violet = Color(red: 0.68, green: 0.60, blue: 0.95)       // 薰衣草（改寫）
    static let mint = Color(red: 0.42, green: 0.75, blue: 0.52)

    /// 全域底：暖白／暖黑實色，加一道很淡的暖光（光球所在的上半部）。靜態、不模糊、不動畫。
    struct Backdrop: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            let dark = scheme == .dark
            ZStack {
                dark ? Color(red: 0.055, green: 0.050, blue: 0.047) : Color(red: 0.980, green: 0.972, blue: 0.960)
                RadialGradient(colors: [Aurora.orange.opacity(dark ? 0.10 : 0.07), .clear],
                               center: UnitPoint(x: 0.5, y: 0.30), startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
    }

    /// 卡片底色：淡色＝白、深色＝暖炭（對齊 iOS grouped 儲存格，不透明、不描邊）。
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.118, green: 0.110, blue: 0.104) : .white
    }
}

extension View {
    /// 控制層玻璃（浮在內容上的小元件）：iOS 26 Liquid Glass；以下 material。
    @ViewBuilder
    func auroraGlass(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            let glass: Glass = (tint.map { Glass.regular.tint($0) } ?? .regular).interactive(interactive)
            self.glassEffect(glass, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// 內容卡片：實心、不描邊、連續圓角。
    func auroraCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        modifier(AuroraCard(cornerRadius: cornerRadius, padding: padding))
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
    var padding: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Aurora.cardFill(scheme)))
    }
}

/// 光球（SwiftUI 包裝）：主 app 的聽寫主角與鍵盤工作階段畫面共用 `OrbView`。
struct LiveOrb: UIViewRepresentable {
    var phase: OrbView.Phase
    var editPalette = false
    /// 球體佔框的比例，其餘是光暈。
    var sphereFraction: CGFloat = 0.6
    /// 目前麥克風音量（dBFS），沒在錄回 nil。
    var level: () -> Float? = { nil }

    func makeUIView(context: Context) -> OrbView {
        let view = OrbView()
        #if DEBUG
        // 截圖／錄影：`-utuvo.type.ios.orbDemo YES` 用合成的講話音量（模擬器沒有麥克風）。
        view.debugSyntheticVoice = UserDefaults.standard.bool(forKey: "utuvo.type.ios.orbDemo")
        #endif
        return view
    }

    func updateUIView(_ view: OrbView, context: Context) {
        view.sphereFraction = sphereFraction
        view.levelProvider = level
        view.editPalette = editPalette
        view.phase = phase
    }
}

/// 按下光球：稍微縮、放開彈回（系統 spring），不疊任何亮面。
struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}
