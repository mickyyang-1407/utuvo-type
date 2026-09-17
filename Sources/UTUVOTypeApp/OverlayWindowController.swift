import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private weak var model: AppModel?

    func update(model: AppModel, preferences: AppPreferences) {
        self.model = model
        guard preferences.overlayStyle == .live,
              model.isRecording || model.isProcessing else {
            hide()
            return
        }

        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        panel.contentView = NSHostingView(rootView: OverlayStatusView(model: model))
        panel.setContentSize(NSSize(width: 128, height: 36))
        position(panel, at: preferences.overlayPosition)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 截圖／預覽用：不管錄音狀態，直接把膠囊畫出來。回傳 panel 供擷取。
    @discardableResult
    func showPreview(model: AppModel, listening: Bool, position: OverlayPosition) -> NSPanel {
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        panel.contentView = NSHostingView(rootView: OverlayStatusView(model: model, preview: listening ? .listening : .processing))
        panel.setContentSize(NSSize(width: 128, height: 36))
        self.position(panel, at: position)
        panel.orderFrontRegardless()
        return panel
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: OverlayStatusView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel, at position: OverlayPosition) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y: CGFloat
        switch position {
        case .top:
            y = visible.maxY - panel.frame.height - 24
        case .bottom:
            y = visible.minY + 24
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// 小膠囊：只有動畫，沒有文字（2026-08-21 產品決定縮小）。
private struct OverlayStatusView: View {
    enum Preview { case listening, processing }
    @ObservedObject var model: AppModel
    var preview: Preview? = nil

    private var showsWaveform: Bool {
        if let preview { return preview == .listening }
        return model.isRecording
    }

    var body: some View {
        Group {
            if showsWaveform {
                ListeningWaveform()
            } else {
                ProcessingDots()
            }
        }
        .frame(width: 124, height: 32)
        // Liquid Glass 膠囊：桌面透過玻璃折射進來，品牌橘細邊維持辨識度。
        .typeGlass(Capsule(), tint: TypeGlass.cardTint, fallback: AppBrand.retroBackground.opacity(0.97))
        .overlay(Capsule().strokeBorder(AppBrand.accent.opacity(0.55), lineWidth: 1.5))
        .padding(2)
        .colorScheme(AppBrand.colorScheme)
    }
}

// TimelineView 純函數動畫：不在 body 求值中寫任何 @Published／@State
//（見 body-eval-state-write 教訓），高度只由時間推導。
private struct ListeningWaveform: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3.5) {
                ForEach(0..<9, id: \.self) { index in
                    let phase = t * 3.1 + Double(index) * 0.85
                    let envelope = 0.55 + 0.45 * sin(t * 1.3 + Double(index) * 1.7)
                    let height = 5 + 13 * abs(sin(phase)) * envelope
                    Capsule()
                        .fill(AppBrand.accent)
                        .frame(width: 3, height: max(4, height))
                }
            }
        }
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = t * 2.4 - Double(index) * 0.45
                    let lift = max(0, sin(phase)) * 5
                    Circle()
                        .fill(AppBrand.lavender)
                        .frame(width: 7, height: 7)
                        .offset(y: -lift)
                }
            }
        }
    }
}
