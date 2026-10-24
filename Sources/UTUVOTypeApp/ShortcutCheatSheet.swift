import Carbon.HIToolbox
import Foundation

/// app-shell-5（2026-10-22）：首頁（選單列 popover）列出所有快捷鍵，像 Typeless 首頁的快捷鍵卡。
/// 純函式：順序固定（聽寫 → 各翻譯變體 → Ask anything → 白話解釋 → 翻譯選取），沒設定的快捷鍵不列。
enum ShortcutCheatSheet {
    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
        let keys: String
    }

    struct TranslationSlot: Equatable {
        let modifier: String
        /// Carbon 修飾鍵（跟 installTranslationVariants 註冊時同一個值）。
        let mask: UInt32
        let target: TranslationTarget

        static func shift(_ target: TranslationTarget) -> Self { .init(modifier: "⇧", mask: UInt32(shiftKey), target: target) }
        static func command(_ target: TranslationTarget) -> Self { .init(modifier: "⌘", mask: UInt32(cmdKey), target: target) }
        static func control(_ target: TranslationTarget) -> Self { .init(modifier: "⌃", mask: UInt32(controlKey), target: target) }
    }

    static func items(dictate: String, slots: [TranslationSlot], ask: String, explain: String,
                      translateSelection: String, zh: Bool) -> [Item] {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var items: [Item] = []
        let base = clean(dictate)
        if !base.isEmpty {
            items.append(Item(id: "dictate", title: zh ? "聽寫" : "Dictate", keys: base))
            // 跟 installTranslationVariants 同一條規則（同一個 ShortcutSpec.parse）：聽寫快捷鍵解析不了就沒有變體；
            // 聽寫快捷鍵本身已含這個修飾鍵就不會註冊，這裡也不列。
            let baseModifiers = ShortcutSpec.parse(base)?.modifiers
            for slot in slots where slot.target != .off {
                guard let baseModifiers, baseModifiers & slot.mask == 0 else { continue }
                let name = slot.target.localizedName(zh: zh)
                items.append(Item(id: "translate-\(slot.modifier)",
                                  title: zh ? "翻成\(name)" : "Translate → \(name)",
                                  keys: "\(slot.modifier) + \(base)"))
            }
        }
        let rest: [(String, String, String)] = [
            ("ask", "Ask anything", clean(ask)),
            ("explain", zh ? "白話解釋選取" : "Explain selection", clean(explain)),
            ("translate-selection", zh ? "翻譯選取" : "Translate selection", clean(translateSelection)),
        ]
        for (id, title, keys) in rest where !keys.isEmpty {
            items.append(Item(id: id, title: title, keys: keys))
        }
        return items
    }

    /// 目前設定對應的清單（popover 用）。
    @MainActor
    static func items(for preferences: AppPreferences) -> [Item] {
        items(dictate: preferences.globalShortcut,
              slots: [.shift(preferences.translationSlotShift), .command(preferences.translationSlotCommand),
                      .control(preferences.translationSlotControl)],
              ask: preferences.askShortcut, explain: preferences.explainShortcut,
              translateSelection: preferences.translateSelectionShortcut, zh: preferences.isChineseUI)
    }
}
