import XCTest

/// 走產品入口看鍵盤：主 app 的 TextField → 切到 UTUVO Type 鍵盤 → 光球在、姿態對，截圖存附件。
/// 模擬器沒麥克風，錄音姿態走 DEBUG launch arg（`-utuvo.type.keyboard.debugPose`）。
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

    /// 第三方鍵盤跑在另一個程序，XCUITest 看得到的只有它的無障礙元素（有時連這個都沒有），
    /// 所以兩種證據擇一：光球 identifier 出現、或「換行」這顆我們鍵盤才有的鍵出現。
    private func switchToUTUVOKeyboard(_ app: XCUIApplication) -> Bool {
        let orb = app.descendants(matching: .any)["utuvoKeyboardOrb"]
        let ours = app.buttons["換行"]
        for i in 0..<5 {
            if orb.waitForExistence(timeout: 2) || ours.exists { return true }
            // 新裝置第一次切鍵盤：系統「Quickly Change Keyboards」導覽，按掉再切。
            let intro = app.buttons["Continue"]
            if intro.exists { intro.tap(); continue }
            let globe = app.buttons["Next keyboard"]
            guard globe.exists else { return false }
            globe.tap()
            sleep(1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "after-globe-\(i)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        print("KEYBOARD TREE:\n\(app.debugDescription)")
        return orb.exists || ours.exists
    }
}
