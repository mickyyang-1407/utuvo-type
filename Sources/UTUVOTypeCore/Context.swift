import Foundation

/// Minimal context contract for future AXUIElement integration.
/// No screenshot, full-screen OCR, or whole-document capture belongs here.
public struct LimitedAppContext: Codable, Equatable, Sendable {
    public var foregroundBundleIdentifier: String?
    public var appName: String?
    public var focusedFieldRole: String?
    public var selectedText: String?
    /// 游標前文字（上限 `ContextBounds.beforeCursorLimit`；2026-10-22 起只放游標前，游標後另放 `textAfterCursor`）。
    public var surroundingText: String?
    /// 游標後文字（上限 `ContextBounds.afterCursorLimit`；與 surroundingText 同一個開關）。
    public var textAfterCursor: String?
    /// 2026-10-13（對齊 Typeless）：前景視窗標題、瀏覽器網頁（只留網域＋路徑，不含查詢參數）、欄位提示文字。
    /// 跟 surroundingText 同一個「附帶有限的周邊 context」開關，預設關閉；都有長度上限（ContextBounds）。
    public var windowTitle: String?
    public var pageLocation: String?
    public var fieldPlaceholder: String?
    /// 這個網站在使用者的「不讀脈絡」清單上：什麼都沒讀（連選取文字都沒有）。
    public var contextBlocked: Bool = false
    /// 擋下的原因（2026-10-22 context-awareness-v2）：清單命中，或網址讀不到為了安全先擋。舊資料沒有這個欄位＝nil。
    public var contextBlockReason: ContextBounds.BlockReason?
    /// 選取超過 `ContextBounds.selectedTextLimit`，`selectedText` 只有前段（2026-10-22）。
    /// Edit Selection 不能拿前段的改寫蓋掉整段選取，要直接說「選取太長」。nil／false＝沒截斷。
    public var selectedTextTruncated: Bool?

    public init(
        foregroundBundleIdentifier: String? = nil,
        appName: String? = nil,
        focusedFieldRole: String? = nil,
        selectedText: String? = nil,
        surroundingText: String? = nil,
        windowTitle: String? = nil,
        pageLocation: String? = nil,
        fieldPlaceholder: String? = nil,
        contextBlocked: Bool = false,
        textAfterCursor: String? = nil,
        contextBlockReason: ContextBounds.BlockReason? = nil,
        selectedTextTruncated: Bool? = nil
    ) {
        self.selectedTextTruncated = selectedTextTruncated
        self.contextBlockReason = contextBlockReason
        self.textAfterCursor = textAfterCursor
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
        self.appName = appName
        self.focusedFieldRole = focusedFieldRole
        self.selectedText = selectedText
        self.surroundingText = surroundingText
        self.windowTitle = windowTitle
        self.pageLocation = pageLocation
        self.fieldPlaceholder = fieldPlaceholder
        self.contextBlocked = contextBlocked
    }

    /// A bounded, explicit summary suitable for a formatter prompt.
    /// Callers must provide already-bounded text; this type never reads UI.
    public var promptSummary: String {
        [
            foregroundBundleIdentifier.map { "bundle=\($0)" },
            appName.map { "app=\($0)" },
            focusedFieldRole.map { "field=\($0)" },
            selectedText.map { "selected=\($0)" },
            surroundingText.map { "surrounding=\($0)" },
            textAfterCursor.map { "after=\($0)" },
            windowTitle.map { "window=\($0)" },
            pageLocation.map { "page=\($0)" },
            fieldPlaceholder.map { "placeholder=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}
