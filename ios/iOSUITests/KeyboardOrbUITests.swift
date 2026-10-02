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
        let term = revealDictionaryModePicker(app)
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
        revealDictionaryModePicker(app)
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
        XCTAssertEqual(settledText(in: field, expecting: "H"), "H",
                       "空欄位起手要自動大寫（與 testR01EnglishLongPressDeleteCommits 一致）")
        app.buttons["i"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi"), "Hi", "第二字起小寫（句中）")

        // 切到標點層，打「.」+ 空白 → 下一字應該自動大寫
        app.buttons["123"].tap()
        app.buttons["."].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi."), "Hi.",
                       "EN 句號 . 要即時進宿主")
        app.buttons["space"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi. "), "Hi. ",
                       "EN 空白要即時進宿主")

        // 句號 + 空白後下一字自動大寫：這條是 setShift 從 .off → .once 的合法變化，
        // guard 不能把它守死
        app.buttons["ABC"].tap()
        app.buttons["h"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi. H"), "Hi. H",
                       "句號 + 空白後要自動大寫（setShift guard 不能守死合法變化）")

        // 反例：逗號後維持小寫（不要為了 oracle 把產品行為改壞）
        app.buttons["i"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi. Hi"), "Hi. Hi",
                       "句中字母繼續小寫")

        app.buttons["123"].tap()
        app.buttons[","].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi. Hi,"), "Hi. Hi,",
                       "逗號即時進宿主")
        app.buttons["space"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi. Hi, "), "Hi. Hi, ",
                       "逗號後空白即時進宿主")

        // 逗號後下一字小寫（comma 不是句末標點）
        app.buttons["ABC"].tap()
        app.buttons["h"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "Hi. Hi, h"), "Hi. Hi, h",
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

    /// 09-29 Micky：紫色光球（說出要怎麼改）每次都「失敗」。iOS 27.0 的 Apple Intelligence 生成全被系統安全模型擋掉；
    /// 模擬器同樣會擋、又沒有雲端 key → 鍵盤要講出原因與補救方法，不能是「無法完成作業」。
    func testEditModeExplainsFailureInsteadOfGenericError() throws {
        let app = XCUIApplication()
        // 當作沒有 Apple Intelligence：09-30 起它在 27.0 又能用了，這條測的是「沒有它、也沒 key」的說明。
        app.launchArguments = ["-utuvo.type.keyboard.debugPose", "edit:改成正式一點", "-utuvo.type.debug.noOnDeviceAI", "YES"]
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        app.terminate()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // 只找鍵盤提示的那句補救方法：只比「智慧整理」會先抓到後面設定頁的「智慧整理（選配）」標題（09-30 假紅）。
        let explained = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '智慧整理加'")).firstMatch
        let ok = explained.waitForExistence(timeout: 30)
        shot("edit-mode-message")
        XCTAssertTrue(ok, "改寫失敗時要告訴使用者去智慧整理加 key：\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '無法完成作業'")).firstMatch.exists,
                       "不能再顯示空泛的系統錯誤")
        XCTAssertTrue(explained.label.contains("Groq key"), "補救方法要完整顯示（不能被截掉）：\(explained.label)")
    }

    /// 09-29 Micky：拼音「除了列出來的候選字，無法往下繼續選字」。候選列要能左右捲，
    /// 右端「⌄」要能展開整頁候選（最多 60 個），點了就選、面板收起。用他截圖的情境：繁體拼音打 suoyi。
    func testCandidateBarScrollsAndExpands() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        app.buttons["注音鍵盤"].tap()
        if !app.buttons["改用注音"].waitForExistence(timeout: 1) { app.buttons["改用拼音"].tap() }
        XCTAssertTrue(app.buttons["分隔音節"].waitForExistence(timeout: 2), "繁體拼音版面沒出來")
        for key in ["s", "u", "o", "y", "i"] { app.buttons[key].tap() }
        XCTAssertTrue(app.buttons["所以"].waitForExistence(timeout: 2), "suoyi 沒有候選")

        // ①候選列左右捲：往左滑，前面的候選要真的移走（量位置，不靠猜哪個字排第幾）
        let second = app.buttons["索引"]
        let before = second.frame.minX
        // 手指慢慢拖（跟真人一樣先按住一下再滑），不是 XCTest 的瞬間 swipe
        let start = second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        shot("bar-after-drag")
        let movedOrGone = !second.exists || !second.isHittable || second.frame.minX < before - 40
        XCTAssertTrue(movedOrGone, "候選列往左滑沒有捲動：「索引」還在 x=\(second.frame.minX)（原本 \(before)）")

        // ②展開整頁：第 35 個候選（速）要在整頁裡找得到，往上捲就點得到
        let more = app.buttons["更多候選字"]
        XCTAssertTrue(more.waitForExistence(timeout: 2), "候選列右端要有「更多候選字」")
        more.tap()
        XCTAssertTrue(app.buttons["收起候選字"].waitForExistence(timeout: 2), "展開後按鈕要變成「收起」")
        let su = app.buttons["速"]
        XCTAssertTrue(su.waitForExistence(timeout: 3), "展開後整頁候選要有「速」")
        let panel = app.scrollViews["candidatePanel"]
        XCTAssertTrue(panel.exists, "找不到整頁候選")
        for _ in 0..<6 where !su.isHittable {
            let p = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            p.press(forDuration: 0.2, thenDragTo: p.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(su.isHittable, "整頁候選往上捲後「速」要點得到")
        shot("pinyin-expanded")
        su.tap()
        let picked = NSPredicate { _, _ in ((field.value as? String) ?? "").hasPrefix("速") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: picked, object: nil)], timeout: 5), .completed,
                       "選了「速」要進輸入框：「\((field.value as? String) ?? "")」")
        XCTAssertFalse(app.buttons["收起候選字"].exists, "選字後整頁候選要收起來")
        XCTAssertTrue(app.buttons["q"].isHittable, "收起後按鍵要點得到")
    }

    /// 09-29 Micky 截圖：右上「繁中」徽章被字幕帶擠窄，折成直排兩行、按鈕變高。
    /// 錄音姿態會放一段長逐字稿進字幕帶，徽章要維持一行、高度跟兩側圓鈕一樣。
    func testLanguageBadgeStaysOnOneLineWithLongTranscript() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-utuvo.type.keyboard.debugPose", "recording"]
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        app.terminate()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let badge = app.buttons["繁中"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "找不到語言徽章")
        sleep(2)   // 姿態 0.3 秒後才放逐字稿
        shot("badge-with-long-transcript")
        let f = badge.frame
        XCTAssertLessThanOrEqual(f.height, 44, "徽章高度 \(f.height) pt：字被擠成兩行")
        XCTAssertGreaterThanOrEqual(f.width, f.height, "徽章寬 \(f.width) < 高 \(f.height)：被擠成直的")
    }

    /// 0.2.5（Threads 回饋「注音好像沒有預測字，要打完整注音」）：邊打邊出候選、簡拼、沒打聲調、聯想詞。
    /// 走產品入口：主 app 字典欄 → UTUVO Type 鍵盤 → 注音版面，候選列點選，看輸入框真的收到字。
    func testZhuyinPredictionAndAssociations() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        app.buttons["注音鍵盤"].tap()
        if app.buttons["改用注音"].waitForExistence(timeout: 1) { app.buttons["改用注音"].tap() }
        XCTAssertTrue(app.buttons["ㄅ"].waitForExistence(timeout: 2), "注音版面沒出來")

        // ①只打一個聲母就有候選：ㄋ → 點「你」
        app.buttons["ㄋ"].tap()
        let ni = app.buttons["你"]
        XCTAssertTrue(ni.waitForExistence(timeout: 2), "只打 ㄋ 候選列就要有「你」")
        shot("zhuyin-partial-n")
        ni.tap()
        XCTAssertEqual(settledText(in: field, expecting: "你"), "你", "點預測的「你」要進輸入框")

        // ②選完接聯想詞：你 → 們（小麥注音聯想詞表第一個）
        let men = app.buttons["們"]
        XCTAssertTrue(men.waitForExistence(timeout: 2), "選字後要出聯想詞「們」")
        shot("zhuyin-association")
        men.tap()
        XCTAssertEqual(settledText(in: field, expecting: "你們"), "你們", "點聯想詞要接在後面")

        // ③簡拼：ㄉㄋ → 候選列有「電腦」，輸入框先顯示打的符號
        app.buttons["ㄉ"].tap()
        app.buttons["ㄋ"].tap()
        let computer = app.buttons["電腦"]
        XCTAssertTrue(computer.waitForExistence(timeout: 2), "簡拼 ㄉㄋ 候選列要有「電腦」")
        XCTAssertEqual(settledText(in: field, expecting: "你們ㄉㄋ"), "你們ㄉㄋ", "組字時輸入框顯示打的注音")
        shot("zhuyin-abbreviation")
        computer.tap()
        XCTAssertEqual(settledText(in: field, expecting: "你們電腦"), "你們電腦")

        // ④不打聲調：ㄋㄧㄏㄠ ＋ 空白 → 整串送出「你好」
        for key in ["ㄋ", "ㄧ", "ㄏ", "ㄠ"] { app.buttons[key].tap() }
        XCTAssertTrue(app.buttons["你好"].waitForExistence(timeout: 2), "ㄋㄧㄏㄠ 候選列第一格要是「你好」")
        app.buttons["空白"].tap()
        XCTAssertEqual(settledText(in: field, expecting: "你們電腦你好"), "你們電腦你好", "沒打聲調按空白＝送出最佳轉換")
        shot("zhuyin-toneless-space")
    }

    /// 0.2.5：英文建議列（UITextChecker 補完／拼字建議），點了換掉正在打的字並補空白；句首大寫照舊。
    func testEnglishSuggestionBar() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["設定"].tap()
        let field = revealDictionaryField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "設定頁找不到字典欄")
        field.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(app), "切不到 UTUVO Type 鍵盤")
        app.buttons["英文鍵盤"].tap()
        for key in ["t", "o", "m", "o", "r"] { app.buttons[key].tap() }
        XCTAssertEqual(settledText(in: field, expecting: "Tomor"), "Tomor", "句首自動大寫照舊")
        let tomorrow = app.buttons["Tomorrow"]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 3), "Tomor 建議列要有「Tomorrow」（照打的大小寫）")
        shot("english-suggestions")
        tomorrow.tap()
        XCTAssertEqual(settledText(in: field, expecting: "Tomorrow "), "Tomorrow ", "點建議換掉整個字並補空白")

        // 拼錯 → 拼字建議
        for key in ["r", "e", "c", "i", "e", "v", "e"] { app.buttons[key].tap() }
        let receive = app.buttons["receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 3), "recieve 要有拼字建議「receive」")
        receive.tap()
        XCTAssertEqual(settledText(in: field, expecting: "Tomorrow receive "), "Tomorrow receive ")
        // 空白之後建議列收起來
        XCTAssertFalse(app.buttons["receive"].exists, "換完字建議列要清掉")
    }

    /// 鍵盤→宿主是非同步的：最多等 5 秒到期望值，再回傳實際值給 XCTAssertEqual 報錯。
    private func settledText(in field: XCUIElement, expecting expected: String) -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if text(in: field) == expected { return expected }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return text(in: field)
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
    /// 0.2.7（09-30 Micky：「在輸入框裡加一個設定，可以跳回 App」）：在別的 app 裡點鍵盤左上品牌區，
    /// 主 app 要被叫起來並停在「設定」分頁。宿主用 Safari 網址列（真實情境：在別人的 app 裡按）。
    func testBrandTapOpensAppSettings() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["聽寫"].tap()          // 先停在別的分頁，才看得出有沒有跳到設定
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let address = safari.textFields.firstMatch
        if !address.waitForExistence(timeout: 8) { safari.buttons["TabBarItemTitle"].firstMatch.tap() }
        let bar = safari.textFields.firstMatch.exists ? safari.textFields.firstMatch : safari.buttons["Address"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "Safari 找不到網址列")
        bar.tap()
        XCTAssertTrue(switchToUTUVOKeyboard(safari), "Safari 裡切不到 UTUVO Type 鍵盤")
        let brand = safari.otherElements["openAppSettings"].exists ? safari.otherElements["openAppSettings"]
                                                                   : safari.descendants(matching: .any)["openAppSettings"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5), "鍵盤左上找不到設定入口")
        shot("brand-settings-entry")
        brand.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "點了之後主 app 沒有到前景")
        XCTAssertTrue(app.tabBars.buttons["設定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["設定"].isSelected, "主 app 沒有停在設定分頁")
        shot("brand-opened-settings")
    }

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

    /// 字典欄上方的「新增詞彙／替換」切換：欄位剛好停在導覽列下緣時，切換被導覽列蓋住，
    /// 點下去會點到狀態列＝整頁捲回頂端（10-02 整套跑時連兩次假紅）。從左側空白邊往下拉一小段，讓切換露出來。
    @discardableResult
    private func revealDictionaryModePicker(_ app: XCUIApplication) -> XCUIElement {
        let field = revealDictionaryField(app)
        let replace = app.buttons["替換"]
        for _ in 0..<3 {
            guard replace.exists, replace.frame.minY < 160 else { break }
            let edge = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.45))
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: 140)))
            sleep(1)
        }
        return field
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
        // 往上捲找；捲過頭（欄位跑到畫面上方、或被懶載入移出樹）就往回捲（09-29 設定頁變長後假紅三次）。
        for i in 0..<10 {
            if ready() { return field }
            if field.exists {
                if field.frame.minY < 120 { app.swipeDown() } else { app.swipeUp() }
            } else if i < 4 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            sleep(1) // 等慣性捲動停下來：還在滑就點，會點到下面的 API key 密碼欄（系統鍵盤）
        }
        return field
    }


}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "exists == true AND hittable == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: self)], timeout: timeout) == .completed
    }
}
