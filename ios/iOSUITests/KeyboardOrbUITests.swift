import XCTest

/// 走產品入口看鍵盤：主 app 的 TextField → 切到 UTUVO Type 鍵盤 → 光球在、姿態對，截圖存附件。
/// 模擬器沒麥克風，錄音姿態走 DEBUG launch arg（`-utuvo.type.keyboard.debugPose`）。
@MainActor
final class KeyboardOrbUITests: XCTestCase {
    /// 暖機：剛重裝後鍵盤 extension 第一次出現時，無障礙樹常接不到 app 上（模擬器測試工具的毛病）。
    /// 先叫出一次鍵盤，不做斷言；XCTest 依名稱排序，這條最先跑。
    func test0WarmUpKeyboard() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = app.textFields["要替換的詞"]
        guard field.waitForExistence(timeout: 5) else { return }
        field.tap()
        _ = switchToUTUVOKeyboard(app)
        app.terminate()
    }

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

    /// 打字模式：右上切 EN 真的打得出字（句首自動大寫）、切注音出注音版面、左右滑回語音。
    func testTypingModes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = app.textFields["要替換的詞"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["英文鍵盤"].tap()
        for key in ["h", "i"] { app.buttons[key].tap() }
        app.buttons["space"].tap()
        XCTAssertEqual(field.value as? String, "Hi ", "EN 鍵盤要打得出字、句首大寫")
        shot("typing-english")

        app.buttons["注音鍵盤"].tap()
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "注音版面沒出來")
        // 真的選字：ㄋㄧˇㄏㄠˇ → 候選列「你好」→ 點下去進輸入框。
        for key in ["ㄋ", "ㄧ", "ˇ", "ㄏ", "ㄠ", "ˇ"] { app.buttons[key].tap() }
        let pick = app.buttons["你好"]
        XCTAssertTrue(pick.waitForExistence(timeout: 2), "候選列沒有「你好」")
        sleep(1)
        shot("typing-zhuyin")
        pick.tap()
        XCTAssertEqual(field.value as? String, "Hi 你好", "選字後要進輸入框")

        // 左滑兩次：繁 → 語音 → EN（循環）
        let start = app.buttons["ㄤ"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        let backToVoice = app.buttons["繁中"].waitForExistence(timeout: 2)
        shot("after-swipe")
        XCTAssertTrue(backToVoice, "左滑沒回到語音")
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // 除錯用：UTUVO_SHOT_DIR 有設就另存一份到主機資料夾（xcresult 收不完整時也拿得到）。
        if let dir = ProcessInfo.processInfo.environment["UTUVO_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let a = XCTAttachment(screenshot: screenshot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 長按地球從清單選 UTUVO Type，再用我們鍵盤專有的「繁中」語言徽章確認。
    /// 不能用「換行」判斷：系統注音鍵盤的換行鍵標籤也叫「換行」（2026-09-18 假綠）。
    /// 模擬器要先在「設定」加入鍵盤（見 AppStoreScreenshotTests.test0EnableKeyboard）。
    private func switchToUTUVOKeyboard(_ app: XCUIApplication) -> Bool {
        // 右上模式切換鈕在語音／EN／繁每個模式都在，只有 UTUVO Type 鍵盤有。
        let badge = app.buttons.matching(NSPredicate(format: "label IN {'英文鍵盤', '繁中'}")).firstMatch
        if badge.waitForExistence(timeout: 4) { return true }
        let globe = app.buttons["Next keyboard"]
        guard globe.waitForExistence(timeout: 3) else { return false }
        globe.press(forDuration: 1.2)
        let pick = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'UTUVO Type'")).firstMatch
        guard pick.waitForExistence(timeout: 4) else { print("KEYBOARD MENU:\n\(app.debugDescription)"); return false }
        pick.tap()
        if badge.waitForExistence(timeout: 8) { return true }
        // 剛重裝後第一次出現：鍵盤畫面在，但它的無障礙樹偶爾沒接到 app 上。
        // 收起鍵盤再點一次輸入框，系統會重新接上（模擬器測試工具的毛病，不是產品問題）。
        for _ in 0..<2 {
            let field = app.textFields.firstMatch
            app.navigationBars.firstMatch.tap()
            sleep(1)
            field.tap()
            if badge.waitForExistence(timeout: 8) { return true }
        }
        shot("switch-failed")
        return false
    }
}
