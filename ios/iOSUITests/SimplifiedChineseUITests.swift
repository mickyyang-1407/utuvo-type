import XCTest

/// 简中介面（zh-Hans）走一遍：畫面上不能留繁體字（漏翻）。
/// - 主 app：launch args 切語言（`-AppleLanguages (zh-Hans) -AppleLocale zh_CN`），不動系統設定。
/// - 鍵盤 extension：程序語言跟「系統」走，launch args 管不到；要先把模擬器系統語言切成简中，
///   再用 `TEST_RUNNER_UTUVO_L10N_KEYBOARD=1` 跑 `testKeyboardInSimplifiedChinese`（平常自動略過）。
/// 截圖存 XCTAttachment；`UTUVO_SHOT_DIR` 有設就另存到主機資料夾。
@MainActor
final class SimplifiedChineseUITests: XCTestCase {
    /// 常見的「只有繁體才有」的字（每個字 OpenCC t2s 都會轉掉）；出現在简中介面上＝漏翻。
    static let traditionalOnly = Set("設聽寫歷語鍵盤說點開關選擇譯雲裝識網體與這個們會對讓還後時間請錄權輸麥麼換錯誤單範標記紀複製儲刪條啟動應內頁將從過機碼檔無顯擊區為視圖轉聲響變舊據庫號屬邊濾準議顏讀實際題")
    /// 刻意兩種介面都一樣的標籤：講的是文字系統，不是介面語言。
    static let intentionalLabels: Set<String> = ["繁中", "繁"]

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - 主 app

    func testAppScreensInSimplifiedChinese() throws {
        XCUIDevice.shared.press(.home)
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            // 歷史頁要有區段標題可看（內容是使用者資料，檢查時靠 identifier 排除）。
            "-utuvo.type.ios.seedHistory", "YES",
            // 聽寫頁要有輸出卡（改寫／複製／翻譯按鈕）；種的內容本身用简体。
            "-utuvo.type.ios.previewOutput", "明天下午三点开会",
        ]
        app.launch()
        var seen: [String] = []

        // 聽寫
        let dictateTab = app.tabBars.buttons["听写"]
        XCTAssertTrue(dictateTab.waitForExistence(timeout: 8), "分頁「听写」不在：app 沒切到简中？\n\(app.debugDescription)")
        sleep(2)
        seen += collect(app, screen: "dictate")
        shot("zh-Hans-01-dictate")
        app.swipeUp()
        sleep(1)
        seen += collect(app, screen: "dictate-scrolled")
        shot("zh-Hans-02-dictate-output")

        // 歷史
        app.tabBars.buttons["历史"].tap()
        sleep(2)
        seen += collect(app, screen: "history")
        shot("zh-Hans-03-history")
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        if search.waitForExistence(timeout: 3) {
            search.tap()
            // 送出收掉鍵盤再收字：跳出來的可能是 UTUVO Type 鍵盤，它跟系統語言走（這裡是繁中），
            // 不屬於這條測試的檢查範圍（鍵盤另有 testKeyboardInSimplifiedChinese）。
            search.typeText("xyz\n")
            sleep(1)
            seen += collect(app, screen: "history-search")
            shot("zh-Hans-04-history-search")
        } else {
            XCTFail("歷史頁找不到搜尋欄")
        }
        // 搜尋狀態下鍵盤蓋住分頁列（iOS 26 的取消鈕是沒有文字的 ✕）：重開 app 最乾淨。
        app.terminate()
        app.launch()

