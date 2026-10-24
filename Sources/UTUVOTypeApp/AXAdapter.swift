import AppKit
import ApplicationServices
import Foundation

/// A captured destination, never a lookup of whichever field is focused later.
@MainActor
protocol DictationDestination: AnyObject {
    var supportsCorrection: Bool { get }
    func insert(_ text: String) async -> Bool
    func replaceInsertedText(with text: String) -> Bool
    func invalidate()
    /// 剪貼簿退路貼上前的最後確認：先前回報沒寫進去的字，是不是其實晚到了（避免貼兩份）。
    func textPresent(_ text: String) -> Bool
    /// 開始聽寫當下游標前的文字（context-awareness-2：接續上一段要不要先補空白或拿掉的「，」）。
    /// 讀不到、或目的地已失效（使用者打字／點滑鼠／換焦點）回 nil＝不補。
    var textBeforeCursor: String? { get }
    /// 這個目的地是哪一個欄位（context-awareness-2：接續上一段只在同一個欄位；同一個 App 的別的欄位不算）。nil＝不知道＝不接續。
    var fieldIdentity: AnyHashable? { get }
    /// 開始聽寫當下的游標位置（UTF-16）。接續上一段要游標正好停在上一段送完的地方。nil＝不知道。
    var cursorLocation: Int? { get }
}

extension DictationDestination {
    func textPresent(_ text: String) -> Bool { false }
    var textBeforeCursor: String? { nil }
    var fieldIdentity: AnyHashable? { nil }
    var cursorLocation: Int? { nil }
}

@MainActor
final class AXAdapter {
    static let shared = AXAdapter()

    /// Captured before ASR. Unsupported fields return nil; no full-value reads.
    func capture(expectedPID: Int32? = nil) -> (any DictationDestination)? {
        capture(expectedPID: expectedPID, beforeUTF16: Self.minimumBeforeWindow)
    }

    /// 游標前至少讀這麼多（UTF-16），跟以前一樣。
    static let minimumBeforeWindow = 32
    /// 游標前最多讀這麼多（UTF-16）：上一段很長時也只讀有限的一段，不讀整份內容。
    static let maximumBeforeWindow = 4_096

    /// context-awareness-2：游標前要讀多長才比得出「游標前就是上一段聽寫的結尾」——上一段長度＋8，
    /// 至少 32、最多 4096（UTF-16，跟 AX 的範圍單位一樣）。
    static func beforeWindow(previous: String?) -> Int {
        min(maximumBeforeWindow, max(minimumBeforeWindow, (previous?.utf16.count ?? 0) + 8))
    }

    /// 游標前真正要讀多長：只有焦點欄位就是上一段送進去的那個欄位，才讀 `window`（上一段＋8）；
    /// 別的欄位（同一個 App 的另一則筆記、別的 App、封鎖網站）一律 32，跟以前一樣——那裡不會接續，多讀沒有用。
    static func effectiveBeforeWindow(_ window: Int, field: AnyHashable, previousField: AnyHashable?) -> Int {
        guard let previousField, previousField == field else { return minimumBeforeWindow }
        return window
    }

    /// 同 `capture(expectedPID:)`，游標前改讀 `beforeUTF16` 個 UTF-16 單位（只限 `previousField` 那個欄位，見
    /// `effectiveBeforeWindow`）；讀不到就退回 32（跟以前一樣）。
    func capture(expectedPID: Int32?, beforeUTF16 requested: Int,
                 previousField: AnyHashable? = nil) -> (any DictationDestination)? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              expectedPID == nil || app.processIdentifier == expectedPID,
              let element = Self.focusedElement(), Self.pid(element) == app.processIdentifier,
              Self.limitMessaging(element),
              let role = Self.attribute(element, kAXRoleAttribute) as? String,
              ["AXTextArea", "AXTextField"].contains(role),
              (Self.attribute(element, kAXSubroleAttribute) as? String) != "AXSecureTextField",
              let selection = Self.range(element), selection.location >= 0, selection.length == 0,
              Self.settable(element, kAXSelectedTextAttribute), Self.settable(element, kAXSelectedTextRangeAttribute),
              let count = Self.attribute(element, kAXNumberOfCharactersAttribute) as? Int,
              count >= selection.location,
              case let window = Self.effectiveBeforeWindow(requested, field: AnyHashable(element), previousField: previousField),
              let before = Self.textBefore(element, location: selection.location, window: window),
              let after = Self.text(element, NSRange(location: selection.location, length: min(32, count - selection.location))) else { return nil }
        return AXCapturedDestination(element: element, pid: app.processIdentifier, role: role, location: selection.location,
                                     before: before, after: after)
    }

    private static func textBefore(_ element: AXUIElement, location: Int, window: Int) -> String? {
        let wanted = min(max(minimumBeforeWindow, min(window, maximumBeforeWindow)), location)
        if let wide = text(element, NSRange(location: location - wanted, length: wanted)) { return wide }
        let narrow = min(minimumBeforeWindow, location)
        guard wanted > narrow else { return nil }
        return text(element, NSRange(location: location - narrow, length: narrow))
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func pid(_ element: AXUIElement) -> Int32? {
        var value: pid_t = 0
        return AXUIElementGetPid(element, &value) == .success ? value : nil
    }
    /// 每次 AX 呼叫最多等 0.2 秒：慢的 App 不能讓按下聽寫快捷鍵時卡住主執行緒（luna-review r3）。
    static func limitMessaging(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.2)
        return true
    }
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let value = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    static func range(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeDowncast(value, to: AXValue.self)
        var result = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &result),
              result.location >= 0, result.length >= 0 else { return nil }
        return NSRange(location: result.location, length: result.length)
    }
    static func text(_ element: AXUIElement, _ range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, range.length <= 16_384 else { return nil }
        if range.length == 0 { return "" }
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success,
              let string = result as? String, string.utf16.count == range.length else { return nil }
        return string
    }
    static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
    static func setRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}

