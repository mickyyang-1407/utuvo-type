@preconcurrency import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

/// Carbon 對已存在的熱鍵回 -9878；Swift 沒有把 eExistingHotKeyErr 曝出來，這裡
/// 直接用 OSStatus 包這個值。所有 Carbon hot-key 註冊失敗都在這個檔判定。
private let existingHotKeyErrCode: OSStatus = OSStatus(-9878)

struct ShortcutSpec: Sendable, Equatable {
    let displayName: String
    let keyCode: UInt32
    let modifiers: UInt32
    /// Fn（🌐）修飾鍵。Carbon RegisterEventHotKey 沒有對應的 bit，
    /// 帶 Fn 的組合只能走 NSEvent／CGEventTap 監聽路徑。
    let requiresFn: Bool

    init(displayName: String, keyCode: UInt32, modifiers: UInt32, requiresFn: Bool = false) {
        self.displayName = displayName
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.requiresFn = requiresFn
    }

    static func parse(_ value: String) -> ShortcutSpec? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lowercased = raw.lowercased()
        var modifiers: UInt32 = 0
        // 偵測與後面 keyName 的剝除必須對稱：任何位置的 "fn" 都當 Fn 修飾鍵
        //（本表的 key name 不含 "fn" 子字串，不會誤判）。
        let requiresFn = raw.contains("🌐") || lowercased.contains("fn")
        if raw.contains("⌘") || lowercased.contains("command") || lowercased.contains("cmd") {
            modifiers |= UInt32(cmdKey)
        }
        if raw.contains("⌥") || lowercased.contains("option") || lowercased.contains("alt") {
            modifiers |= UInt32(optionKey)
        }
        if raw.contains("⌃") || lowercased.contains("control") || lowercased.contains("ctrl") {
            modifiers |= UInt32(controlKey)
        }
        if raw.contains("⇧") || lowercased.contains("shift") {
            modifiers |= UInt32(shiftKey)
        }

