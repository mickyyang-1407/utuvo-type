import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import UTUVOTypeCore

@MainActor
enum AccessibilitySupport {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func openPrivacySettings(section: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(section)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func readCurrentContext(includeSurrounding: Bool = false) -> LimitedAppContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = LimitedAppContext(
            foregroundBundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName
        )

        guard isTrusted() else { return context }
        let system = AXUIElementCreateSystemWide()
        guard let focusedValue = copyAttribute(system, kAXFocusedUIElementAttribute) else {
            return context
        }
        let focused = focusedValue as! AXUIElement
        context.focusedFieldRole = copyAttribute(focused, kAXRoleAttribute) as? String
        if let selected = copyAttribute(focused, kAXSelectedTextAttribute) as? String {
            context.selectedText = ContextBounds.boundedSelectedText(selected)
        }
        if includeSurrounding {
            context.surroundingText = boundedSurroundingText(of: focused)
        }
        return context
    }

    private static func boundedSurroundingText(of element: AXUIElement) -> String? {
        guard let selectedRangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute) else {
            return nil
        }
        let axSelectedRange = selectedRangeValue as! AXValue
        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetType(axSelectedRange) == .cfRange,
              AXValueGetValue(axSelectedRange, .cfRange, &selectedRange) else {
            return nil
        }

        // Ask Accessibility for only a small range around the selection. This
        // avoids reading an entire document or a whole text field into Type.
        let radius = ContextBounds.surroundingRadius
        let requestedStart = max(0, selectedRange.location - radius)
        let requestedLength = selectedRange.length + radius * 2
        var requestedRange = CFRange(location: requestedStart, length: requestedLength)
        guard let rangeValue = AXValueCreate(.cfRange, &requestedRange) else { return nil }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard status == .success, let text = result as? String else { return nil }
        return ContextBounds.boundedSurroundingText(text)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

}

@MainActor
enum ClipboardPaster {
    enum PasteError: Error, CustomStringConvertible {
        case emptyText
        case eventUnavailable

        var description: String {
            switch self {
            case .emptyText: return "沒有可貼上的文字（No text to paste）"
            case .eventUnavailable: return "無法對目前輸入欄位送出貼上事件；請確認輔助使用權限（Could not deliver the paste event; check Accessibility permission）"
            }
        }
    }

    static func paste(
        _ text: String,
        method: PasteMethod = .clipboard,
        handling: ClipboardHandling = .restore
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PasteError.emptyText
        }

        if method == .accessibility,
           replaceFocusedSelection(with: text) {
            return
        }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw PasteError.eventUnavailable
        }
        let pastedChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw PasteError.eventUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if handling == .restore {
            // Restore the clipboard only if the user has not copied something
            // else in the meantime.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pasteboard.changeCount == pastedChangeCount else { return }
                pasteboard.clearContents()
                if let previousString {
                    pasteboard.setString(previousString, forType: .string)
                }
            }
        }
    }

    private static func replaceFocusedSelection(with text: String) -> Bool {
        guard AccessibilitySupport.isTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return result == .success
    }

    static func submit(_ setting: AutoSubmit) {
        guard setting != .off else { return }
        // Let the target finish consuming Cmd+V before an optional submit
        // key arrives in the same input field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postSubmit(setting)
        }
    }

    private static func postSubmit(_ setting: AutoSubmit) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Return),
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Return),
            keyDown: false
        ) else { return }

        let flags: CGEventFlags
        switch setting {
        case .off, .returnKey:
            flags = []
        case .commandReturn:
            flags = .maskCommand
        case .controlReturn:
            flags = .maskControl
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
