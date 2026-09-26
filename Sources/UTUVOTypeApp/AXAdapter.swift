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
}

@MainActor
final class AXAdapter {
    static let shared = AXAdapter()

    /// Captured before ASR. Unsupported fields return nil; no full-value reads.
    func capture(expectedPID: Int32? = nil) -> (any DictationDestination)? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              expectedPID == nil || app.processIdentifier == expectedPID,
              let element = Self.focusedElement(), Self.pid(element) == app.processIdentifier,
              let role = Self.attribute(element, kAXRoleAttribute) as? String,
              ["AXTextArea", "AXTextField"].contains(role),
              (Self.attribute(element, kAXSubroleAttribute) as? String) != "AXSecureTextField",
              let selection = Self.range(element), selection.location >= 0, selection.length == 0,
              Self.settable(element, kAXSelectedTextAttribute), Self.settable(element, kAXSelectedTextRangeAttribute),
              let count = Self.attribute(element, kAXNumberOfCharactersAttribute) as? Int,
              count >= selection.location,
              let before = Self.text(element, NSRange(location: max(0, selection.location - 32), length: min(32, selection.location))),
              let after = Self.text(element, NSRange(location: selection.location, length: min(32, count - selection.location))) else { return nil }
        return AXCapturedDestination(element: element, pid: app.processIdentifier, role: role, location: selection.location,
                                     before: before, after: after)
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
    static func focusedElement() -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
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
        // AX already accepted the write: report delivered (caller must not paste a second copy); only correction is off.
        guard matches(text) else { changingOwnText = false; invalidate(); return true }
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
