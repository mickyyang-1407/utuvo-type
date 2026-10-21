import XCTest

/// 本地化字串的測試輔助。
///
/// 這批測試要驗的是「**某個判斷選到了哪一句**」（回車鍵 `.send` 要給送出那句、錯誤 429 要給額度用完那句），
/// 不是「這句話長什麼樣」。直接寫死中文字面值，等於把測試綁死在測試主機的語言上——
/// 測試機語言一變（工單 ios-D 補完英文後，模擬器是 en-TW），全部變紅，而且紅的原因跟被測的邏輯無關。
///
/// `localized(_:)` 跟產品程式碼走同一條路（`String(localized:)`／Bundle.main）。
/// 拿它當期望值，測的就是「映射對不對」——回車鍵映射到錯的 key 仍然會紅。
enum LocalizationTestSupport {
    /// 跟產品程式碼同一條解析路徑。
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

extension XCTestCase {
    /// 映射測試用：斷言結果等於「同一個 key 經同一條路徑解析出來的值」。
    /// 這不是放寬——映射到別的 key 一樣會紅，而且紅在對的地方。
    ///
    /// 只有這一個 overloaded 版本。**不要**再加一個 `String` 版本轉呼叫 optional 版：
    /// `String` 會無歧義地優先選中非 optional 的那個，於是它呼叫自己 → 無限遞迴 → 整個測試行程 crash
    /// （XCTest 只會印 "Restarting after unexpected exit"，看起來像隨機 hang）。
    func assertLocalizedEquals(_ key: String,
                               _ actual: @autoclosure () -> String?,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        let expected: String? = LocalizationTestSupport.localized(key)
        XCTAssertEqual(actual(), expected,
                       "「\(key)」的映射不對（測試主機語言：\(Locale.preferredLanguages.first ?? "?")）",
                       file: file, line: line)
    }

    /// 插值字串的版本：程式裡寫的是 `String(localized: "服務忙或暫時故障（\(code)）")`，
    /// 字串目錄裡的 key 是 `服務忙或暫時故障（%@）`——**填好的那一版不是 key**，
    /// 拿它去查會查不到而原樣回傳，於是拿中文去比英文，測試永遠紅。
    /// 這裡用 key 解析、再把 `%@` 換成實際值。
    func assertLocalizedTemplateEquals(_ key: String,
                                       substituting value: String,
                                       _ actual: @autoclosure () -> String?,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let expected = LocalizationTestSupport.localized(key).replacingOccurrences(of: "%@", with: value)
        XCTAssertEqual(actual(), expected,
                       "「\(key)」（代入 \(value)）的映射不對（測試主機語言：\(Locale.preferredLanguages.first ?? "?")）",
                       file: file, line: line)
    }

}
