import StoreKitTest
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

/// 教學影片分場（2026-09-26，照「還能花」做法）：`TEST_RUNNER_UTUVO_TOUR=<scene>` 才跑，一場一次，
/// 外面用 `simctl io recordVideo` 錄。模擬器要是繁中系統語言（設定、訊息的標籤都是中文）。
/// 結束時印 `TOUR-DONE <scene>`，錄影腳本看到它才收。
@MainActor
final class TutorialTourUITests: XCTestCase {
    private var scene: String { ProcessInfo.processInfo.environment["UTUVO_TOUR"] ?? "" }

    override func setUp() async throws {
        try XCTSkipIf(scene.isEmpty, "只在錄教學影片時跑")
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    private func tapWhenReady(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "找不到 \(what)：\n\(app.debugDescription)")
        element.tap()
    }

    private func launchApp(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-utuvo.type.ios.keyboardGuideDismissed", "YES", "-utuvo.type.keyboard.language", "zh-TW",
                               "-utuvo.type.ios.language", "zh-TW"] + args
        app.launch()
        return app
    }

    private func shotToDir(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UTUVO_SHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func openSettingsTab(_ app: XCUIApplication) {
        tapWhenReady(app.tabBars.buttons["設定"], "設定 tab", in: app)
        sleep(1)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
            usleep(600_000)
        }
    }

    /// 訊息 App 的輸入框，並切到 UTUVO Type 鍵盤。
    private func messagesWithOurKeyboard() -> XCUIApplication {
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        for label in ["繼續", "以後", "好", "Continue", "Not Now", "OK"] where messages.buttons[label].waitForExistence(timeout: 1) {
            messages.buttons[label].tap()
        }
        let thread = messages.cells.firstMatch
        if thread.waitForExistence(timeout: 4) { thread.tap() }
        let body = messages.textFields["messageBodyField"]
        tapWhenReady(body, "訊息輸入框", in: messages)
        return messages
    }

    private func pickOurKeyboard(_ messages: XCUIApplication) {
        let badge = messages.buttons.matching(NSPredicate(format: "label IN {'繁中', '简中'}")).firstMatch
        if badge.waitForExistence(timeout: 2) { return }
        let globe = messages.buttons.matching(NSPredicate(format: "label IN {'Next keyboard', '下一個鍵盤', '下一个键盘'}")).firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5), "找不到地球鍵：\n\(messages.debugDescription)")
        sleep(1)
        globe.press(forDuration: 1.4)
        sleep(1)
        tapWhenReady(any(messages, "label == 'UTUVO Type'"), "鍵盤清單的 UTUVO Type", in: messages)
    }

    func testTour() throws {
        switch scene {
        case "home":
            _ = launchApp(["-utuvo.type.ios.orbDemo", "YES",
                           "-utuvo.type.ios.previewOutput", "明天下午三點在錄音室對 Atmos 母帶，記得帶硬碟和耳機。"])
            sleep(7)

        case "addkb":
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.terminate()
            settings.launch()
            sleep(2)
            let general = any(settings, "label == '一般'")
            scrollTo(general, in: settings)
            tapWhenReady(general, "一般", in: settings)
            sleep(1)
            let keyboard = any(settings, "label == '鍵盤'")
            scrollTo(keyboard, in: settings)
            tapWhenReady(keyboard, "鍵盤", in: settings)
            sleep(1)
            tapWhenReady(settings.cells.matching(NSPredicate(format: "label BEGINSWITH '鍵盤'")).firstMatch, "鍵盤清單", in: settings)
            sleep(1)
            tapWhenReady(any(settings, "identifier == 'AddNewKeyboard' OR label BEGINSWITH '新增鍵盤' OR label BEGINSWITH '加入新鍵盤'"), "新增鍵盤", in: settings)
            sleep(1)
            let ours = any(settings, "label == 'UTUVO Type'")
            scrollTo(ours, in: settings)
            tapWhenReady(ours, "UTUVO Type", in: settings)
            sleep(2)

        case "fullaccess":
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.activate()
            sleep(1)
            let toggle = settings.switches.firstMatch
            if !toggle.waitForExistence(timeout: 2) {
                tapWhenReady(any(settings, "label BEGINSWITH 'UTUVO Type'"), "鍵盤清單裡的 UTUVO Type", in: settings)
                sleep(1)
            }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "找不到允許完整取用開關：\n\(settings.debugDescription)")
            sleep(1)
            // iOS 26+ 的開關要點在開關本體（右側），點整列不會切。
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let allow = settings.alerts.buttons.matching(NSPredicate(format: "label IN {'允許', 'Allow'}")).firstMatch
            if allow.waitForExistence(timeout: 4) { sleep(1); allow.tap() }
            sleep(1)
            XCTAssertEqual(toggle.value as? String, "1", "允許完整取用沒有打開：\n\(settings.debugDescription)")
            sleep(1)

        case "switchkb":
            let messages = messagesWithOurKeyboard()
            sleep(1)
            pickOurKeyboard(messages)
            sleep(3)

        case "jump":
            // 鍵盤第一次點光球：跳到 UTUVO Type 開麥克風（URL 跟鍵盤送的一樣，帶回訊息的 bundle id）。
            let messages = messagesWithOurKeyboard()
            pickOurKeyboard(messages)
            sleep(2)
            XCUIDevice.shared.system.open(URL(string: "utuvotype://voice?lang=zh-TW&return=com.apple.MobileSMS")!)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["打開", "Open"] where springboard.buttons[label].waitForExistence(timeout: 2) { springboard.buttons[label].tap() }
            let app = XCUIApplication()
            _ = app.wait(for: .runningForeground, timeout: 8)
            // 第一次會問麥克風／語音辨識權限：照實按「允許」（這也是教學的一步）。
            for _ in 0..<3 {
                let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'允許', '好', 'Allow', 'OK'}")).firstMatch
                if allow.waitForExistence(timeout: 3) { sleep(1); allow.tap() } else { break }
            }
            sleep(5)
            let end = app.buttons["結束鍵盤語音"]
            if end.waitForExistence(timeout: 3) { end.tap() }
            sleep(1)

        case "speak":
            let app = launchApp(["-utuvo.type.keyboard.debugPose", "flow:4"])
            sleep(1)
            app.terminate()
            let messages = messagesWithOurKeyboard()
            pickOurKeyboard(messages)
            sleep(7)
            messages.terminate()
            // 收掉姿態，免得之後的場景又自動演一次。
            let clean = launchApp()
            sleep(1)
            clean.terminate()

        case "keepopen":
            let app = launchApp()
            openSettingsTab(app)
            let picker = any(app, "label BEGINSWITH '鍵盤語音保持開啟'")
            scrollTo(picker, in: app)
            sleep(1)
            picker.tap()
            sleep(1)
            let thirty = any(app, "label == '30 分鐘'")
            if thirty.waitForExistence(timeout: 3) { thirty.tap() }
            sleep(2)

        case "groqapp":
            let app = launchApp()
            openSettingsTab(app)
            let row = app.descendants(matching: .any)["smartCleanupRow"]
            scrollTo(row, in: app)
            sleep(1)
            row.tap()
            sleep(2)
            let picker = app.buttons.containing(NSPredicate(format: "label CONTAINS '服務'")).firstMatch
            if picker.waitForExistence(timeout: 3) {
                picker.tap(); sleep(1)
                any(app, "label == 'Groq（推薦）'").tap(); sleep(1)
            }
            let field = app.secureTextFields["smartKey"]
            scrollTo(field, in: app)
            field.tap()
            field.typeText("gsk_demo_placeholder_0000")
            sleep(1)
            app.buttons["儲存"].firstMatch.tap()
            sleep(1)
            let toggle = app.switches["用這把 key 辨識語音"]
            scrollTo(toggle, in: app)
            sleep(1)
            if toggle.exists { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
            sleep(2)

        case "dict":
            let app = launchApp()
            openSettingsTab(app)
            let field = app.textFields["dictionaryTerm"]
            scrollTo(field, in: app)
            sleep(1)
            field.tap()
            field.typeText("Tonmeister")
            sleep(1)
            app.buttons["加入"].firstMatch.tap()
            sleep(2)

        case "tipjar":
            // 幫我加油（0.2.4）：本機 StoreKit 設定，真的走一次購買；兩張截圖（清單＋謝謝）也是 IAP 送審截圖。
            let session = try SKTestSession(configurationFileNamed: "TypeTips")
            session.disableDialogs = true
            session.failTransactionsEnabled = false
            session.askToBuyEnabled = false
            session.clearTransactions()
            let app = launchApp()
            openSettingsTab(app)
            let row = app.descendants(matching: .any)["tipJarRow"]
            scrollTo(row, in: app)
            sleep(1)
            row.tap()
            let coffee = app.buttons["tip:com.utuvo.type.ios.tip.coffee"]
            XCTAssertTrue(coffee.waitForExistence(timeout: 10), "加油清單沒載出來：\n\(app.debugDescription)")
            XCTAssertTrue(app.buttons["tip:com.utuvo.type.ios.tip.boost"].exists)
            sleep(1)
            shotToDir("tipjar-list")
            coffee.tap()
            let thanks = app.alerts["謝謝你的加油！"]
            XCTAssertTrue(thanks.waitForExistence(timeout: 10), "買完沒有出現謝謝：\n\(app.debugDescription)")
            sleep(1)
            shotToDir("tipjar-thanks")
            thanks.buttons.firstMatch.tap()
            XCTAssertEqual(session.allTransactions().count, 1, "應該剛好一筆交易")
            session.clearTransactions()
            sleep(1)

        default:
            XCTFail("不認得的場景 \(scene)")
        }
        print("TOUR-DONE \(scene)")
    }
}
