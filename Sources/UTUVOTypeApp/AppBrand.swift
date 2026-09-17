import AppKit
import SwiftUI

enum AppBrand {
    static let displayName = "UTUVO Type"
    static let subtitle = "快速、本機優先的語音輸入"

    /// 由 AppPreferences 在 init 與 didSet 同步。Views 都 observe preferences，
    /// 主題一改就整體重繪，重繪時讀到新 palette。
    /// MAC1（2026-09-11）：改 @MainActor —— 執行緒安全從「靠約定」升級成「靠型別」。
    @MainActor static var themeChoice: AppThemeChoice = .system

    @MainActor static var isDark: Bool {
        switch themeChoice {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApplication.shared.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    // 淡色＝奶油底＋暖杏面板；深色＝暖炭底同一組語意。accent 兩邊同一顆 UTUVO 橘
    //（產品決定：不用粉紅）。字體圓體。
    static let accent = Color(red: 0.976, green: 0.451, blue: 0.086)         // UTUVO 橘
    static let accentNSColor = NSColor(calibratedRed: 0.976, green: 0.451, blue: 0.086, alpha: 1)
    static let lavender = Color(red: 0.68, green: 0.60, blue: 0.95)          // 薰衣草（次要動畫色）
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.29)              // 琥珀金（漸層亮端）

    /// 品牌漸層（橘→琥珀金）：2026-08-23 視覺升級，Dribbble 高分錄音 UI 的漸層語言。
    /// 不用粉紅（產品決定）。
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [amber, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @MainActor static var retroBackground: Color {
        isDark ? Color(red: 0.118, green: 0.102, blue: 0.086)                // 暖炭底
               : Color(red: 1.0, green: 0.973, blue: 0.945)                  // 奶油白底
    }
    @MainActor static var retroPanel: Color {
        isDark ? Color(red: 0.169, green: 0.147, blue: 0.125)
               : Color(red: 1.0, green: 0.925, blue: 0.867)                  // 淡杏橘面板
    }
    @MainActor static var retroPanelRaised: Color {
        isDark ? Color(red: 0.216, green: 0.188, blue: 0.157)
               : Color(red: 0.996, green: 0.882, blue: 0.796)
    }
    @MainActor static var retroText: Color {
        isDark ? Color(red: 0.95, green: 0.92, blue: 0.88)
               : Color(red: 0.34, green: 0.26, blue: 0.20)                   // 暖棕主文字
    }
    @MainActor static var retroMuted: Color {
        isDark ? Color(red: 0.63, green: 0.58, blue: 0.53)
               : Color(red: 0.64, green: 0.55, blue: 0.47)
    }
    @MainActor static var retroGreen: Color {
        isDark ? Color(red: 0.50, green: 0.80, blue: 0.58)
               : Color(red: 0.42, green: 0.75, blue: 0.52)                   // 抹茶綠
    }

    @MainActor static var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Popover／視窗 chrome 要跟內容同一套深淺：內容透明之後，NSPopover 自己的玻璃若還是
    /// 系統外觀，使用者選「深色」時會變成白玻璃上白字。
    @MainActor static var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // 名稱保留 mono 以免大改呼叫點；實際字體已改為圓體（rounded）。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// macOS 26／27 介面字：SF Pro 系統字，圓體只留給品牌字樣與小徽章。
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Menu bar 圖示：品牌橘的語音泡泡＋I-beam＋句點，程式畫、任何 scale 都銳利。
    /// 不是 template：macOS 26／27 的 menu bar 會忽略 template 圖的 contentTintColor、一律畫成單色
    ///（09-17 實機看到黑色）；要橘就得自己上色。
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // 泡泡本體（實心）＋左下小尾巴
            let bubble = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.0, width: 15, height: 12), xRadius: 3.6, yRadius: 3.6)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 4.2, y: 5.0))
            tail.line(to: NSPoint(x: 3.2, y: 1.6))
            tail.line(to: NSPoint(x: 7.4, y: 4.6))
            tail.close()
            bubble.append(tail)
            accentNSColor.setFill()
            bubble.fill()
            // I-beam 與句點用 destinationOut 挖空，泡泡裡透出 menu bar 底色
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let beam = NSBezierPath()
            beam.append(NSBezierPath(roundedRect: NSRect(x: 5.4, y: 12.1, width: 4.6, height: 1.4), xRadius: 0.7, yRadius: 0.7))
            beam.append(NSBezierPath(roundedRect: NSRect(x: 5.4, y: 6.5, width: 4.6, height: 1.4), xRadius: 0.7, yRadius: 0.7))
            beam.append(NSBezierPath(roundedRect: NSRect(x: 7.0, y: 6.9, width: 1.4, height: 6.2), xRadius: 0.5, yRadius: 0.5))
            beam.append(NSBezierPath(ovalIn: NSRect(x: 11.6, y: 6.5, width: 2.0, height: 2.0)))
            NSColor.black.setFill()
            beam.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = displayName
        return image
    }
}

/// 錄音脈衝光暈（2026-08-23 視覺升級）：套在錄音中要「呼吸」的元素上。
struct PulseGlow: ViewModifier {
    var isActive: Bool
    var color: Color
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(0.55) : color.opacity(0.18),
                    radius: isActive ? (pulsing ? 22 : 12) : 6)
            .onAppear { pulsing = true }
            .animation(isActive ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                       value: pulsing)
    }
}

extension View {
    func pulseGlow(active: Bool, color: Color = AppBrand.accent) -> some View {
        modifier(PulseGlow(isActive: active, color: color))
    }
}
