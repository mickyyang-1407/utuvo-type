import Foundation

/// Minimal context contract for future AXUIElement integration.
/// No screenshot, full-screen OCR, or whole-document capture belongs here.
public struct LimitedAppContext: Codable, Equatable, Sendable {
    public var foregroundBundleIdentifier: String?
    public var appName: String?
    public var focusedFieldRole: String?
    public var selectedText: String?
    public var surroundingText: String?

    public init(
        foregroundBundleIdentifier: String? = nil,
        appName: String? = nil,
        focusedFieldRole: String? = nil,
        selectedText: String? = nil,
        surroundingText: String? = nil
    ) {
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
        self.appName = appName
        self.focusedFieldRole = focusedFieldRole
        self.selectedText = selectedText
        self.surroundingText = surroundingText
    }

    /// A bounded, explicit summary suitable for a formatter prompt.
    /// Callers must provide already-bounded text; this type never reads UI.
    public var promptSummary: String {
        [
            foregroundBundleIdentifier.map { "bundle=\($0)" },
            appName.map { "app=\($0)" },
            focusedFieldRole.map { "field=\($0)" },
            selectedText.map { "selected=\($0)" },
            surroundingText.map { "surrounding=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}
