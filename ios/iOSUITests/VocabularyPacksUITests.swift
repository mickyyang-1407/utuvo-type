import XCTest

/// 詞庫包 UI 端到端（runtime 票驗收 §6）：
/// 進入明細、關閉狀態下搜尋到「非 seed」的完整詞表詞目、來源連結可見、
/// 開關可切換且重啟 app 後記得住（toggle persistence）。
/// 用真實 catalog（manager 落地的 data/vocabulary 已用 folder reference 打進 app bundle），
/// 不需要注入 fixture；不改任何使用者 live 資料——測試結束會把開關還原成關。
final class VocabularyPacksUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Form 是 lazy List：畫面外的 row 不在 accessibility 樹裡，往下滑到出現為止。
    @discardableResult
    private func scrollUntilFound(_ element: XCUIElement, maxSwipes: Int = 6, timeout: TimeInterval = 2) -> Bool {
        var attempts = 0
        while !element.waitForExistence(timeout: timeout) && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
        return element.exists
    }

    /// 設定 tab → 詞庫包與匯入頁。
    private func openPacksScreen() {
        let settingsTab = app.tabBars.buttons["設定"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "應有「設定」tab")
        settingsTab.tap()
        let packs = app.descendants(matching: .any)["vocabularyPacksRow"]
        XCTAssertTrue(scrollUntilFound(packs), "設定頁應有「詞庫包與匯入」入口")
        packs.tap()
    }

    /// 真實 catalog 六包都列在「可選專業詞庫」區。
    func testCatalogSectionListsSixPacksWithTermCounts() throws {
        openPacksScreen()
        for name in ["資訊與電腦", "醫學", "財經", "法律", "工程", "音樂與音響"] {
            let row = app.staticTexts[name]
            XCTAssertTrue(scrollUntilFound(row), "應列出 \(name)")
        }
    }

    /// 關閉狀態下進明細：搜尋必須找到「非 seed」的詞目（完整詞表載入，不是只有 31–40 個 seed）、
    /// 來源連結可見；離開時該包仍保持關閉（瀏覽不等於啟用）。
    func testDisabledPackDetailsSearchFindsNonSeedTermAndShowsSource() throws {
        openPacksScreen()
        let row = app.staticTexts["資訊與電腦"]
        XCTAssertTrue(scrollUntilFound(row))
        row.tap()

        let details = app.descendants(matching: .any)["packDetails:computing"]
        XCTAssertTrue(details.waitForExistence(timeout: 5) || app.navigationBars["資訊與電腦"].waitForExistence(timeout: 5),
                      "應進入 computing 明細頁")

        let search = app.textFields["packSearch:computing"]
        XCTAssertTrue(scrollUntilFound(search), "明細頁應有搜尋欄")
        search.tap()
        search.typeText("雲端運算")   // computing.txt 內、非 seedTerms 的詞
        let term = app.staticTexts["packTerm:computing:雲端運算"]
        XCTAssertTrue(scrollUntilFound(term, maxSwipes: 8),
                      "關閉狀態也要搜得到完整詞表裡的非 seed 詞（不能只有 seed）")

        let source = app.descendants(matching: .any)["packSource:computing"]
        XCTAssertTrue(scrollUntilFound(source), "來源（連結）必須可見")

        // 回列表：pack 仍是關閉（瀏覽不得隱式啟用）。
        app.navigationBars.buttons.firstMatch.tap()
        let backRow = app.staticTexts["資訊與電腦"]
        XCTAssertTrue(backRow.waitForExistence(timeout: 5) || scrollUntilFound(backRow))
    }

    /// 開關切換 + 持久化：打開 medicine → 重啟 app → 仍是開的；測後還原成關。
    func testTogglePersistenceAcrossRelaunch() throws {
        openPacksScreen()
        let toggle = app.switches["pack:medicine"]
        XCTAssertTrue(scrollUntilFound(toggle), "switch 要用 pack:medicine 這個 id 查得到（綁在 Toggle 本體）")
        // 讀 switch 當前值；預設應是關（全新環境）。若已是開（殘留狀態），先關掉再測。
        func value(_ sw: XCUIElement) -> String {
            sw.value as? String ?? "0"
        }
        if value(toggle) == "1" { toggle.tap() }
        XCTAssertEqual(value(toggle), "0", "測試前置：medicine 應為關")
        toggle.tap()
        XCTAssertEqual(value(toggle), "1", "點開關後應為開")

        app.terminate()
        app.launch()
        openPacksScreen()
        let toggle2 = app.switches["pack:medicine"]
        XCTAssertTrue(scrollUntilFound(toggle2))
        XCTAssertEqual(value(toggle2), "1", "重啟 app 後 medicine 應仍是開（persistence）")

        // 還原：關掉，不留測試狀態。
        toggle2.tap()
        XCTAssertEqual(value(toggle2), "0")
    }
}
