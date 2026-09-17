import Foundation

/// 讀取使用者畫面內容的硬上限（2026-09-11 抽出）。
///
/// 產品的隱私宣稱是「只讀 focused 欄位的選取文字與它周圍一小段，不截圖、不讀整份文件」。
/// 在此之前這兩個數字是散在 `AccessibilitySupport` 裡的 magic number，**沒有任何測試**——
/// 有人把 12_000 改成 120_000 不會有東西變紅，而綠燈跟「沒在檢查」長得一模一樣。
/// 常數與截斷邏輯移到這裡，`ContextBoundsTests` 釘住。
public enum ContextBounds: Sendable {
    /// 選取文字上限（字元）。
    public static let selectedTextLimit = 12_000
    /// 游標周圍上下文的請求半徑（字元）。
    public static let surroundingRadius = 1_000
    /// 游標周圍上下文的回傳上限（字元）。
    public static let surroundingLimit = 2_000

    /// 超過上限就截斷；沒超過原樣返回。以 Character 計（一個中文字＝1）。
    public static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    public static func boundedSelectedText(_ text: String) -> String {
        bounded(text, limit: selectedTextLimit)
    }

    public static func boundedSurroundingText(_ text: String) -> String {
        bounded(text, limit: surroundingLimit)
    }
}
