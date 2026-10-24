import Foundation

/// 結果送不進去時不能默默弄丟（delivery-learning-2，2026-10-22）。
///
/// Typeless：插入後讀焦點欄位能不能編輯，不能就跳「Copy last transcript」卡片（文字＋複製鈕）。
/// Mac 以前三種情況都只改選單裡的一行狀態：目的地 App 換了、貼上失敗、焦點根本不是文字欄位。
///
/// 規則（純函式，可測）：
/// - **照舊貼上**——不靠「AXValue 可不可寫」擋貼上：Chromium／Electron 的 contenteditable 常回 AXGroup／
///   AXWebArea 或「不可寫」，擋了就是誤擋（corrections：誤擋跟漏擋一樣是缺陷）。
/// - 只有「確定不是文字欄位」（按鈕、清單、大綱、圖片，或根本沒有焦點元素）才另外跳出結果卡；
///   AX 讀不到、角色不認得＝不知道，什麼都不多做。
/// - 目的地 App 換了：維持不貼（比 Typeless 保守），改跳結果卡。
public enum DeliveryTarget: Sendable {
    /// 投遞前讀到的焦點狀態。
    public enum Focus: Equatable, Sendable {
        /// AX 回報有焦點元素。
        case element(role: String?, subrole: String?, valueSettable: Bool?)
        /// AX 正常回答「沒有焦點元素」（例如焦點在 Finder 桌面）。
        case noFocusedElement
        /// AX 讀不到（沒權限、逾時、App 不回應）。
        case unreadable
    }

    public enum Verdict: Equatable, Sendable {
        /// 確定是文字欄位。
        case deliverable
        /// 確定不是文字欄位：照貼，但另外跳結果卡讓使用者拿得回文字。
        case undeliverable
        /// 不知道：照現在的行為，只貼。
        case unknown
    }

    /// 已知會接受貼上的文字角色。
    public static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    /// 確定不是文字欄位的角色（verifier 清單：按鈕、清單、大綱、圖片）。
    /// AXTable 刻意不放：Numbers／試算表選取儲存格時焦點是 AXTable，⌘V 會貼進儲存格。
    public static let nonTextRoles: Set<String> = ["AXButton", "AXList", "AXOutline", "AXImage"]

    public static func classify(_ focus: Focus) -> Verdict {
        switch focus {
        case .unreadable:
            return .unknown
        case .noFocusedElement:
            return .undeliverable
        case .element(let role, _, let valueSettable):
            guard let role, !role.isEmpty else { return .unknown }
            if textRoles.contains(role) { return valueSettable == false ? .unknown : .deliverable }
            if nonTextRoles.contains(role) { return .undeliverable }
            return .unknown
        }
    }

    /// 這次投遞要做什麼。
    public struct Plan: Equatable, Sendable {
        /// 送 ⌘V。
        public var paste: Bool
        /// 另外跳出結果卡（文字＋複製／插入到這裡）。
        public var showCard: Bool

        public init(paste: Bool, showCard: Bool) {
            self.paste = paste
            self.showCard = showCard
        }
    }

    /// - Parameters:
    ///   - destinationChanged: 前景 App 跟開始聽寫時不同。
    ///   - focus: 投遞前的焦點判斷。
    public static func plan(destinationChanged: Bool, focus: Verdict) -> Plan {
        if destinationChanged { return Plan(paste: false, showCard: true) }
        return Plan(paste: true, showCard: focus == .undeliverable)
    }
}
