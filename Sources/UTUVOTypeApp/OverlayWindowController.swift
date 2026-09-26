import AppKit

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private var orb: VoiceOrbView?
    private let size = NSSize(width: 96, height: 96)

    func update(model: AppModel, preferences: AppPreferences) {
        guard preferences.overlayStyle == .live, model.isRecording || model.isProcessing else {
            hide(); return
        }
        let panel = ensurePanel()
        orb?.levelProvider = { [weak model] in model?.liveVoiceLevel() }
        orb?.phase = model.isRecording ? .listening : .processing
        orb?.accessibilityStatus = model.isRecording
            ? preferences.tr("聆聽中", "Listening") : preferences.tr("整理中", "Processing")
        position(panel, at: preferences.overlayPosition)
        panel.orderFrontRegardless()
        orb?.isActive = true
    }
    func hide() {
        orb?.isActive = false
        panel?.orderOut(nil)
    }
    /// Synthetic preview only: no microphone or normal app lifecycle.
    @discardableResult
    func showPreview(model: AppModel, listening: Bool, position: OverlayPosition) -> NSPanel {
        let panel = ensurePanel()
        orb?.levelProvider = { listening ? -24 : nil }
        orb?.phase = listening ? .listening : .processing
        orb?.accessibilityStatus = listening ? "聆聽中" : "整理中"
        self.position(panel, at: position)
        panel.orderFrontRegardless()
        orb?.isActive = true
        return panel
    }
    var previewDiagnostics: String {
        guard let orb else { return "尚未顯示" }
        return "\(orb.renderingBackend) · frames \(orb.renderedFrames) · \(orb.isRenderingPaused ? "paused" : "running")"
    }
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        let orb = VoiceOrbView(frame: NSRect(origin: .zero, size: size))
        orb.autoresizingMask = [.width, .height]
        panel.contentView = orb
        self.orb = orb; self.panel = panel
        return panel
    }
    private func position(_ panel: NSPanel, at position: OverlayPosition) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = position == .top ? visible.maxY - panel.frame.height - 24 : visible.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