        // 設定（Form 是 lazy 的：往下捲、每一段都收）
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8))
        settingsTab.tap()
        sleep(2)
        seen += collect(app, screen: "settings")
        shot("zh-Hans-05-settings")
        for page in 1...4 {
            app.swipeUp()
            sleep(1)
            seen += collect(app, screen: "settings-\(page)")
            shot("zh-Hans-0\(5 + page)-settings-\(page)")
        }

        // 鍵盤翻譯語言
        for _ in 0..<5 { app.swipeDown() }
        let languages = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '键盘翻译语言'")).firstMatch
        XCTAssertTrue(languages.waitForExistence(timeout: 5), "設定頁找不到「键盘翻译语言」")
        languages.tap()
        sleep(2)
        seen += collect(app, screen: "translation-languages")
        shot("zh-Hans-10-translation-languages")
        app.swipeUp()
        sleep(1)
        seen += collect(app, screen: "translation-languages-scrolled")
        shot("zh-Hans-11-translation-languages-scrolled")

        // 反面把關：真的有收到简中字串，不是空集合的假綠。
        XCTAssertGreaterThan(Set(seen).count, 40, "收到的標籤太少，檢查可能沒在看畫面")
        for expected in ["设置", "个人词典", "识别与隐私", "搜索历史", "英语"] {
            XCTAssertTrue(seen.contains { $0.contains(expected) }, "简中介面應該看得到「\(expected)」")
        }
        print("ZH-HANS LABELS (\(Set(seen).count)):\n" + Set(seen).sorted().joined(separator: "\n"))
    }

    // MARK: - 鍵盤（系統語言要先切成简中）

    func testKeyboardInSimplifiedChinese() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UTUVO_L10N_KEYBOARD"] == "1",
                          "鍵盤跟系統語言走：模擬器系統語言切成简中後，帶 TEST_RUNNER_UTUVO_L10N_KEYBOARD=1 才跑")
        let app = XCUIApplication()
        // 剛重裝後鍵盤的無障礙樹常接不到 app 上（同 KeyboardOrbUITests.test0WarmUpKeyboard）：
        // 第一次叫出鍵盤當暖機，接不上就重開 app 再來一次。
        var switched = false
        for _ in 0..<2 where !switched {
            app.launch()
            let settingsTab = app.tabBars.buttons["设置"]
            XCTAssertTrue(settingsTab.waitForExistence(timeout: 8), "系統語言不是简中（分頁不是「设置」）")
            settingsTab.tap()
            let field = app.textFields["dictionaryTerm"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            revealDictionaryField(app)
            field.tap()
            switched = switchToUTUVOKeyboard(app)
            if !switched { app.terminate() }
        }
        XCTAssertTrue(switched, "切不到 UTUVO Type 鍵盤")
        sleep(2)

        var seen: [String] = []
        XCTAssertTrue(app.staticTexts["点一下开始说"].waitForExistence(timeout: 3), "鍵盤提示沒翻成简中")
        XCTAssertTrue(app.buttons["繁中"].exists, "語言徽章「繁中」兩種介面都不翻")
        seen += collect(app, screen: "keyboard-voice")
        shot("zh-Hans-kb-01-voice")

        app.buttons["英文键盘"].tap()
        sleep(1)
        seen += collect(app, screen: "keyboard-english")
        shot("zh-Hans-kb-02-english")

        // 打字區右上循環鍵：EN → 繁（注音）→ 简（拼音）。
        XCTAssertTrue(app.buttons["语音"].exists, "打字區左上回語音鍵沒翻成简中")
        app.buttons["切换键盘布局"].tap()
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "注音版面沒出來")
        XCTAssertTrue(app.buttons["空格"].exists, "注音版面的空白鍵在简中介面應該叫「空格」")
        seen += collect(app, screen: "keyboard-zhuyin")
        shot("zh-Hans-kb-03-zhuyin")

        app.buttons["切换键盘布局"].tap()
        XCTAssertTrue(app.buttons["分隔音节"].waitForExistence(timeout: 2), "拼音版面沒出來")
        seen += collect(app, screen: "keyboard-pinyin")
        shot("zh-Hans-kb-04-pinyin")

        print("ZH-HANS KEYBOARD LABELS:\n" + Set(seen).sorted().joined(separator: "\n"))
    }

    // MARK: - 工具

    /// 收畫面上所有標籤＋placeholder，同時檢查有沒有繁體字；回傳收到的標籤。
    /// 使用者內容（歷史紀錄文字、輸入框的值）不算介面文案，不檢查。
    private func collect(_ app: XCUIApplication, screen: String) -> [String] {
        guard let root = try? app.snapshot() else {
            XCTFail("\(screen)：拿不到畫面快照")
            return []
        }
        var userContent: [String] = []
        var labels: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier == "historyRecordText" {
                if !node.label.isEmpty { userContent.append(node.label) }
                return
            }
            if !node.label.isEmpty { labels.append(node.label) }
            if let placeholder = node.placeholderValue, !placeholder.isEmpty { labels.append(placeholder) }
            node.children.forEach(walk)
        }
        walk(root)
        let checked = labels.filter { label in
            !Self.intentionalLabels.contains(label) && !userContent.contains { label.contains($0) }
        }
        let leaks = checked.filter { $0.contains(where: Self.traditionalOnly.contains) }
        XCTAssertTrue(leaks.isEmpty, "\(screen)：简中介面還有繁體字：\n" + Set(leaks).sorted().joined(separator: "\n"))
        return checked
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

    /// 同 KeyboardOrbUITests 的做法，標籤換成简中系統下的名字。
    private func switchToUTUVOKeyboard(_ app: XCUIApplication) -> Bool {
        let badge = app.buttons.matching(NSPredicate(format: "label IN {'英文键盘', '繁中'}")).firstMatch
        if badge.waitForExistence(timeout: 4) { return true }
        let globe = app.buttons.matching(NSPredicate(format: "label IN {'Next keyboard', '下一个键盘', '下一個鍵盤'}")).firstMatch
        guard globe.waitForExistence(timeout: 3) else { print("NO GLOBE:\n\(app.debugDescription)"); return false }
        globe.press(forDuration: 1.2)
        let pick = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'UTUVO Type'")).firstMatch
        guard pick.waitForExistence(timeout: 4) else { print("KEYBOARD MENU:\n\(app.debugDescription)"); return false }
        pick.tap()
        if badge.waitForExistence(timeout: 8) { return true }
        for _ in 0..<2 {
            let field = app.textFields.firstMatch
            app.navigationBars.firstMatch.tap()
            sleep(1)
            revealDictionaryField(app)
            field.tap()
            if badge.waitForExistence(timeout: 8) { return true }
        }
        shot("zh-Hans-switch-failed")
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
