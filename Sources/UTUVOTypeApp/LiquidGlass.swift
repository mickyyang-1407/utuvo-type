import AppKit
import SwiftUI

// MARK: - Liquid Glass 語彙（macOS 26／27）
//
// 所有 glass 呼叫點集中在這一檔：macOS 26+ 走真的 `glassEffect`／`GlassEffectContainer`／
// `.glass` button style；macOS 14–15 退回 material＋暖色 fallback，呼叫點不用寫兩份。
// 規則（Apple HIG, Liquid Glass）：
//   1. glass 只用在「浮在內容上」的一層：卡片、膠囊、按鈕、側欄。不要拿 glass 鋪整個視窗底。
//   2. 相鄰的 glass 元件包在同一個 `TypeGlassContainer` 裡，系統才會把它們當一片玻璃合成
//      （靠近時融合、避免重疊時互相取樣）。
//   3. 底下要有東西可折射：設定視窗用 `AmbientBackdrop`；popover 與 overlay 本來就浮在桌面上。

enum TypeGlass {
    /// 效能 A/B 用：UTUVO_TYPE_NO_GLASS=1 強制走 material fallback（截圖模式量設定頁開啟時間）。
    static let enabled: Bool = ProcessInfo.processInfo.environment["UTUVO_TYPE_NO_GLASS"] != "1"
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 14
    static let chipRadius: CGFloat = 10

    /// 卡片用的暖色 tint：淡色＝淡杏、深色＝暖炭，透明度壓低讓玻璃感留著。
    @MainActor static var cardTint: Color {
        AppBrand.isDark ? Color(red: 0.216, green: 0.188, blue: 0.157).opacity(0.28)
                        : Color(red: 1.0, green: 0.925, blue: 0.867).opacity(0.34)
    }
    /// 被選取／主要動作用的品牌 tint。
    static var accentTint: Color { AppBrand.accent.opacity(0.82) }
    static var accentSoftTint: Color { AppBrand.accent.opacity(0.22) }
}

extension View {
    /// macOS 26+：Liquid Glass；以下：material＋fallback 色。同一個呼叫點兩邊都對。
    @ViewBuilder
    func typeGlass<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color
    ) -> some View {
        if #available(macOS 26.0, *), TypeGlass.enabled {
            let glass: Glass = (tint.map { Glass.regular.tint($0) } ?? .regular).interactive(interactive)
            self.glassEffect(glass, in: shape)
        } else {
            self.background(fallback, in: shape).background(.thinMaterial, in: shape)
        }
    }

    /// 卡片：圓角 18、暖 tint、細邊。
    @MainActor
    func glassCard(cornerRadius: CGFloat = TypeGlass.cardRadius, rim: Color? = nil, rimOpacity: Double? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let rimColor = rim ?? AppBrand.retroMuted
        let opacity = rimOpacity ?? (rim == nil ? 0.16 : 0.45)
        return self
            .typeGlass(shape, tint: TypeGlass.cardTint, fallback: AppBrand.retroPanel)
            .overlay(shape.strokeBorder(rimColor.opacity(opacity), lineWidth: 1))
    }

    /// Popover 根：macOS 26+ 的 NSPopover 本身就是 Liquid Glass，什麼都不畫讓它透出來；
    /// 舊系統補回不透明暖底。
    @MainActor
    func popoverSurface() -> some View { modifier(PopoverSurfaceModifier()) }

    /// 可點的方塊（模式卡、側欄項目）：選取時帶品牌 tint，未選取是素玻璃。
    @MainActor
    func glassTile(selected: Bool, cornerRadius: CGFloat = TypeGlass.tileRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .typeGlass(
                shape,
                tint: selected ? TypeGlass.accentSoftTint : TypeGlass.cardTint,
                interactive: true,
                fallback: selected ? AppBrand.retroPanelRaised : AppBrand.retroPanel
            )
            .overlay(shape.strokeBorder(
                selected ? AppBrand.accent.opacity(0.70) : AppBrand.retroMuted.opacity(0.18),
                lineWidth: 1
            ))
    }

    /// 主要動作（開始聽寫）：品牌色玻璃，錄音中轉紅。
    func glassPrimary(color: Color, cornerRadius: CGFloat = TypeGlass.tileRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .typeGlass(shape, tint: color.opacity(0.88), interactive: true, fallback: color)
            .overlay(shape.strokeBorder(Color.white.opacity(0.42), lineWidth: 1))
    }
}

