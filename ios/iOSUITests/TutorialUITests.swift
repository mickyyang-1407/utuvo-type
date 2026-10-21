import XCTest

/// 一步一步教學（10-15）：照教學上的字去點**真的** iPhone 設定，教學寫的每一個按鈕名稱都要找得到。
@MainActor
final class TutorialUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openTutorial(_ id: String, app: XCUIApplication) {
        app.tabBars.buttons["設定"].tap()
        let guide = app.buttons.containing(NSPredicate(format: "label CONTAINS '使用教學'")).firstMatch
        for _ in 0..<8 where !(guide.exists && guide.isHittable) { app.swipeUp() }
        guide.tap()
        let row = app.buttons["tutorial-\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "使用教學頁找不到 \(id)")
        row.tap()
        XCTAssertTrue(app.staticTexts["tutorialProgress"].waitForExistence(timeout: 5))
    }

    private func pages(_ app: XCUIApplication, name: String) -> Int {
        var count = 0
        repeat {
            count += 1
            shot("\(name)-\(count)")
            let next = app.buttons["tutorialNext"]
            if next.label == "完成" { break }
            next.tap()
            sleep(1)
        } while count < 12
        return count
    }

    /// 加入鍵盤：每一頁都看得到；第 1 頁的「打開設定」真的打開設定裡 UTUVO Type 那一頁，
    /// 教學說的「鍵盤」「UTUVO Type」「允許完整取用」都在。
    func testKeyboardTutorialMatchesRealSettings() throws {
        let app = XCUIApplication()
        app.launch()
        openTutorial("keyboard", app: app)
        XCTAssertEqual(pages(app, name: "tutorial-keyboard"), 6)
        // 回第一頁按「打開設定」
        for _ in 0..<6 { app.buttons["tutorialBack"].tap() }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()   // 設定已經開在別頁時，系統可能停在原頁；使用者第一次照做時設定通常沒開
        app.buttons["tutorialOpenSettings"].tap()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), "沒有打開設定")
        // 教學第 2 步：停在設定首頁時，照「App → UTUVO Type」走。
        let keyboards = settings.staticTexts["鍵盤"].firstMatch
        if !keyboards.waitForExistence(timeout: 4) {
            shot("real-settings-root")
            let apps = settings.staticTexts["App"].firstMatch
            for _ in 0..<6 where !(apps.exists && apps.isHittable) { settings.swipeUp() }
            XCTAssertTrue(apps.exists, "設定首頁找不到教學說的「App」")
            apps.tap()
            let ours = settings.staticTexts["UTUVO Type"].firstMatch
            for _ in 0..<12 where !(ours.exists && ours.isHittable) { settings.swipeUp() }
            XCTAssertTrue(ours.exists, "「App」清單裡找不到「UTUVO Type」")
            shot("real-settings-apps")
            ours.tap()
        }
        XCTAssertTrue(keyboards.waitForExistence(timeout: 8), "設定裡 UTUVO Type 頁沒有「鍵盤」：\n\(settings.debugDescription)")
        shot("real-settings-app-page")
        keyboards.tap()
        XCTAssertTrue(settings.switches["UTUVO Type"].waitForExistence(timeout: 5), "鍵盤頁沒有「UTUVO Type」開關")
        XCTAssertTrue(settings.switches["允許完整取用"].exists, "鍵盤頁沒有「允許完整取用」")
        shot("real-settings-keyboards")
        settings.terminate()
    }

    /// 申請 Groq key：七頁都在；最後一頁貼上不是 key 的東西要說清楚、不能存。
    func testGroqTutorialPasteRejectsNonKey() throws {
        let app = XCUIApplication()
        app.launch()
        openTutorial("groqKey", app: app)
        XCTAssertEqual(pages(app, name: "tutorial-groq"), 7)
        UIPasteboard.general.string = "hello"
        let paste = app.buttons["tutorialPasteKey"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let status = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'gsk_'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "貼上不是 key 的內容，要說清楚")
        shot("tutorial-groq-paste-wrong")
    }

    /// 有測試 key（TEST_RUNNER_UTUVO_GROQ_TEST_KEY）時：貼上真的存好並連得上 Groq。
    func testGroqTutorialPasteSavesAndTestsRealKey() throws {
        guard let key = ProcessInfo.processInfo.environment["UTUVO_GROQ_TEST_KEY"], !key.isEmpty else {
            throw XCTSkip("沒有測試 key")
        }
        let app = XCUIApplication()
        app.launch()
        openTutorial("groqKey", app: app)
        _ = pages(app, name: "tutorial-groq-real")
        UIPasteboard.general.string = key
        app.buttons["tutorialPasteKey"].tap()
        let ok = app.staticTexts["存好了，也測試過可以用！"]
        XCTAssertTrue(ok.waitForExistence(timeout: 20), "真 key 要存好並測試成功：\(app.staticTexts["tutorialKeyStatus"].label)")
        shot("tutorial-groq-paste-ok")
        UIPasteboard.general.string = ""
    }

    func testFirstUseTutorialPages() throws {
        let app = XCUIApplication()
        app.launch()
        openTutorial("firstUse", app: app)
        XCTAssertEqual(pages(app, name: "tutorial-firstuse"), 5)
    }

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
}
