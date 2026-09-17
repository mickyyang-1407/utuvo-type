import AppKit

/// Carbon RegisterEventHotKey 對已佔用的組合只回 -9878，不會告訴我們被誰搶走。
/// 退而求其次：常見搶 ⌥Space 的 App bundle ID 表，掃 runningApplications
/// 比對得到的就是目前最可能的兇手；沒命中就當「另一個 App」。
struct HotkeyConflictSuspect {
    let bundleID: String
    let name: String
    let unbindHintZH: String
    let unbindHintEN: String
}

enum HotkeyConflictSuspects {
    /// 比對順序就是 UI 顯示順序：越多人在搶，越值得列在前面。
    /// unbindHint 告訴使用者到哪一頁去把那顆鍵解開，不是按鈕。
    static let table: [HotkeyConflictSuspect] = [
        HotkeyConflictSuspect(
            bundleID: "com.google.Gemini",
            name: "Gemini",
            unbindHintZH: "Gemini → 設定 → 鍵盤快捷鍵",
            unbindHintEN: "Gemini → Settings → Keyboard shortcut"
        ),
        HotkeyConflictSuspect(
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            unbindHintZH: "ChatGPT → 設定 → 鍵盤快捷鍵",
            unbindHintEN: "ChatGPT → Settings → Keyboard shortcuts"
        ),
        HotkeyConflictSuspect(
            bundleID: "com.raycast.macos",
            name: "Raycast",
            unbindHintZH: "Raycast → 設定 → General → Raycast Hotkey",
            unbindHintEN: "Raycast → Settings → General → Raycast Hotkey"
        ),
        HotkeyConflictSuspect(
            bundleID: "com.runningwithcrayons.Alfred",
            name: "Alfred",
            unbindHintZH: "Alfred → General → Alfred Hotkey",
            unbindHintEN: "Alfred → General → Alfred Hotkey"
        )
    ]

    /// 目前正在跑、且 bundle ID 命中 table 的嫌犯；空陣列表示被未知 App 搶走。
    static func running() -> [HotkeyConflictSuspect] {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return table.filter { runningBundleIDs.contains($0.bundleID) }
    }
}

/// 衝突卡要的所有資訊：被搶的快捷鍵 displayName 與當下掃到的嫌犯清單。
/// 不持久化（UserDefaults key 不變），純記憶體狀態。
struct HotkeyConflictInfo {
    let shortcut: String
    let suspects: [HotkeyConflictSuspect]

    /// 用於 UI：嫌犯名用「、」串起來；沒人命中時退到「另一個 App／another app」。
    func suspectsDisplayName(zh: Bool) -> String {
        guard !suspects.isEmpty else {
            return zh ? "另一個 App" : "another app"
        }
        return suspects.map(\.name).joined(separator: "、")
    }

    /// 第一個嫌犯的解除路徑；沒有嫌犯時 nil（卡會顯示「未知 App」中性訊息）。
    var firstUnbindHintZH: String? { suspects.first?.unbindHintZH }
    var firstUnbindHintEN: String? { suspects.first?.unbindHintEN }
}