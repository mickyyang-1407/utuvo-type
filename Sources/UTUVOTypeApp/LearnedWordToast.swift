import AppKit
import SwiftUI
import UTUVOTypeCore

/// 從修改學到字時的小提示（2026-10-22 delivery-learning-4，對齊 Typeless「"詞" added to your dictionary」＋Undo，5 秒）。
///
/// 浮在畫面右上角、不搶焦點：面板不會變成 key window，使用者正在打字的欄位不受影響；5 秒後自己收掉。
/// - 自動加進字典的：「已加入字典：Protus → Pro Tools」＋「復原」（刪掉那筆、記進忽略清單）。
/// - 只留建議的：「要加入字典嗎？」＋「加入」／「忽略」，一鍵決定，不必開設定頁。
@MainActor
final class LearnedWordToast {
    static let shared = LearnedWordToast()
    static let duration: Duration = .seconds(5)
    /// 詞太長就截斷顯示（Typeless 也是超過 14 字截斷）。
    static let maxShownLength = 14
    /// 一次最多列幾筆，其他的看設定頁。
    static let maxLines = 3

    struct Content: Equatable {
        enum Kind: Equatable { case added, suggested }
        var kind: Kind
        var title: String
        var lines: [String]
        /// 列不下、或另外進了建議清單的筆數說明。
        var note: String?
        var primary: String
        var secondary: String?
        /// 「加入／忽略」作用的建議＝卡片上列出來的那幾筆（2026-10-22 修補：以前按「加入」連沒列出來的也一起加進字典）。
        /// 沒列出來的留在設定頁的建議清單，等使用者自己看。
        var suggestions: [EditTracker.Correction] = []
    }

    /// 提示卡要顯示什麼（純函式，可測）。有自動加入的就顯示「已加入」＋復原；只有建議才顯示「加入／忽略」。
    static func content(for result: AppPreferences.EditLearningResult, zh: Bool) -> Content? {
        if !result.added.isEmpty {
            let hidden = result.added.count - min(result.added.count, maxLines)
            var notes: [String] = []
            if hidden > 0 { notes.append(zh ? "還有 \(hidden) 個詞" : "\(hidden) more") }
            if !result.suggested.isEmpty {
                notes.append(zh ? "另有 \(result.suggested.count) 個建議在設定的「個人字典」"
                                : "\(result.suggested.count) more suggestion(s) in Dictionary settings")
            }
            return Content(kind: .added, title: zh ? "已加入字典" : "Added to dictionary",
                           lines: result.added.prefix(maxLines).map(line),
                           note: notes.isEmpty ? nil : notes.joined(separator: zh ? "；" : "; "),
                           primary: zh ? "復原" : "Undo", secondary: nil)
        }
        guard !result.suggested.isEmpty else { return nil }
        let shownSuggestions = Array(result.suggested.prefix(maxLines))
        let hidden = result.suggested.count - shownSuggestions.count
        return Content(kind: .suggested, title: zh ? "要加入字典嗎？" : "Add to dictionary?",
                       lines: shownSuggestions.map { "\(shown($0.from)) → \(shown($0.to))" },
                       note: hidden > 0 ? (zh ? "另有 \(hidden) 個建議在設定的「個人字典」"
                                              : "\(hidden) more suggestion(s) in Dictionary settings") : nil,
                       primary: zh ? "加入" : "Add", secondary: zh ? "忽略" : "Ignore",
                       suggestions: shownSuggestions)
    }

    /// 「加入」：只加卡片上列出來的建議。
    static func accept(_ content: Content, preferences: AppPreferences) {
        content.suggestions.forEach(preferences.acceptSuggestion)
    }

    /// 「忽略」：只忽略卡片上列出來的建議。
    static func ignore(_ content: Content, preferences: AppPreferences) {
        content.suggestions.forEach(preferences.ignoreSuggestion)
    }

    static func shown(_ text: String) -> String {
        text.count > maxShownLength ? String(text.prefix(maxShownLength)) + "…" : text
    }

    static func line(_ term: AppPreferences.LearnedTerm) -> String {
        term.isVocabulary ? shown(term.output) : "\(shown(term.source)) → \(shown(term.output))"
    }

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// 修改追蹤找到配對之後：交給偏好設定決定自動加或建議，再把結果顯示出來。
    func present(_ result: AppPreferences.EditLearningResult, preferences: AppPreferences) {
        guard preferences.isolation == nil, let content = Self.content(for: result, zh: preferences.isChineseUI) else { return }
        if !result.added.isEmpty { DictionaryCloud.sync(preferences) }
        let primary: () -> Void
        var secondary: (() -> Void)?
        switch content.kind {
        case .added:
            primary = { [weak preferences] in
                guard let preferences else { return }
                preferences.undoLearned(result.added)
                DictionaryCloud.sync(preferences)
            }
        case .suggested:
            primary = { [weak preferences] in
                guard let preferences else { return }
                Self.accept(content, preferences: preferences)
                DictionaryCloud.sync(preferences)
            }
            secondary = { [weak preferences] in
                guard let preferences else { return }
                Self.ignore(content, preferences: preferences)
            }
        }
        show(content, primary: primary, secondary: secondary)
    }

    func show(_ content: Content, primary: @escaping () -> Void, secondary: (() -> Void)?) {
        let panel = ensurePanel()
        let view = LearnedWordToastView(
            content: content,
            onPrimary: { [weak self] in primary(); self?.close() },
            onSecondary: secondary.map { action in { [weak self] in action(); self?.close() } },
            onClose: { [weak self] in self?.close() }
        )
        let host = FirstClickHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        let width = max(280, min(380, size.width)), height = max(64, size.height)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - width - 24, y: screen.maxY - height - 24, width: width, height: height),
                           display: true)
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: ([content.title] + content.lines).joined(separator: "，"),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        // 無邊框＋nonactivating：點按鈕不會把 UTUVO Type 叫到前面，也不會搶走正在打字的欄位的鍵盤焦點。
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }
}

/// 不是 key window 也能一按就觸發按鈕（不必先點一下讓視窗變成作用中）。
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct LearnedWordToastView: View {
    let content: LearnedWordToast.Content
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: content.kind == .added ? "character.book.closed.fill" : "lightbulb")
                .foregroundStyle(AppBrand.accent)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(content.title).font(.callout.weight(.semibold))
                ForEach(content.lines, id: \.self) { line in
                    Text(line).font(.callout).lineLimit(1).accessibilityIdentifier("learnedToastLine")
                }
                if let note = content.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if let onSecondary {
                        Button(content.secondary ?? "", action: onSecondary)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("learnedToastSecondary")
                    }
                    Button(content.primary, action: onPrimary)
                        .accessibilityIdentifier("learnedToastPrimary")
                }
                Button(action: onClose) { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("learnedToastClose")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 280, maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppBrand.accent.opacity(0.18)))
    }
}
