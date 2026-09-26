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
        let field = revealDictionaryField(app)
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
            let field = revealDictionaryField(app)
            XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
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
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
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
        // 2026-09-20：按鍵改成「按下就出字」之後，滑動切換的手勢絕對不能留下誤打的字。
        let beforeSwipe = field.value as? String
        swipeLeft(from: "ㄤ")
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "左滑沒到简（拼音）")
        XCTAssertEqual(field.value as? String, beforeSwipe, "滑動切換不該打進任何字（按下就出字要能收回）")
        shot("typing-pinyin")
        swipeLeft(from: "l")
        let backToVoice = app.buttons["繁中"].waitForExistence(timeout: 2)
        shot("after-swipe")
        XCTAssertTrue(backToVoice, "左滑沒回到語音")
        XCTAssertEqual(field.value as? String, beforeSwipe, "第二次滑動也不該留字")
    }

    /// 拼音：简 打 nihao 選「你好」；繁切拼音打 taibei 選臺北／台北、nihao 按空白送出繁體；再切回注音。
    func testPinyinModes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
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
        // 定稿延遲 15 秒：滿載的模擬器上「點輸入框 → 讀值」量過要 9 秒，3 秒會在讀到「講話中」之前就定稿（2026-09-25 假紅）。
        app.launchArguments = ["-utuvo.type.keyboard.debugPose", "flow:15"]
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        // 姿態在鍵盤出現 0.3 秒後開始；切鍵盤本身要一點時間，所以重新叫一次鍵盤讓時序從頭來。
        app.terminate()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(app.buttons["繁中"].waitForExistence(timeout: 5))
        sleep(1)
        shot("flow-partial")
        let placeholder = field.placeholderValue ?? ""
        let during = (field.value as? String) ?? ""
        XCTAssertTrue(during.isEmpty || during == placeholder, "講話中不該把逐字稿插進輸入框，卻有「\(during)」")
        let finalized = NSPredicate { _, _ in ((field.value as? String) ?? "").hasPrefix("記得帶耳機和硬碟") }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finalized, object: nil)], timeout: 25)
        sleep(1)   // 定稿後若重複插入，會在這一秒內出現
        shot("flow-final")
        let after = (field.value as? String) ?? ""
        XCTAssertTrue(after.hasPrefix("記得帶耳機和硬碟"), "定稿要進輸入框：「\(after)」")
        XCTAssertEqual(after.components(separatedBy: "記得帶耳機和硬碟").count - 1, 1, "定稿只能插一次：「\(after)」")
        XCTAssertTrue(app.staticTexts["UTUVO Type"].exists, "定稿後左上品牌（Logo＋字標）要回來")
    }

    /// R1-1：講完在「整理中…」（主 app 的定稿還沒回來）又按光球，上一句要先貼上，不能整句消失。
    func testTapWhileFinishingKeepsPreviousSentence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-utuvo.type.keyboard.debugPose", "finishing"]
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        // 姿態在鍵盤出現 0.3 秒後才擺；切鍵盤本身要時間，重新叫一次鍵盤讓姿態從頭來（同 testDictationInsertsOnlyOnFinal）。
        app.terminate()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(app.buttons["繁中"].waitForExistence(timeout: 5))
        let finishing = app.staticTexts["整理中…"]
        XCTAssertTrue(finishing.waitForExistence(timeout: 10), "姿態沒進到「整理中…」")
        let placeholder = field.placeholderValue ?? ""
        let before = (field.value as? String) ?? ""
        XCTAssertTrue(before.isEmpty || before == placeholder, "還沒按光球就有文字：「\(before)」")
        shot("finishing-before-tap")
        let orb = app.descendants(matching: .any)["utuvoKeyboardOrb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 5), "找不到光球")
        orb.tap()
        // 按下去後鍵盤開始下一段：模擬器上沒有活著的語音工作階段，會用 URL 叫起主 app，主 app 切到「聽寫」分頁。
        // 上一句是在那之前同步貼進輸入框的；切回「設定」再讀（TabView 保留分頁狀態）。
        sleep(3)
        // 主 app 開始錄音時系統可能問麥克風／語音辨識權限（隔離模擬器已先 simctl privacy grant；這裡是保險）。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "允許", "允许", "OK", "好"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            sleep(1)
        }
        shot("finishing-after-tap")
        // 主 app 會蓋上「鍵盤正在聽」全螢幕畫面：按「結束鍵盤語音」關掉它（也結束這段模擬器錄音）。
        let endVoice = app.buttons["結束鍵盤語音"]
        if endVoice.waitForExistence(timeout: 3) { endVoice.tap(); sleep(1) }
        if !field.exists {
            app.tabBars.buttons["設定"].tap()
            revealDictionaryField(app)
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "回不到字典欄")
        let after = (field.value as? String) ?? ""
        XCTAssertEqual(after.components(separatedBy: "上一句要留下").count - 1, 1, "上一句要貼上而且只貼一次：「\(after)」")
    }

    /// 個人字典兩種用法：預設「新增詞彙」只有一格；切「替換」多一格「改成」。
    func testDictionaryModes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let term = revealDictionaryField(app)
        XCTAssertTrue(term.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        XCTAssertFalse(app.textFields["dictionaryOutput"].exists, "新增詞彙模式不該有「改成」欄")
        shot("dictionary-vocabulary")
        app.buttons["替換"].tap()
        XCTAssertTrue(app.textFields["dictionaryOutput"].waitForExistence(timeout: 2), "替換模式要有「改成」欄")
        shot("dictionary-replacement")
    }

    // MARK: - TYPE-MT01 host marked-text 回歸：1 char 收回、退到空 preedit 沒有 ghost、快速輸入收回

    /// 空 preedit 收回後不能留 ghost：從乾淨狀態做一次 press-then-drag，預期宿主完全沒多字。
    /// 修 Apple UITextDocumentProxy 行為：`unmarkText` 只清 mark 狀態、不刪字；只有當 ime preedit
    /// 退到空且我們擁有 mark 時，要走 setMarkedText("", range 0) + unmark 才會清乾淨。
    /// **oracle**：partial 拼音字母的 preedit 字串跟詞庫綁死（測試機可能產「嗯」不是「你」），只看
    /// 「empty 開始 → drag 收回後還是 empty」這個 lifecycle 才是穩定的；具體字元放進 MT02 驗。
    func testMT01PinyinEmptyCompositionSlideCancelNoGhost() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2))
        // baseline：宿主是 placeholder（=empty），ime 是空
        let baseline = text(in: field)
        XCTAssertTrue(baseline.isEmpty,
                      "基線必須是空（用 text(in:) 已過濾 placeholder）：「\(baseline)」")

        // 從 n 鍵 press-then-drag：onDown 先餵 n（ime.preedit 有值 + 宿主 marked），
        // onUndo 把 n 收回（ime 空 + 宿主清掉 mark）。最後宿主必須仍然是空。
        let n = app.buttons["n"]
        let start = n.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 30, dy: 30)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)

        let afterCancel = text(in: field)
        XCTAssertEqual(afterCancel, baseline,
                      "1 字母收回後宿主必須等於 baseline（不能留 ghost 半字）：「\(afterCancel)」vs「\(baseline)」")
    }

    /// 拼音打 1 個字母後退到空 preedit 不能留 ghost，再打要能重新建立 marked preedit。
    /// **oracle**：partial 拼音字母的 preedit 字串跟詞庫綁死（測試機可能產「嗯」不是「你」）；
    /// 用「可見字串 ≠ placeholder」斷 preedit 真的有顯示，不綁死具體字元。
    /// 注意：UITextField 空字時 XCUITest 的 `value` 會回 placeholder（「要加入的詞」之類），
    /// `text(in:)` helper 會把 placeholder 視為 empty。
    func testMT02PinyinBackspaceToEmptyClearsHost() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2))
        app.buttons["n"].tap()
        sleep(1)

        // 不綁死 partial preedit 具體字元，只要「不是 placeholder（=有實際 marked text）」
        let withPreedit = text(in: field)
        XCTAssertFalse(withPreedit.isEmpty,
                      "打 n 之後宿主要有 visible preedit（marked text 非空）：「\(withPreedit)」")

        // 進 ime 組字模式：delete 走 typingDelete 的 ime.backspace 路徑，不動 doc selection。
        let delete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'delete'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 2), "找不到 delete 鍵")
        delete.tap()
        sleep(1)

        let afterBackspace = text(in: field)
        XCTAssertTrue(afterBackspace.isEmpty,
                      "拼音退到空 preedit 後宿主必須清空，不能留 ghost：" +
                      "「\(afterBackspace)」")

        // 再打一個字母：要能重新建立 marked preedit（證明 host 沒被我們誤刪 selection）
        app.buttons["h"].tap()
        sleep(1)
        let afterRetype = text(in: field)
        XCTAssertFalse(afterRetype.isEmpty,
                      "重新打字母後宿主必須有 marked preedit，不能空白：「\(afterRetype)」")
    }

    /// 拼音快速打 nihao 後立刻收回：marked text 必須完整還原，且 IME 狀態跟收前一樣能再送出。
    /// 注意：press-then-drag 會先做 onDown（把 o 加進 ime）再做 onUndo（收回）；ime 在收回後回到
    /// 完整 5 bytes（nihao），不是 4 bytes。所以不要在收回後再打 o——那會多加一個 o。
    /// 這條同時驗證：owned mark 旗標正確釋放／重新建立、host cursor 沒被誤刪、收回後送出仍正確。
    /// nihao 完整拼音 walk 在 bundled 詞庫上確定會產「你好」——這條 oracle 對具體字串穩。
    func testMT03PinyinRapidTypeSlideCancelRestores() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2))
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }
        sleep(1)
        let beforeCancel = text(in: field)
        XCTAssertTrue(beforeCancel.contains("你好"),
                      "打完 nihao 必須有 marked preedit「你好」：" +
                      "「\(beforeCancel)」")

        // 把 o 鍵快速滑出：press 已先打進 o，drag > 20pt 觸發 onUndo 把 o 收回，ime 回到 nihao 5 bytes。
        let o = app.buttons["o"]
        let start = o.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 30, dy: 30)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)

        let afterCancel = text(in: field)
        // 收回後 ime 還是 nihao（5 bytes），marked text 必須還存在且 =「你好」。
        XCTAssertEqual(afterCancel, "你好",
                      "收回 o 後宿主必須仍有 marked preedit「你好」（ime 已 undo 剛剛 press 加的 o）：「\(afterCancel)」")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '好'")).firstMatch.exists,
                      "收回後候選列還要有「好」這類前綴候選")

        // 不再額外打 o（ime 已經是 nihao）：直接 tap space 送出
        app.buttons["空格"].tap()
        XCTAssertEqual(text(in: field), "你好",
                       "收回→送出：宿主必須收到「你好」：" +
                       "「\(text(in: field))」")
    }

    /// 跨欄位組字 isolation：設定「替換」模式有兩個輸入欄（source → output）。先在 source 邊組
    /// 拼音邊留 marked preedit，切到 output 欄打新拼音——output 必須只有新組字、不該把 source
    /// 的 stale preedit 寫進來；source 也必須保留原 preedit 不被新組字覆蓋。
    /// Unsaved replacement fields keep independent composition buffers across focus changes.
    func testMT04TwoFieldImeIsolation() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        revealDictionaryField(app)
        app.buttons["替換"].tap()
        let source = app.textFields["dictionaryTerm"]
        let output = app.textFields["dictionaryOutput"]
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        source.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app))
        app.buttons["拼音鍵盤"].tap()
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }
        XCTAssertEqual(source.value as? String, "你好")

        output.tap()
        XCTAssertFalse((output.value as? String ?? "").contains("你好"))
        if !app.buttons["分隔音節"].exists { app.buttons["拼音鍵盤"].tap() }
        for key in ["n", "i"] { app.buttons[key].tap() }
        XCTAssertEqual(output.value as? String, "你")
        XCTAssertEqual(source.value as? String, "你好")
        source.tap()
        XCTAssertEqual(source.value as? String, "你好")
        XCTAssertEqual(output.value as? String, "你")
    }

    /// Host feedback and capitalization remain correct across punctuation layers.
    func testMT05EnglishImmediateHostAndCapitalization() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["英文鍵盤"].tap()
        // 空欄位起手 → 自動大寫：H 鍵是 shift-state 變化（once→onDown 進 .once 之外的 setter 路徑）
        app.buttons["h"].tap()
        XCTAssertEqual(text(in: field), "H",
                       "空欄位起手要自動大寫（與 testR01EnglishLongPressDeleteCommits 一致）")
        app.buttons["i"].tap()
        XCTAssertEqual(text(in: field), "Hi", "第二字起小寫（句中）")

        // 切到標點層，打「.」+ 空白 → 下一字應該自動大寫
        app.buttons["123"].tap()
        app.buttons["."].tap()
        XCTAssertEqual(text(in: field), "Hi.",
                       "EN 句號 . 要即時進宿主")
        app.buttons["space"].tap()
        XCTAssertEqual(text(in: field), "Hi. ",
                       "EN 空白要即時進宿主")

        // 句號 + 空白後下一字自動大寫：這條是 setShift 從 .off → .once 的合法變化，
        // guard 不能把它守死
        app.buttons["ABC"].tap()
        app.buttons["h"].tap()
        XCTAssertEqual(text(in: field), "Hi. H",
                       "句號 + 空白後要自動大寫（setShift guard 不能守死合法變化）")

        // 反例：逗號後維持小寫（不要為了 oracle 把產品行為改壞）
        app.buttons["i"].tap()
        XCTAssertEqual(text(in: field), "Hi. Hi",
                       "句中字母繼續小寫")

        app.buttons["123"].tap()
        app.buttons[","].tap()
        XCTAssertEqual(text(in: field), "Hi. Hi,",
                       "逗號即時進宿主")
        app.buttons["space"].tap()
        XCTAssertEqual(text(in: field), "Hi. Hi, ",
                       "逗號後空白即時進宿主")

        // 逗號後下一字小寫（comma 不是句末標點）
        app.buttons["ABC"].tap()
        app.buttons["h"].tap()
        XCTAssertEqual(text(in: field), "Hi. Hi, h",
                       "逗號 + 空白後不該自動大寫（產品行為，不是 setShift 該守死合法變化的鍋）")
    }

    /// 英文長按 delete 鬆手不反彈：修 TypingKeyboardView.touchesEnded「長按完放開誤觸 onUndo」回歸。
    /// **oracle**：0.6s 長按 → onDown + holdTimer@0.45 + 1 repeat@0.54 = K=2。
    /// doc 從 "Hello world test"（16 字）變 NEW="Hello world te"（14 字）；OLD 路徑會把 lastDeleted="s"
    /// 反彈回 doc 尾部 → "Hello world tes"（15 字）。兩個字串長度差 1、末字元不同（'e' vs 's'），
    /// 舊版長度不對就 fail，不是只驗「字串非空」。
    func testR01EnglishLongPressDeleteCommits() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["英文鍵盤"].tap()
        // 16 字確保 K=2 後還有 14 字留存、lastDeleted 一定有值（不會因為 doc 空而 nil）。
        for key in ["h", "e", "l", "l", "o", "space", "w", "o", "r", "l", "d", "space", "t", "e", "s", "t"] {
            app.buttons[key].tap()
        }
        XCTAssertEqual(field.value as? String, "Hello world test", "EN 鍵盤打字預備")

        let delete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'delete'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 2), "找不到 delete 鍵")
        delete.press(forDuration: 0.6)
        sleep(1)
        let after = (field.value as? String) ?? ""
        XCTAssertEqual(after, "Hello world te",
                       "長按 0.6s delete 應停在 K=2 NEW（14 字）；OLD 會把 lastDeleted=\"s\" 反彈成「Hello world tes」（15 字、尾 's'）")
    }

    /// 拼音 nihao 從空白向上拖動取消：組字狀態＋宿主 marked text 都要還原；正常空白要再完整送出「你好」。
    /// 修 KeyboardViewController.typingUndoSpace「拼音空白送出後 undo 只刪一字」回歸。
    /// **2026-09-20 host-marked-text 之後**：取消後 doc 會回到 marked preedit（不是空字）；
    /// UITextField 的 `value` 包含 marked text，所以這裡改驗「你好」會回來（marked，不是實字）。
    func testR01PinyinSpaceDragUpCancel() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "简（拼音）版面沒出來")
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }
        XCTAssertTrue(app.buttons["你好"].waitForExistence(timeout: 2), "拼音 nihao 候選列沒有「你好」")

        // 從「空格」向上拖：縱向 > 20pt 觸發取消、橫向位移 0 不會切模式（橫滑門檻 70pt）。
        let space = app.buttons["空格"]
        let start = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)

        // 取消後 marked text 必須回到「你好」（使用者打開的組字），不能留 ghost 半字也不能消失。
        XCTAssertEqual(field.value as? String, "你好",
                       "拼音空白上滑取消：宿主 marked text 必須還原成「你好」，不是空字")
        XCTAssertTrue(app.buttons["你好"].waitForExistence(timeout: 2),
                      "ime 應還原到 nihao 組字狀態（候選列還看得到「你好」）")

        // 再正常按一次空白：這次要送出完整組字。
        app.buttons["空格"].tap()
        XCTAssertEqual(field.value as? String, "你好", "還原後正常空白要送出完整「你好」")
    }

    /// 橫向滑動切模式遵守 setSurface 的「送出原組字」語意：組字中橫滑不能留下半詞。
    /// 驗收：拼音輸入「nihao」後從右側按鍵起手橫滑到語音，doc 必須是完整「你好」。
    func testR01PinyinHorizontalSlideCommits() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "简（拼音）版面沒出來")
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }
        XCTAssertTrue(app.buttons["你好"].waitForExistence(timeout: 2), "拼音 nihao 候選列沒有「你好」")

        // 從「p」起手往左拖 240pt：橫向位移遠超過 70pt 門檻、縱向 0，觸發切模式。
        // p 鍵的 onDown 會先餵一個 p，touchesMoved > 20pt 觸發 onUndo 收回 p；橫滑完成後
        // setSurface 會 commitComposition 把 nihao 送出。
        let start = app.buttons["p"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["繁中"].waitForExistence(timeout: 3), "橫滑該回到語音")
        XCTAssertEqual(field.value as? String, "你好",
                       "橫滑切模式要走 setSurface 的 commitComposition，不留半詞")
    }

    /// 拼音「你」前綴選字後空白拖取消：剩「hao」必須還原成 preedit「好」、正常空白送出「你好」。
    /// 修 TYPE-R01-repair #5：snapshot/restore 對 select(prefix) 後留下來的「hao」要正確處理，
    /// 否則取消會丟掉這段半成品組字。
    func testR01PinyinPrefixPickThenCancelRestores() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["拼音鍵盤"].tap()
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "简（拼音）版面沒出來")
        for key in ["n", "i", "h", "a", "o"] { app.buttons[key].tap() }

        // 候選列必須有「你」這個前綴（消耗 "ni" 兩 byte，剩 "hao" = "好"）
        let niCandidate = app.buttons["你"]
        XCTAssertTrue(niCandidate.waitForExistence(timeout: 2), "拼音 nihao 候選列沒有「你」前綴")
        niCandidate.tap()
        XCTAssertEqual(field.value as? String, "你好", "已選「你」＋剩餘組字「好」須同時顯示")

        // 此時 ime 還有 raw=[h,a,o]，preedit 應是「好」、候選列應看得到「好」。
        XCTAssertTrue(app.buttons["好"].waitForExistence(timeout: 2),
                      "選字後 ime 還有「hao」組字，候選列必須還看得到「好」")

        // 從「空格」向上拖取消：必須還原 ime、不動 doc
        let space = app.buttons["空格"]
        let start = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)

        XCTAssertEqual(field.value as? String, "你好",
                       "取消空白須還原已選「你」＋組字「好」，不能重複或少字")
        XCTAssertTrue(app.buttons["好"].waitForExistence(timeout: 2),
                      "ime 必須還原到「hao」組字狀態（候選列還看得到「好」）")

        // 正常空白：送出完整「你好」
        app.buttons["空格"].tap()
        XCTAssertEqual(field.value as? String, "你好",
                       "還原後正常空白要送出「你好」")
    }

    /// 注音「ㄋㄧˇ」已完成音節＋正在組「ㄏㄠ」時空白拖取消：readings 與 composing 必須完整還原。
    /// 修 TYPE-R01-repair #5：snapshot/restore 對 zhuyin 已完成 reading + 正在 composing 雙段狀態的處理。
    /// **2026-09-20 host-marked-text**：取消後宿主端 marked text 應是還原後的 preedit（walk(readings)
    /// + composing）＝「你」＋「ㄏㄠ」，不能變成空字也不能留 ghost 半字。
    func testR01ZhuyinComposingSpaceDragCancel() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")

        app.buttons["注音鍵盤"].tap()
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "注音版面沒出來")

        // 打 ㄋㄧˇ（你）—— 完成一個音節，readings=["ㄋㄧˇ"]
        for key in ["ㄋ", "ㄧ", "ˇ"] { app.buttons[key].tap() }
        XCTAssertTrue(app.buttons["你"].waitForExistence(timeout: 2),
                      "注音 ㄋㄧˇ 候選列沒有「你」")

        // 再打 ㄏㄠ—— 部分組字，composing="ㄏㄠ"
        app.buttons["ㄏ"].tap()
        app.buttons["ㄠ"].tap()
        sleep(1)

        // 此時 ime: readings=["ㄋㄧˇ"], composing="ㄏㄠ"
        // 從「空白」向上拖取消：必須還原 ime + 宿主 marked text 也還原
        let space = app.buttons["空白"]
        let start = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)

        // 取消後 marked text ＝ walk(["ㄋㄧˇ"]) + "ㄏㄠ" ＝ "你" + "ㄏㄠ" = "你ㄏㄠ"
        // （不能是空字也不能留下 ghost 字）
        XCTAssertEqual(field.value as? String, "你ㄏㄠ",
                       "注音 composing 空白拖取消：宿主 marked text 必須還原成「你ㄏㄠ」，不能空也不能多字")
        // readings 還原：「你」必須還在候選列
        XCTAssertTrue(app.buttons["你"].waitForExistence(timeout: 2),
                      "ime readings 必須還原（候選列還看得到「你」）")
    }

    private func text(in field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
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
        let globe = app.buttons.matching(NSPredicate(format: "label IN {'Next keyboard', '下一個鍵盤', '下一个键盘'}")).firstMatch
        guard globe.waitForExistence(timeout: 3) else { print("KEYBOARD AX:", app.debugDescription); return false }
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
    /// 把字典欄捲到看得見的位置。SwiftUI 的 Form 是懶載入：離畫面太遠的列**根本不在無障礙樹裡**，
    /// 所以不能先 waitForExistence 再捲，要一邊捲一邊看（2026-09-20 設定頁多兩列就踩到）。
    @discardableResult
    private func revealDictionaryField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["dictionaryTerm"]
        let tabBar = app.tabBars.firstMatch
        func ready() -> Bool {
            guard field.exists, field.isHittable else { return false }
            guard tabBar.exists else { return true }
            return field.frame.maxY < tabBar.frame.minY - 8 && field.frame.minY > 0
        }
        for _ in 0..<6 {
            if ready() { return field }
            app.swipeUp()
            sleep(1) // 等慣性捲動停下來：還在滑就點，會點到下面的 API key 密碼欄（系統鍵盤）
        }
        return field
    }


}
