import Foundation
import AppKit
import ApplicationServices

/// Immutable bounded-span evidence. The production adapter separately retains actual AX element identity.
struct AXInsertionTicket: Sendable, Equatable {
    /// 行程 pid；流程中讀到的 frontmostApplication.processIdentifier。
    let processIdentifier: Int32
    /// 行程 bundle identifier；驗證 target 沒換。
    let bundleIdentifier: String
    /// 行程顯示名稱；診斷用。
    let appName: String
    /// 該欄位的 AX identifier（kAXIdentifierAttribute）。一般 NSTextView 沒設＝空字串，
    /// 沒有 identifier 時純資料 gate 拒絕；production 另持有真正 AX element。
    let axIdentifier: String
    /// 該欄位的 AX role（kAXRoleAttribute）。例如 "AXTextArea"。
    let axRole: String
    /// 插入瞬間 focus 範圍的 UTF-16 位置（range.location）。
    let insertedUTF16Location: Int
    /// 插入的字串長度（UTF-16 units）。
    let insertedUTF16Length: Int
    /// 插入瞬間的「前面文字」前綴（從插入位置往前讀的一段 window；最長 256 字）。
    /// 用來驗證：focus 沒被切到別處、欄位內容還在那邊。
    let contextBeforePrefix: String
    /// 真正送出的原文（normalized.cleaned；不是 cleanup 結果）。
    let insertedText: String
    /// capture moment（單調時間戳；只給 logging 用，不參與 equality）。
    let capturedAt: Date

    var canIdentifyColumnReliably: Bool {
        // 沒設 AXIdentifier 或非 text-area role → 不做安全替換。
        return !axIdentifier.isEmpty && (axRole == "AXTextArea" || axRole == "AXTextField")
    }
}

/// Pure checks used after the adapter proves CF identity, caret and bounded anchors. Missing evidence rejects.
enum AXReplacementGate {
    enum Verdict: Equatable {
        case ok
        case processMismatch(expected: Int32, actual: Int32)
        case bundleMismatch(expected: String, actual: String)
        case identifierMismatch(expected: String, actual: String)
        case rangeOutOfBounds
        case contentChanged(expected: String, actual: String)
        case contextDrift(expected: String, actual: String)
        case focusLost
    }

    /// - Parameters:
    ///   - ticket: capture-time 票根。
    ///   - current: 即時 AX 快照。
    ///   - rangeProbe: 呼叫端讀出的欄位範圍文字（含 inserted 位置）。
    struct LiveSnapshot: Sendable {
        var processIdentifier: Int32
        var bundleIdentifier: String
        var axIdentifier: String
        var axRole: String
        var focused: Bool
        var rangeText: String  // 從 insertedUTF16Location 起到 insertedUTF16Length 為止的內容
        var contextBefore: String  // 欄位前 256 字
    }

    static func verdict(ticket: AXInsertionTicket, current: LiveSnapshot) -> Verdict {
        guard current.focused else { return .focusLost }
        guard ticket.insertedUTF16Location >= 0, ticket.insertedUTF16Length > 0,
              ticket.insertedUTF16Location <= Int.max - ticket.insertedUTF16Length,
              ticket.insertedText.utf16.count == ticket.insertedUTF16Length else { return .rangeOutOfBounds }
        guard ticket.canIdentifyColumnReliably, current.axRole == ticket.axRole else { return .focusLost }
        guard ticket.processIdentifier == current.processIdentifier else {
            return .processMismatch(expected: ticket.processIdentifier, actual: current.processIdentifier)
        }
        guard ticket.bundleIdentifier == current.bundleIdentifier else {
            return .bundleMismatch(expected: ticket.bundleIdentifier, actual: current.bundleIdentifier)
        }
        guard ticket.axIdentifier == current.axIdentifier else {
            return .identifierMismatch(expected: ticket.axIdentifier, actual: current.axIdentifier)
        }
        return checkRange(ticket: ticket, current: current)
    }

    private static func checkRange(ticket: AXInsertionTicket, current: AXReplacementGate.LiveSnapshot) -> Verdict {
        guard ticket.insertedUTF16Length == current.rangeText.utf16.count else {
            // 長度對不上 = 範圍被剪輯或內容被改寫
            return .contentChanged(expected: ticket.insertedText, actual: current.rangeText)
        }
        guard current.rangeText == ticket.insertedText else {
            return .contentChanged(expected: ticket.insertedText, actual: current.rangeText)
        }
        // 進一步看前面是否還對得上（focus 漂走／被插入別段）
        if !ticket.contextBeforePrefix.isEmpty,
           current.contextBefore != ticket.contextBeforePrefix {
            return .contextDrift(expected: ticket.contextBeforePrefix, actual: current.contextBefore)
        }
        return .ok
    }

    /// 從一段「欄位前半段」推出 prefix，最多 256 UTF-16 units。
    static func prefix(from context: String, maxUTF16: Int = 256) -> String {
        var result = String.UnicodeScalarView()
        var used = 0
        for scalar in context.unicodeScalars.reversed() {
            let width = scalar.utf16.count
            guard used + width <= max(0, maxUTF16) else { break }
            result.insert(scalar, at: result.startIndex)
            used += width
        }
        return String(result)
    }
}
