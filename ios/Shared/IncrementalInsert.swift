import Foundation

/// 鍵盤增量插入的唯一決策點（IOS3／2026-09-11）。
///
/// v1 的邏輯是 `if text.count > lastText.count { insert(suffix) }`，假設辨識器
/// 只會往後長。中文辨識常常回頭改前面的字（「四十」→「是十」→「40」），
/// 這時新字串跟舊字串前綴不同、長度也可能變短：舊邏輯要嘛插入錯的尾巴，
/// 要嘛整段不更新。
///
/// 改成算共同前綴：刪掉舊字串多出來的尾巴，再補上新字串的尾巴。
/// 純函式，鍵盤只負責照 plan 呼叫 deleteBackward／insertText。
enum IncrementalInsert {
    struct Plan: Equatable, Sendable {
        /// 要按幾次 backspace（以 Character 計）。
        var deleteCount: Int
        /// 刪完之後要插入的字串。
        var insert: String

        static let noop = Plan(deleteCount: 0, insert: "")
        var isNoop: Bool { deleteCount == 0 && insert.isEmpty }
    }

    /// - Parameters:
    ///   - previous: 目前已經插進文件、由本鍵盤負責的那段文字。
    ///   - current: 辨識器最新的完整結果。
    /// - Returns: 把 `previous` 變成 `current` 的最小編輯。
    static func plan(previous: String, current: String) -> Plan {
        if previous == current { return .noop }

        let previousChars = Array(previous)
        let currentChars = Array(current)
        var common = 0
        while common < previousChars.count,
              common < currentChars.count,
              previousChars[common] == currentChars[common] {
            common += 1
        }
        return Plan(
            deleteCount: previousChars.count - common,
            insert: String(currentChars[common...])
        )
    }
}