        let keyName = raw
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⌃", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .replacingOccurrences(of: "command", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "cmd", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "option", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "alt", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "control", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "ctrl", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "shift", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "🌐", with: "")
            .replacingOccurrences(of: "fn", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let keyCode = ShortcutKey.keyCode(for: keyName)
        guard let keyCode else { return nil }
        // F13–F20 這類鍵本身就帶 .function flag；Fn 修飾鍵只對一般鍵有意義。
        let fn = ShortcutKey.fnHeld(fnFlagSet: requiresFn, keyCode: keyCode)
        var display = raw
        if requiresFn && !fn {
            // Fn 被剔除時顯示名稱也要跟著剔除，否則 UI 顯示 "Fn+F13"、
            // 實際上 bare F13 就會觸發。
            display = display
                .replacingOccurrences(of: "🌐", with: "")
                .replacingOccurrences(of: "fn+", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "fn", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ShortcutSpec(displayName: display, keyCode: keyCode, modifiers: modifiers, requiresFn: fn)
    }
}

enum ShortcutKey {
    private static let namedKeyCodes: [String: UInt32] = [
        "SPACE": UInt32(kVK_Space),
        "RETURN": UInt32(kVK_Return),
        "ENTER": UInt32(kVK_Return),
        "TAB": UInt32(kVK_Tab),
        "ESC": UInt32(kVK_Escape),
        "ESCAPE": UInt32(kVK_Escape),
        "DELETE": UInt32(kVK_Delete),
        "BACKSPACE": UInt32(kVK_Delete),
        "FORWARDDELETE": UInt32(kVK_ForwardDelete),
        "FORWARDDEL": UInt32(kVK_ForwardDelete),
        "UP": UInt32(kVK_UpArrow),
        "ARROWUP": UInt32(kVK_UpArrow),
        "DOWN": UInt32(kVK_DownArrow),
        "ARROWDOWN": UInt32(kVK_DownArrow),
        "LEFT": UInt32(kVK_LeftArrow),
        "ARROWLEFT": UInt32(kVK_LeftArrow),
        "RIGHT": UInt32(kVK_RightArrow),
        "ARROWRIGHT": UInt32(kVK_RightArrow),
        "PAGEUP": UInt32(kVK_PageUp),
        "PAGEDOWN": UInt32(kVK_PageDown),
        "HOME": UInt32(kVK_Home),
        "END": UInt32(kVK_End),
        "HELP": UInt32(kVK_Help),
        "0": UInt32(kVK_ANSI_0),
        "1": UInt32(kVK_ANSI_1),
        "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4),
        "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6),
        "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        "A": UInt32(kVK_ANSI_A),
        "B": UInt32(kVK_ANSI_B),
        "C": UInt32(kVK_ANSI_C),
        "D": UInt32(kVK_ANSI_D),
        "E": UInt32(kVK_ANSI_E),
        "F": UInt32(kVK_ANSI_F),
        "G": UInt32(kVK_ANSI_G),
        "H": UInt32(kVK_ANSI_H),
        "I": UInt32(kVK_ANSI_I),
        "J": UInt32(kVK_ANSI_J),
        "K": UInt32(kVK_ANSI_K),
        "L": UInt32(kVK_ANSI_L),
        "M": UInt32(kVK_ANSI_M),
        "N": UInt32(kVK_ANSI_N),
        "O": UInt32(kVK_ANSI_O),
        "P": UInt32(kVK_ANSI_P),
        "Q": UInt32(kVK_ANSI_Q),
        "R": UInt32(kVK_ANSI_R),
        "S": UInt32(kVK_ANSI_S),
        "T": UInt32(kVK_ANSI_T),
        "U": UInt32(kVK_ANSI_U),
        "V": UInt32(kVK_ANSI_V),
        "W": UInt32(kVK_ANSI_W),
        "X": UInt32(kVK_ANSI_X),
        "Y": UInt32(kVK_ANSI_Y),
        "Z": UInt32(kVK_ANSI_Z),
        // 退路鍵（⌥\`）：筆電與機械鍵盤都不會被其他 App 佔用，與 Gemini /
        // ChatGPT / Raycast / Alfred 預設的 ⌥Space 不衝突；displayName 直接用反引號字元。
        "`": UInt32(kVK_ANSI_Grave),
        "GRAVE": UInt32(kVK_ANSI_Grave)
    ]

    private static let functionKeyCodes: [String: UInt32] = [
        "F1": UInt32(kVK_F1), "F2": UInt32(kVK_F2), "F3": UInt32(kVK_F3),
        "F4": UInt32(kVK_F4), "F5": UInt32(kVK_F5), "F6": UInt32(kVK_F6),
        "F7": UInt32(kVK_F7), "F8": UInt32(kVK_F8), "F9": UInt32(kVK_F9),
        "F10": UInt32(kVK_F10), "F11": UInt32(kVK_F11), "F12": UInt32(kVK_F12),
        "F13": UInt32(kVK_F13), "F14": UInt32(kVK_F14), "F15": UInt32(kVK_F15),
        "F16": UInt32(kVK_F16), "F17": UInt32(kVK_F17), "F18": UInt32(kVK_F18),
        "F19": UInt32(kVK_F19), "F20": UInt32(kVK_F20)
    ]

    private static let keyNamesByCode: [UInt32: String] = {
        var result: [UInt32: String] = [:]
        for (name, code) in namedKeyCodes where result[code] == nil {
            result[code] = name
        }
        for (name, code) in functionKeyCodes {
            result[code] = name
        }
        return result
    }()

    static func keyCode(for name: String) -> UInt32? {
        let normalized = name
            .replacingOccurrences(of: "␣", with: "SPACE")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        if let code = namedKeyCodes[normalized] { return code }
        return functionKeyCodes[normalized]
    }

    static func name(for keyCode: UInt32) -> String? {
        keyNamesByCode[keyCode]
    }

    /// 這些鍵按下時 macOS 會自動附上 .function flag（不代表使用者按著 Fn）。
    /// 判斷 Fn 修飾鍵時必須把它們排除。
    private static let functionFlaggedKeyCodes: Set<UInt32> = {
        var codes = Set(functionKeyCodes.values)
        codes.formUnion([
            UInt32(kVK_UpArrow), UInt32(kVK_DownArrow),
            UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow),
            UInt32(kVK_PageUp), UInt32(kVK_PageDown),
            UInt32(kVK_Home), UInt32(kVK_End),
            UInt32(kVK_ForwardDelete), UInt32(kVK_Help)
        ])
        return codes
    }()

    static func isFunctionFlaggedKey(_ keyCode: UInt32) -> Bool {
        functionFlaggedKeyCodes.contains(keyCode)
    }

    /// Recorder 與 matcher 必須用同一條規則判斷「使用者是否真的按著 Fn」，
    /// 否則錄下來的快捷鍵會永遠比對不到。
    static func fnHeld(fnFlagSet: Bool, keyCode: UInt32) -> Bool {
        fnFlagSet && !isFunctionFlaggedKey(keyCode)
    }
}

final class GlobalShortcut: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.utuvo.type", category: "shortcut")
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var isPressed = false
    // 只在主執行緒（tap 與 monitor 都掛在 main run loop）讀寫：
    // 記錄哪個 keyDown 被 tap 吞掉，對應的 keyUp 才一併吞，避免前景 app 收到孤兒 keyUp。
    private var swallowedDown = false
    private static let hotKeySignature = OSType(0x55545556)
    private let spec: ShortcutSpec
    private let keyCode: UInt16
    private let requiredModifiers: NSEvent.ModifierFlags
    private let requiresFn: Bool
    private let identifier: UInt32
    private let onPress: @MainActor @Sendable () -> Void
    private let onRelease: (@MainActor @Sendable () -> Void)?
    /// 別人搶走 Carbon hot-key 時由 listen-only tap 觸發；AppDelegate 收到會 reclaim
    /// 並補上本次被吃掉的按壓。nil＝不裝偵測（Fn／Carbon 失敗路徑不裝）。
    private let onStolen: (@MainActor @Sendable () -> Void)?
    // 偵測用 listen-only tap：只觀察 keyDown，不吞事件。Carbon 註冊成功才裝。
    private var listenEventTap: CFMachPort?
    private var listenEventTapSource: CFRunLoopSource?
    // tap 看到比對得上的 keyDown 時記下時間；Carbon deliver(isRelease:false) 到就清掉；
    // 250ms 後還留著就視為被搶。兩個欄位只在 main thread 讀寫（tap 與 deliver 都掛
    // main run loop）。
    private var lastSeenKeyDown: Date?
    private var stealDetectTask: Task<Void, Never>?

