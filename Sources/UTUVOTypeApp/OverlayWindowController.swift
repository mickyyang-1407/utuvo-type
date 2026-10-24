import AppKit

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private var orb: VoiceOrbView?
    private var badgeView: NSView?
    private var badgeLabel: NSTextField?
    private static let orbSize = NSSize(width: 96, height: 96)
    /// modes-v2：有標籤時面板加寬加高，圓球大小不變，標籤在圓球下方。
    static let badgeWidth: CGFloat = 160
    static let badgeHeight: CGFloat = 22
    static let badgeGap: CGFloat = 4

    /// 純函式：有沒有標籤決定面板大小（一般聽寫維持 96×96）。
    static func panelSize(badge: String?) -> NSSize {
        guard badge != nil else { return orbSize }
        return NSSize(width: badgeWidth, height: orbSize.height + badgeGap + badgeHeight)
    }

    /// 目前顯示的標籤（測試／診斷用）。
    var badgeText: String? { badgeView?.isHidden == false ? badgeLabel?.stringValue : nil }

    func update(model: AppModel, preferences: AppPreferences) {
        guard preferences.overlayStyle == .live, model.isRecording || model.isProcessing else {
            hide(); return
        }
        let panel = ensurePanel()
        orb?.levelProvider = { [weak model] in model?.liveVoiceLevel() }
        orb?.phase = model.isRecording ? .listening : .processing
        let badge = model.isRecording ? model.overlayBadge : nil
        orb?.accessibilityStatus = Self.accessibilityStatus(isRecording: model.isRecording,
                                                            limitNotice: model.recordingLimitNotice, preferences: preferences)
            + (badge.map { "（\($0)）" } ?? "")
        orb?.limitWarning = Self.showsLimitWarning(isRecording: model.isRecording, countdown: model.recordingLimitCountdown)
        apply(badge: badge, to: panel)
        position(panel, at: preferences.overlayPosition)
        panel.orderFrontRegardless()
        orb?.isActive = true
    }
    /// 錄音球的輔助說明（VoiceOver 念的那一句）。快到上限／很久沒聲音的倒數也放進來（repair-batch1）：
    /// 選單關著、畫面上只有這顆球的時候，倒數不能只活在選單裡。
    static func accessibilityStatus(isRecording: Bool, limitNotice: String?, preferences: AppPreferences) -> String {
        guard isRecording else { return preferences.tr("整理中", "Processing") }
        let listening = preferences.tr("聆聽中", "Listening")
        guard let limitNotice else { return listening }
        return preferences.tr("\(listening)：\(limitNotice)", "\(listening): \(limitNotice)")
    }
    /// 錄音中快到上限／很久沒聲音要停了：錄音球換成「快停了」的樣子（變灰、每秒閃一下；減少動態效果時固定變灰）。
    /// repair round 2：倒數不出聲（麥克風開著），選單關著時看得到的就是這顆球。
    static func showsLimitWarning(isRecording: Bool, countdown: RecordingLimits.StopReason?) -> Bool {
        isRecording && countdown != nil
    }
    func hide() {
        orb?.isActive = false
        panel?.orderOut(nil)
    }
    /// Synthetic preview only: no microphone or normal app lifecycle.
    @discardableResult
    func showPreview(model: AppModel, listening: Bool, position: OverlayPosition, limitWarning: Bool = false,
                     badge: String? = nil) -> NSPanel {
        let panel = ensurePanel()
        orb?.levelProvider = { listening ? -24 : nil }
        orb?.phase = listening ? .listening : .processing
        orb?.accessibilityStatus = listening ? "聆聽中" : "整理中"
        orb?.limitWarning = listening && limitWarning
        apply(badge: badge, to: panel)
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
        let size = Self.orbSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let orb = VoiceOrbView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(orb)
        let badgeView = NSView(frame: .zero)
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = Self.badgeHeight / 2
        badgeView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        badgeView.isHidden = true
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)   // 圓球的 accessibilityStatus 已經唸標籤
        badgeView.addSubview(label)
        container.addSubview(badgeView)
        panel.contentView = container
        self.orb = orb; self.panel = panel; self.badgeView = badgeView; self.badgeLabel = label
        return panel
    }

    /// 依標籤調整面板大小與排版：圓球固定 96×96 置中在上，標籤膠囊在下方。
    private func apply(badge: String?, to panel: NSPanel) {
        let size = Self.panelSize(badge: badge)
        if panel.frame.size != size { panel.setContentSize(size) }
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        orb?.frame = NSRect(x: (size.width - Self.orbSize.width) / 2, y: size.height - Self.orbSize.height,
                            width: Self.orbSize.width, height: Self.orbSize.height)
        guard let badge, let badgeView, let badgeLabel else {
            badgeView?.isHidden = true
            return
        }
        badgeLabel.stringValue = badge
        let textWidth = min(Self.badgeWidth - 4, ceil(badgeLabel.intrinsicContentSize.width) + 20)
        badgeView.frame = NSRect(x: (size.width - textWidth) / 2, y: 0, width: textWidth, height: Self.badgeHeight)
        let labelHeight = ceil(badgeLabel.intrinsicContentSize.height)
        badgeLabel.frame = NSRect(x: 8, y: (Self.badgeHeight - labelHeight) / 2, width: textWidth - 16, height: labelHeight)
        badgeView.isHidden = false
    }
    private func position(_ panel: NSPanel, at position: OverlayPosition) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = position == .top ? visible.maxY - panel.frame.height - 24 : visible.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