/// 內容層卡片（popover 與設定頁共用）：不用 glassEffect。
/// 兩個理由：① NSPopover 裡再疊 glass 會被系統攤平成灰材質（09-17 截圖實證）；
/// ② 設定頁十幾張玻璃卡讓一般分頁開啟從 0.7 s 變 1.3 s（09-17 A/B 量測）。
/// Apple 的 Liquid Glass 指引本來就是：玻璃給浮在內容上的控制層（側欄、按鈕、膠囊），內容層不鋪玻璃。
@MainActor
extension View {
    func popoverCard(cornerRadius: CGFloat = TypeGlass.cardRadius, rim: Color? = nil, rimOpacity: Double? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let rimColor = rim ?? AppBrand.retroMuted
        let opacity = rimOpacity ?? (rim == nil ? 0.18 : 0.45)
        return self
            .background(shape.fill(AppBrand.retroPanel.opacity(AppBrand.isDark ? 0.55 : 0.62)))
            .overlay(shape.strokeBorder(rimColor.opacity(opacity), lineWidth: 1))
    }

    func popoverTile(selected: Bool, cornerRadius: CGFloat = TypeGlass.tileRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(selected
                ? AppBrand.accent.opacity(AppBrand.isDark ? 0.22 : 0.15)
                : AppBrand.retroPanel.opacity(AppBrand.isDark ? 0.50 : 0.55)))
            .overlay(shape.strokeBorder(
                selected ? AppBrand.accent.opacity(0.65) : AppBrand.retroMuted.opacity(0.20),
                lineWidth: 1
            ))
            .shadow(color: selected ? AppBrand.accent.opacity(0.18) : .clear, radius: 10, y: 4)
    }

    /// 主要動作：品牌漸層＋玻璃高光（上緣白色漸層）＋白邊，錄音中換紅。
    func popoverPrimary(color: Color, gradient: LinearGradient?, cornerRadius: CGFloat = TypeGlass.tileRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(
                shape.fill(gradient.map { AnyShapeStyle($0) } ?? AnyShapeStyle(color))
            )
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(0.32), Color.white.opacity(0.04), Color.clear],
                    startPoint: .top, endPoint: .bottom
                ))
                .allowsHitTesting(false)
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
            .shadow(color: color.opacity(0.35), radius: 14, y: 6)
    }
}

extension View {
    /// 系統 `.glass`／`.glassProminent` button style；舊系統退回 bordered。
    func glassButton() -> some View { modifier(GlassButtonModifier(prominent: false)) }
    func glassProminentButton() -> some View { modifier(GlassButtonModifier(prominent: true)) }
}

struct PopoverSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(AppBrand.retroBackground)
        }
    }
}

struct GlassButtonModifier: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// 相鄰 glass 元件的容器：macOS 26+ 用 GlassEffectContainer 讓系統合成；以下直接放內容。
struct TypeGlassContainer<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 設定視窗底：奶油／暖炭底加幾團模糊的琥珀、薰衣草色塊，讓上面的玻璃有東西可折射。
/// 純靜態，不動畫。**只畫一次**：四團大半徑 blur 若交給 SwiftUI 每次 layout 重算，
/// 開設定視窗會卡（09-17 實測）；改成 CoreGraphics 一次畫成點陣圖快取，之後只是貼圖。
struct AmbientBackdrop: View {
    var body: some View {
        Image(nsImage: AmbientBackdropCache.image(dark: AppBrand.isDark))
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .ignoresSafeArea()
    }
}

@MainActor
enum AmbientBackdropCache {
    private static var cache: [Bool: NSImage] = [:]
    /// 低解析度就夠（全是模糊），放大時 interpolation 會補平。
    private static let size = NSSize(width: 560, height: 400)

    static func image(dark: Bool) -> NSImage {
        if let cached = cache[dark] { return cached }
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base = dark ? NSColor(calibratedRed: 0.118, green: 0.102, blue: 0.086, alpha: 1)
                            : NSColor(calibratedRed: 1.0, green: 0.973, blue: 0.945, alpha: 1)
            ctx.setFillColor(base.cgColor)
            ctx.fill(rect)
            // (顏色, 透明度, 半徑, 圓心 x/y 比例)：跟原 SwiftUI 版本同一組色團
            let blobs: [(NSColor, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.29, alpha: 1), dark ? 0.22 : 0.42, 0.62, 0.18, 0.86),
                (NSColor(calibratedRed: 0.976, green: 0.451, blue: 0.086, alpha: 1), dark ? 0.16 : 0.22, 0.55, 0.88, 0.78),
                (NSColor(calibratedRed: 0.68, green: 0.60, blue: 0.95, alpha: 1), dark ? 0.18 : 0.30, 0.50, 0.82, 0.14),
                (dark ? NSColor(calibratedRed: 0.169, green: 0.147, blue: 0.125, alpha: 1)
                      : NSColor(calibratedRed: 1.0, green: 0.925, blue: 0.867, alpha: 1), 0.9, 0.62, 0.20, 0.12),
            ]
            for (color, alpha, radius, fx, fy) in blobs {
                let center = CGPoint(x: rect.width * fx, y: rect.height * fy)
                let r = rect.height * radius
                let colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { continue }
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
            }
            return true
        }
        cache[dark] = image
        return image
    }
}
