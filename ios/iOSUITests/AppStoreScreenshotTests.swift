import XCTest

/// App Store 截圖（6.9 吋）：`TEST_RUNNER_UTUVO_STORE_SHOTS=1` 才跑，截圖存成 xcresult 附件。
/// 模擬器沒麥克風：錄音姿態走 DEBUG launch arg，歷史用 `-utuvo.type.ios.seedHistory` 種範例。
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UTUVO_STORE_SHOTS"] == "1", "只在出截圖時跑")
        continueAfterFailure = false
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launchApp(_ args: [String]) -> XCUIApplication {
        // 先回主畫面：從別的 app 切過來狀態列會留「◀︎ 上一個 app」。
        XCUIDevice.shared.press(.home)
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-utuvo.type.ios.seedHistory", "YES", "-utuvo.type.ios.keyboardGuideDismissed", "YES"] + args
        app.launch()
        return app
    }

    func test1Home() {
        _ = launchApp([])
        sleep(3)
        shot("01-home")
    }

    func test2Listening() {
        _ = launchApp(["-utuvo.type.ios.orbDemo", "YES",
                       "-utuvo.type.ios.previewOutput", "明天下午三點在錄音室對 Atmos 母帶，記得帶硬碟和耳機。"])
        sleep(2)
        shot("02-listening")
    }

    func test3History() {
        let app = launchApp([])
        app.tabBars.buttons["歷史"].tap()
        sleep(2)
        shot("05-history")
    }

    /// 走正規路徑在「設定」加入 UTUVO Type 鍵盤（defaults 寫入只對自家 app 有效，系統 app 的清單看不到）。
    func test0EnableKeyboard() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        for label in ["General", "Keyboard"] {
            let cell = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "找不到 \(label)：\n\(settings.debugDescription)")
            cell.tap()
        }
        let list = settings.cells["KEYBOARDS"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.tap()
        sleep(1)
        print("KEYBOARD LIST:", settings.cells.allElementsBoundByIndex.map(\.label))
        if settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'UTUVO Type'")).firstMatch.waitForExistence(timeout: 2) {
            print("KEYBOARD ALREADY LISTED"); return
        }
        let add = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Add New Keyboard'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "\(settings.debugDescription)")
        add.tap()
        let ours = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'UTUVO Type'")).firstMatch
        XCTAssertTrue(ours.waitForExistence(timeout: 5), "新增鍵盤清單沒有 UTUVO Type：\n\(settings.debugDescription)")
        ours.tap()
        sleep(1)
        print("KEYBOARD ADDED")
    }

    func test4KeyboardInMessages() throws {
        for (pose, name) in [("recording", "03-keyboard-recording"), ("arc", "04-keyboard-translate")] {
            let app = launchApp(["-utuvo.type.keyboard.debugPose", pose])
            sleep(1)
            app.terminate()
            let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
            messages.launch()
            for label in ["Continue", "Not Now", "OK"] where messages.buttons[label].waitForExistence(timeout: 1) {
                messages.buttons[label].tap()
            }
            // 模擬器內建幾段範例對話：點第一段進去，在對話裡叫鍵盤（比空白的新訊息像真實使用）。
            let thread = messages.cells.firstMatch
            if thread.waitForExistence(timeout: 4) { thread.tap() }
            let body = messages.textFields["messageBodyField"]
            XCTAssertTrue(body.waitForExistence(timeout: 5), "找不到訊息輸入框：\n\(messages.debugDescription)")
            body.tap()
            // 長按地球鍵，從清單直接選 UTUVO Type（輪流切會停在哪個鍵盤不確定）。
            let globe = messages.buttons["Next keyboard"]
            XCTAssertTrue(globe.waitForExistence(timeout: 5))
            globe.press(forDuration: 1.2)
            let pick = messages.descendants(matching: .any).matching(NSPredicate(format: "label == 'UTUVO Type'")).firstMatch
            XCTAssertTrue(pick.waitForExistence(timeout: 4), "鍵盤清單沒有 UTUVO Type：\n\(messages.debugDescription)")
            pick.tap()
            // 斷言真的是我們的鍵盤：語言徽章「繁中」只有 UTUVO Type 鍵盤有。
            XCTAssertTrue(messages.buttons["繁中"].waitForExistence(timeout: 5), "切換後不是 UTUVO Type 鍵盤")
            sleep(2)
            shot(name)
            messages.terminate()
        }
    }
}
