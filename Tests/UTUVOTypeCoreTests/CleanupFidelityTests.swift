import XCTest
@testable import UTUVOTypeCore

final class CleanupFidelityTests: XCTestCase {
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
        XCTAssertTrue(CleanupFidelity.preservesContent(
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
}
