import XCTest

/// App Store 截圖（6.9 吋）：`TEST_RUNNER_UTUVO_STORE_SHOTS=1` 才跑，截圖存成 xcresult 附件。
/// 模擬器沒麥克風：錄音姿態走 DEBUG launch arg，歷史用 `-utuvo.type.ios.seedHistory` 種範例。
/// 简中版：`TEST_RUNNER_UTUVO_SHOT_LOCALE=zh-Hans`（主 app 用 launch args 切；鍵盤跟系統語言走，要在系統已是简中的模擬器跑）。
/// `TEST_RUNNER_UTUVO_SHOT_DIR` 有設就另存 PNG 到主機資料夾。
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UTUVO_STORE_SHOTS"] == "1", "只在出截圖時跑")
        continueAfterFailure = false
    }

    private var hans: Bool { ProcessInfo.processInfo.environment["UTUVO_SHOT_LOCALE"] == "zh-Hans" }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["UTUVO_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let a = XCTAttachment(screenshot: screenshot)
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
            + (hans ? ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                       "-utuvo.type.keyboard.language", "zh-CN", "-utuvo.type.ios.language", "zh-CN"]
                    : ["-utuvo.type.keyboard.language", "zh-TW", "-utuvo.type.ios.language", "zh-TW"])
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
                       "-utuvo.type.ios.previewOutput", hans ? "明天下午三点在录音室对 Atmos 母带，记得带硬盘和耳机。"
                                                             : "明天下午三點在錄音室對 Atmos 母帶，記得帶硬碟和耳機。"])
        sleep(2)
        shot("02-listening")
    }

    func test3History() {
        let app = launchApp([])
        app.tabBars.buttons[hans ? "历史" : "歷史"].tap()
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
            for label in ["Continue", "Not Now", "OK", "继续", "以后", "好"] where messages.buttons[label].waitForExistence(timeout: 1) {
                messages.buttons[label].tap()
            }
            // 模擬器內建幾段範例對話：點第一段進去，在對話裡叫鍵盤（比空白的新訊息像真實使用）。
            let thread = messages.cells.firstMatch
            if thread.waitForExistence(timeout: 4) { thread.tap() }
            let body = messages.textFields["messageBodyField"]
            XCTAssertTrue(body.waitForExistence(timeout: 5), "找不到訊息輸入框：\n\(messages.debugDescription)")
            body.tap()
            // 長按地球鍵，從清單直接選 UTUVO Type（輪流切會停在哪個鍵盤不確定）。
            // 已經是我們的鍵盤就不用切（系統會記住上一次用的鍵盤）。
            // 語言徽章只有 UTUVO Type 鍵盤有（「繁中」或「简中」，看上次選的聽寫語言）。
            let badge = messages.buttons.matching(NSPredicate(format: "label IN {'繁中', '简中'}")).firstMatch
            if !badge.waitForExistence(timeout: 2) {
                // 地球鍵標籤跟系統語言走（简中系統叫「下一个键盘」）。
                let globe = messages.buttons.matching(NSPredicate(format: "label IN {'Next keyboard', '下一个键盘', '下一個鍵盤'}")).firstMatch
                XCTAssertTrue(globe.waitForExistence(timeout: 5), "找不到地球鍵：\n\(messages.debugDescription)")
                globe.press(forDuration: 1.2)
                let pick = messages.descendants(matching: .any).matching(NSPredicate(format: "label == 'UTUVO Type'")).firstMatch
                XCTAssertTrue(pick.waitForExistence(timeout: 4), "鍵盤清單沒有 UTUVO Type：\n\(messages.debugDescription)")
                pick.tap()
            }
            // 斷言真的是我們的鍵盤：語言徽章「繁中」只有 UTUVO Type 鍵盤有。
            // Messages 裡鍵盤的無障礙樹有時接不上（畫面在、元素找不到；模擬器測試工具的毛病）。
            // 這是出截圖用的測試：找不到就照拍，並在 log 標記要目視確認，不擋出圖。
            if !badge.waitForExistence(timeout: 5) { print("⚠️ \(name)：AX 樹找不到語言徽章，截圖要目視確認是 UTUVO Type 鍵盤") }
            sleep(2)
            shot(name)
            messages.terminate()
        }
    }
}
