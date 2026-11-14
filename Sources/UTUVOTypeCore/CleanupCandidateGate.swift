import Foundation

/// 模型整理結果的把關（Mac 版原本寫在 `UTUVOTypeApp.SmartCleanup.accepts`，11-14 搬進 core 讓 iOS 共用）。
///
/// - 嚴格（relaxed = false）：`CleanupFidelity.preservesContent`——原文實詞都要在。
/// - 寬鬆（relaxed = true，Mac 的 Claude、iOS「精簡」風格）：`CleanupFidelity.passesRelaxed`——
///   允許條列、修錯字、濃縮；數字、對比句反轉、人稱照樣擋。
/// 兩種都檢查人稱不翻轉、不准開場白、內容不能整段消失或暴增（字數比例 0.3～1.55）。
/// Mac 另外先過 `FormatterOutputGuard`（只有 Mac 有），所以這裡不含那一道。
public enum CleanupCandidateGate {
    public static func accepts(original: String, cleaned: String, relaxed: Bool) -> Bool {
        // 寬鬆把關：整套檢查（含字數比例）都用轉成同一種數字寫法的兩邊——「一萬二，不對，一萬兩千塊」→「12,000塊」
        // 中文字從 14 掉到 4，比例 0.29 被擋（2026-10-19 真人錄音 sc02）。
        let original = relaxed ? Normalizer.normalizeNumbers(original) : original
        let cleaned = relaxed ? Normalizer.normalizeNumbers(cleaned) : cleaned
        func counts(_ s: String) -> (cjk: Int, latin: Int, digits: Int) {
            var cjk = 0, latin = 0, digits = 0
            for c in s {
                // 寬鬆把關：阿拉伯數字不算進英數比例——「十月十三號」→「10 月 13 號」會讓數字變多；
                // 數字另由 CleanupFidelity.introducesDigits 把關（2026-10-19 真人錄音 6 句數字句被誤擋）。
                if c.isASCII { if c.isLetter || (!relaxed && c.isNumber) { latin += 1 } else if c.isNumber { digits += 1 } }
                else if c.isLetter || c.isNumber { cjk += 1 }
            }
            return (cjk, latin, digits)
        }
        guard !cleaned.contains("<<<"), !cleaned.contains(">>>"),
              relaxed ? CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned)
                      : CleanupFidelity.preservesContent(original: original, cleaned: cleaned),
              // 人稱不能被翻轉（寬鬆與嚴格都檢查）。
              CleanupFidelity.keepsPerson(original: original, cleaned: cleaned) else { return false }
        let lower = cleaned.lowercased()
        guard !["here is", "here are", "sure,", "certainly", "as an ai"].contains(where: lower.hasPrefix) else { return false }
        let before = counts(original), after = counts(cleaned)
        // 只有數字的一句（「一萬二」→「12,000」）兩邊照樣有內容（FX-9）：寬鬆把關不把數字算進比例，但空不空要算；
        // 數值對不對由 passesRelaxed 的數值檢查把關（「12,000」→「21,000」擋）。
        guard before.cjk + before.latin + before.digits > 0, after.cjk + after.latin + after.digits > 0 else { return false }
        if before.cjk > 0 {
            let ratio = Double(after.cjk) / Double(before.cjk)
            guard ratio >= 0.3, ratio <= 1.55 else { return false }
        } else if after.cjk > 3 {
            return false
        }
        if before.latin > 0 {
            let ratio = Double(after.latin) / Double(before.latin)
            guard ratio >= 0.3, ratio <= 2.0 else { return false }
        } else if after.latin > 12 {
            return false
        }
        return true
    }
}
