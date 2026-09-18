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
        let field = app.textFields["dictionaryTerm"]
        guard field.waitForExistence(timeout: 5) else { return }
        revealDictionaryField(app)
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
            let field = app.textFields["dictionaryTerm"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            revealDictionaryField(app)
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

    /// 打字模式：光球左側切 EN 真的打得出字（句首自動大寫）、右上循環鍵切注音、左右滑回語音。
    func testTypingModes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = app.textFields["dictionaryTerm"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        revealDictionaryField(app)
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        shot("voice-idle")

        app.buttons["英文鍵盤"].tap()
        for key in ["h", "i"] { app.buttons[key].tap() }
        app.buttons["space"].tap()
        XCTAssertEqual(field.value as? String, "Hi ", "EN 鍵盤要打得出字、句首大寫")
        shot("typing-english")

        // 打字區右上循環鍵：EN → 繁（注音）。
        app.buttons["切換鍵盤版面"].tap()
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "注音版面沒出來")
        // 真的選字：ㄋㄧˇㄏㄠˇ → 候選列「你好」→ 點下去進輸入框。
        for key in ["ㄋ", "ㄧ", "ˇ", "ㄏ", "ㄠ", "ˇ"] { app.buttons[key].tap() }
        let pick = app.buttons["你好"]
        XCTAssertTrue(pick.waitForExistence(timeout: 2), "候選列沒有「你好」")
        sleep(1)
        shot("typing-zhuyin")
        pick.tap()
        XCTAssertEqual(field.value as? String, "Hi 你好", "選字後要進輸入框")

        // 左滑：繁 → 简（拼音版面有分隔音節鍵）→ 語音。從右邊的鍵起手，往左拖才不會拖出螢幕。
        func swipeLeft(from key: String) {
            let start = app.buttons[key].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        }
        swipeLeft(from: "ㄤ")
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "左滑沒到简（拼音）")
        shot("typing-pinyin")
        swipeLeft(from: "l")
        let backToVoice = app.buttons["繁中"].waitForExistence(timeout: 2)
        shot("after-swipe")
        XCTAssertTrue(backToVoice, "左滑沒回到語音")
    }

    /// 拼音：简 打 nihao 選「你好」；繁切拼音打 taibei 選臺北／台北、nihao 按空白送出繁體；再切回注音。
    func testPinyinModes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = app.textFields["dictionaryTerm"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        revealDictionaryField(app)
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "简（拼音）版面沒出來")
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }
        let nihao = app.buttons["你好"]
        XCTAssertTrue(nihao.waitForExistence(timeout: 2), "简 nihao 候選列沒有「你好」")
        shot("typing-pinyin-hans")
        nihao.tap()
        XCTAssertEqual(field.value as? String, "你好", "简 選字後要進輸入框")

        // 打字區左上小光球回語音，再從光球左側那排選「繁」。
        app.buttons["語音"].tap()
        XCTAssertTrue(app.buttons["注音鍵盤"].waitForExistence(timeout: 2), "回語音後左側沒有切版面的鈕")
        app.buttons["注音鍵盤"].tap()
        // 上一次若停在繁拼音，先回注音，保證從已知狀態開始。
        if app.buttons["改用注音"].waitForExistence(timeout: 1) { app.buttons["改用注音"].tap() }
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "繁（注音）版面沒出來")
        app.buttons["改用拼音"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "繁切拼音後沒出拼音版面")
        for key in ["t", "a", "i", "b", "e", "i"] { app.buttons[key].tap() }
        let taipei = app.buttons.matching(NSPredicate(format: "label IN {'臺北', '台北'}")).firstMatch
        XCTAssertTrue(taipei.waitForExistence(timeout: 2), "繁拼音 taibei 候選列沒有臺北／台北")
        shot("typing-pinyin-hant")
        let picked = taipei.label
        taipei.tap()
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }
        app.buttons["空白"].tap()
        XCTAssertEqual(field.value as? String, "你好" + picked + "你好", "繁拼音空白要送出最佳轉換")

        app.buttons["改用注音"].tap()
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "切回注音失敗")
    }

    /// 真機回報 09-18：①講話中逐字稿就進輸入框（沒按停止也能送出、按停止又送一次）②講完左上 Logo 不見。
    /// 用 DEBUG 姿態 flow 走鍵盤真正的 handle()：兩段即時字幕 → 3 秒後定稿。
    func testDictationInsertsOnlyOnFinal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-utuvo.type.keyboard.debugPose", "flow"]
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = app.textFields["dictionaryTerm"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        revealDictionaryField(app)
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        // 姿態在鍵盤出現 0.3 秒後開始；切鍵盤本身要一點時間，所以重新叫一次鍵盤讓時序從頭來。
        app.terminate()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        revealDictionaryField(app)
        field.tap()
        XCTAssertTrue(app.buttons["繁中"].waitForExistence(timeout: 5))
        sleep(1)
        shot("flow-partial")
        let placeholder = field.placeholderValue ?? ""
        let during = (field.value as? String) ?? ""
        XCTAssertTrue(during.isEmpty || during == placeholder, "講話中不該把逐字稿插進輸入框，卻有「\(during)」")
        sleep(4)
        shot("flow-final")
        let after = (field.value as? String) ?? ""
        XCTAssertTrue(after.hasPrefix("記得帶耳機和硬碟"), "定稿要進輸入框：「\(after)」")
        XCTAssertEqual(after.components(separatedBy: "記得帶耳機和硬碟").count - 1, 1, "定稿只能插一次：「\(after)」")
        XCTAssertTrue(app.staticTexts["UTUVO Type"].exists, "定稿後左上品牌（Logo＋字標）要回來")
    }

    /// 個人字典兩種用法：預設「新增詞彙」只有一格；切「替換」多一格「改成」。
    func testDictionaryModes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let term = app.textFields["dictionaryTerm"]
        XCTAssertTrue(term.waitForExistence(timeout: 5))
        revealDictionaryField(app)
        XCTAssertFalse(app.textFields["dictionaryOutput"].exists, "新增詞彙模式不該有「改成」欄")
        shot("dictionary-vocabulary")
        app.buttons["替換"].tap()
        XCTAssertTrue(app.textFields["dictionaryOutput"].waitForExistence(timeout: 2), "替換模式要有「改成」欄")
        shot("dictionary-replacement")
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
        // 叫出鍵盤一律從語音開始：「繁中」語言徽章（或左側「英文鍵盤」鈕）只有 UTUVO Type 鍵盤有。
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
            revealDictionaryField(app)
            field.tap()
            if badge.waitForExistence(timeout: 8) { return true }
        }
        shot("switch-failed")
        return false
    }

    /// 字典輸入欄可能落在浮動分頁列正後方：直接點會點到分頁列的「歷史」（2026-09-18 假紅）。先往上捲一次。
    private func revealDictionaryField(_ app: XCUIApplication) {
        let field = app.textFields["dictionaryTerm"]
        let tabBar = app.tabBars.firstMatch
        if field.exists, tabBar.exists, field.frame.maxY > tabBar.frame.minY - 8 {
            app.swipeUp()
            sleep(2) // 等慣性捲動停下來：還在滑就點，會點到下面的 API key 密碼欄（系統鍵盤）
        }
    }

}