/// AX has no atomic compare-and-swap. Restrict to observable native text controls,
/// retain actual CF identity and compare only bounded ranges. Never restore a whole field.
@MainActor
final class AXCapturedDestination: DictationDestination {
    private let element: AXUIElement
    private let processID: Int32
    private let capturedRole: String
    private let location: Int
    private let before: String
    private let after: String
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, String)] = []
    private var workspaceMonitor: NSObjectProtocol?
    private var inputMonitor: Any?
    private var localMonitor: Any?
    private var invalid = false
    private var changingOwnText = false
    private var inserted: String?
    private(set) var supportsCorrection = false

    init(element: AXUIElement, pid: Int32, role: String, location: Int, before: String, after: String) {
        self.element = element; self.processID = pid; self.capturedRole = role; self.location = location
        self.before = before; self.after = after
        installObservers()
    }

    private func installObservers() {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, name, pointer in
            guard let pointer else { return }
            // AX observer run-loop source is registered only on the main run loop.
            MainActor.assumeIsolated {
                let owner = Unmanaged<AXCapturedDestination>.fromOpaque(pointer).takeUnretainedValue()
                owner.observed(name as String)
            }
        }
        guard AXObserverCreate(processID, callback, &created) == .success, let created else { return }
        observer = created
        let app = AXUIElementCreateApplication(processID)
        let requests = [(element, kAXValueChangedNotification), (element, kAXSelectedTextChangedNotification),
                        (app, kAXFocusedUIElementChangedNotification)]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        for (target, notification) in requests {
            guard AXObserverAddNotification(created, target, notification as CFString, pointer) == .success else {
                removeObservers(); return
            }
            registrations.append((target, notification))
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        workspaceMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.invalidate() }; return event
        }
        supportsCorrection = inputMonitor != nil && localMonitor != nil
    }

    private func observed(_ notification: String) {
        if notification == kAXFocusedUIElementChangedNotification { invalidate(); return }
        // Own insertion produces asynchronous value/selection notifications. During
        // this brief acknowledgement window input/focus invalidation remains active.
        if !changingOwnText { invalidate() }
    }

    private func sameFocus() -> Bool {
        guard !invalid, NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let current = AXAdapter.focusedElement(), AXAdapter.pid(current) == processID,
              (AXAdapter.attribute(current, kAXRoleAttribute) as? String) == capturedRole else { return false }
        return CFEqual(current, element)
    }

    /// 寫入後字有沒有真的出現在欄位裡（只讀插入點附近，不讀整份內容）。
    static func textAppeared(_ text: String, in element: AXUIElement, at location: Int) -> Bool {
        let length = text.utf16.count
        guard length > 0, location >= 0, location <= Int.max - length else { return false }
        return AXAdapter.text(element, NSRange(location: location, length: length)) == text
    }

    func textPresent(_ text: String) -> Bool { Self.textAppeared(text, in: element, at: location) }

    /// 開始聽寫當下讀到的游標前文字；目的地已失效就不提供（不能拿過時的內容決定要不要補標點）。
    var textBeforeCursor: String? { invalid ? nil : before }

    /// AXUIElement 以 CFEqual／CFHash 比較：同一個 App 的同一個欄位元素才相等（元素本身帶著 pid）。
    var fieldIdentity: AnyHashable? { AnyHashable(element) }
    var cursorLocation: Int? { location }

    private func matches(_ text: String) -> Bool {
        let length = text.utf16.count
        guard location <= Int.max - length, sameFocus(),
              AXAdapter.range(element) == NSRange(location: location + length, length: 0),
              AXAdapter.text(element, NSRange(location: location, length: length)) == text,
              AXAdapter.text(element, NSRange(location: location - before.utf16.count, length: before.utf16.count)) == before,
              AXAdapter.text(element, NSRange(location: location + length, length: after.utf16.count)) == after else { return false }
        if !text.isEmpty {
            // CFEqual above proves actual field identity, including hosts without AXIdentifier.
            let identity = "captured-\(processID)-\(location)"
            let ticket = AXInsertionTicket(processIdentifier: processID, bundleIdentifier: "captured", appName: "",
                axIdentifier: identity, axRole: capturedRole, insertedUTF16Location: location,
                insertedUTF16Length: length, contextBeforePrefix: before, insertedText: text, capturedAt: Date())
            guard let actual = AXAdapter.text(element, NSRange(location: location, length: length)) else { return false }
            return AXReplacementGate.verdict(ticket: ticket, current: .init(processIdentifier: processID,
                bundleIdentifier: "captured", axIdentifier: identity, axRole: capturedRole, focused: sameFocus(),
                rangeText: actual, contextBefore: before)) == .ok
        }
        return true
    }

    func insert(_ text: String) async -> Bool {
        guard inserted == nil, !text.isEmpty, text.utf16.count <= 16_384, matches("") else { invalidate(); return false }
        changingOwnText = true
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            changingOwnText = false; invalidate(); return false
        }
        inserted = text
        // Confirm immediately, then allow AppKit's own AX notifications to drain.
        guard matches(text) else {
            // AX 回 success 不代表字真的進去了：Electron／Chromium 的輸入框（Claude 桌面版等）
            // 收下寫入卻什麼都不做（2026-10-14 實機：辨識正確、Smart 模式、畫面上沒字、也沒走剪貼簿）。
            // 給它一點時間非同步套用；確定沒出現就回 false，讓呼叫端改走剪貼簿貼上。
            // 每次讀取最多 0.2 秒（messaging timeout），輪數保守：最壞約 4×(75+200) ms。
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(75))
                if Task.isCancelled { break }
                if Self.textAppeared(text, in: element, at: location) {
                    // 字進去了（只是位置／游標驗證不過）：算已送達，不能再貼第二份；只是關掉事後替換。
                    changingOwnText = false; invalidate(); return true
                }
            }
            changingOwnText = false; inserted = nil; invalidate(); return false
        }
        try? await Task.sleep(for: .milliseconds(80))
        changingOwnText = false
        if Task.isCancelled || !matches(text) { invalidate() }
        // Text was delivered even if a subsequent user action invalidated correction.
        return true
    }

    func replaceInsertedText(with text: String) -> Bool {
        guard supportsCorrection, let original = inserted, !Task.isCancelled,
              !text.isEmpty, text.utf16.count <= 16_384, matches(original) else { invalidate(); return false }
        // Stop correction tracking before our one allowed write, retaining the target.
        removeObservers()
        guard sameFocus(), AXAdapter.setRange(element, NSRange(location: location, length: original.utf16.count)) else {
            invalid = true; return false
        }
        // A final bounded comparison after selecting; no intervening await.
        guard sameFocus(), AXAdapter.range(element) == NSRange(location: location, length: original.utf16.count),
              AXAdapter.text(element, NSRange(location: location, length: original.utf16.count)) == original else {
            invalid = true; return false
        }
        let written = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        // Native NSTextView collapses the selection at the inserted end. Only set
        // the caret if the same field still has exactly our just-written selection.
        let end = NSRange(location: location + text.utf16.count, length: 0)
        if written, sameFocus(), AXAdapter.range(element) == NSRange(location: location, length: text.utf16.count) {
            _ = AXAdapter.setRange(element, end)
        }
        if !written, sameFocus(),
           AXAdapter.range(element) == NSRange(location: location, length: original.utf16.count),
           AXAdapter.text(element, NSRange(location: location, length: original.utf16.count)) == original {
            _ = AXAdapter.setRange(element, NSRange(location: location + original.utf16.count, length: 0))
        }
        let confirmed = written && matches(text)
        invalid = true
        return confirmed
    }

    func invalidate() { invalid = true; removeObservers() }

    private func removeObservers() {
        if let observer {
            for (target, name) in registrations { AXObserverRemoveNotification(observer, target, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; registrations = []
        if let workspaceMonitor { NSWorkspace.shared.notificationCenter.removeObserver(workspaceMonitor) }
        workspaceMonitor = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }; inputMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }

    deinit {
        // Owners explicitly invalidate before dropping a session; this last cleanup
        // uses the actor-isolated lifetime because all references are main-actor bound.
        MainActor.assumeIsolated { removeObservers() }
    }
}
