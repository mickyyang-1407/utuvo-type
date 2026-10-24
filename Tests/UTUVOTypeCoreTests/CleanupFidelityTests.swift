import XCTest
@testable import UTUVOTypeCore

final class CleanupFidelityTests: XCTestCase {
    /// FX-3 第四輪 fx-gate 的 findings 原話（把關測試表的輸入）：GoldenExportTests 會丟進整條 normalize 管線，
    /// 匯出給 Kotlin 逐條比對（本機版第一次貼上的字兩邊要一樣，把關才比得一樣）。
    static let goldenInputs = [
        "三點開會，五點吃飯，更正，六點",
        "三點開會，五點吃飯，不對，吃飯是六點",
        "三點開會，五點吃飯，不對，六點",
        "明天三點開會，後天五點吃飯，不對，六點",
        "三點開會，五點吃飯，講錯了，六點",
        "三點開會，五點吃飯，不對，開會是四點",
        "請他幫我訂票",
        "跟他說我明天會晚到",
        "告訴她我明天不去",
        "麻煩他幫我改一下",
        "我會叫他明天打電話給我",
        "我拜託他幫我買咖啡",
        "我請他幫我訂明天下午的高鐵票",
        "我明天會把報告寄給他",
        "Tell him to send me the stems",
        "Ask her to call me tomorrow",
        "Remind him to email me the mix",
        "I asked him to call me",
        "I told him to email me the file",
        "You will send me the invoice tomorrow.",
        "我要喝拿鐵不是美式",
        "這次用Pro Tools不是Logic",
        "It's Wednesday, it's not Thursday",
        "It's Wednesday, it isn't Thursday",
        "We meet on Wednesday, we don't meet on Thursday",
        "Use the 48k version, don't use the 96k version",
        "Send it to Alice and not Bob",
        "開會時間是星期三不是星期四",
        "開會不是星期四，而是星期三",
        "要寄的不是母帶而是混音",
        "我們要的是第二版不是第三版",
        "我住三樓，不是四樓",
        "我要的是48K不是96K",
        "萬一不是三點呢",
        "100元，不是200元",
        "The meeting is not on Thursday but on Wednesday",
        "預定的是台北不是台南，台北需要提前預約",
        "開會時間是星期三不是星期四，地點不是台北",
        "響度設在負的十四LUFS",
        "響度設在負的三dB",
        "set it to minus fourteen LUFS",
        "響度設為-14 LUFS",
        "氣溫零下五度",
        "劑量為1.5毫克",
        "預算是100元，訂金是200元",
        "我買了1200元",
        "我想說他應該會打給我",
        "我就想說他會等我",
        "我在想說他是不是忘了我",
        "I told him that she will call me",
        "I told you that he loves me",
        "是三點不是四點",
        "不是星期四而是星期三",
        "呃那個我明天會把報告寄給他",
        "那個他明天會來",
        "他說他明天會來",
        "三點，不對，四點出發",
        "檔名叫做Final V3,啊不對是Final V4",
        "幫我轉寄給小雅跟小柏﹑不是,是小雅跟小潘﹑",
        "我請他幫我訂票",
        "嗯我跟他說我明天會晚到",
        "他明天會把報告寄給我",
        "我們明天三點開會",
        "這次案子分成三個部分，第一個部分是前期的素材整理，主要把客戶給的 martetrack收進來。然後檢查每一軌的完整性另外第二個部分是實際的婚姻，這部分大概會花三天重點在於人生的空間感，總之交付的時候記得付一份 mixingnote",
        "這次案子分成三個部分，第一個部分是前期的素材整理，主要把客戶給的 multitrack收進來，然後檢查每一鬼的彎。完整性另外第二個部分是實際的混音這部分大概會花三天，重點在於人生的空間感總之交付的時候記得付一份 Mikesenotes"
    ]

