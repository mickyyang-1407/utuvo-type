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

    static func readCurrentContext(includeSurrounding: Bool = false, blockedSites: [String] = []) -> LimitedAppContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = LimitedAppContext(
            foregroundBundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName
        )

        guard isTrusted() else { return context }
        let system = AXUIElementCreateSystemWide()
        // luna-review r2：所有 AX 讀取都設逾時，慢的 App 不能卡住主執行緒。
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let focusedValue = copyAttribute(system, kAXFocusedUIElementAttribute) else {
            return context
        }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.2)
        context.focusedFieldRole = copyAttribute(focused, kAXRoleAttribute) as? String
        if (copyAttribute(focused, kAXSubroleAttribute) as? String) == "AXSecureTextField" {
            // Don't include app identity, selected text or field contents from password managers / secure inputs.
            return LimitedAppContext(focusedFieldRole: "AXSecureTextField")
        }
        // 敏感網站先判斷，跟「附帶周邊 context」開關無關：在封鎖清單上的網站，連選取文字都不讀
        // （luna-review r2：Edit Selection／Ask anything 曾在開關關閉時照樣送出選取文字）。
        let lookup: ContextBounds.PageLookup = (includeSurrounding || !blockedSites.isEmpty) ? webAreaURL(above: focused) : .notWeb
        var page: String?
        if case .webArea(let url) = lookup { page = url.flatMap(ContextBounds.pageLocation(from:)) }
        if ContextBounds.shouldBlock(lookup, isBrowser: ContextBounds.isBrowser(bundleIdentifier: app?.bundleIdentifier),
                                     blockedSites: blockedSites) {
            return LimitedAppContext(foregroundBundleIdentifier: context.foregroundBundleIdentifier,
                                     appName: context.appName, focusedFieldRole: context.focusedFieldRole,
                                     contextBlocked: true)
        }
        if let selected = copyAttribute(focused, kAXSelectedTextAttribute) as? String {
            context.selectedText = ContextBounds.boundedSelectedText(selected)
        }
        if includeSurrounding {
            context.surroundingText = boundedSurroundingText(of: focused)
            // 2026-10-13 對齊 Typeless：視窗標題、網頁（網域＋路徑）、欄位提示文字。
            if let placeholder = copyAttribute(focused, kAXPlaceholderValueAttribute) as? String {
                context.fieldPlaceholder = nonEmpty(ContextBounds.bounded(placeholder, limit: ContextBounds.titleLimit))
            }
            if let pid = app?.processIdentifier {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, 0.2)
                if let windowValue = copyAttribute(appElement, kAXFocusedWindowAttribute),
                   CFGetTypeID(windowValue as CFTypeRef) == AXUIElementGetTypeID(),
                   let title = copyAttribute(windowValue as! AXUIElement, kAXTitleAttribute) as? String {
                    context.windowTitle = nonEmpty(ContextBounds.bounded(title, limit: ContextBounds.titleLimit))
                }
            }
            context.pageLocation = page
        }
        return context
    }

    /// 目前焦點元素（Ask anything 用來確認貼回去的還是原本那個欄位）。
    static func focusedElement() -> AXUIElement? {
        guard isTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let value = copyAttribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 從焦點欄位往上找網頁區塊（AXWebArea），讀它的網址。最多 40 層、總共 150 毫秒，每次 AX 呼叫最多等 0.1 秒
    /// （luna-review r1：深層 AX 樹在主執行緒逐層查詢會卡 UI）。用完預算、或父節點讀不到但還沒到 App 頂層＝`.unknown`（r3／r4）。
    private static func webAreaURL(above element: AXUIElement) -> ContextBounds.PageLookup {
        var current = element
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<40 {
            guard CFAbsoluteTimeGetCurrent() - start < 0.15 else { return .unknown }
            AXUIElementSetMessagingTimeout(current, 0.1)
            let role = copyAttribute(current, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                if let url = copyAttribute(current, kAXURLAttribute) as? URL { return .webArea(url: url.absoluteString) }
                return .webArea(url: copyAttribute(current, kAXURLAttribute) as? String)
            }
            if role == kAXApplicationRole as String { return .notWeb }
            guard let parent = copyAttribute(current, kAXParentAttribute),
                  CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID() else { return .unknown }
            current = parent as! AXUIElement
        }
        return .unknown
    }

    /// 焦點欄位目前的選取範圍（UTF-16）。Ask 用來確認貼回去時選取／游標沒動過（luna-review r3）。
    static func selectedRange(of element: AXUIElement) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let value = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(value as! AXValue) == .cfRange, AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func selectedText(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        return copyAttribute(element, kAXSelectedTextAttribute) as? String
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
        // 還原時要整份還原（圖片、富文字、檔案），不能只剩純文字（luna-review r5 指出的既有問題，順手修）。
        let previousItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } },
                       uniquingKeysWith: { first, _ in first })
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw PasteError.eventUnavailable
        }
        // 2026-10-13 對齊 Typeless：有條列時另附 HTML，富文字編輯器（Docs／Notion／Gmail／備忘錄）變真正的清單；
        // 純文字欄位照舊拿上面那份純文字。
        if let html = RichTextShape.html(for: text) {
            pasteboard.setString(html, forType: .html)
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
                let restored = previousItems.filter { !$0.isEmpty }.map { types -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                }
                if !restored.isEmpty { pasteboard.writeObjects(restored) }
            }
        }
    }

    private static func replaceFocusedSelection(with text: String) -> Bool {
        guard AccessibilitySupport.isTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)   // luna-review r4：慢的 App 不能卡住主執行緒
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
        AXUIElementSetMessagingTimeout(focused, 0.2)
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
