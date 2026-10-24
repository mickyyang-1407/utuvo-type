import AppKit
import SwiftUI
import UTUVOTypeCore

/// Ask anything 的回答卡（2026-10-13，對齊 Typeless interactive card）：浮在畫面右上、不搶焦點，
/// 可複製、可插入到原本的游標位置、Esc 或按關閉收掉。
@MainActor
final class AnswerCardController {
    static let shared = AnswerCardController()
    private var panel: NSPanel?

    struct Card {
        var question: String
        var answer: String
        var zh: Bool
        var onInsert: (() -> Void)?
        /// 模型回答（Ask／白話解釋）：卡片畫粗體、複製拿純文字（modes-6）。
        /// 聽寫結果卡（沒送到輸入欄位，delivery-learning-2）是使用者說的話：原樣顯示、原樣複製。
        var rendersMarkdown: Bool = true
        /// 插入按鈕的字；nil＝「插入」。
        var insertLabel: String? = nil

        /// 按「複製」放進剪貼簿的文字。
        var copyText: String { rendersMarkdown ? AnswerText.plain(answer) : answer }
    }

    func show(_ card: Card) {
        let panel = ensurePanel()
        let view = AnswerCardView(card: card,
                                  onCopy: { [weak self] in
                                      NSPasteboard.general.clearContents()
                                      NSPasteboard.general.setString(card.copyText, forType: .string)
                                      self?.close()
                                  },
                                  onInsert: card.onInsert.map { insert in { [weak self] in self?.close(); insert() } },
                                  onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        let size = NSSize(width: 420, height: min(520, 140 + CGFloat(card.answer.count / 30) * 18))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    /// 截圖模式用。
    var window: NSWindow? { panel }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        // 卡片右上自己有關閉鈕；系統的紅黃綠按鈕藏起來。
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }
}

private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private struct AnswerCardView: View {
    let card: AnswerCardController.Card
    let onCopy: () -> Void
    let onInsert: (() -> Void)?
    let onClose: () -> Void

    /// 回答的 Markdown 畫成粗體／條列（不再看到 ** 和 #）；解析不了就原樣顯示。
    private var displayed: AttributedString {
        guard card.rendersMarkdown else { return AttributedString(card.answer) }
        return (try? AttributedString(markdown: AnswerText.inlineMarkdown(card.answer),
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(card.answer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "sparkles").foregroundStyle(AppBrand.accent)
                Text(card.question).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    .accessibilityIdentifier("answerCardClose")
            }
            ScrollView {
                Text(displayed)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("answerCardText")
            }
            HStack {
                Spacer()
                Button(card.zh ? "複製" : "Copy", action: onCopy)
                if let onInsert {
                    Button(card.insertLabel ?? (card.zh ? "插入" : "Insert"), action: onInsert).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
