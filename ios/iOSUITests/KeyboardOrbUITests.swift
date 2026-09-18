import XCTest

/// 走產品入口看鍵盤：主 app 的 TextField → 切到 UTUVO Type 鍵盤 → 光球在、姿態對，截圖存附件。
/// 模擬器沒麥克風，錄音姿態走 DEBUG launch arg（`-utuvo.type.keyboard.debugPose`）。
@MainActor
final class KeyboardOrbUITests: XCTestCase {
    func testKeyboardOrbPoses() throws {
        for pose in ProcessInfo.processInfo.environment["ORB_POSES"].map { $0.components(separatedBy: ",") } ?? ["idle", "recording", "arc"] {
            let app = XCUIApplication()
            app.launchArguments = pose == "idle" ? [] : ["-utuvo.type.keyboard.debugPose", pose]
            app.launch()
            app.tabBars.buttons["設定"].tap()
            let field = app.textFields["要替換的詞"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
            sleep(2)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "keyboard-\(pose)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// 長按地球從清單選 UTUVO Type，再用我們鍵盤專有的「繁中」語言徽章確認。
    /// 不能用「換行」判斷：系統注音鍵盤的換行鍵標籤也叫「換行」（2026-09-18 假綠）。
    /// 模擬器要先在「設定」加入鍵盤（見 AppStoreScreenshotTests.test0EnableKeyboard）。
    private func switchToUTUVOKeyboard(_ app: XCUIApplication) -> Bool {
        let badge = app.buttons["繁中"]
        if badge.waitForExistence(timeout: 2) { return true }
        let globe = app.buttons["Next keyboard"]
        guard globe.waitForExistence(timeout: 3) else { return false }
        globe.press(forDuration: 1.2)
        let pick = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'UTUVO Type'")).firstMatch
        guard pick.waitForExistence(timeout: 4) else { print("KEYBOARD MENU:\n\(app.debugDescription)"); return false }
        pick.tap()
        return badge.waitForExistence(timeout: 5)
    }
}