    func testRejectsSynonymAndContentWordLossFromTicket() {
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "然後送到清風教室去示範",
            cleaned: "之後送往清風教室進行示範"
        ))
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "教室改成四樓，另外教材我會帶過去",
            cleaned: "教室四樓，教材我會帶過去"
        ))
    }

    func testAllowsOnlyFillerAndExplicitCorrectionRemoval() {
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "嗯那個就是說我覺得這個這個方案還可以",
            cleaned: "我覺得這個方案還可以"
        ))
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我想明天，不對，後天寄",
            cleaned: "我想後天寄"
        ))
        // FX-3 ④（2026-10-22）：改口要有改口語法（前後停頓、或「不是」後面接「是」）；
        // 沒有停頓的「禮拜三不是禮拜五」是對比（前面那個才對），原本這組期望放行，改成要擋。
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我們約禮拜三，不是，禮拜五下午見",
            cleaned: "我們約禮拜五下午見"
        ))
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "我們約禮拜三不是禮拜五下午見",
            cleaned: "我們約禮拜五下午見"
        ))
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "了解，了解你的意思",
            cleaned: "了解你的意思"
        ), "Meaningful repeated acknowledgements must stay")
    }

    func testChineseNumberCorrectionsStuttersAndFullwidthDigits() {
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我們約三點開會，不對，四點",
            cleaned: "我們約四點開會"
        ), "A spoken number correction may replace the old value while retaining its tail")
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我我想要這個",
            cleaned: "我想要這個"
        ), "The duplicated pronoun in a stutter may be removed: \(String(describing: CleanupFidelity.rejectionReason(original: "我我想要這個", cleaned: "我想要這個")))")
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "測試１",
            cleaned: "測試"
        ), "Fullwidth digits must be treated the same as ASCII digits")
    }

    func testContextualFillersMayBeKeptRemovedOrAdded() {
        let opening = "嗯,我覺得那個,就是,這個 low-end 還可以再收一點。"
        XCTAssertTrue(CleanupFidelity.preservesContent(original: opening, cleaned: opening))
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: opening,
            cleaned: "我覺得這個 low-end 還可以再收一點。"
        ), "Reject reason: \(String(describing: CleanupFidelity.rejectionReason(original: opening, cleaned: "我覺得這個 low-end 還可以再收一點。")))")

        let connector = "嗯嗯,然後就是說,我這邊沒有收到你的檔案。"
        XCTAssertTrue(CleanupFidelity.preservesContent(original: connector, cleaned: connector))
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: connector,
            cleaned: "我這邊沒有收到你的檔案。"
        ))
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我覺得可以",
            cleaned: "嗯嗯，我覺得可以"
        ), "Recognized filler words are optional in model output too")
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我覺得可以",
            cleaned: "我覺得，就是，可以"
        ), "A paused filler may be retained even when it was absent from the source")
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "對對，我覺得可以",
            cleaned: "我覺得可以"
        ), "對對 may be removed")
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "我覺得可以",
            cleaned: "對對，我覺得可以"
        ), "對對 may also be added by the cleanup model")
    }

    func testMeaningfulThenJiuShiAndDemonstrativesMustStay() {
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "做完然後寄給他",
            cleaned: "做完然後寄給他"
        ))
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "做完然後寄給他",
            cleaned: "做完寄給他"
        ), "A connective 然後 inside the sentence is substantive")
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "他就是負責人",
            cleaned: "他負責人"
        ), "A meaningful 就是 must stay")
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "我覺得這個方案可以",
            cleaned: "我覺得方案可以"
        ), "A demonstrative 這個 must stay when it names the plan")
    }

    func testRepeatedThenCanBeKeptCollapsedOrRemovedAtSentenceStart() {
        let original = "然後然後寄給他"
        XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: original))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: "然後寄給他"))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: "寄給他"))

        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "做完然後然後寄給他",
            cleaned: "做完然後寄給他"
        ))
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "做完然後然後寄給他",
            cleaned: "做完寄給他"
        ), "Only the repeated copy is optional in a meaningful mid-sentence connector")
    }

    func testRejectReasonNamesMissingSourceContent() {
        let reason = CleanupFidelity.rejectionReason(
            original: "做完然後寄給他",
            cleaned: "做完寄給他"
        )
        XCTAssertTrue(reason?.contains("然後") == true, "Actual rejection reason: \(String(describing: reason))")
    }

    func testAllowsPunctuationListAndNumberFormattingOnly() {
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "明天下午三點開會，後天下午四點開會",
            cleaned: "1. 明天下午3點開會\n2. 後天下午4點開會。"
        ))
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "一、明天下午三點開會\n二、後天下午四點開會",
            cleaned: "1. 明天下午3點開會\n2. 後天下午4點開會。"
        ))
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "今天下午三點開會",
            cleaned: "今天下午4點開會"
        ), "Number values must remain the same")
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "三個人明天出發",
            cleaned: "明天三個人出發"
        ), "Numbers must stay in their original position")
    }

    func testPromptCandidateV2ProbeOutputsPassTheFidelityGate() {
        let cases: [(String, String)] = [
            ("嗯,我覺得那個,就是,這個low-end還可以再收一點。", "我覺得這個 low-end 還可以再收一點。"),
            ("然後然後,呃,高頻好像有點毛,你再聽一下。", "高頻好像有點毛，你再聽一下。"),
            ("嗯嗯,然後就是說,我這邊沒有收到你的檔案。", "我這邊沒有收到你的檔案。"),
            ("我們約3點開會,不對,4點,地點在3樓", "我們約4點開會，地點在3樓。"),
            ("黨名叫做Final V3,啊不對,是Final V4。", "黨名叫做Final V4。"),
            ("幫我轉寄給小雅跟小博,不是,是小雅跟小潘。", "幫我轉寄給小雅跟小潘。"),
            ("接下來有三件事,第一是把Low-End收乾淨,第二是把Delay收短,第三是重做母帶",
             "接下來有三件事：\n1. 把 Low-End 收乾淨\n2. 把 Delay 收短\n3. 重做母帶"),
            ("今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明",
             "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"),
            ("那個Compressor的Ratio我建議設成2比1,不要讓它Pump。", "Compressor的Ratio我建議設成2比1，不要讓它Pump。"),
            ("王老師好,這次上課的教室改成四樓,另外教材我會帶過去。",
             "王老師好，這次上課的教室改成四樓，另外教材我會帶過去。")
        ]

        for (index, pair) in cases.enumerated() {
            XCTAssertTrue(
                CleanupFidelity.preservesContent(original: pair.0, cleaned: pair.1),
                "Probe case \(index + 1) rejected: \(String(describing: CleanupFidelity.rejectionReason(original: pair.0, cleaned: pair.1)))"
            )
        }
    }

    func testQ2NumberedListConversionsAllowOnlyListMarkersAndItemConnectorsToDrop() {
        let s17 = "今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明"
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: s17,
            cleaned: "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ))
        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: s17,
            cleaned: "今天的工作清單：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ), "The list-intro 是 and spoken ordinals may be omitted when replaced by numbering")

        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。",
            cleaned: "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭"
        ), "A connector before a separately numbered item may be omitted")

        for connector in ["和", "以及", "跟"] {
            XCTAssertTrue(CleanupFidelity.preservesContent(
                original: "清單：播放器、耳機\(connector)線材",
                cleaned: "清單：\n1. 播放器\n2. 耳機\n3. 線材"
            ), "\(connector) may be omitted only at an emitted numbered-item boundary")
            XCTAssertTrue(CleanupFidelity.preservesContent(
                original: "播放器、耳機\(connector)線材",
                cleaned: "1. 播放器\n2. 耳機\n3. 線材"
            ), "Unmarked three-item lists may also replace the item connector")
        }

        XCTAssertTrue(CleanupFidelity.preservesContent(
            original: "今天有幾件事，首先，先確認檔案，第二，備份資料",
            cleaned: "今天有幾件事：\n1. 先確認檔案\n2. 備份資料"
        ), "Ordinal words may be replaced by numbered list markers")
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "今天的工作清單是,第一,更新文件,第二,備份資料",
            cleaned: "今天的工作清單：更新文件，備份資料"
        ), "List-specific omissions are not allowed without numbered output")
    }

    func testQ2OverEditsRemainRejected() {
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "是不是該把主唱推到前面一點？", cleaned: "該把主唱推到前面一點嗎？"))
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "上面做的", cleaned: "上做"))
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "地點在3樓", cleaned: "地點在三樓"))
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "教室改成四樓", cleaned: "教室四樓"))

        for transition in ["另外", "對了", "總之"] {
            XCTAssertFalse(CleanupFidelity.preservesContent(
                original: "清單：先確認檔案，\(transition)備份資料",
                cleaned: "清單：\n1. 先確認檔案\n2. 備份資料"
            ), "\(transition) remains substantive even in numbered output")
        }
        XCTAssertFalse(CleanupFidelity.preservesContent(
            original: "首先先確認檔案",
            cleaned: "先確認檔案"
        ), "首先 is removable only when it is replaced by numbered list formatting")
    }

    func testLongRejectedParagraphUsesBoundedFidelityWork() {
        let original = String(repeating: "甲", count: 2_000)
        let cleaned = String(repeating: "乙", count: 2_000)
        _ = CleanupFidelity.rejectionReason(original: original, cleaned: cleaned)

        let start = DispatchTime.now().uptimeNanoseconds
        let reason = CleanupFidelity.rejectionReason(original: original, cleaned: cleaned)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertNotNil(reason)
        XCTAssertLessThan(elapsedMilliseconds, 50, "2,000-character fidelity check took \(elapsedMilliseconds) ms")
    }

    // MARK: - Q4 忠實度要放行「同音錯字修正」

    private func reason(_ original: String, _ cleaned: String) -> String {
        String(describing: CleanupFidelity.rejectionReason(original: original, cleaned: cleaned))
    }

    func testQ4AllowsSamePositionHomophoneTypoCorrections() {
        let station = ("我搭到元山站以後再換車", "我搭到圓山站以後再換車")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: station.0, cleaned: station.1),
            "元山→圓山：\(reason(station.0, station.1))"
        )
        let card = ("悠悠卡記得先除值", "悠遊卡記得先儲值")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: card.0, cleaned: card.1),
            "悠悠卡→悠遊卡、除值→儲值：\(reason(card.0, card.1))"
        )
        let whole = (
            "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。",
            "我們約禮拜四下午三點在公司見，然後我搭到圓山站以後再換車，悠遊卡記得先儲值。"
        )
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: whole.0, cleaned: whole.1),
            "orchestrator 實測的三個錯字合在整句裡也要放行：\(reason(whole.0, whole.1))"
        )
    }

    func testQ4StillRejectsSemanticCharacterSwaps() {
        // 否定詞互換：讀音相同但語意翻轉。
        let swaps: [(String, String, String)] = [
            ("這個方案不可以今天就送", "這個方案布可以今天就送", "不→布"),
            ("這個方案沒有問題", "這個方案梅有問題", "沒→梅"),
            ("這個方案我們別亂改", "這個方案我們憋亂改", "別→憋"),
            ("這件事我還未確認", "這件事我還味確認", "未→味"),
            // 數字字被換成同音字＝數值被改掉。
            ("我們下午一點開會", "我們下午衣點開會", "一→衣"),
            ("我們下午三點開會", "我們下午傘點開會", "三→傘"),
            ("剩下的零件是零個", "剩下的零件是鈴個", "零→鈴"),
            // 人稱代名詞互換＝替使用者猜。
            ("這份合約等他簽", "這份合約等她簽", "他→她"),
            ("我要通知你明天到", "我要通知妳明天到", "你→妳"),
            // 整詞換成不同音的同義詞。
            ("我要確認這個檔案", "我要核對這個檔案", "確認→核對")
        ]
        for (original, cleaned, label) in swaps {
            XCTAssertFalse(
                CleanupFidelity.preservesContent(original: original, cleaned: cleaned),
                "\(label) must stay rejected"
            )
        }
        // 增刪實詞。
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "教室改成四樓", cleaned: "教室四樓"))
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "這個方案今天送", cleaned: "這個新方案今天送"))
    }

    func testQ4RejectsAntonymAndMagnitudeHomophones() {
        // 反義同音字（買／賣）：讀音一樣但原意相反，換掉＝整句意思顛倒。
        let swaps: [(String, String, String)] = [
            ("我要買這台車", "我要賣這台車", "買→賣"),
            ("我要买这辆自行车", "我要卖这辆自行车", "买→卖（简体）"),
            // 數量級字：換掉＝數值被改一個數量級。（別用「五億元」這類片段——
            // Normalizer 會先把中文數字展開，測到的會變成數字比對而不是同音替換。）
            ("這個億萬計畫", "這個意萬計畫", "億→意"),
            ("這個亿万計畫", "這個意万計畫", "亿→意（简体）"),
            ("這個兆頭不錯", "這個照頭不錯", "兆→照"),
            ("我拾起那個包包", "我石起那個包包", "拾→石"),
            ("花費三百佰元", "花費三百擺元", "佰→擺"),
            ("花費三千仟元", "花費三千牽元", "仟→牽")
        ]
        for (original, cleaned, label) in swaps {
            XCTAssertFalse(
                CleanupFidelity.preservesContent(original: original, cleaned: cleaned),
                "\(label) must stay rejected"
            )
        }
    }

    func testQ4ShortSentencesStillGetOneSubstitution() {
        // 25% 的整數除法會讓 2–3 字短句歸零（2*25/100 = 0），「除值→儲值」這種
        // 一個字的修正就整個被擋掉。兩個字以上至少留一個名額。
        let two = ("除值", "儲值")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: two.0, cleaned: two.1),
            "除值→儲值：\(reason(two.0, two.1))"
        )
        let station = ("元山", "圓山")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: station.0, cleaned: station.1),
            "元山→圓山：\(reason(station.0, station.1))"
        )
        // 單字沒有餘裕，預算維持 0。
        XCTAssertFalse(
            CleanupFidelity.preservesContent(original: "搭", cleaned: "達"),
            "單字來源沒有替換預算"
        )
    }

    func testQ4RemovesOptionalStutterBeforePairingHomophones() {
        // 被刪掉的重複「討」不該先跟後面的「陶」同音配對，否則整條對齊錯位。
        let stutter = ("研討研討陶器", "研討陶器")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: stutter.0, cleaned: stutter.1),
            "研討研討陶器→研討陶器：\(reason(stutter.0, stutter.1))"
        )
        // 同時同音替換本身還是要走得通。
        let card = ("悠悠卡記得先除值", "悠遊卡記得先儲值")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: card.0, cleaned: card.1),
            "悠悠卡→悠遊卡、除值→儲值：\(reason(card.0, card.1))"
        )
    }

    // MARK: - 2026-10-22 cleanup-semantics-1：沒標點的改口（借用 Normalizer 的改口對齊）

    func testUnpunctuatedSelfCorrectionsPassTheStrictGate() {
        let cases: [(String, String)] = [
            ("取樣率用 48K不對是 96K。", "取樣率用 96K。"),
            ("幫我轉寄給小雅跟小波不是，是小雅跟小潘。", "幫我轉寄給小雅跟小潘。"),
            ("金額是 1200，不對是 12,000塊。", "金額是 12000塊。"),
            ("金額是 1200不對是 12,000塊。", "金額是 12,000塊。"),
            ("我們約禮拜三不對禮拜四開會", "我們約禮拜四開會"),
            ("幫我轉寄給小雅跟小柏、不是，是小雅跟小潘、", "幫我轉寄給小雅跟小潘。"),
            ("取樣率用 48K，不對，是 96K。", "取樣率用 96K。"),
            ("四點不對不對三點", "三點。")
        ]
        for (original, cleaned) in cases {
            XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: cleaned),
                          "\(original) → \(cleaned)：\(reason(original, cleaned))")
        }
        // FX-1 v2（C2）：把關看不出原本有沒有停頓，「不對」類只認值換值；「Final下橫線V4」開頭不是值，直接拿原始逐字稿比會擋。
        // Mac／iOS／Android 都拿第一次貼上（這句已經改好成「檔名叫做Final V4」）來比，整理結果照樣放行。
        let finalFirst = SentenceMood.finish(Normalizer().normalize("檔名叫做Final V3,不對是Final下橫線V4").cleaned)
        XCTAssertEqual(finalFirst, "檔名叫做Final V4")
        XCTAssertTrue(CleanupFidelity.preservesContent(original: finalFirst, cleaned: "檔名叫做Final_V4"),
                      reason(finalFirst, "檔名叫做Final_V4"))
        // 原樣照抄（沒處理改口）一樣放行；忠實照抄的對比句也不能被擋。
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "取樣率用 48K不對是 96K。", cleaned: "取樣率用 48K不對是 96K。"))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "我們約禮拜三，不是禮拜四開會。", cleaned: "我們約禮拜三，不是禮拜四開會。"))
    }

    func testReversalsContrastAndMisalignedCorrectionsStayRejected() {
        let cases: [(String, String, String)] = [
            ("取樣率用四十八K不對是九十六K", "取樣率用四十八K。", "改口後反而留舊值"),
            ("我們約三點開會不對四點", "我們約三點開會。", "改口後反而留舊值"),
            ("取樣率用 48K不對是 96K。", "取樣率用 44K。", "換成第三個值"),
            ("我要的是三點不是四點", "我要的是四點。", "單獨的「不是」是對比"),
            ("取樣率是48K不是96K", "取樣率是96K。", "單獨的「不是」是對比"),
            ("這不是重點", "重點。", "否定不能拿掉"),
            ("我們約禮拜三，不是禮拜四開會。", "我們約禮拜四開會。", "「A，不是B」是對比"),
            ("我應該要去找 Claude Code 不對是要去搞 Codex", "我應該要去搞 Codex", "對不齊的改口只交給 Claude")
        ]
        for (original, cleaned, label) in cases {
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "\(label)：\(original) → \(cleaned)")
        }
    }

    // MARK: - 2026-10-22 cleanup-semantics-v1：沒標點的「那個就是」與「恩」

    func testUnpunctuatedDemonstrativeChainsAndEnSpellingAreOptional() {
        let cases: [(String, String)] = [
            ("我覺得那個就是這個low end可以再收一點", "我覺得這個 low end 可以再收一點。"),
            ("，我覺得那個就是這個 low and可以再收一點", "我覺得這個 low and 可以再收一點。"),
            ("我覺得那個嗯就是這個low end可以再收一點", "我覺得這個 low end 可以再收一點。"),
            ("恩恩，然後就是說我這邊沒有收到你的檔案喔。", "我這邊沒有收到你的檔案喔。")
        ]
        for (original, cleaned) in cases {
            XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: cleaned),
                          "\(original) → \(cleaned)：\(reason(original, cleaned))")
        }
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "那就是這個問題", cleaned: "那問題。"))
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "我覺得那個就是重點", cleaned: "我覺得重點。"),
                       "「那個就是」後面不是另一個這個／那個＝實詞")
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "恩人很好", cleaned: "人很好"), "恩人的恩不是贅詞")
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "感恩，謝謝", cleaned: "謝謝"), "感恩的恩不是贅詞")
    }

    // MARK: - 2026-10-22 cleanup-semantics-3：人稱不能被翻轉（從 iOS 搬進 core）

    func testKeepsPersonRejectsFlippedOrAnsweredPerson() {
        XCTAssertFalse(CleanupFidelity.keepsPerson(original: "你覺得這個 mix 的低頻夠不夠", cleaned: "我覺得這個 mix 的低頻夠了。"))
        XCTAssertFalse(CleanupFidelity.keepsPerson(original: "你覺得這個版本可以直接給客戶聽嗎", cleaned: "這個版本還不能直接給客戶聽。"))
        XCTAssertFalse(CleanupFidelity.keepsPerson(original: "在手機上叫做 Utuvoltype，被搞問了。", cleaned: "在手機上叫做 Utuvoltype，我被搞糊塗了。"))
        XCTAssertFalse(CleanupFidelity.keepsPerson(original: "我們先去錄音室", cleaned: "我想明天去錄音室"))
        XCTAssertTrue(CleanupFidelity.keepsPerson(original: "你覺得這個版本可以直接給客戶聽嗎", cleaned: "你覺得這個版本可以直接給客戶聽嗎？"))
        XCTAssertTrue(CleanupFidelity.keepsPerson(original: "是不是要重新開一個 session", cleaned: "是不是要重新開一個 session？"))
        XCTAssertTrue(CleanupFidelity.keepsPerson(original: "我們明天見", cleaned: "我們明天見。"))
        // 整理成條列時省掉主詞不算翻轉人稱（2026-10-22 lp03；352 組錄好的候選稿只翻這一句）。
        XCTAssertTrue(CleanupFidelity.keepsPerson(original: "首先我們花了三個禮拜做demo，收集了12首候選曲",
                                                  cleaned: "1. 花了三個禮拜做 demo，收集了 12 首候選曲"))
        XCTAssertFalse(CleanupFidelity.keepsPerson(original: "我們先去錄音室，我再跟你說", cleaned: "我先去錄音室再跟你說"))
    }

    // MARK: - 2026-10-22 cleanup-format-1(b)：寬鬆把關比數值，不只比 0–9

    func testRelaxedGateRejectsChangedNumberValues() {
        let wrong: [(String, String)] = [
            ("總共是1,250塊", "總共是12,500塊"),
            ("下午3:30開會", "下午3:00開會"),
            ("預算是30萬，第二期先付10萬5", "預算是 30,000，第二期先付 100,000。")
        ]
        for (original, cleaned) in wrong {
            XCTAssertFalse(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.introducesDigits(original: Normalizer.normalizeNumbers(original),
                                                            cleaned: Normalizer.normalizeNumbers(cleaned)),
                           "數字集合一樣，靠的是數值比對：\(original)")
        }
        let fine: [(String, String)] = [
            ("預算是三十萬", "預算是 300,000"),
            ("預算是30萬", "預算是 30 萬"),
            ("我的電話是零九一二三四五六七八", "我的電話是 0912-345-678"),
            ("我的電話是0912345678", "我的電話是 0912-345-678"),
            ("總共是一千兩百五十塊", "總共是 1,250 塊"),
            ("中間休息一小時", "中間休息 1 小時"),
            ("我建議設成2比1", "我建議設成 2:1"),
            ("今天要做三件事，第一，更新，第二，匯出，第三，寫說明", "今天要做三件事：\n1. 更新\n2. 匯出\n3. 寫說明")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
    }

    func testIntroducesNumberValuesComparesValuesNotDigits() {
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "總共是1,250塊", cleaned: "總共是12,500塊"))
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "下午3:30", cleaned: "下午3:00"))
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "大概2到3天", cleaned: "大概 2-3 天"), "區間拆開對得上")
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "0912345678", cleaned: "0912-345-678"), "電話合起來對得上")
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "播放器、耳機", cleaned: "1. 播放器\n2. 耳機"), "行首清單編號不算")
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "休息一小時", cleaned: "休息 1 小時"))
        // 10-19 真人錄音：ASR 結巴「十十月」＝十月，整理成「10 月」不是新數值；但不能因此放行別的值。
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "十十月十三號", cleaned: "10 月 13 號"))
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "十十月十三號", cleaned: "11 月 13 號"))
        // replay real-claude s23：電話重新分段（數字順序不變）照樣放行；改了一位、或把兩個短數字黏成一個就擋。
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "我的電話是 0912到 345678傳真號碼是 02到 23333333。",
                                                              cleaned: "我的電話是 0912-345-678，傳真號碼是 02-2333-3333。"))
        XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: "我的電話是 0912到 345678，傳真號碼是 02到 23333333。",
                                                              cleaned: "我的電話是 0912345678，傳真號碼是 0223333333。"))
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "我的電話是 0912到 345678", cleaned: "我的電話是 0912-345-679"))
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "大概3到5天", cleaned: "大概35天"))
        // replay real-claude s25（實際念的是「三十萬」「十萬五」）：ASR 寫成「30,00」，模型猜成 30,000＝錯十倍，要擋。
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "預算是 30,00，第二期先付 10,00000。",
                                                             cleaned: "預算是 30,000，第二期先付 100,000。"))
    }

    // MARK: - 2026-10-22 cleanup-semantics-v2：對比句不能被翻成只剩後半

    func testRelaxedGateRejectsInvertedContrast() {
        let inverted: [(String, String)] = [
            ("我要的是三點不是四點", "我要的是四點。"),
            ("我要的是三點不是四點", "我要的是 4 點。"),
            ("取樣率是48K不是96K", "取樣率是96K。"),
            ("我們約禮拜三，不是禮拜四開會。", "我們約禮拜四開會。")
        ]
        for (original, cleaned) in inverted {
            XCTAssertTrue(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let kept: [(String, String)] = [
            ("我要的是三點不是四點", "我要的是三點，不是四點。"),
            ("我要的是三點不是四點", "我要的是三點。"),
            ("幫我轉寄給小雅跟小波不是，是小雅跟小潘。", "幫我轉寄給小雅跟小潘。"),
            ("幫我轉寄給小雅跟小博，不是，是小雅跟小潘。", "幫我轉寄給小雅跟小潘。"),
            ("嗯我們約禮拜三，不是，禮拜四下午三點在公司見", "我們約禮拜四下午三點在公司見。"),
            ("我想明天，不對，後天寄", "我想後天寄。")
        ]
        for (original, cleaned) in kept {
            XCTAssertFalse(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
    }

    // MARK: - 2026-10-22 FX-3：把關會收下改了意思的輸出（Codex adversarial review）

    /// FX-3 ①：數值要整個比——正負號、小數點都算數值的一部分（寬鬆與嚴格都一樣）。
    func testSignedAndDecimalValuesAreComparedWhole() {
        let wrong: [(String, String)] = [
            ("響度設為-14 LUFS", "響度設為14 LUFS"),
            ("劑量為1.5毫克", "劑量為5.1毫克"),
            ("增益是3dB", "增益是-3dB"),
            ("響度設為負十四LUFS", "響度設為14 LUFS")
        ]
        for (original, cleaned) in wrong {
            XCTAssertFalse(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: Normalizer.normalizeNumbers(original),
                                                                 cleaned: Normalizer.normalizeNumbers(cleaned)),
                          "數值：\(original) → \(cleaned)")
        }
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "響度設為-14 LUFS", cleaned: "響度設為14 LUFS"), "嚴格：負號不能丟")
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "增益是3dB", cleaned: "增益是-3dB"), "嚴格：負號不能加")
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "-14 LUFS 就好", cleaned: "14 LUFS 就好"), "嚴格：行首的負號不是項目符號")
        // 不該擋：連字號在數字中間（電話、日期、區間、型號）不是負號；千分位、時間是格式；「負」「零下」＝負號；「一點五」＝1.5。
        let fine: [(String, String)] = [
            ("響度設為-14 LUFS", "響度設為 -14 LUFS。"),
            ("響度設為負14 LUFS", "響度設為 -14 LUFS"),
            ("明天低溫零下五度要穿外套", "明天低溫 -5 度，要穿外套。"),
            ("劑量為1.5毫克", "劑量為 1.5 毫克。"),
            ("劑量為一點五毫克", "劑量為 1.5 毫克。"),
            ("這首歌的音場用七點一點四來做混音", "這首歌的音場用 7.1.4 來做混音。"),
            ("我的電話是0912-345-678", "我的電話是 0912-345-678"),
            ("截止日是2026-10-22", "截止日是 2026 年 10 月 22 日"),
            ("大概3-5天", "大概 3-5 天"),
            ("COVID-19 的疫苗打了兩劑", "COVID-19 的疫苗打了兩劑。"),
            ("型號是A-1", "型號是 A-1。"),
            ("總共是一萬兩千塊", "總共是 12,000 塊"),
            ("下午三點半開會", "下午 3:30 開會。"),
            ("音量調到負六dB", "音量調到 -6 dB。"),
            ("LUFS 目標是負十四", "LUFS 目標是 -14。"),
            ("版本號是1.0.8", "版本號是 1.0.8。")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "relaxed：\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "響度設為-14 LUFS", cleaned: "響度設為 -14 LUFS。"))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "我的電話是0912-345-678", cleaned: "我的電話是 0912-345-678。"))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "大概3-5天", cleaned: "大概 3-5 天。"))
    }

    /// FX-3 ②：數值不能換主人——輸出的數值要依原文順序出現、次數不能變多；改口後的值照樣放行。
    func testNumberValuesKeepTheirOrderAndCount() {
        let wrong: [(String, String)] = [
            ("預算是100元，訂金是200元", "預算是200元，訂金是100元"),
            ("預算是100元，訂金是200元", "預算是100元，訂金是100元"),
            ("預算是一百，訂金兩百", "預算是兩百，訂金一百"),
            ("買三個蘋果和五個橘子", "買五個蘋果和三個橘子"),
            ("3樓開會，5樓吃飯", "5樓開會，3樓吃飯"),
            ("預算是100元，訂金是200元，不對，250元", "預算是250元，訂金是100元")
        ]
        for (original, cleaned) in wrong {
            XCTAssertFalse(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let fine: [(String, String)] = [
            ("預算是100元，不對，150元，訂金是200元", "預算是150元，訂金是200元。"),
            ("我們約3點開會,不對,4點,地點在3樓", "我們約4點開會，地點在3樓。"),
            ("預算是三十萬，第二期先付十萬", "預算是 300,000，第二期先付 100,000。"),
            ("我的電話是 0912到 345678傳真號碼是 02到 23333333。", "我的電話是 0912-345-678，傳真號碼是 02-2333-3333。"),
            ("今天要做三件事，第一，更新，第二，匯出，第三，寫說明", "今天要做三件事：\n1. 更新\n2. 匯出\n3. 寫說明"),
            ("大概三到五天，最多一週", "大概 3 到 5 天，最多一週。"),
            ("報告在十十月十三號以前要交給客戶", "報告在 10 月 13 號以前要交給客戶。"),
            ("預算是100元，訂金是200元", "預算是100元。"),
            // 改口的值不在被取代的那個位置旁邊：改口後的值可以搬去取代前面的值。
            ("我們約三點開會在5樓，不對，四點", "我們約四點開會在5樓。"),
            ("我們約3點開會，地點在5樓，不對，4點", "我們約4點開會，地點在5樓。")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.reordersNumberValues(original: Normalizer.normalizeNumbers(original),
                                                                cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.reordersNumberValues(original: "預算是100元，訂金是200元", cleaned: "預算是200元，訂金是100元"))
        XCTAssertTrue(CleanupFidelity.reordersNumberValues(original: "預算是100元，訂金是200元", cleaned: "預算是100元，訂金是100元"))
    }

    /// FX-3 ③：每一組對比各自檢查——別處的「不是」、別處出現的原選項都不能拿來抵。
    func testEachContrastIsCheckedOnItsOwn() {
        let inverted: [(String, String)] = [
            ("開會時間是星期三不是星期四，地點不是台北", "開會時間是星期四，地點不是台北"),
            ("預定的是台北不是台南，台北需要提前預約", "預定的是台南，台北需要提前預約"),
            ("我要的是三點不是四點", "我要的是四點不是三點。"),
            ("我們約禮拜三，不是禮拜四開會，不是在公司", "我們約禮拜四開會，不是在公司。")
        ]
        for (original, cleaned) in inverted {
            XCTAssertTrue(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let kept: [(String, String)] = [
            ("開會時間是星期三不是星期四，地點不是台北", "開會時間是星期三，不是星期四，地點不是台北。"),
            ("開會時間是星期三不是星期四，地點不是台北", "開會時間是星期三，地點不是台北。"),
            ("預定的是台北不是台南，台北需要提前預約", "預定的是台北，不是台南，台北需要提前預約。"),
            ("預定的是台北不是台南，台南那家下次再訂", "預定的是台北，不是台南，台南那家下次再訂。"),
            ("我要的是三點而不是四點", "我要的是三點，而不是四點。")
        ]
        for (original, cleaned) in kept {
            XCTAssertFalse(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
    }

    /// FX-3 ④：嚴格把關也不能把對比句翻掉；「星期三不是星期四」沒有改口語法（不是＋是、或前後停頓）就不是改口。
    func testStrictGateKeepsWeekdayContrasts() {
        let inverted: [(String, String)] = [
            ("開會時間是星期三不是星期四", "開會時間是星期四"),
            ("開會時間是星期三不是星期四，地點不是台北", "開會時間是星期四，地點不是台北"),
            ("我們約禮拜三不是禮拜五下午見", "我們約禮拜五下午見")
        ]
        for (original, cleaned) in inverted {
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let corrections: [(String, String)] = [
            ("我們約禮拜三，不是，禮拜五下午見", "我們約禮拜五下午見"),
            ("我們約禮拜三不是，是禮拜五下午見", "我們約禮拜五下午見"),
            ("我們約禮拜三不是是禮拜五下午見", "我們約禮拜五下午見"),
            ("我們約禮拜三不對禮拜五下午見", "我們約禮拜五下午見"),
            ("開會時間是星期三不是星期四", "開會時間是星期三，不是星期四。"),
            ("開會時間是星期三不是星期四", "開會時間是星期三不是星期四")
        ]
        for (original, cleaned) in corrections {
            XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: cleaned),
                          "\(original) → \(cleaned)：\(reason(original, cleaned))")
        }
    }

    /// FX-3 ⑤：人稱的先後（誰寄給誰）不能對調，中英文都算；省掉人稱、他／她同音互換照樣放行。
    func testPersonReferencesKeepTheirOrder() {
        let flipped: [(String, String)] = [
            ("我明天會把報告寄給他", "他明天會把報告寄給我"),
            ("You will send me the invoice tomorrow.", "I will send you the invoice tomorrow."),
            ("我們會把檔案寄給他們", "他們會把檔案寄給我們"),
            ("We will send them the files.", "They will send us the files."),
            ("你跟他說我晚點到", "他跟你說我晚點到"),
            ("She told him the mix was done.", "He told her the mix was done.")
        ]
        for (original, cleaned) in flipped {
            XCTAssertFalse(CleanupFidelity.keepsPerson(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let fine: [(String, String)] = [
            ("我明天會把報告寄給他", "我明天會把報告寄給她。"),
            ("我我明天會把報告寄給他", "我明天會把報告寄給他。"),
            ("其他的我再跟你說", "其他的我再跟你說。"),
            ("吉他的部分我來彈，你負責鼓", "吉他的部分我來彈，你負責鼓。"),
            ("寄給他，不對，寄給你", "寄給你。"),
            ("You will send me the invoice tomorrow.", "You will send me the invoice tomorrow."),
            ("I think the US mix is louder", "I think the US mix is louder."),
            ("Can you send it to me", "Can you send it to me?"),
            ("我覺得你那邊的版本比較好", "你那邊的版本比較好。")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(CleanupFidelity.keepsPerson(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
    }

    // MARK: - 2026-10-22 FX-3 第二輪：獨立驗證找到的漏網（寬鬆把關，兩邊先轉成同一種數字寫法，同 production）

    private func relaxed(_ original: String, _ cleaned: String) -> Bool {
        CleanupFidelity.passesRelaxed(original: original, cleaned: cleaned)
    }

    /// 對比的 B 在原文別處也出現（「台南那家下次再訂」）時，翻轉照樣要擋：B 坐上了 A 的位置、或 A 不見了 B 還在。
    /// b8817d8 的整句檢查擋得下，3da76c7 的逐組檢查只數 B 的次數、數字打平就放行了（回歸）。
    func testContrastInversionIsCaughtWhenTheOtherOptionAppearsElsewhere() {
        let inverted: [(String, String)] = [
            ("預定的是台北不是台南，台南那家下次再訂", "預定的是台南，那家下次再訂。"),
            ("我要的是三點不是四點，四點我有別的會", "我要的是4點，我有別的會。"),
            ("寄給客戶的是A版不是B版，B版的低頻還要再修", "寄給客戶的是B版，低頻還要再修。"),
            ("要寄給小王，不是小李，小李那份明天再寄", "要寄給小李，那份明天再寄。"),
            ("開會是星期三不是星期四，星期四我要出差", "開會是星期四，我要出差。"),
            ("寄的是A版不是B版，B版還沒混完", "寄的是B版，還沒混完。"),
            ("我要喝咖啡，不是茶，茶我不喝", "我要喝茶，我不喝。"),
            ("開會是星期三不是星期四，星期四我要出差", "開會是星期四，星期四我要出差")
        ]
        for (original, cleaned) in inverted {
            XCTAssertTrue(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        let kept: [(String, String)] = [
            ("預定的是台北不是台南，台南那家下次再訂", "預定的是台北，不是台南，台南那家下次再訂。"),
            ("預定的是台北不是台南，台南那家下次再訂", "預定的是台北，台南那家下次再訂。"),
            ("我要的是三點不是四點，四點我有別的會", "我要的是下午三點，不是四點，四點我有別的會。"),
            ("開會是星期三不是星期四，星期四我要出差", "開會是週三，不是週四；週四我要出差。"),
            ("要寄給小王，不是小李，小李那份明天再寄", "寄給小王，不是小李；小李那份明天再寄。"),
            ("我要喝咖啡，不是茶，茶我不喝", "我要喝咖啡，不是茶，茶我不喝。")
        ]
        for (original, cleaned) in kept {
            XCTAssertFalse(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 沒有「是」也沒有逗號的「X不是Y」：前後是同一種東西（星期三／星期四、三點／四點、A版本／B版本）就是對比；
    /// 換了說法（禮拜→星期、台→臺）、英文的「A, not B」「Wednesday not Thursday」、帶負號的值也一樣。一般的否定不算對比。
    func testBareAndRewordedContrastsAreChecked() {
        let inverted: [(String, String)] = [
            ("我們約禮拜三不是禮拜五下午見", "我們約禮拜五下午見。"),
            ("我們約三點不是4點見面", "我們約4點見面。"),
            ("開會星期三不是星期四", "開會星期四"),
            ("我要三點不是四點的那場", "我要四點的那場"),
            ("檔案要寄給A版本不是B版本", "那個檔案要寄B版本。"),
            ("開會時間是禮拜三不是禮拜四", "開會時間是星期四。"),
            ("預定的是台北不是台南", "預定的是臺南"),
            ("我們約禮拜三不是禮拜五下午見", "我們約週五下午見。"),
            ("The meeting is on Wednesday, not Thursday.", "The meeting is on Thursday."),
            ("the meeting is on wednesday not thursday", "The meeting is on Thursday."),
            ("I need the 3 pm slot, not the 4 pm slot.", "I need the 4 pm slot."),
            ("I'll do it tomorrow, not today", "I'll do it today."),
            ("溫度是零下五度不是零下十度", "溫度是 -10 度。"),
            ("這是我的不是你的", "這是你的。")
        ]
        for (original, cleaned) in inverted {
            XCTAssertTrue(CleanupFidelity.invertsContrast(original: Normalizer.normalizeNumbers(original),
                                                          cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "開會星期三不是星期四", cleaned: "開會星期四"), "嚴格也擋")
        XCTAssertFalse(CleanupFidelity.preservesContent(original: "預定的是台北不是台南", cleaned: "預定的是臺南"), "嚴格也擋")
        let fine: [(String, String)] = [
            ("我們約禮拜三不是禮拜五下午見", "我們約週三，不是週五，下午見。"),
            ("我要的是 A 版本而不是 B 版本", "我要的是 A 版本，而不是 B 版本。"),
            ("這不是問題，問題是時間", "這不是問題，問題是時間。"),
            ("他說的不是真的", "他說的不是真的。"),
            ("這個版本不是最終版", "這版本並非最終版。"),
            ("不是我不想去，是我沒空", "不是我不想去，是我沒空。"),
            ("我不是說你錯，我是說時間不夠", "我不是說你錯，是時間不夠。"),
            ("This is not a drill", "This is not a drill."),
            ("I'll do it tomorrow, not today", "I'll do it tomorrow, not today."),
            ("溫度是零下五度不是零下十度", "溫度是 -5 度，不是 -10 度。"),
            ("我們約禮拜三不是是禮拜五", "我們約禮拜五。"),
            ("不是星期三是星期四", "不是星期三，是星期四。")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 同一個人稱出現兩次時，人稱的先後擋不住對調（「我請他幫我訂」→「他請我訂」）：輸出的人稱搶了另一個人的位置就擋。
    /// 英文 and／or 並列的人稱對調是文法修正（「Me and him」→「He and I」），照樣放行。
    func testRepeatedPersonsCannotTradePlaces() {
        let flipped: [(String, String)] = [
            ("我請他幫我訂明天下午的高鐵票", "他請我訂明天下午的高鐵票。"),
            ("我明天早上會請他把那份報告寄給我", "他明天早上會請我把那份報告寄出去"),
            ("我會叫他明天打電話給我", "他會叫我明天打電話。"),
            ("I told him to email me the file.", "He told me to email the file."),
            ("I asked him to call me tomorrow", "He asked me to call tomorrow."),
            ("我請他幫我訂票", "他請我幫他訂票。")
        ]
        for (original, cleaned) in flipped {
            XCTAssertFalse(CleanupFidelity.keepsPerson(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let fine: [(String, String)] = [
            ("我請他幫我訂明天下午的高鐵票", "我請他幫我訂明天下午的高鐵票。"),
            ("我請他幫我訂票", "請他幫我訂票。"),
            ("我跟你說，他明天會來", "跟你說，他明天會來。"),
            ("you know I was thinking we could meet", "I was thinking we could meet."),
            ("Me and him will fix it tomorrow", "He and I will fix it tomorrow."),
            ("me and her are going to the studio", "She and I are going to the studio."),
            ("寄給他，不對，寄給你", "寄給你。"),
            ("那個你可以幫我把檔案寄給他嗎", "你可以幫我把檔案寄給他嗎？"),
            ("我會把報告寄給你，你再寄給他", "我會把報告寄給你，你再寄給他。"),
            // 刪掉贅詞後人稱剛好緊鄰別人原本緊鄰的字：只有一邊，不是對調。
            ("我嗯要去，他要來", "我要去，他要來。"),
            ("我那個跟你說，他跟我說過", "我跟你說，他跟我說過。")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(CleanupFidelity.keepsPerson(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 兩段內容繞著中間不動的一段對調＝誰對誰被換掉（名字、他／她、英文名字都算）；只把一段話挪個位置不算。
    func testPartsSwappedAroundTheSameMiddleAreRejected() {
        let swapped: [(String, String)] = [
            ("王經理要把合約寄給李律師", "李律師要把合約寄給王經理。"),
            ("小明欠小華五百元", "小華欠小明500元"),
            ("Alice owes Bob 500 dollars.", "Bob owes Alice 500 dollars."),
            ("小王寄給小李", "小李寄給小王。"),
            ("我們今天先討論預算然後再討論時程", "我們今天先討論時程，然後再討論預算。"),
            ("她要把錢轉給他", "他要把錢轉給她"),
            ("他把它放在桌上", "它把他放在桌上"),
            ("John will call Mary at 10 am", "Mary will call John at 10 am."),
            // 兩邊都是時間＝誰在哪天被換掉，不是挪時間副詞。
            ("明天見客戶，後天見老闆", "後天見客戶，明天見老闆。"),
            ("下午三點開會，晚上七點吃飯", "晚上七點開會，下午三點吃飯。")
        ]
        for (original, cleaned) in swapped {
            XCTAssertTrue(CleanupFidelity.swapsAroundSharedMiddle(original: Normalizer.normalizeNumbers(original),
                                                                  cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        let moved: [(String, String)] = [
            ("明天我要去台北，後天去台中", "我明天要去台北，後天去台中。"),
            ("因為下雨，所以我們取消了", "我們取消了，因為下雨。"),
            ("小王跟小李一起去", "小王和小李一起去。"),
            ("我們今天先討論預算然後再討論時程", "我們今天先討論預算，然後再討論時程。"),
            ("Me and him will fix it tomorrow", "He and I will fix it tomorrow."),
            // 把時間副詞挪個位置（一段全是時間、另一段完全沒有時間）。
            ("at 3 pm on October 22 we meet", "We meet on October 22 at 3 pm."),
            ("tomorrow at 10 am I will call John", "I will call John tomorrow at 10 am."),
            // 改口：照改口改好的讀法沒有對調（2026-10-22 iOS 真人錄音 sc04）。
            ("幫我轉寄給小雅跟小波不是是小雅跟小潘。", "幫我轉寄給小雅跟小潘，不是小雅跟小波。")
        ]
        for (original, cleaned) in moved {
            XCTAssertFalse(CleanupFidelity.swapsAroundSharedMiddle(original: Normalizer.normalizeNumbers(original),
                                                                   cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 數量與符號：「一杯」「一張」也是數量（跟其他數量比先後）；英文 minus／negative、「負 14」（有空白）是負號；
    /// 「減三dB」寫成 -3 或 3 都對；改口取代最近一個同單位的值；不同單位的值可以換位置（日期與時間重排）。
    func testQuantitiesSignsAndCorrectionTargets() {
        let wrong: [(String, String)] = [
            ("我要一杯拿鐵跟兩杯美式", "我要兩杯拿鐵跟一杯美式。"),
            ("我買一張票，他買兩張票", "我買兩張票，他買一張票。"),
            ("Set the loudness to minus 14 LUFS.", "Set the loudness to 14 LUFS."),
            ("The target is negative 14 LUFS.", "The target is 14 LUFS."),
            ("響度設為負 14 LUFS", "響度設為 14 LUFS"),
            ("預算是100元，訂金是200元，不對，是300元", "預算是300元，訂金是200元"),
            ("我3點到公司，5點開會，不對，6點", "我6:00到公司，5:00開會"),
            ("三樓開會，五點吃飯", "5點開會，3樓吃飯。"),
            ("I have 3 apples and 5 oranges", "I have 5 apples and 3 oranges."),
            // 響度單位後面緊接的減號是負號（不是「A-1」那種編號）。
            ("LUFS-14是標準", "LUFS 14是標準")
        ]
        for (original, cleaned) in wrong {
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.reordersNumberValues(original: "我要一杯拿鐵跟兩杯美式", cleaned: "我要兩杯拿鐵跟一杯美式。"))
        // 單位不同的值互相換走對方後面的詞＝換了主人（數值檢查本身就要擋，不靠別的檢查碰巧擋到）。
        XCTAssertTrue(CleanupFidelity.reordersNumberValues(original: "三樓開會，五點吃飯", cleaned: Normalizer.normalizeNumbers("5點開會，3樓吃飯。")))
        XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: "Set the loudness to minus 14 LUFS.", cleaned: "Set the loudness to 14 LUFS."))
        let fine: [(String, String)] = [
            ("Set the loudness to minus 14 LUFS", "Set the loudness to -14 LUFS."),
            ("the gain is negative 3 dB", "The gain is -3 dB."),
            ("響度設為負 14 LUFS", "響度設為 -14 LUFS。"),
            ("音量要減三dB", "音量要 -3 dB。"),
            ("音量要減三dB", "音量要減 3 dB。"),
            ("我要一個漢堡跟兩杯可樂", "我要一個漢堡、兩杯可樂。"),
            ("我要一杯拿鐵", "我要一杯拿鐵。"),
            ("明天下午三點，十月二十三號要交", "10 月 23 日（明天）下午3點要交。"),
            ("三樓開會，五點吃飯", "3樓開會，5點吃飯。"),
            ("我們約三點開會在5樓，不對，四點", "我們約四點開會在5樓。"),
            ("我3點到公司，5點開會，不對，6點", "我3點到公司，6點開會。"),
            // 英文日期時間重排：月份後面的數字是幾號，跟「3 pm」的單位不同，可以換位置。
            ("at 3 pm on October 22 we meet", "We meet on October 22 at 3 pm."),
            ("LUFS-14是標準", "-14 LUFS 是標準。"),
            ("A-1版本先寄", "A-1 版本先寄。"),
            ("COVID-19的影響", "COVID-19 的影響。")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    // MARK: - 2026-10-22 FX-3 第三輪：第二輪獨立驗證找到的漏網與誤擋

    /// 主從對調：動詞換了說法時，緊鄰的字也跟著換（「我請他幫我訂」→「他要我訂」），要看「當主詞的人稱後面、同一個子句裡還有誰」。
    /// 原文每一個當主詞的人稱都算：省掉主詞、轉述的後半句換人當主詞（「我跟你說他明天會來找你」→「他明天會來找你」）照樣放行。
    func testSubjectAndObjectCannotTradePlacesWhenTheVerbIsReworded() {
        let flipped: [(String, String)] = [
            ("我會叫他明天打電話給我", "他明天會叫我打電話。"),
            ("我會叫他明天打電話給我", "他明天叫我打電話。"),
            ("我請他幫我訂明天下午的高鐵票", "他要我訂明天下午的高鐵票。"),
            ("我請他幫我訂明天下午的高鐵票", "他拜託我訂明天下午的高鐵票。"),
            ("我拜託他幫我買咖啡", "他明天拜託我買咖啡。"),
            ("I told him to email me the file", "He asked me to email the file."),
            ("I asked him to call me tomorrow", "He told me to call tomorrow.")
        ]
        for (original, cleaned) in flipped {
            XCTAssertFalse(CleanupFidelity.keepsPerson(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
        let fine: [(String, String)] = [
            ("我請他幫我訂明天下午的高鐵票", "我請他幫忙訂明天下午的高鐵票。"),
            ("我請他幫我訂票", "請他幫我訂票。"),
            ("我跟你說他明天會來找你", "他明天會來找你。"),
            ("我跟你說，他明天會來找你", "他明天會來找你。"),
            ("我們跟他們說了他們明天會給我們回覆", "我們跟他們說了，他們明天會回覆我們。"),
            ("我想他應該會打給我", "我想他應該會打給我。"),
            ("我昨天跟他說我明天不能去", "我昨天跟他說，我明天不能去。"),
            ("嗯我覺得他說的對我們就照他的做", "我覺得他說的對，我們就照他的做。"),
            ("然後他就跟我說你明天不用來了", "他跟我說你明天不用來了。"),
            ("是他寄給我的不是我寄給他的", "是他寄給我的，不是我寄給他的。"),
            ("He told me I should call him", "He told me to call him."),
            ("I told him to email me the file", "I told him to email me the file.")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(CleanupFidelity.keepsPerson(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 「不是 B 而是 A」「不是 B，是 A」「not B but A」：後面那個 A 才對，整理成 B 就是翻轉；
    /// 「A 而非／並非 B」「A instead of／rather than B」跟「A 不是 B」一樣是 A 對。保留整組、或改寫成「A，不是 B」照樣放行。
    func testTurnedContrastsAndOtherContrastMarkersAreChecked() {
        let inverted: [(String, String)] = [
            ("開會不是星期四，而是星期三", "開會是星期四。"),
            ("開會不是星期四，而是星期三", "開會時間是星期四。"),
            ("要寄的不是母帶而是混音", "要寄的是母帶。"),
            ("不是星期四，是星期三", "是星期四。"),
            ("The meeting is not on Thursday but on Wednesday", "The meeting is on Thursday."),
            ("The meeting is not on Thursday but on Wednesday", "The meeting is Thursday."),
            ("It is not the mix but the master", "It is the mix."),
            ("我要的是三點而非四點", "我要的是四點"),
            ("我要的是三點，並非四點", "我要的是四點"),
            ("寄的是混音版而非母帶版", "寄的是母帶版。"),
            ("I need the 3 pm slot instead of the 4 pm slot", "I need the 4 pm slot."),
            ("We want the 48k version rather than the 96k version", "We want the 96k version.")
        ]
        for (original, cleaned) in inverted {
            XCTAssertTrue(CleanupFidelity.invertsContrast(original: Normalizer.normalizeNumbers(original),
                                                          cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        let kept: [(String, String)] = [
            ("開會不是星期四，而是星期三", "開會是星期三。"),
            ("要寄的不是母帶而是混音", "要寄的不是母帶，而是混音。"),
            ("要寄的不是母帶而是混音", "要寄的是混音，不是母帶。"),
            ("The meeting is not on Thursday but on Wednesday", "The meeting is not on Thursday but on Wednesday."),
            ("The meeting is not on Thursday but on Wednesday", "The meeting is on Wednesday, not Thursday."),
            ("我要的是三點而非四點", "我要的是3點，而非4點。"),
            ("I need the 3 pm slot instead of the 4 pm slot", "I need the 3 pm slot instead of the 4 pm slot."),
            ("We want the 48k version rather than the 96k version", "We want the 48k version, not the 96k version.")
        ]
        for (original, cleaned) in kept {
            XCTAssertFalse(CleanupFidelity.invertsContrast(original: Normalizer.normalizeNumbers(original),
                                                           cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 本機版把「第二版不是第三版」排成清單、在「不是」後面換行（本機第一次貼上：「我們要的是\n第二版不是\n第三版」）：
    /// 換行不是停頓，對比照樣認得。
    func testContrastSplitAcrossLinesByTheLocalPasteIsStillChecked() {
        let inverted: [(String, String)] = [
            ("我們要的是\n第二版不是\n第三版", "我們要的是第三版。"),
            ("我們要的是\n第二版不是\n第三版", "我們要第三版。"),
            ("我們要用\n第一版不是\n第二版", "我們要用第二版。"),
            ("要交的是\n第一首不是\n第二首", "要交的是第二首。")
        ]
        for (original, cleaned) in inverted {
            XCTAssertTrue(CleanupFidelity.invertsContrast(original: original, cleaned: cleaned), "\(original) → \(cleaned)")
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        let kept: [(String, String)] = [
            ("我們要的是\n第二版不是\n第三版", "我們要的是第二版，不是第三版。"),
            ("我們要用\n第一版不是\n第二版", "我們要用第一版，不是第二版。")
        ]
        for (original, cleaned) in kept {
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    /// 第二輪驗證找到的誤擋：本機版把重複的 B 併掉、整理模型照原話補回來；數量還綁著同一樣東西就可以換位置；
    /// 只把「我們」挪到前面不是對調；同一個值緊接著再說一次；改口先重提是哪一個（「不對，開會是四點」）；「B1」＝負一樓。
    /// 同樣的放寬不能放掉真的翻轉、換主人。
    func testHarmlessRewritesFoundInRoundTwoPass() {
        let fine: [(String, String)] = [
            ("開會是星期三不是星期四我要出差", "開會是星期三，不是星期四；星期四我要出差。"),
            ("開會是星期三不是星期四我要出差", "開會是星期三，不是星期四，星期四我要出差。"),
            ("寄的是混音版不是母帶版還沒做完", "寄的是混音版，不是母帶版；母帶版還沒做完。"),
            ("要調的是左聲道不是右聲道沒問題", "要調的是左聲道，不是右聲道；右聲道沒問題。"),
            ("兩杯拿鐵，一杯美式", "一杯美式，兩杯拿鐵"),
            ("我想要一杯咖啡跟一個蛋糕", "我想要一個蛋糕跟一杯咖啡。"),
            ("如果明天下雨我們就改到室內", "我們明天如果下雨就改到室內。"),
            ("我要的是三點不是四點，三點比較好，四點我有會", "我要的是3點，不是4點，比較好；4點我有會。"),
            ("三點開會，五點吃飯，不對，開會是四點", "4:00開會，5點吃飯"),
            ("三點開會，五點吃飯，不對，開會是四點", "4:00開會，五點吃飯。"),
            ("負一樓停車場", "B1停車場")
        ]
        for (original, cleaned) in fine {
            XCTAssertTrue(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
        let wrong: [(String, String)] = [
            ("開會是星期三不是星期四我要出差", "開會是星期四；星期四我要出差。"),
            ("寄的是混音版不是母帶版還沒做完", "寄的是母帶版；母帶版還沒做完。"),
            ("兩杯拿鐵，一杯美式", "兩杯美式，一杯拿鐵"),
            ("我想要一杯咖啡跟兩個蛋糕", "我想要兩杯咖啡跟一個蛋糕。"),
            ("三點開會，五點吃飯，不對，開會是四點", "4:00開會，3點吃飯"),
            ("負一樓停車場", "1樓停車場")
        ]
        for (original, cleaned) in wrong {
            XCTAssertFalse(relaxed(original, cleaned), "\(original) → \(cleaned)")
        }
    }

    func testQ4SubstitutionStopsAtTwentyFivePercentOfSourceCharacters() {
        // 來源 8 個實詞 → 2/8 = 25%，兩個字剛好用完額度。
        let atCap = ("悠悠卡記得先除值", "悠遊卡記得先儲值")
        XCTAssertTrue(
            CleanupFidelity.preservesContent(original: atCap.0, cleaned: atCap.1),
            "2 substitutions in 8 source characters is exactly the 25% cap：\(reason(atCap.0, atCap.1))"
        )
        // 同一個 8 字來源、第 3 個同音替換就超過 25%。
        let overCap = ("悠悠卡元山站除值", "悠遊卡圓山站儲值")
        XCTAssertFalse(
            CleanupFidelity.preservesContent(original: overCap.0, cleaned: overCap.1),
            "3 substitutions in 8 source characters exceeds the 25% cap"
        )
    }

    // MARK: - 2026-10-23 FX-7：wave 2 交叉審查（codex-adv）找到的五類漏網（V1–M4 在這裡，L5 條列在 DeterministicStructureTests）
    // 每一組都同時列「要擋」與「要放行」：誤擋跟漏擋一樣是缺陷。Kotlin CleanupFidelityTest 同名測試是同一批句子。

    /// FX-7 V1：版本號／點分識別碼每一段照字串比，「2.10」不等於「2.1」。算版本的：兩個點以上（7.10.4、192.168.1.10）、
    /// 前面是 版本／版／V／v／version／ver／iOS／macOS／Android／build、後面接「版」、同一個子句提到版本，
    /// 或說出來連著三段以上（「七點一零點四」）。一般數值的小數尾零照舊可以拿掉（3.50 元＝3.5 元、1.50 倍＝1.5 倍）。
    static let fx7VersionsWrong: [(String, String)] = [
        ("請安裝版本2.10，這個版本比較穩定", "請安裝版本2.1，這個版本比較穩定"),
        ("升級到7.10.4", "升級到7.1.4"),
        ("版本V2.10上線了", "版本V2.1上線了。"),
        ("升級到iOS 17.10", "升級到iOS 17.1。"),
        ("升級到macOS 15.10", "升級到 macOS 15.1"),
        ("IP是192.168.1.10", "IP是192.168.1.1"),
        ("build 3.10先上", "build 3.1先上。"),
        ("請大家安裝新的2.10版，比較穩定", "請大家安裝新的 2.1 版，比較穩定。"),
        ("請安裝版本二點一零，這個版本比較穩定", "請安裝版本2.1，這個版本比較穩定。"),
        ("升級到iOS十七點一零", "升級到 iOS 17.1。"),
        ("這首歌的音場用七點一零點四來做混音", "這首歌的音場用 7.1.4 來做混音。")
    ]
    static let fx7VersionsFine: [(String, String)] = [
        ("請安裝版本2.10，這個版本比較穩定", "請安裝版本 2.10，這個版本比較穩定。"),
        ("升級到7.10.4", "升級到 7.10.4。"),
        ("請大家安裝新的2.10版，比較穩定", "請大家安裝新的 2.10 版，比較穩定。"),
        ("價格是3.50元", "價格是3.5元。"),
        ("音量調到1.50倍", "音量調到1.5倍。"),
        ("這個版本要3.50元", "這個版本要3.5元。"),
        ("請安裝版本二點一零，這個版本比較穩定", "請安裝版本 2.10，這個版本比較穩定。"),
        ("升級到iOS十七點一零", "升級到 iOS 17.10。"),
        ("這首歌的音場用七點一零點四來做混音", "這首歌的音場用 7.10.4 來做混音。"),
        ("這首歌的音場用七點一點四來做混音", "這首歌的音場用 7.1.4 來做混音。"),
        ("音量調到一點五零倍", "音量調到 1.5 倍。"),
        ("音量調到一點五零倍", "音量調到 1.50 倍。"),
        ("版本號是1.0.8", "版本號是 1.0.8。")
    ]

    func testFx7VersionsAndDottedIdentifiersKeepEveryComponent() {
        for (original, cleaned) in Self.fx7VersionsWrong {
            XCTAssertFalse(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: Normalizer.normalizeNumbers(original),
                                                                 cleaned: Normalizer.normalizeNumbers(cleaned)), "數值：\(original) → \(cleaned)")
        }
        for (original, cleaned) in Self.fx7VersionsFine {
            XCTAssertTrue(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
        }
        // 照原樣（只補空白、句號）的版本號兩個把關都放行。
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "請安裝版本2.10，這個版本比較穩定", cleaned: "請安裝版本 2.10，這個版本比較穩定。"))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "升級到7.10.4", cleaned: "升級到 7.10.4。"))
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "請大家安裝新的2.10版，比較穩定", cleaned: "請大家安裝新的 2.10 版，比較穩定。"))
    }

    /// FX-7 R2：輸出裡重複的數值要有原文的根據——原文在那裡本來就說了兩次，或重複的是同一個主人（「預算100元，預算100元」）。
    /// 把「訂金200元」改成「訂金100元」再補一個「合計200元」＝換了主人，要擋；數值的主人與次數都要照原文。
    static let fx7RepeatsWrong: [(String, String)] = [
        ("預算100元，訂金200元", "預算100元，訂金100元，合計200元"),
        ("預算100元，訂金200元", "預算100元，訂金100元。"),
        ("預算100元訂金200元", "預算100元訂金100元合計200元")
    ]
    static let fx7RepeatsFine: [(String, String)] = [
        ("預算100元，訂金200元", "預算100元，訂金200元。"),
        ("預算100元，訂金200元", "預算100元，預算100元，訂金200元。"),
        ("預算100元，訂金100元", "預算100元，訂金100元。"),
        ("預算100元，訂金100元", "預算和訂金都是100元。"),
        ("三點開會，五點吃飯", "三點開會，三點開會，五點吃飯。"),
        // 「下午」「星期」是數值自己的一部分，不是主人：照原話補回被併掉的重複照樣放行。
        ("開會是下午三點不是下午四點我有會", "開會是下午三點，不是下午四點；下午四點我有會。"),
        ("開會是星期三不是星期四我要出差", "開會是星期三，不是星期四；星期四我要出差。")
    ]

    func testFx7RestoredRepeatsNeedSourceEvidence() {
        for (original, cleaned) in Self.fx7RepeatsWrong {
            XCTAssertFalse(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.reordersNumberValues(original: "預算100元，訂金200元", cleaned: "預算100元，訂金100元，合計200元"),
                      "數值檢查本身就要擋（不靠別的檢查碰巧擋到）")
        for (original, cleaned) in Self.fx7RepeatsFine {
            XCTAssertTrue(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "預算100元，訂金200元", cleaned: "預算100元，訂金200元。"))
    }

    /// FX-7 R3：名字在別處又出現一次（「王經理明天休假」）時，誰對誰對調照樣要擋——錨點逐個出現位置配對，不再因為重複就丟掉。
    static let fx7RolesWrong: [(String, String)] = [
        ("王經理要把合約寄給李律師，王經理明天休假", "李律師要把合約寄給王經理，王經理明天休假"),
        ("王經理要把合約寄給李律師，王經理明天休假", "李律師要把合約寄給王經理，王經理明天休假。"),
        ("小陳把報告交給小林，小陳下午請假", "小林把報告交給小陳，小陳下午請假。"),
        ("他把鑰匙給了她，他晚上才回來", "她把鑰匙給了他，他晚上才回來。")
    ]
    static let fx7RolesFine: [(String, String)] = [
        ("王經理要把合約寄給李律師，王經理明天休假", "王經理要把合約寄給李律師，王經理明天休假"),
        ("王經理要把合約寄給李律師，王經理明天休假", "王經理要把合約寄給李律師，王經理明天休假。"),
        ("王經理要把合約寄給李律師，王經理明天休假", "王經理明天休假，要把合約寄給李律師。"),
        ("小陳把報告交給小林，小陳下午請假", "小陳把報告交給小林，小陳下午請假。"),
        ("小陳把報告交給小林，小陳下午請假", "小陳把報告交給小林，下午請假。"),
        ("小陳把報告交給小林，小陳下午請假", "小陳下午請假，報告交給小林。")
    ]

    func testFx7RoleSwapsAreCaughtWhenANameRepeats() {
        for (original, cleaned) in Self.fx7RolesWrong {
            XCTAssertTrue(CleanupFidelity.swapsAroundSharedMiddle(original: Normalizer.normalizeNumbers(original),
                                                                  cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertFalse(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
        }
        for (original, cleaned) in Self.fx7RolesFine {
            XCTAssertFalse(CleanupFidelity.swapsAroundSharedMiddle(original: Normalizer.normalizeNumbers(original),
                                                                   cleaned: Normalizer.normalizeNumbers(cleaned)), "\(original) → \(cleaned)")
            XCTAssertTrue(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.preservesContent(original: "王經理要把合約寄給李律師，王經理明天休假", cleaned: "王經理要把合約寄給李律師，王經理明天休假。"))
    }

    /// FX-7 M4：減號後面隔了空白還是負號。U+2212「−」、全形「－」一律是；半形「-」緊接在非空白字後面、再隔空白接數字也是。
    /// 行首的「- 」是項目符號、數字之間的「3 - 5」是區間，都不是負號。
    static let fx7SignsWrong: [(String, String)] = [
        ("目標響度是− 14 LUFS，請照這個輸出", "目標響度是14 LUFS，請照這個輸出"),
        ("目標響度是14 LUFS，請照這個輸出", "目標響度是− 14 LUFS，請照這個輸出"),
        ("目標響度是−14 LUFS，請照這個輸出", "目標響度是14 LUFS，請照這個輸出。"),
        ("目標響度是－ 14 LUFS", "目標響度是14 LUFS"),
        ("目標響度是- 14 LUFS", "目標響度是14 LUFS"),
        ("響度是 − 14 LUFS", "響度是 14 LUFS")
    ]
    static let fx7SignsFine: [(String, String)] = [
        ("目標響度是− 14 LUFS，請照這個輸出", "目標響度是 -14 LUFS，請照這個輸出。"),
        ("目標響度是- 14 LUFS", "目標響度是 -14 LUFS"),
        ("目標響度是－ 14 LUFS", "目標響度是 -14 LUFS。"),
        ("響度是 − 14 LUFS", "響度是 -14 LUFS"),
        ("大概3 - 5天", "大概3-5天"),
        ("大概3 - 5天", "大概 3 - 5 天。"),
        ("待辦：\n- 14號交報告\n- 15號開會", "待辦：\n14號交報告\n15號開會")
    ]

    func testFx7MinusSignFollowedBySpacesIsStillASign() {
        for (original, cleaned) in Self.fx7SignsWrong {
            XCTAssertFalse(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.introducesNumberValues(original: Normalizer.normalizeNumbers(original),
                                                                 cleaned: Normalizer.normalizeNumbers(cleaned)), "數值：\(original) → \(cleaned)")
        }
        for (original, cleaned) in Self.fx7SignsFine {
            XCTAssertTrue(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.introducesNumberValues(original: Normalizer.normalizeNumbers(original),
                                                                  cleaned: Normalizer.normalizeNumbers(cleaned)), "數值：\(original) → \(cleaned)")
        }
    }

    /// FX-7 單元測試的全部句對：GoldenExportTests 匯出 fidelity.json（連同 benchmarks/fx-seven-golden-corpus.tsv），Kotlin 逐條比對。
    static var fx7Pairs: [(String, String)] {
        fx7VersionsWrong + fx7VersionsFine + fx7RepeatsWrong + fx7RepeatsFine + fx7RolesWrong + fx7RolesFine + fx7SignsWrong + fx7SignsFine
    }

    /// FX-9：把關拿掉行首清單編號時，把開頭的小數（「3.5元」的「3.」、「1.1 ms」的「1.」）和開頭的一串數字（「三、一百」的「三、」）
    /// 也當編號拿掉了——寬鬆把關原文剩「5元」、輸出還是「3.5元」，忠實照抄被擋；嚴格把關兩邊都剩「5元」，「3.5元→4.5元」反而放行。
    /// 編號後面直接接數字（中間沒有空白）就是數值的一部分。原文＝本機版第一次貼上的字（「十點五 ms」→「10.5 ms」、「三、一 ms」→「三、1 ms」）。
    static let fx9LeadingNumbersFine: [(String, String)] = [
        ("3.5元的咖啡", "3.5元的咖啡。"),
        ("3.5元", "3.5元。"),
        ("3.5元的咖啡很好喝", "3.5元的咖啡很好喝"),
        ("3.5元的咖啡很好喝", "3.5元的咖啡，很好喝。"),
        ("2.10版比較穩定", "2.10版比較穩定"),
        ("1.5倍速度比較好", "1.5倍速度比較好。"),
        ("1.1 ms", "1.1 ms。"),
        ("10.5 ms", "10.5 ms。"),
        ("8.3倍", "8.3倍"),
        ("三、一百", "三、一百。"),
        ("五、三萬就好", "五、三萬就好"),
        ("三、1 ms", "三、1 ms。"),
        ("一、一萬", "一、一萬。")
    ]
    /// 開頭的數值被改掉，兩個把關都要擋。
    static let fx9LeadingNumbersWrong: [(String, String)] = [
        ("3.5元", "4.5元"),
        ("2.10版比較穩定", "3.10版比較穩定"),
        ("1.1 ms", "2.1 ms"),
        ("8.3倍", "9.3倍"),
        ("3.5元的咖啡", "4.5元的咖啡。"),
        ("3.5元的咖啡", "5.3元的咖啡。"),
        ("3.5元的咖啡", "35元的咖啡。"),
        ("1.1 ms", "11 ms"),
        ("2.10版比較穩定", "2.1版比較穩定"),
        ("3.5元的咖啡很好喝", "4.5元的咖啡很好喝"),
        ("1.5倍速度比較好", "2.5倍速度比較好"),
        ("三、一百", "四、一百。"),
        ("五、三萬就好", "五、四萬就好"),
        ("一、3:00開會", "二、3:00開會。")
    ]
    /// 真的清單編號（後面隔空白、或接數字以外的字）照舊拿掉再比：輸出拿掉或加上編號都放行。
    static let fx9ListPrefixesFine: [(String, String)] = [
        ("1. 3:00開會", "3:00開會。"),
        ("二、報告寫完", "報告寫完。"),
        ("- 報告寫完", "報告寫完。"),
        ("報告寫完", "1. 報告寫完")
    ]

    func testFx9LeadingNumbersAreValuesNotListNumbers() {
        for (original, cleaned) in Self.fx9LeadingNumbersFine {
            XCTAssertTrue(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.reordersNumberValues(original: Normalizer.normalizeNumbers(original),
                                                                cleaned: Normalizer.normalizeNumbers(cleaned)), "數值先後：\(original) → \(cleaned)")
        }
        for (original, cleaned) in Self.fx9LeadingNumbersWrong {
            XCTAssertFalse(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertFalse(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
        }
        for (original, cleaned) in Self.fx9ListPrefixesFine {
            XCTAssertTrue(relaxed(original, cleaned), "relaxed：\(original) → \(cleaned)")
            XCTAssertTrue(CleanupFidelity.preservesContent(original: original, cleaned: cleaned), "strict：\(original) → \(cleaned)")
        }
    }

    /// FX-9 單元測試的全部句對：GoldenExportTests 匯出到 fidelity.json（連同 benchmarks/fx-nine-golden-corpus.tsv），Kotlin 逐條比對。
    static var fx9Pairs: [(String, String)] {
        fx9LeadingNumbersFine + fx9LeadingNumbersWrong + fx9ListPrefixesFine
    }

    // MARK: - FX-13 G1：數字句掉一個值（沒有明講改口）＝無聲的資料遺失

    /// FX-13 oracle 的 G1／G-keep／G-guard 三組句對（fx-thirteen-oracle.tsv 前三段）。
    /// `fx13MustReject` 是 oracle 的全部 G1（兩道把關都要擋，其中 5 句本來就被別條規則擋到，
    /// 由 SmartCleanupTests 端到端驗）；`fx13Drops` 是這條新規則自己擋的那 14 句。
    static let fx13MustReject: [(String, String)] = [
        ("100，200", "100"), ("100，200", "200"), ("一萬二，兩萬一", "12,000"),
        ("100，200，300", "100，300"), ("100 200", "100"), ("100、200", "100"),
        ("100和200", "100"), ("100跟200", "200"), ("3.5，4.5", "3.5"),
        ("1200，2400", "2400"), ("100，200", "100。"), ("一百，兩百", "100"),
        ("12,000，21,000", "12,000"), ("100，100", "100"), ("5，6，7", "5，7"),
        ("100，200元", "100元"), ("100元，200元", "200元"), ("3:00，4:00", "3:00"),
        ("2026，2027", "2026")
    ]
    static let fx13Drops: [(String, String)] = [
        ("100，200", "100"), ("100，200", "200"), ("一萬二，兩萬一", "12,000"),
        ("100，200，300", "100，300"), ("100 200", "100"), ("100、200", "100"),
        ("1200，2400", "2400"), ("100，200", "100。"), ("12,000，21,000", "12,000"),
        ("100，100", "100"), ("100，200元", "100元"), ("100元，200元", "200元"),
        ("3:00，4:00", "3:00"), ("2026，2027", "2026")
    ]
    static let fx13MustAccept: [(String, String)] = [
        ("100，200", "100，200。"), ("100，200", "100、200"), ("一萬二，兩萬一", "12,000，21,000"),
        ("100 200", "100 200"), ("一萬二", "12,000"), ("12000", "12,000"),
        ("一萬不對兩萬", "兩萬。"), ("一萬，不對，兩萬", "兩萬。"), ("一萬我是說兩萬", "兩萬。"),
        ("1200，不對，12000", "12000。"), ("1200不對不對12000", "12000。"),
        ("1200，我是說，12000", "12000。"), ("1200啊不對12000", "12000。"),
        ("12,000，不對，兩萬一", "兩萬一。"), ("12,000，我是說，一萬二", "12,000"),
        ("100，200，300", "100，200，300。"), ("3.5，4.5", "3.5、4.5")
    ]
    /// 有實詞的句子不在這條規則的範圍內，照原判定（放行的照放行）。
    static let fx13WithWords: [(String, String)] = [
        ("預算100，運費200", "預算100"), ("三點五萬塊", "35,000塊"),
        ("我要100個，不對，200個", "我要200個。")
    ]

    func testNumberOnlyTextMustNotDropAValue() {
        for (original, cleaned) in Self.fx13Drops {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        // 連字號分段重新寫法不算掉（值只是換了分段的樣子）。
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "2026年10月22日", cleaned: "2026-10-22"))
        // 連字號拆開的一個輸出值對上前面的連續幾格。
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "0912，345678", cleaned: "0912-345678"))
    }

    /// 換一種寫法不算掉，值一個不少就放行；明講改口掉的才放行。
    func testNumberOnlyTextKeepsEveryValueUnlessCorrected() {
        for (original, cleaned) in Self.fx13MustAccept {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: "100，不對，200", cleaned: "100"),
                      "改口後的新值也沒留，不算改口")
        // 改口後面還是同一個值（「12,000，我是說，一萬二」→「12,000」）本來就只留一個，不算掉值。
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "12000，我是說，12000", cleaned: "12000"))
    }

    /// 有實詞的句子（預算／運費／我要／塊）維持原判定，不在這條規則的範圍。
    func testTextsWithWordsKeepTheBaseDecision() {
        for (original, cleaned) in Self.fx13WithWords {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "有實詞＝不歸這條管：\(original) → \(cleaned)")
        }
    }

    /// FX-13 的全部句對：GoldenExportTests 匯出到 fidelity.json，Kotlin 逐條比對。
    static var fx13Pairs: [(String, String)] {
        fx13MustReject + fx13MustAccept + fx13WithWords
    }

    /// FX-13 修復 R1：輸出的連字號分段可以各自配一格——「100～200」→「100-200」兩個值都還在，不算掉值；
    /// 真的少一個還是擋（「100～200」→「100」）。日期與電話重新分段也不算掉。
    func testRangeAndHyphenRewriteKeepsEveryValue() {
        for (original, cleaned) in [("100～200", "100-200"), ("100，200", "100-200"),
                                    ("2026年10月22日", "2026-10-22"), ("0912，345678", "0912-345678"),
                                    ("100，200", "100、200")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("100～200", "100"), ("100～200", "100-300"),
                                    ("2026年10月22日", "2026-10"), ("0912，345678", "0912")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
    }

    /// FX-13 修復 R1：年、圓、分鐘這些必要的單位字算數字句的一部分，掉一個值就要擋；
    /// 忠實的排版與改寫照放行；實詞（預算、運費、我要）還是不歸這條規則管。
    func testUnitsCountAsNumberOnlyText() {
        for (original, cleaned) in [("2026年，2027年", "2026年"), ("100圓，200圓", "100圓"),
                                    ("30分鐘，40分鐘", "30分鐘"), ("2026年，2027年", "2027年"),
                                    ("10月，11月", "10月"), ("3點，4點", "3點")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("2026年，2027年", "2026年、2027年"), ("2026年，2027年", "2026年 2027年"),
                                    ("100圓，200圓", "100圓、200圓"), ("30分鐘，40分鐘", "30分鐘、40分鐘"),
                                    ("2026年，2027年", "2026年、2027年。")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "預算100圓，運費200圓", cleaned: "預算100圓"),
                       "有實詞＝不歸這條管")
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "我要100個，不對，200個", cleaned: "我要100個"),
                       "有實詞＝不歸這條管")
    }

    // MARK: - FX-13 修復 R2：名額獨佔、單位詞不拆實詞、英文單位認得出來

    /// FX-13 修復 R2 ①：輸出的名額是獨佔的。整串與另一種讀法（「1.0」的兩種讀法）是同一個名額的兩種讀法，
    /// 用掉一種另一種就不能再用；連字號的值要嘛當整串、要嘛當它每一段，不能兩種都來。
    /// 名額被重複使用＝其實少了一個值，必須擋。
    func testOutputCapacityIsExclusive() {
        for (original, cleaned) in [("100-200，100", "100-200"), ("1，1.0", "1.0")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        // 名額沒有被重複使用時照放行：連字號分段各自配一格、電話與日期重新分段。
        for (original, cleaned) in [("100～200", "100-200"), ("100，200", "100-200"),
                                    ("2026年10月22日", "2026-10-22"), ("0912，345678", "0912-345678")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
    }

    /// FX-13 修復 R2 ②：單位要看完整的單位詞，不能把單一字分開看（「條件」＝條＋件），
    /// 有實詞的句子照原判定，不歸這條規則管；真正的單位詞還是算數字句的一部分。
    func testUnitDomainDoesNotDecomposeWords() {
        for (original, cleaned) in [("條件100，200", "條件100"), ("預算100，運費200", "預算100"),
                                    ("我要100個，不對，200個", "我要100個")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "有實詞＝不歸這條管：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("2026年，2027年", "2026年"), ("100圓，200圓", "100圓"),
                                    ("30分鐘，40分鐘", "30分鐘")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        // 單位詞跟改口詞黏在一起還是算數字句（「三點不對應該是四點」）：改口後的新值沒留就要擋。
        XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: "三點不對應該是四點", cleaned: "三點。"),
                      "改口後的新值沒留，不算改口")
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "三點不對應該是四點", cleaned: "四點。"),
                       "明講改口而且新值有留")
    }

    /// FX-13 修復 R2 ③：英文的單位要認得出來（標點分開的「kg，kg」也算），但不能把實詞當單位。
    func testEnglishUnitsAreRecognizedWithoutAdmittingWords() {
        for (original, cleaned) in [("100kg，200kg", "100kg"), ("100 kg，200 kg", "100 kg")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("100kg，200kg", "100kg，200kg"), ("100 kg，200 kg", "100 kg，200 kg")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        // 英文的實詞不是單位：有實詞的句子照原判定。
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "100apple，200apple", cleaned: "100apple"),
                       "英文實詞不該當單位")
    }

    // MARK: - FX-13 修復 R3：重複的一段只吃一次；必要的完整單位詞（公里／公分／小時…）

    /// FX-13 修復 R3 ①：輸出的連字號分段可以各自配一格，同樣的值出現兩次也只配掉一段——
    /// 「100，100」→「100-100」兩個值都還在，不算掉值；名額還是獨佔的（「100-200，100」照樣擋）。
    func testDuplicatePartsConsumeOneOccurrence() {
        for (original, cleaned) in [("100～100", "100-100"), ("100，100", "100-100")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("100-200，100", "100-200"), ("1，1.0", "1.0")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
    }

    /// FX-13 修復 R3 ②：必要的完整單位詞（公里、公分、毫米、小時、個小時、毫秒）算數字句的一部分，
    /// 掉一個值就要擋；忠實的清單照放行；實詞（條件）還是不歸這條規則管。
    func testCompoundUnitsCountAsNumberOnlyText() {
        for (original, cleaned) in [("3公里，4公里", "3公里"), ("3公分，4公分", "3公分"),
                                    ("10小時，20小時", "10小時"), ("3個小時，4個小時", "3個小時"),
                                    ("3毫米，4毫米", "3毫米"), ("100毫秒，200毫秒", "100毫秒"),
                                    ("100kg，200kg", "100kg")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("3公里，4公里", "3公里、4公里"), ("10小時，20小時", "10小時、20小時"),
                                    ("100kg，200kg", "100kg，200kg")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "條件100，200", cleaned: "條件100"),
                       "有實詞＝不歸這條管")
    }

    // MARK: - FX-13 修復 R4：單獨的「萬」不是數值，沒有值可掉

    /// FX-13 修復 R4：單獨的「萬」（「三 萬 塊」裡的萬）本來就沒有值，不是掉值。
    /// 原文與輸出一樣（連句號都一樣）要放行；真的有值不見了照樣擋。
    func testStandaloneMagnitudeIsNotADroppedValue() {
        for (original, cleaned) in [("萬 塊", "萬 塊"), ("萬 塊", "萬 塊。"),
                                    ("一點一 萬 塊", "一點一 萬 塊"), ("一點一 萬 塊", "一點一 萬 塊。"),
                                    ("一、二 萬 塊", "一、二 萬 塊"), ("第二點五 萬 塊", "第二點五 萬 塊"),
                                    ("一點半三 萬 塊", "1:30三 萬 塊"), ("一點半三 萬 塊", "1:30三 萬 塊。"),
                                    ("週五一點半三 萬 塊", "週五1:30三 萬 塊")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        // 單獨的「萬」在旁邊時，真的值不見了還是要擋。
        for (original, cleaned) in [("萬 塊，100 塊", "萬 塊"), ("萬 塊，200 塊", "萬 塊"),
                                    ("三 萬 塊，100 塊", "三 萬 塊")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
    }

    // MARK: - FX-13 修復 R5：數字清單裡的頓號不能把值當成清單編號

    /// FX-13 修復 R5：掉值這條規則掃描時，「100、一百」裡的 100 是值不是清單編號——
    /// 原文用逗號、輸出用頓號，兩個值都還在，不算掉值；真的有值不見了照樣擋；
    /// 隔空格的清單編號（「1. 一百」）照舊是編號，只有一個值。
    func testNumericListPunctuationKeepsValues() {
        for (original, cleaned) in [("100，一百", "100、一百。"), ("100 一百", "100、一百"),
                                    ("100；一百", "100、一百。"), ("100，兩百", "100、兩百。"),
                                    ("12000，一百", "12000、一百"), ("100，一百", "100，一百。"),
                                    ("7，一百", "7、一百。")] {
            XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                           "不該算掉值：\(original) → \(cleaned)")
        }
        for (original, cleaned) in [("100，一百", "100"), ("100、一百", "100"), ("100，一百", "100。")] {
            XCTAssertTrue(CleanupFidelity.dropsNumberValues(original: original, cleaned: cleaned),
                          "掉值沒擋：\(original) → \(cleaned)")
        }
        XCTAssertFalse(CleanupFidelity.dropsNumberValues(original: "1. 一百", cleaned: "100"),
                       "隔空格的清單編號不是值")
    }
}
