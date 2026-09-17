import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

/// A click-then-press shortcut recorder. The user clicks once, then presses the
/// desired key combination; no manual syntax or text editing is required.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var shortcut: String
    @Binding var isCapturing: Bool
    /// (zh, en) -> displayed string. Default keeps existing zh-only call sites unchanged.
    var localize: (String, String) -> String = { zh, _ in zh }

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut, isCapturing: $isCapturing)
    }

    func makeNSView(context: Context) -> HotkeyCaptureButton {
        let button = HotkeyCaptureButton()
        button.localize = localize
        button.onBeginCapture = {
            context.coordinator.isCapturing.wrappedValue = true
        }
        button.onCapture = { value in
            context.coordinator.shortcut.wrappedValue = value
            context.coordinator.isCapturing.wrappedValue = false
        }
        button.onCancel = {
            context.coordinator.isCapturing.wrappedValue = false
        }
        button.apply(shortcut: shortcut, isCapturing: isCapturing)
        return button
    }

    func updateNSView(_ nsView: HotkeyCaptureButton, context: Context) {
        nsView.localize = localize
        nsView.apply(shortcut: shortcut, isCapturing: isCapturing)
    }

    final class Coordinator {
        let shortcut: Binding<String>
        let isCapturing: Binding<Bool>

        init(shortcut: Binding<String>, isCapturing: Binding<Bool>) {
            self.shortcut = shortcut
            self.isCapturing = isCapturing
        }
    }
}

final class HotkeyCaptureButton: NSButton {
    var onBeginCapture: (() -> Void)?
    var onCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var localize: (String, String) -> String = { zh, _ in zh }

    /// 錄製開始／結束時廣播，AppDelegate 據此暫停／恢復自家全域熱鍵——
    /// 否則錄製時按下目前綁定的鍵（例如 F14）會被 Carbon 搶去開始錄音。
    static let captureDidBegin = Notification.Name("com.utuvo.type.hotkeyCapture.began")
    static let captureDidEnd = Notification.Name("com.utuvo.type.hotkeyCapture.ended")

    private var capturing = false
    // 用 local monitor 抓鍵，不依賴 first responder：NSHostingView 裡的
    // makeFirstResponder 可能失敗，keyDown 永遠到不了本按鈕（實犯：
    // 2026-08-21 使用者回報任何按鍵與組合都錄不進去）。
    private var captureMonitor: Any?
    // 再加一層 session 級 CGEventTap（head-insert）：F14／F15 被 macOS 當亮度鍵在
    // NSEvent 層就吃掉、F13／F16–F18 常被 Stream Deck 之類搶走，只有在它們之前
    // 攔截才錄得到。需要輔助使用權限；建不起來就退回 local monitor。
    private var captureTap: CFMachPort?
    private var captureTapSource: CFRunLoopSource?
    // F1：關閉設定視窗（orderOut，view 不會離開 window）或切到別的 app 時必須結束錄製，
    // 否則 session 級 tap 繼續吞全系統按鍵並把第一個字母綁成快捷鍵。
    private var focusObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func apply(shortcut: String, isCapturing: Bool) {
        // F3：外部把 isCapturing 重設成 false（Clear／Reset 按鈕）時必須連 monitor 一起拆，
        // 否則舊 monitor 永久漏掉且下一次點擊會再疊一個。
        if !isCapturing, hasCaptureResources {
            endCaptureMonitor()
        }
        capturing = isCapturing
        title = isCapturing
            ? localize("按下快捷鍵…", "Press shortcut…")
            : (shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               ? localize("未設定・點擊後按鍵", "Not set · click, then press keys")
               : shortcut)
        toolTip = isCapturing
            ? localize("按下任意按鍵組合；Escape 取消", "Press any key combination; Escape cancels")
            : localize("點擊後按下想使用的快捷鍵", "Click, then press the shortcut you want")
        contentTintColor = isCapturing ? .controlAccentColor : .labelColor
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        beginCapture()
    }

    @objc private func beginCaptureAction() {
        beginCapture()
    }