    init(
        spec: ShortcutSpec,
        onPress: @escaping @MainActor @Sendable () -> Void,
        onRelease: (@MainActor @Sendable () -> Void)? = nil,
        onStolen: (@MainActor @Sendable () -> Void)? = nil,
        identifier: UInt32 = 1
    ) throws {
        self.spec = spec
        self.keyCode = UInt16(spec.keyCode)
        self.requiredModifiers = Self.modifierFlags(for: spec.modifiers)
        self.requiresFn = spec.requiresFn
        self.identifier = identifier
        self.onPress = onPress
        self.onRelease = onRelease
        self.onStolen = onStolen

        // Fn 修飾鍵在 Carbon 沒有對應 bit，只能走監聽路徑。監聽路徑沒有
        // 輔助使用權限就完全收不到任何事件——這裡直接把失敗說出來，
        // 不能裝完監聽就回報成功。
        if spec.requiresFn {
            guard AXIsProcessTrusted() else {
                throw ProviderError.unavailable("Fn 快捷鍵需要輔助使用權限；請先在系統設定授權後重新設定（Fn shortcuts need Accessibility permission）")
            }
            installEventMonitors()
            installCGEventTap()
            Self.logger.info("shortcut uses Fn modifier; monitor-only path keyCode=\(self.keyCode, privacy: .public)")
            return
        }

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let installStatus = eventTypes.withUnsafeBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
                // 每個 GlobalShortcut 都裝了自己的 handler；不比對 hotKeyID 的話，
                // 任何熱鍵事件都會被先裝的 handler 吃掉並送錯 callback。
                var hotKeyID = EventHotKeyID()
                let idStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard idStatus == noErr else {
                    // 讀不到參數不等於「事件屬於別人」，掉事件要留下痕跡。
                    GlobalShortcut.logger.error("hotkey id read failed status=\(idStatus, privacy: .public)")
                    return OSStatus(eventNotHandledErr)
                }
                guard hotKeyID.signature == GlobalShortcut.hotKeySignature,
                      hotKeyID.id == shortcut.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                Task { @MainActor in
                    shortcut.deliver(isRelease: isRelease)
                }
                return noErr
                },
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )
        }
        guard installStatus == noErr else {
            throw ProviderError.unavailable("無法安裝全域快捷鍵事件（Failed to install the global shortcut event handler）")
        }

        let hotKeyIdentifier = EventHotKeyID(signature: Self.hotKeySignature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        Self.logger.info("carbon register status=\(registerStatus, privacy: .public) keyCode=\(self.keyCode, privacy: .public)")
        if registerStatus != noErr {
            // Carbon 對已註冊的組合一律回 eExistingHotKeyErr(-9878)；
            // 這不是監聽路徑能救的，要讓 UI 把衝突告訴使用者。
            if registerStatus == existingHotKeyErrCode {
                if let handlerRef { RemoveEventHandler(handlerRef) }
                self.handlerRef = nil
                throw ProviderError.hotkeyTaken(spec.displayName)
            }
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            // 某些鍵盤配置會讓 RegisterEventHotKey 拒絕 F13–F20；退回監聽路徑。
            // 監聽路徑需要輔助使用權限，沒有就明講失敗。
            guard AXIsProcessTrusted() else {
                throw ProviderError.unavailable("快捷鍵註冊失敗，可能與其他 App 衝突（Shortcut registration failed; it may conflict with another app）")
            }
            installEventMonitors()
            installCGEventTap()
        } else {
            // Carbon 註冊成功才裝 steal detect（Fn／Carbon 失敗路徑已有 defaultTap／monitor，
            // 不要疊加觀察 tap）。
            installStealDetectionTap()
        }
    }

    deinit {
        stealDetectTask?.cancel()
        stealDetectTask = nil
        lastSeenKeyDown = nil
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let listenEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), listenEventTapSource, .commonModes)
        }
        if let listenEventTap {
            CGEvent.tapEnable(tap: listenEventTap, enable: false)
            CFMachPortInvalidate(listenEventTap)
        }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installEventMonitors() {
        // Carbon remains the primary path. These monitors are read-only and
        // exist to cover high function keys that some keyboards expose
        // outside the Carbon hot-key stream. The pressed guard in deliver()
        // de-duplicates both paths.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            self?.observe(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    private func installCGEventTap() {
        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let keyUpMask = CGEventMask(1) << CGEventType.keyUp.rawValue
        let eventMask = keyDownMask | keyUpMask
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // defaultTap（非 listenOnly）：比對到的快捷鍵要吞掉，否則 Fn＋字母
        // 這類組合會把字元漏進前景 app（Carbon 熱鍵本來就會吞，監聽路徑要對齊）。
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let shortcut = Unmanaged<GlobalShortcut>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    shortcut.reenableEventTap()
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown || type == .keyUp {
                    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    let consume = shortcut.handleTapEvent(
                        keyCode: keyCode,
                        flags: event.flags,
                        isRelease: type == .keyUp
                    )
                    if consume { return nil }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        guard let eventTap else {
            // fail-open 要留痕：沒有 tap＝Fn 組合不吞事件、字元會漏進前景 app。
            Self.logger.error("event tap creation failed; keystrokes will not be consumed")
            return
        }
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func reenableEventTap() {
        guard let eventTap else { return }
        // tap 被 timeout 停用期間 keyUp 可能繞過；歸零配對狀態避免吞掉別人的 keyUp。
        swallowedDown = false
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// 觀察用 tap：只看 keyDown，不吞事件。背景檢查「使用者按了我們的熱鍵
    /// 但 Carbon 沒送 hotKeyPressed」——若 250ms 內 Carbon 沒回，就呼叫 onStolen。
    private func installStealDetectionTap() {
        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        listenEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let shortcut = Unmanaged<GlobalShortcut>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    shortcut.reenableStealTap()
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    let flags = event.flags
                    var actualModifiers: NSEvent.ModifierFlags = []
                    if flags.contains(.maskCommand) { actualModifiers.insert(.command) }
                    if flags.contains(.maskAlternate) { actualModifiers.insert(.option) }
                    if flags.contains(.maskControl) { actualModifiers.insert(.control) }
                    if flags.contains(.maskShift) { actualModifiers.insert(.shift) }
                    shortcut.handleStealTapKeyDown(
                        keyCode: keyCode,
                        actualModifiers: actualModifiers,
                        fnFlagSet: flags.contains(.maskSecondaryFn)
                    )
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        guard let listenEventTap else {
            // 沒有 tap ＝ 無輔助使用權限；功能照常，但失去了被搶偵測能力。
            Self.logger.error("steal-detect tap unavailable")
            return
        }
        listenEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, listenEventTap, 0)
        if let listenEventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), listenEventTapSource, .commonModes)
            CGEvent.tapEnable(tap: listenEventTap, enable: true)
        }
    }

    private func reenableStealTap() {
        guard let listenEventTap else { return }
        CGEvent.tapEnable(tap: listenEventTap, enable: true)
    }

    /// tap callback 已比對過修飾鍵符合我們 spec 才呼叫這裡。
    /// 記下 keyDown 時間並起 250ms 計時器；Carbon deliver(isRelease:false) 來會清掉。
    private func handleStealTapKeyDown(
        keyCode: UInt16,
        actualModifiers: NSEvent.ModifierFlags,
        fnFlagSet: Bool
    ) {
        guard keyCode == self.keyCode else { return }
        guard matchesModifiers(
            actualModifiers,
            fnFlagSet: fnFlagSet,
            keyCode: UInt32(keyCode)
        ) else { return }
        lastSeenKeyDown = Date()
        stealDetectTask?.cancel()
        stealDetectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            // 期間 Carbon 沒送 press → lastSeenKeyDown 仍在 → 觸發 stolen。
            if self.lastSeenKeyDown != nil {
                self.lastSeenKeyDown = nil
                self.onStolen?()
            }
        }
    }

    /// Unregister + Register 同一 spec（同 id／signature）：變成「最後一個註冊者」，
    /// 把別人靜悄悄搶回去的 Carbon hot-key 收回到我們這邊。
    @MainActor
    func reclaim() -> Bool {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let hotKeyIdentifier = EventHotKeyID(signature: Self.hotKeySignature, id: identifier)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        Self.logger.info("hotkey reclaimed keyCode=\(self.keyCode, privacy: .public) status=\(status, privacy: .public)")
        return status == noErr
    }

    private func observe(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        let isRelease = event.type == .keyUp
        // keyUp 只比對 keyCode：放開時修飾鍵（尤其 Fn）常比主鍵先放開，
        // 比對修飾鍵會漏掉 release，isPressed 卡死。deliver() 會擋不成對的 keyUp。
        if !isRelease {
            guard matchesModifiers(
                normalizedModifiers(event.modifierFlags),
                fnFlagSet: event.modifierFlags.contains(.function),
                keyCode: UInt32(event.keyCode)
            ) else { return }
        }
        Task { @MainActor [weak self] in
            self?.deliver(isRelease: isRelease)
        }
    }

    /// 回傳 true 表示這個事件要被 tap 吞掉（不再送往前景 app）。
    private func handleTapEvent(keyCode: UInt16, flags: CGEventFlags, isRelease: Bool) -> Bool {
        guard keyCode == self.keyCode else { return false }
        if isRelease {
            // keyUp 只比對 keyCode（理由同上）；只有對應的 keyDown 被吞掉時才吞 keyUp。
            let consume = swallowedDown
            swallowedDown = false
            Task { @MainActor [weak self] in
                self?.deliver(isRelease: true)
            }
            return consume
        }
        var actualModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { actualModifiers.insert(.command) }
        if flags.contains(.maskAlternate) { actualModifiers.insert(.option) }
        if flags.contains(.maskControl) { actualModifiers.insert(.control) }
        if flags.contains(.maskShift) { actualModifiers.insert(.shift) }
        guard matchesModifiers(
            actualModifiers,
            fnFlagSet: flags.contains(.maskSecondaryFn),
            keyCode: UInt32(keyCode)
        ) else { return false }
        swallowedDown = true
        Task { @MainActor [weak self] in
            self?.deliver(isRelease: false)
        }
        return true
    }

    private func matchesModifiers(
        _ actualModifiers: NSEvent.ModifierFlags,
        fnFlagSet: Bool,
        keyCode: UInt32
    ) -> Bool {
        guard actualModifiers == requiredModifiers else { return false }
        // 只在快捷鍵要求 Fn 時檢查 Fn；不要求時忽略該 flag——
        // 部分外接鍵盤／remapper 會在合成事件帶 maskSecondaryFn，
        // 拿它當否決條件會殺掉正常的 ⌘⌥ 組合（Carbon 路徑本來也忽略 Fn）。
        if requiresFn {
            return ShortcutKey.fnHeld(fnFlagSet: fnFlagSet, keyCode: keyCode)
        }
        return true
    }

    private static func modifierFlags(for modifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    private func normalizedModifiers(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .help, .function])
    }

    @MainActor
    private func deliver(isRelease: Bool) {
        if isRelease {
            guard isPressed else { return }
            isPressed = false
            Self.logger.info("shortcut release keyCode=\(self.keyCode, privacy: .public)")
            onRelease?()
        } else {
            guard !isPressed else { return }
            isPressed = true
            // Carbon 收到 press → 取消 in-flight 的 steal 檢查。
            stealDetectTask?.cancel()
            stealDetectTask = nil
            lastSeenKeyDown = nil
            Self.logger.info("shortcut press keyCode=\(self.keyCode, privacy: .public)")
            onPress()
        }
    }
}
