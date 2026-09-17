import Foundation

/// 輸出形狀的 deterministic 修整（2026-09-11）。
///
/// 本機小型 editor（Qwen3-4B）會把單一敘述也加上 "- " 前綴——「等一下開會」
/// 變成「- 等一下開會」，貼進文件就是多一顆髒點。prompt 已經寫明單一敘述要用段落，
/// 但不能只靠模型守規矩，這裡用純函式再兜一層。
///
/// 放在 Core 是為了可測（App target 沒有測試 target）。
public enum OutputShape: Sendable {
    private static let bulletMarkers = ["- ", "* ", "• ", "・"]

    /// 整段輸出恰好一行、而且那行是條列項時，剝掉條列符號。
    /// 兩行以上（真的多項條列）一律原樣返回。
    public static func stripLoneBullet(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 1 else { return text }
        let line = lines[0].trimmingCharacters(in: .whitespaces)
        for marker in bulletMarkers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}