    private func beginCapture() {
        guard !capturing else { return }
        capturing = true
        title = localize("按下快捷鍵…", "Press shortcut…")
        toolTip = localize("按下任意按鍵組合；Escape 取消", "Press any key combination; Escape cancels")
        contentTintColor = .controlAccentColor
        onBeginCapture?()
        window?.makeFirstResponder(self)
        tearDownCapture()
        NotificationCenter.default.post(name: Self.captureDidBegin, object: self)
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.capturing else { return event }
            self.capture(event)
            return nil
        }
        installCaptureTap()
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelCapture() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelCapture() }
            }
        ]
        needsDisplay = true
    }

    private var hasCaptureResources: Bool {
        captureMonitor != nil || captureTap != nil || !focusObservers.isEmpty
    }

    private func cancelCapture() {
        guard capturing else { return }
        capturing = false
        endCaptureMonitor()
        onCancel?()
    }

    private func installCaptureTap() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        captureTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let button = Unmanaged<HotkeyCaptureButton>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                // source 掛在 main run loop，callback 在主執行緒；同步處理避免連按時丟鍵（F4）。
                let consumed: Bool = MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = button.captureTap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return false
                    }
                    guard type == .keyDown, button.capturing else { return false }
                    button.capture(keyCode: keyCode, cgFlags: flags)
                    return true
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )
        guard let captureTap else { return }
        captureTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, captureTap, 0)
        if let captureTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), captureTapSource, .commonModes)
            CGEvent.tapEnable(tap: captureTap, enable: true)
        }
    }

    /// 只拆資源、不廣播（beginCapture 的重入清理與 deinit 用）。
    private func tearDownCapture() {
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }
        captureMonitor = nil
        if let captureTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), captureTapSource, .commonModes)
        }
        if let captureTap {
            CGEvent.tapEnable(tap: captureTap, enable: false)
            CFMachPortInvalidate(captureTap)
        }
        captureTapSource = nil
        captureTap = nil
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers = []
    }

    /// 結束錄製：拆資源並廣播 end。只有真的有資源在跑時才廣播，
    /// 否則每次 SwiftUI 重繪呼叫 apply(false) 都會誤發 end（F2）。
    private func endCaptureMonitor() {
        guard hasCaptureResources else { return }
        tearDownCapture()
        NotificationCenter.default.post(name: Self.captureDidEnd, object: self)
    }

    /// CGEventTap 路徑：把 CGEventFlags 轉成 NSEvent.ModifierFlags 後走同一套 capture 規則。
    private func capture(keyCode: UInt16, cgFlags: CGEventFlags) {
        guard capturing else { return }
        var flags: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskCommand) { flags.insert(.command) }
        if cgFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgFlags.contains(.maskControl) { flags.insert(.control) }
        if cgFlags.contains(.maskShift) { flags.insert(.shift) }
        if cgFlags.contains(.maskSecondaryFn) { flags.insert(.function) }
        captureKey(keyCode: keyCode, rawFlags: flags)
    }

    // F2：設定視窗關閉／切分頁把 view 拆出視窗時，capture 必須跟著結束，
    // 否則 local monitor 繼續吞整個 app 的鍵盤事件並默默改綁快捷鍵。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelCapture()
        }
    }

    deinit {
        // AppKit view 只會在主執行緒釋放；這裡只拆資源，不再廣播通知。
        MainActor.assumeIsolated { tearDownCapture() }
    }

    override func keyDown(with event: NSEvent) {
        guard capturing else {
            super.keyDown(with: event)
            return
        }

        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturing else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        captureKey(
            keyCode: event.keyCode,
            rawFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    private func captureKey(keyCode: UInt16, rawFlags: NSEvent.ModifierFlags) {
        guard capturing else { return }
        let flags = rawFlags.subtracting([.capsLock, .numericPad, .help, .function])

        if keyCode == UInt16(kVK_Escape), flags.isEmpty {
            capturing = false
            endCaptureMonitor()
            onCancel?()
            return
        }

        guard let keyName = ShortcutKey.name(for: UInt32(keyCode)) else { return }
        // F13–F20 等鍵本身帶 .function flag，不代表使用者按著 Fn。
        let fnHeld = ShortcutKey.fnHeld(
            fnFlagSet: rawFlags.contains(.function),
            keyCode: UInt32(keyCode)
        )
        let value = Self.displayName(modifiers: flags, keyName: keyName, fnHeld: fnHeld)
        capturing = false
        endCaptureMonitor()
        onCapture?(value)
    }

    private func configure() {
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        isBordered = true
        target = self
        action = #selector(beginCaptureAction)
        alignment = .center
        font = .systemFont(ofSize: 13, weight: .medium)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
    }

    private static func displayName(
        modifiers: NSEvent.ModifierFlags,
        keyName: String,
        fnHeld: Bool = false
    ) -> String {
        var result = fnHeld ? "Fn" : ""
        if modifiers.contains(.command) { result += "⌘" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.shift) { result += "⇧" }
        return result + keyName
    }
}
