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
        if let reason = ContextBounds.blockReason(lookup, isBrowser: ContextBounds.isBrowser(bundleIdentifier: app?.bundleIdentifier),
                                                  blockedSites: blockedSites) {
            return LimitedAppContext(foregroundBundleIdentifier: context.foregroundBundleIdentifier,
                                     appName: context.appName, focusedFieldRole: context.focusedFieldRole,
                                     contextBlocked: true, contextBlockReason: reason)
        }
        if let selected = copyAttribute(focused, kAXSelectedTextAttribute) as? String {
            context.selectedText = ContextBounds.boundedSelectedText(selected)
            if ContextBounds.selectionExceedsLimit(selected) { context.selectedTextTruncated = true }
        }
        if includeSurrounding {
            let around = cursorText(of: focused)
            context.surroundingText = around.before
            context.textAfterCursor = around.after
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

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// 投遞前看一眼焦點（delivery-learning-2）：沒有焦點元素、或焦點是按鈕／清單這類非文字元素時，
    /// ⌘V 多半沒進去。只讀角色與「值可不可寫」，不讀欄位內容。分類規則在 core 的 `DeliveryTarget`。
    static func deliveryFocus() -> DeliveryTarget.Focus {
        guard isTrusted() else { return .unreadable }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .noValue { return .noFocusedElement }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unreadable }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return .element(role: copyAttribute(element, kAXRoleAttribute) as? String,
                        subrole: copyAttribute(element, kAXSubroleAttribute) as? String,
                        valueSettable: settableStatus == .success ? settable.boolValue : nil)
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

    /// 游標前後的文字（context-awareness-1）：範圍由 `ContextBounds.cursorWindows` 算，
    /// 游標前一定合法、不需要欄位總長度；拿不到總長度只少了游標後那段。
    private static func cursorText(of element: AXUIElement) -> (before: String?, after: String?) {
        guard let selection = selectedRange(of: element) else { return (nil, nil) }
        let count = copyAttribute(element, kAXNumberOfCharactersAttribute) as? Int
        let windows = ContextBounds.cursorWindows(location: selection.location, selectionLength: selection.length,
                                                  count: count)
        let before = string(of: element, in: windows.before).map { ContextBounds.clampBeforeCursor($0) }
        let after = windows.after.flatMap { string(of: element, in: $0) }.map { ContextBounds.clampAfterCursor($0) }
        return (nonEmpty(before), nonEmpty(after))
    }

    /// 只讀一小段（AXStringForRange），不讀整個欄位。
    private static func string(of element: AXUIElement, in range: NSRange) -> String? {
        guard range.length > 0 else { return nil }
        var requested = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard status == .success, let text = result as? String else { return nil }
        return text
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
        guard writeForPaste(text, to: pasteboard, handling: handling) else {
            throw PasteError.eventUnavailable
        }
        let pastedChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        // delivery-learning-6：按目前鍵盤配置上的 V（Dvorak 等配置的 keycode 9 不是 V）。
        let vKey = KeyboardLayoutKeyCode.commandV()
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
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

    /// 剪貼簿管理工具（Maccy、Raycast、Paste……）的慣例：有這個型別的內容是暫時的，不記進歷史。
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// delivery-learning-6（2026-10-22）：把要貼的字寫進剪貼簿。
    /// - `.restore`（貼完會還原原本內容）：`prepareForNewContents(.currentHostOnly)`——不同步到同 Apple ID 的其他裝置；
    ///   另加 `org.nspasteboard.TransientType`，剪貼簿管理工具不會把每一句聽寫都記下來。
    ///   不加 `org.nspasteboard.ConcealedType`：那是「這是密碼」的標記，聽寫內容不是。
    /// - `.keep`（使用者要留在剪貼簿）：照一般複製，不加任何標記。
    /// 有條列時另附 HTML（2026-10-13 對齊 Typeless：富文字編輯器變真正的清單；純文字欄位照舊拿純文字）。
    @discardableResult
    static func writeForPaste(_ text: String, to pasteboard: NSPasteboard, handling: ClipboardHandling) -> Bool {
        if handling == .restore {
            pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        guard pasteboard.setString(text, forType: .string) else { return false }
        if let html = RichTextShape.html(for: text) {
            pasteboard.setString(html, forType: .html)
        }
        if handling == .restore {
            pasteboard.setData(Data(), forType: transientType)
        }
        return true
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
