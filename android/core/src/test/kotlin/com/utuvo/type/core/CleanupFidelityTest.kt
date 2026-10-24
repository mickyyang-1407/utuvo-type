package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CleanupFidelityTest {
    @Test
    fun rejectsSynonymAndContentWordLossFromTicket() {
        assertFalse(CleanupFidelity.preservesContent("然後送到清風教室去示範", "之後送往清風教室進行示範"))
        assertFalse(CleanupFidelity.preservesContent("教室改成四樓，另外教材我會帶過去", "教室四樓，教材我會帶過去"))
    }

    @Test
    fun allowsOnlyFillerAndExplicitCorrectionRemoval() {
        assertTrue(CleanupFidelity.preservesContent("嗯那個就是說我覺得這個這個方案還可以", "我覺得這個方案還可以"))
        assertTrue(CleanupFidelity.preservesContent("我想明天，不對，後天寄", "我想後天寄"))
        assertFalse(CleanupFidelity.preservesContent("了解，了解你的意思", "了解你的意思"))
    }

    @Test
    fun chineseNumberCorrectionsStuttersAndFullwidthDigits() {
        assertTrue(CleanupFidelity.preservesContent("我們約三點開會，不對，四點", "我們約四點開會"))
        assertTrue(CleanupFidelity.preservesContent("我我想要這個", "我想要這個"))
        assertFalse(CleanupFidelity.preservesContent("測試１", "測試"))
    }

    @Test
    fun contextualFillersMayBeKeptRemovedOrAdded() {
        val opening = "嗯,我覺得那個,就是,這個 low-end 還可以再收一點。"
        assertTrue(CleanupFidelity.preservesContent(opening, opening))
        assertTrue(CleanupFidelity.preservesContent(opening, "我覺得這個 low-end 還可以再收一點。"))

        val connector = "嗯嗯,然後就是說,我這邊沒有收到你的檔案。"
        assertTrue(CleanupFidelity.preservesContent(connector, connector))
        assertTrue(CleanupFidelity.preservesContent(connector, "我這邊沒有收到你的檔案。"))
        assertTrue(CleanupFidelity.preservesContent("我覺得可以", "嗯嗯，我覺得可以"))
        assertTrue(CleanupFidelity.preservesContent("我覺得可以", "我覺得，就是，可以"))
        assertTrue(CleanupFidelity.preservesContent("對對，我覺得可以", "我覺得可以"))
        assertTrue(CleanupFidelity.preservesContent("我覺得可以", "對對，我覺得可以"))
    }

    @Test
    fun meaningfulConnectorsAndDemonstrativesMustStay() {
        assertTrue(CleanupFidelity.preservesContent("做完然後寄給他", "做完然後寄給他"))
        assertFalse(CleanupFidelity.preservesContent("做完然後寄給他", "做完寄給他"))
        assertFalse(CleanupFidelity.preservesContent("他就是負責人", "他負責人"))
        assertFalse(CleanupFidelity.preservesContent("我覺得這個方案可以", "我覺得方案可以"))
    }

    @Test
    fun repeatedThenMayStayCollapseOrBeRemovedAtSentenceStart() {
        val original = "然後然後寄給他"
        assertTrue(CleanupFidelity.preservesContent(original, original))
        assertTrue(CleanupFidelity.preservesContent(original, "然後寄給他"))
        assertTrue(CleanupFidelity.preservesContent(original, "寄給他"))
        assertTrue(CleanupFidelity.preservesContent("做完然後然後寄給他", "做完然後寄給他"))
        assertFalse(CleanupFidelity.preservesContent("做完然後然後寄給他", "做完寄給他"))
    }

    @Test
    fun rejectionReasonNamesMissingSourceContent() {
        assertTrue(CleanupFidelity.rejectionReason("做完然後寄給他", "做完寄給他")?.contains("然後") == true)
    }

    @Test
    fun allowsPunctuationListAndNumberFormattingOnly() {
        assertTrue(CleanupFidelity.preservesContent(
            "明天下午三點開會，後天下午四點開會",
            "1. 明天下午3點開會\n2. 後天下午4點開會。"
        ))
        assertTrue(CleanupFidelity.preservesContent(
            "一、明天下午三點開會\n二、後天下午四點開會",
            "1. 明天下午3點開會\n2. 後天下午4點開會。"
        ))
        assertFalse(CleanupFidelity.preservesContent("今天下午三點開會", "今天下午4點開會"))
        assertFalse(CleanupFidelity.preservesContent("三個人明天出發", "明天三個人出發"))
    }

    @Test
    fun promptCandidateV2ProbeOutputsPassTheFidelityGate() {
        val cases = listOf(
            "嗯,我覺得那個,就是,這個low-end還可以再收一點。" to "我覺得這個 low-end 還可以再收一點。",
            "然後然後,呃,高頻好像有點毛,你再聽一下。" to "高頻好像有點毛，你再聽一下。",
            "嗯嗯,然後就是說,我這邊沒有收到你的檔案。" to "我這邊沒有收到你的檔案。",
            "我們約3點開會,不對,4點,地點在3樓" to "我們約4點開會，地點在3樓。",
            "黨名叫做Final V3,啊不對,是Final V4。" to "黨名叫做Final V4。",
            "幫我轉寄給小雅跟小博,不是,是小雅跟小潘。" to "幫我轉寄給小雅跟小潘。",
            "接下來有三件事,第一是把Low-End收乾淨,第二是把Delay收短,第三是重做母帶" to
                "接下來有三件事：\n1. 把 Low-End 收乾淨\n2. 把 Delay 收短\n3. 重做母帶",
            "今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明" to
                "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明",
            "那個Compressor的Ratio我建議設成2比1,不要讓它Pump。" to "Compressor的Ratio我建議設成2比1，不要讓它Pump。",
            "王老師好,這次上課的教室改成四樓,另外教材我會帶過去。" to
                "王老師好，這次上課的教室改成四樓，另外教材我會帶過去。"
        )

        cases.forEachIndexed { index, (source, output) ->
            assertTrue(
                CleanupFidelity.preservesContent(source, output),
                "Probe case ${index + 1} rejected: ${CleanupFidelity.rejectionReason(source, output)}"
            )
        }
    }

    @Test
    fun q2NumberedListConversionsAllowOnlyListMarkersAndItemConnectorsToDrop() {
        val s17 = "今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明"
        assertTrue(CleanupFidelity.preservesContent(
            s17,
            "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ))
        assertTrue(CleanupFidelity.preservesContent(
            s17,
            "今天的工作清單：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ), "The list-intro 是 and spoken ordinals may be omitted when replaced by numbering")

        assertTrue(CleanupFidelity.preservesContent(
            "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。",
            "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭"
        ))

        listOf("和", "以及", "跟").forEach { connector ->
            assertTrue(CleanupFidelity.preservesContent(
                "清單：播放器、耳機${connector}線材",
                "清單：\n1. 播放器\n2. 耳機\n3. 線材"
            ), "$connector may be omitted only at an emitted numbered-item boundary")
            assertTrue(CleanupFidelity.preservesContent(
                "播放器、耳機${connector}線材",
                "1. 播放器\n2. 耳機\n3. 線材"
            ), "Unmarked three-item lists may also replace the item connector")
        }

        assertTrue(CleanupFidelity.preservesContent(
            "今天有幾件事，首先，先確認檔案，第二，備份資料",
            "今天有幾件事：\n1. 先確認檔案\n2. 備份資料"
        ))
        assertFalse(CleanupFidelity.preservesContent(
            "今天的工作清單是,第一,更新文件,第二,備份資料",
            "今天的工作清單：更新文件，備份資料"
        ), "List-specific omissions are not allowed without numbered output")
    }

    @Test
    fun q2OverEditsRemainRejected() {
        assertFalse(CleanupFidelity.preservesContent("是不是該把主唱推到前面一點？", "該把主唱推到前面一點嗎？"))
        assertFalse(CleanupFidelity.preservesContent("上面做的", "上做"))
        assertFalse(CleanupFidelity.preservesContent("地點在3樓", "地點在三樓"))
        assertFalse(CleanupFidelity.preservesContent("教室改成四樓", "教室四樓"))

        listOf("另外", "對了", "總之").forEach { transition ->
            assertFalse(CleanupFidelity.preservesContent(
                "清單：先確認檔案，${transition}備份資料",
                "清單：\n1. 先確認檔案\n2. 備份資料"
            ), "$transition remains substantive even in numbered output")
        }
        assertFalse(CleanupFidelity.preservesContent("首先先確認檔案", "先確認檔案"))
    }

    @Test
    fun longRejectedParagraphUsesBoundedFidelityWork() {
        val original = "甲".repeat(2_000)
        val cleaned = "乙".repeat(2_000)
        repeat(2) { CleanupFidelity.rejectionReason(original, cleaned) }

        val start = System.nanoTime()
        val reason = CleanupFidelity.rejectionReason(original, cleaned)
        val elapsedMillis = (System.nanoTime() - start) / 1_000_000.0
        assertTrue(reason != null)
        assertTrue(elapsedMillis < 50, "2,000-character fidelity check took $elapsedMillis ms")
    }

    // MARK: - Q4 忠實度要放行「同音錯字修正」

    /** 真實拼音（不計聲調），只收本檔案用到的字。沒列到的字讀音＝null，一律不視為可替換。 */
    private val pinyin = mapOf(
        '元' to "yuan", '圓' to "yuan", '悠' to "you", '游' to "you", '遊' to "you", '除' to "chu", '儲' to "chu",
        '不' to "bu", '布' to "bu", '沒' to "mei", '梅' to "mei", '別' to "bie", '憋' to "bie",
        '未' to "wei", '味' to "wei", '一' to "yi", '衣' to "yi", '三' to "san", '傘' to "san",
        '零' to "ling", '鈴' to "ling", '他' to "ta", '她' to "ta", '你' to "ni", '妳' to "ni",
        '核' to "he", '對' to "dui", '確' to "que", '認' to "ren",
        '買' to "mai", '賣' to "mai", '买' to "mai", '卖' to "mai",
        '億' to "yi", '亿' to "yi", '意' to "yi", '兆' to "zhao", '照' to "zhao",
        '拾' to "shi", '石' to "shi", '佰' to "bai", '百' to "bai", '擺' to "bai",
        '仟' to "qian", '千' to "qian", '牽' to "qian",
        '搭' to "da", '達' to "da", '研' to "yan", '討' to "tao", '陶' to "tao", '器' to "qi"
    )
    private val readings = CjkReadingLookup { character -> pinyin[character] }

    private fun allows(original: String, cleaned: String): Boolean =
        CleanupFidelity.preservesContent(original, cleaned, readings)

    private fun reason(original: String, cleaned: String): String? =
        CleanupFidelity.rejectionReason(original, cleaned, readings)

    @Test
    fun q4AllowsSamePositionHomophoneTypoCorrections() {
        assertTrue(
            allows("我搭到元山站以後再換車", "我搭到圓山站以後再換車"),
            "元山→圓山"
        )
        assertTrue(
            allows("悠悠卡記得先除值", "悠遊卡記得先儲值"),
            "悠悠卡→悠遊卡、除值→儲值：" + reason("悠悠卡記得先除值", "悠遊卡記得先儲值")
        )
        assertTrue(
            allows(
                "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。",
                "我們約禮拜四下午三點在公司見，然後我搭到圓山站以後再換車，悠遊卡記得先儲值。"
            ),
            "orchestrator 實測的三個錯字合在整句裡也要放行"
        )
    }

    @Test
    fun q4StillRejectsSemanticCharacterSwaps() {
        // 否定詞互換：讀音相同但語意翻轉。
        assertFalse(allows("這個方案不可以今天就送", "這個方案布可以今天就送"), "不→布")
        assertFalse(allows("這個方案沒有問題", "這個方案梅有問題"), "沒→梅")
        assertFalse(allows("這個方案我們別亂改", "這個方案我們憋亂改"), "別→憋")
        assertFalse(allows("這件事我還未確認", "這件事我還味確認"), "未→味")
        // 數字字被換成同音字＝數值被改掉。
        assertFalse(allows("我們下午一點開會", "我們下午衣點開會"), "一→衣")
        assertFalse(allows("我們下午三點開會", "我們下午傘點開會"), "三→傘")
        assertFalse(allows("剩下的零件是零個", "剩下的零件是鈴個"), "零→鈴")
        // 人稱代名詞互換＝替使用者猜。
        assertFalse(allows("這份合約等他簽", "這份合約等她簽"), "他→她")
        assertFalse(allows("我要通知你明天到", "我要通知妳明天到"), "你→妳")
        // 整詞換成不同音的同義詞。
        assertFalse(allows("我要確認這個檔案", "我要核對這個檔案"), "確認→核對")
        // 增刪實詞。
        assertFalse(allows("教室改成四樓", "教室四樓"))
        assertFalse(allows("這個方案今天送", "這個新方案今天送"))
    }

    @Test
    fun q4RejectsAntonymAndMagnitudeHomophones() {
        // 反義同音字（買／賣）：讀音一樣但原意相反。
        assertFalse(allows("我要買這台車", "我要賣這台車"), "買→賣")
        assertFalse(allows("我要买这辆自行车", "我要卖这辆自行车"), "买→卖（简体）")
        // 數量級字：換掉＝數值被改一個數量級。（別用「五億元」這類片段——
        // Normalizer 會先把中文數字展開，測到的會變成數字比對而不是同音替換。）
        assertFalse(allows("這個億萬計畫", "這個意萬計畫"), "億→意")
        assertFalse(allows("這個亿万計畫", "這個意万計畫"), "亿→意（简体）")
        assertFalse(allows("這個兆頭不錯", "這個照頭不錯"), "兆→照")
        assertFalse(allows("我拾起那個包包", "我石起那個包包"), "拾→石")
        assertFalse(allows("花費三百佰元", "花費三百擺元"), "佰→擺")
        assertFalse(allows("花費三千仟元", "花費三千牽元"), "仟→牽")
    }

    @Test
    fun q4ShortSentencesStillGetOneSubstitution() {
        // 25% 的整數除法會讓 2–3 字短句歸零（2*25/100 = 0），一個字的修正就整個被擋掉。
        assertTrue(allows("除值", "儲值"), "除值→儲值：" + reason("除值", "儲值"))
        assertTrue(allows("元山", "圓山"), "元山→圓山：" + reason("元山", "圓山"))
        // 單字沒有餘裕，預算維持 0。
        assertFalse(allows("搭", "達"), "單字來源沒有替換預算")
    }

    @Test
    fun q4RemovesOptionalStutterBeforePairingHomophones() {
        assertTrue(
            allows("研討研討陶器", "研討陶器"),
            "研討研討陶器→研討陶器：" + reason("研討研討陶器", "研討陶器")
        )
        assertTrue(
            allows("悠悠卡記得先除值", "悠遊卡記得先儲值"),
            "悠悠卡→悠遊卡、除值→儲值：" + reason("悠悠卡記得先除值", "悠遊卡記得先儲值")
        )
    }

    @Test
    fun q4SubstitutionStopsAtTwentyFivePercentOfSourceCharacters() {
        // 來源 8 個實詞 → 2/8 = 25%，兩個字剛好用完額度。
        assertTrue(
            allows("悠悠卡記得先除值", "悠遊卡記得先儲值"),
            "2 substitutions in 8 source characters is exactly the 25% cap"
        )
        // 同一個 8 字來源、第 3 個同音替換就超過 25%。
        assertFalse(
            allows("悠悠卡元山站除值", "悠游卡圓山站儲值"),
            "3 substitutions in 8 source characters exceeds the 25% cap"
        )
    }

    @Test
    fun q4WithoutReadingsKeepsThePreviousStrictBehaviour() {
        assertFalse(
            CleanupFidelity.preservesContent("悠悠卡記得先除值", "悠遊卡記得先儲值"),
            "沒有注入讀音時維持原嚴格行為（fail-closed）"
        )
    }

    // 2026-10-22 cleanup-semantics-1：沒標點的改口（借用 Normalizer 的改口對齊），同 Swift CleanupFidelityTests。
    @Test
    fun unpunctuatedSelfCorrectionsPassTheStrictGate() {
        val cases = listOf(
            "取樣率用 48K不對是 96K。" to "取樣率用 96K。",
            "幫我轉寄給小雅跟小波不是，是小雅跟小潘。" to "幫我轉寄給小雅跟小潘。",
            "金額是 1200，不對是 12,000塊。" to "金額是 12000塊。",
            "金額是 1200不對是 12,000塊。" to "金額是 12,000塊。",
            "我們約禮拜三不對禮拜四開會" to "我們約禮拜四開會",
            "幫我轉寄給小雅跟小柏、不是，是小雅跟小潘、" to "幫我轉寄給小雅跟小潘。",
            "取樣率用 48K，不對，是 96K。" to "取樣率用 96K。",
            "四點不對不對三點" to "三點。",
        )
        for ((original, cleaned) in cases) {
            assertTrue(
                CleanupFidelity.preservesContent(original, cleaned),
                "$original → $cleaned：${CleanupFidelity.rejectionReason(original, cleaned)}",
            )
        }
        // FX-1 v2（C2）：把關看不出原本有沒有停頓，「不對」類只認值換值；直接拿原始逐字稿比會擋（同 Swift）。
        // 三個 app 都拿第一次貼上（已經改好成「檔名叫做Final V4」）來比，整理結果照樣放行。
        val finalFirst = SentenceMood.finish(Normalizer().normalize("檔名叫做Final V3,不對是Final下橫線V4").cleaned)
        assertEquals("檔名叫做Final V4", finalFirst)
        assertTrue(
            CleanupFidelity.preservesContent(finalFirst, "檔名叫做Final_V4"),
            "${CleanupFidelity.rejectionReason(finalFirst, "檔名叫做Final_V4")}",
        )
        assertTrue(CleanupFidelity.preservesContent("取樣率用 48K不對是 96K。", "取樣率用 48K不對是 96K。"))
        assertTrue(CleanupFidelity.preservesContent("我們約禮拜三，不是禮拜四開會。", "我們約禮拜三，不是禮拜四開會。"))
    }

    @Test
    fun reversalsContrastAndMisalignedCorrectionsStayRejected() {
        val cases = listOf(
            Triple("取樣率用四十八K不對是九十六K", "取樣率用四十八K。", "改口後反而留舊值"),
            Triple("我們約三點開會不對四點", "我們約三點開會。", "改口後反而留舊值"),
            Triple("取樣率用 48K不對是 96K。", "取樣率用 44K。", "換成第三個值"),
            Triple("我要的是三點不是四點", "我要的是四點。", "單獨的「不是」是對比"),
            Triple("取樣率是48K不是96K", "取樣率是96K。", "單獨的「不是」是對比"),
            Triple("這不是重點", "重點。", "否定不能拿掉"),
            Triple("我們約禮拜三，不是禮拜四開會。", "我們約禮拜四開會。", "「A，不是B」是對比"),
            Triple("我應該要去找 Claude Code 不對是要去搞 Codex", "我應該要去搞 Codex", "對不齊的改口只交給 Claude"),
        )
        for ((original, cleaned, label) in cases) {
            assertFalse(CleanupFidelity.preservesContent(original, cleaned), "$label：$original → $cleaned")
        }
    }

    // 2026-10-22 cleanup-semantics-v1：沒標點的「那個就是」與「恩」。
    @Test
    fun unpunctuatedDemonstrativeChainsAndEnSpellingAreOptional() {
        val cases = listOf(
            "我覺得那個就是這個low end可以再收一點" to "我覺得這個 low end 可以再收一點。",
            "，我覺得那個就是這個 low and可以再收一點" to "我覺得這個 low and 可以再收一點。",
            "我覺得那個嗯就是這個low end可以再收一點" to "我覺得這個 low end 可以再收一點。",
            "恩恩，然後就是說我這邊沒有收到你的檔案喔。" to "我這邊沒有收到你的檔案喔。",
        )
        for ((original, cleaned) in cases) {
            assertTrue(
                CleanupFidelity.preservesContent(original, cleaned),
                "$original → $cleaned：${CleanupFidelity.rejectionReason(original, cleaned)}",
            )
        }
        assertFalse(CleanupFidelity.preservesContent("那就是這個問題", "那問題。"))
        assertFalse(CleanupFidelity.preservesContent("我覺得那個就是重點", "我覺得重點。"), "「那個就是」後面不是另一個這個／那個＝實詞")
        assertFalse(CleanupFidelity.preservesContent("恩人很好", "人很好"), "恩人的恩不是贅詞")
        assertFalse(CleanupFidelity.preservesContent("感恩，謝謝", "謝謝"), "感恩的恩不是贅詞")
    }

    // 2026-10-22 cleanup-semantics-3：人稱不能被翻轉（從 iOS 搬進 core）。
    @Test
    fun keepsPersonRejectsFlippedOrAnsweredPerson() {
        assertFalse(CleanupFidelity.keepsPerson("你覺得這個 mix 的低頻夠不夠", "我覺得這個 mix 的低頻夠了。"))
        assertFalse(CleanupFidelity.keepsPerson("你覺得這個版本可以直接給客戶聽嗎", "這個版本還不能直接給客戶聽。"))
        assertFalse(CleanupFidelity.keepsPerson("在手機上叫做 Utuvoltype，被搞問了。", "在手機上叫做 Utuvoltype，我被搞糊塗了。"))
        assertFalse(CleanupFidelity.keepsPerson("我們先去錄音室", "我想明天去錄音室"))
        assertTrue(CleanupFidelity.keepsPerson("你覺得這個版本可以直接給客戶聽嗎", "你覺得這個版本可以直接給客戶聽嗎？"))
        assertTrue(CleanupFidelity.keepsPerson("是不是要重新開一個 session", "是不是要重新開一個 session？"))
        assertTrue(CleanupFidelity.keepsPerson("我們明天見", "我們明天見。"))
        assertTrue(CleanupFidelity.keepsPerson("首先我們花了三個禮拜做demo，收集了12首候選曲", "1. 花了三個禮拜做 demo，收集了 12 首候選曲"))
        assertFalse(CleanupFidelity.keepsPerson("我們先去錄音室，我再跟你說", "我先去錄音室再跟你說"))
    }

    // 2026-10-22 cleanup-format-1(b)：比數值，不只比 0–9（兩邊先 normalizeNumbers，同 Swift passesRelaxed）。
    @Test
    fun introducesNumberValuesComparesValuesNotDigits() {
        fun changes(original: String, cleaned: String) =
            CleanupFidelity.introducesNumberValues(Normalizer.normalizeNumbers(original), Normalizer.normalizeNumbers(cleaned))
        assertTrue(changes("總共是1,250塊", "總共是12,500塊"))
        assertTrue(changes("下午3:30開會", "下午3:00開會"))
        assertTrue(changes("預算是30萬，第二期先付10萬5", "預算是 30,000，第二期先付 100,000。"))
        assertFalse(changes("預算是三十萬", "預算是 300,000"))
        assertFalse(changes("預算是30萬", "預算是 30 萬"))
        assertFalse(changes("我的電話是零九一二三四五六七八", "我的電話是 0912-345-678"))
        assertFalse(changes("我的電話是0912345678", "我的電話是 0912-345-678"))
        assertFalse(changes("總共是一千兩百五十塊", "總共是 1,250 塊"))
        assertFalse(changes("中間休息一小時", "中間休息 1 小時"))
        assertFalse(changes("我建議設成2比1", "我建議設成 2:1"))
        assertFalse(changes("今天要做三件事，第一，更新，第二，匯出，第三，寫說明", "今天要做三件事：\n1. 更新\n2. 匯出\n3. 寫說明"))
        assertFalse(CleanupFidelity.introducesNumberValues("大概2到3天", "大概 2-3 天"), "區間拆開對得上")
        assertFalse(CleanupFidelity.introducesNumberValues("0912345678", "0912-345-678"), "電話合起來對得上")
        assertFalse(CleanupFidelity.introducesNumberValues("播放器、耳機", "1. 播放器\n2. 耳機"), "行首清單編號不算")
        assertFalse(CleanupFidelity.introducesNumberValues("十十月十三號", "10 月 13 號"), "ASR 結巴「十十月」＝十月")
        assertTrue(CleanupFidelity.introducesNumberValues("十十月十三號", "11 月 13 號"))
        // replay real-claude s23：電話重新分段照樣放行；改了一位、或把兩個短數字黏成一個就擋。
        assertFalse(CleanupFidelity.introducesNumberValues(
            "我的電話是 0912到 345678傳真號碼是 02到 23333333。", "我的電話是 0912-345-678，傳真號碼是 02-2333-3333。"))
        assertFalse(CleanupFidelity.introducesNumberValues(
            "我的電話是 0912到 345678，傳真號碼是 02到 23333333。", "我的電話是 0912345678，傳真號碼是 0223333333。"))
        assertTrue(CleanupFidelity.introducesNumberValues("我的電話是 0912到 345678", "我的電話是 0912-345-679"))
        assertTrue(CleanupFidelity.introducesNumberValues("大概3到5天", "大概35天"))
        // replay real-claude s25（實際念「三十萬」「十萬五」）：模型把「30,00」猜成 30,000＝錯十倍，要擋。
        assertTrue(CleanupFidelity.introducesNumberValues("預算是 30,00，第二期先付 10,00000。", "預算是 30,000，第二期先付 100,000。"))
    }

    // 2026-10-22 cleanup-semantics-v2：對比句不能被翻成只剩後半。
    @Test
    fun invertsContrastCatchesOnlyFlippedContrast() {
        val inverted = listOf(
            "我要的是三點不是四點" to "我要的是四點。",
            "我要的是三點不是四點" to "我要的是 4 點。",
            "取樣率是48K不是96K" to "取樣率是96K。",
            "我們約禮拜三，不是禮拜四開會。" to "我們約禮拜四開會。",
        )
        for ((original, cleaned) in inverted) assertTrue(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
        val kept = listOf(
            "我要的是三點不是四點" to "我要的是三點，不是四點。",
            "我要的是三點不是四點" to "我要的是三點。",
            "幫我轉寄給小雅跟小波不是，是小雅跟小潘。" to "幫我轉寄給小雅跟小潘。",
            "幫我轉寄給小雅跟小博，不是，是小雅跟小潘。" to "幫我轉寄給小雅跟小潘。",
            "嗯我們約禮拜三，不是，禮拜四下午三點在公司見" to "我們約禮拜四下午三點在公司見。",
            "我想明天，不對，後天寄" to "我想後天寄。",
        )
        for ((original, cleaned) in kept) assertFalse(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
    }

    // 2026-10-22 FX-3：把關會收下改了意思的輸出（Codex adversarial review）。同 Swift CleanupFidelityTests。

    private fun normalized(original: String, cleaned: String) =
        Normalizer.normalizeNumbers(original) to Normalizer.normalizeNumbers(cleaned)

    /** FX-3 ①：數值要整個比——負號、小數點都算數值的一部分（寬鬆與嚴格都一樣）。 */
    @Test
    fun signedAndDecimalValuesAreComparedWhole() {
        val wrong = listOf(
            "響度設為-14 LUFS" to "響度設為14 LUFS",
            "劑量為1.5毫克" to "劑量為5.1毫克",
            "增益是3dB" to "增益是-3dB",
            "響度設為負十四LUFS" to "響度設為14 LUFS",
        )
        for ((original, cleaned) in wrong) {
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.introducesNumberValues(o, n), "數值：$original → $cleaned")
        }
        assertFalse(CleanupFidelity.preservesContent("響度設為-14 LUFS", "響度設為14 LUFS"), "嚴格：負號不能丟")
        assertFalse(CleanupFidelity.preservesContent("增益是3dB", "增益是-3dB"), "嚴格：負號不能加")
        assertFalse(CleanupFidelity.preservesContent("-14 LUFS 就好", "14 LUFS 就好"), "嚴格：行首的負號不是項目符號")
        // 不該擋：連字號在數字中間（電話、日期、區間、型號）不是負號；千分位、時間是格式；「負」「零下」＝負號；「一點五」＝1.5。
        val fine = listOf(
            "響度設為-14 LUFS" to "響度設為 -14 LUFS。",
            "響度設為負14 LUFS" to "響度設為 -14 LUFS",
            "明天低溫零下五度要穿外套" to "明天低溫 -5 度，要穿外套。",
            "劑量為1.5毫克" to "劑量為 1.5 毫克。",
            "劑量為一點五毫克" to "劑量為 1.5 毫克。",
            "這首歌的音場用七點一點四來做混音" to "這首歌的音場用 7.1.4 來做混音。",
            "我的電話是0912-345-678" to "我的電話是 0912-345-678",
            "截止日是2026-10-22" to "截止日是 2026 年 10 月 22 日",
            "大概3-5天" to "大概 3-5 天",
            "COVID-19 的疫苗打了兩劑" to "COVID-19 的疫苗打了兩劑。",
            "型號是A-1" to "型號是 A-1。",
            "總共是一萬兩千塊" to "總共是 12,000 塊",
            "下午三點半開會" to "下午 3:30 開會。",
            "音量調到負六dB" to "音量調到 -6 dB。",
            "LUFS 目標是負十四" to "LUFS 目標是 -14。",
            "版本號是1.0.8" to "版本號是 1.0.8。",
        )
        for ((original, cleaned) in fine) {
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.introducesNumberValues(o, n), "數值：$original → $cleaned")
            assertFalse(CleanupFidelity.reordersNumberValues(o, n), "順序：$original → $cleaned")
        }
        assertTrue(CleanupFidelity.preservesContent("響度設為-14 LUFS", "響度設為 -14 LUFS。"))
        assertTrue(CleanupFidelity.preservesContent("我的電話是0912-345-678", "我的電話是 0912-345-678。"))
        assertTrue(CleanupFidelity.preservesContent("大概3-5天", "大概 3-5 天。"))
    }

    /** FX-3 ②：數值不能換主人——輸出的數值要依原文順序出現、次數不能變多；改口後的值照樣放行。 */
    @Test
    fun numberValuesKeepTheirOrderAndCount() {
        val wrong = listOf(
            "預算是100元，訂金是200元" to "預算是200元，訂金是100元",
            "預算是100元，訂金是200元" to "預算是100元，訂金是100元",
            "預算是一百，訂金兩百" to "預算是兩百，訂金一百",
            "買三個蘋果和五個橘子" to "買五個蘋果和三個橘子",
            "3樓開會，5樓吃飯" to "5樓開會，3樓吃飯",
            "預算是100元，訂金是200元，不對，250元" to "預算是250元，訂金是100元",
        )
        for ((original, cleaned) in wrong) {
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.reordersNumberValues(o, n), "$original → $cleaned")
        }
        val fine = listOf(
            "預算是100元，不對，150元，訂金是200元" to "預算是150元，訂金是200元。",
            "我們約3點開會,不對,4點,地點在3樓" to "我們約4點開會，地點在3樓。",
            "預算是三十萬，第二期先付十萬" to "預算是 300,000，第二期先付 100,000。",
            "我的電話是 0912到 345678傳真號碼是 02到 23333333。" to "我的電話是 0912-345-678，傳真號碼是 02-2333-3333。",
            "今天要做三件事，第一，更新，第二，匯出，第三，寫說明" to "今天要做三件事：\n1. 更新\n2. 匯出\n3. 寫說明",
            "大概三到五天，最多一週" to "大概 3 到 5 天，最多一週。",
            "報告在十十月十三號以前要交給客戶" to "報告在 10 月 13 號以前要交給客戶。",
            "預算是100元，訂金是200元" to "預算是100元。",
            // 改口的值不在被取代的那個位置旁邊：改口後的值可以搬去取代前面的值。
            "我們約三點開會在5樓，不對，四點" to "我們約四點開會在5樓。",
            "我們約3點開會，地點在5樓，不對，4點" to "我們約4點開會，地點在5樓。",
        )
        for ((original, cleaned) in fine) {
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.reordersNumberValues(o, n), "$original → $cleaned")
            assertFalse(CleanupFidelity.introducesNumberValues(o, n), "$original → $cleaned")
        }
    }

    /** FX-3 ③：每一組對比各自檢查——別處的「不是」、別處出現的原選項都不能拿來抵。 */
    @Test
    fun eachContrastIsCheckedOnItsOwn() {
        val inverted = listOf(
            "開會時間是星期三不是星期四，地點不是台北" to "開會時間是星期四，地點不是台北",
            "預定的是台北不是台南，台北需要提前預約" to "預定的是台南，台北需要提前預約",
            "我要的是三點不是四點" to "我要的是四點不是三點。",
            "我們約禮拜三，不是禮拜四開會，不是在公司" to "我們約禮拜四開會，不是在公司。",
        )
        for ((original, cleaned) in inverted) assertTrue(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
        val kept = listOf(
            "開會時間是星期三不是星期四，地點不是台北" to "開會時間是星期三，不是星期四，地點不是台北。",
            "開會時間是星期三不是星期四，地點不是台北" to "開會時間是星期三，地點不是台北。",
            "預定的是台北不是台南，台北需要提前預約" to "預定的是台北，不是台南，台北需要提前預約。",
            "預定的是台北不是台南，台南那家下次再訂" to "預定的是台北，不是台南，台南那家下次再訂。",
            "我要的是三點而不是四點" to "我要的是三點，而不是四點。",
        )
        for ((original, cleaned) in kept) assertFalse(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
    }

    /** FX-3 ④：嚴格把關也不能把對比句翻掉；「星期三不是星期四」沒有改口語法就不是改口。 */
    @Test
    fun strictGateKeepsWeekdayContrasts() {
        val inverted = listOf(
            "開會時間是星期三不是星期四" to "開會時間是星期四",
            "開會時間是星期三不是星期四，地點不是台北" to "開會時間是星期四，地點不是台北",
            "我們約禮拜三不是禮拜五下午見" to "我們約禮拜五下午見",
        )
        for ((original, cleaned) in inverted) assertFalse(CleanupFidelity.preservesContent(original, cleaned), "$original → $cleaned")
        val corrections = listOf(
            "我們約禮拜三，不是，禮拜五下午見" to "我們約禮拜五下午見",
            "我們約禮拜三不是，是禮拜五下午見" to "我們約禮拜五下午見",
            "我們約禮拜三不是是禮拜五下午見" to "我們約禮拜五下午見",
            "我們約禮拜三不對禮拜五下午見" to "我們約禮拜五下午見",
            "開會時間是星期三不是星期四" to "開會時間是星期三，不是星期四。",
            "開會時間是星期三不是星期四" to "開會時間是星期三不是星期四",
        )
        for ((original, cleaned) in corrections) {
            assertTrue(CleanupFidelity.preservesContent(original, cleaned), "$original → $cleaned：${CleanupFidelity.rejectionReason(original, cleaned)}")
        }
    }

    /** FX-3 ⑤：人稱的先後（誰寄給誰）不能對調，中英文都算；省掉人稱、他／她同音互換照樣放行。 */
    @Test
    fun personReferencesKeepTheirOrder() {
        val flipped = listOf(
            "我明天會把報告寄給他" to "他明天會把報告寄給我",
            "You will send me the invoice tomorrow." to "I will send you the invoice tomorrow.",
            "我們會把檔案寄給他們" to "他們會把檔案寄給我們",
            "We will send them the files." to "They will send us the files.",
            "你跟他說我晚點到" to "他跟你說我晚點到",
            "She told him the mix was done." to "He told her the mix was done.",
        )
        for ((original, cleaned) in flipped) assertFalse(CleanupFidelity.keepsPerson(original, cleaned), "$original → $cleaned")
        val fine = listOf(
            "我明天會把報告寄給他" to "我明天會把報告寄給她。",
            "我我明天會把報告寄給他" to "我明天會把報告寄給他。",
            "其他的我再跟你說" to "其他的我再跟你說。",
            "吉他的部分我來彈，你負責鼓" to "吉他的部分我來彈，你負責鼓。",
            "寄給他，不對，寄給你" to "寄給你。",
            "You will send me the invoice tomorrow." to "You will send me the invoice tomorrow.",
            "I think the US mix is louder" to "I think the US mix is louder.",
            "Can you send it to me" to "Can you send it to me?",
            "我覺得你那邊的版本比較好" to "你那邊的版本比較好。",
        )
        for ((original, cleaned) in fine) assertTrue(CleanupFidelity.keepsPerson(original, cleaned), "$original → $cleaned")
    }

    // 2026-10-22 FX-3 第二輪：獨立驗證找到的漏網（同 Swift CleanupFidelityTests 第二輪）。
    // core 沒有雙字詞比例那幾條（在 app 的 SmartCleanup.accepts），這裡只看 core 的意思檢查：兩邊先轉成同一種數字寫法，同 production。
    private fun meaningKept(original: String, cleaned: String): Boolean {
        val (o, n) = normalized(original, cleaned)
        return !CleanupFidelity.introducesNumberValues(o, n) && !CleanupFidelity.reordersNumberValues(o, n) &&
            !CleanupFidelity.invertsContrast(o, n) && !CleanupFidelity.swapsAroundSharedMiddle(o, n)
    }

    /** 對比的 B 在原文別處也出現（「台南那家下次再訂」）時，翻轉照樣要擋：B 坐上了 A 的位置、或 A 不見了 B 還在。 */
    @Test
    fun contrastInversionIsCaughtWhenTheOtherOptionAppearsElsewhere() {
        val inverted = listOf(
            "預定的是台北不是台南，台南那家下次再訂" to "預定的是台南，那家下次再訂。",
            "我要的是三點不是四點，四點我有別的會" to "我要的是4點，我有別的會。",
            "寄給客戶的是A版不是B版，B版的低頻還要再修" to "寄給客戶的是B版，低頻還要再修。",
            "要寄給小王，不是小李，小李那份明天再寄" to "要寄給小李，那份明天再寄。",
            "開會是星期三不是星期四，星期四我要出差" to "開會是星期四，我要出差。",
            "寄的是A版不是B版，B版還沒混完" to "寄的是B版，還沒混完。",
            "我要喝咖啡，不是茶，茶我不喝" to "我要喝茶，我不喝。",
            "開會是星期三不是星期四，星期四我要出差" to "開會是星期四，星期四我要出差",
        )
        for ((original, cleaned) in inverted) {
            assertTrue(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
            assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
        }
        val kept = listOf(
            "預定的是台北不是台南，台南那家下次再訂" to "預定的是台北，不是台南，台南那家下次再訂。",
            "預定的是台北不是台南，台南那家下次再訂" to "預定的是台北，台南那家下次再訂。",
            "我要的是三點不是四點，四點我有別的會" to "我要的是下午三點，不是四點，四點我有別的會。",
            "開會是星期三不是星期四，星期四我要出差" to "開會是週三，不是週四；週四我要出差。",
            "要寄給小王，不是小李，小李那份明天再寄" to "寄給小王，不是小李；小李那份明天再寄。",
            "我要喝咖啡，不是茶，茶我不喝" to "我要喝咖啡，不是茶，茶我不喝。",
        )
        for ((original, cleaned) in kept) {
            assertFalse(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
            assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
        }
    }

    /** 沒有「是」也沒有逗號的「X不是Y」、換了說法（禮拜→星期、台→臺）、英文的「A, not B」都是對比；一般的否定不算。 */
    @Test
    fun bareAndRewordedContrastsAreChecked() {
        val inverted = listOf(
            "我們約禮拜三不是禮拜五下午見" to "我們約禮拜五下午見。",
            "我們約三點不是4點見面" to "我們約4點見面。",
            "開會星期三不是星期四" to "開會星期四",
            "我要三點不是四點的那場" to "我要四點的那場",
            "檔案要寄給A版本不是B版本" to "那個檔案要寄B版本。",
            "開會時間是禮拜三不是禮拜四" to "開會時間是星期四。",
            "預定的是台北不是台南" to "預定的是臺南",
            "我們約禮拜三不是禮拜五下午見" to "我們約週五下午見。",
            "The meeting is on Wednesday, not Thursday." to "The meeting is on Thursday.",
            "the meeting is on wednesday not thursday" to "The meeting is on Thursday.",
            "I need the 3 pm slot, not the 4 pm slot." to "I need the 4 pm slot.",
            "I'll do it tomorrow, not today" to "I'll do it today.",
            "溫度是零下五度不是零下十度" to "溫度是 -10 度。",
            "這是我的不是你的" to "這是你的。",
        )
        for ((original, cleaned) in inverted) {
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.invertsContrast(o, n), "$original → $cleaned")
            assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
        }
        assertFalse(CleanupFidelity.preservesContent("開會星期三不是星期四", "開會星期四"), "嚴格也擋")
        assertFalse(CleanupFidelity.preservesContent("預定的是台北不是台南", "預定的是臺南"), "嚴格也擋")
        val fine = listOf(
            "我們約禮拜三不是禮拜五下午見" to "我們約週三，不是週五，下午見。",
            "我要的是 A 版本而不是 B 版本" to "我要的是 A 版本，而不是 B 版本。",
            "這不是問題，問題是時間" to "這不是問題，問題是時間。",
            "他說的不是真的" to "他說的不是真的。",
            "這個版本不是最終版" to "這版本並非最終版。",
            "不是我不想去，是我沒空" to "不是我不想去，是我沒空。",
            "我不是說你錯，我是說時間不夠" to "我不是說你錯，是時間不夠。",
            "This is not a drill" to "This is not a drill.",
            "I'll do it tomorrow, not today" to "I'll do it tomorrow, not today.",
            "溫度是零下五度不是零下十度" to "溫度是 -5 度，不是 -10 度。",
            "我們約禮拜三不是是禮拜五" to "我們約禮拜五。",
            "不是星期三是星期四" to "不是星期三，是星期四。",
        )
        for ((original, cleaned) in fine) assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
    }

    /** 同一個人稱出現兩次時，兩個人互相搶了對方的位置＝對調；英文 and／or 並列對調、刪贅詞後剛好緊鄰同一個字都不算。 */
    @Test
    fun repeatedPersonsCannotTradePlaces() {
        val flipped = listOf(
            "我請他幫我訂明天下午的高鐵票" to "他請我訂明天下午的高鐵票。",
            "我明天早上會請他把那份報告寄給我" to "他明天早上會請我把那份報告寄出去",
            "我會叫他明天打電話給我" to "他會叫我明天打電話。",
            "I told him to email me the file." to "He told me to email the file.",
            "I asked him to call me tomorrow" to "He asked me to call tomorrow.",
            "我請他幫我訂票" to "他請我幫他訂票。",
        )
        for ((original, cleaned) in flipped) assertFalse(CleanupFidelity.keepsPerson(original, cleaned), "$original → $cleaned")
        val fine = listOf(
            "我請他幫我訂明天下午的高鐵票" to "我請他幫我訂明天下午的高鐵票。",
            "我請他幫我訂票" to "請他幫我訂票。",
            "我跟你說，他明天會來" to "跟你說，他明天會來。",
            "you know I was thinking we could meet" to "I was thinking we could meet.",
            "Me and him will fix it tomorrow" to "He and I will fix it tomorrow.",
            "me and her are going to the studio" to "She and I are going to the studio.",
            "寄給他，不對，寄給你" to "寄給你。",
            "那個你可以幫我把檔案寄給他嗎" to "你可以幫我把檔案寄給他嗎？",
            "我會把報告寄給你，你再寄給他" to "我會把報告寄給你，你再寄給他。",
            "我嗯要去，他要來" to "我要去，他要來。",
            "我那個跟你說，他跟我說過" to "我跟你說，他跟我說過。",
        )
        for ((original, cleaned) in fine) assertTrue(CleanupFidelity.keepsPerson(original, cleaned), "$original → $cleaned")
    }

    /** 兩段內容繞著中間不動的一段對調＝誰對誰被換掉；只把一段話（或時間副詞）挪個位置不算。 */
    @Test
    fun partsSwappedAroundTheSameMiddleAreRejected() {
        val swapped = listOf(
            "王經理要把合約寄給李律師" to "李律師要把合約寄給王經理。",
            "小明欠小華五百元" to "小華欠小明500元",
            "Alice owes Bob 500 dollars." to "Bob owes Alice 500 dollars.",
            "小王寄給小李" to "小李寄給小王。",
            "我們今天先討論預算然後再討論時程" to "我們今天先討論時程，然後再討論預算。",
            "她要把錢轉給他" to "他要把錢轉給她",
            "他把它放在桌上" to "它把他放在桌上",
            "John will call Mary at 10 am" to "Mary will call John at 10 am.",
            "明天見客戶，後天見老闆" to "後天見客戶，明天見老闆。",
            "下午三點開會，晚上七點吃飯" to "晚上七點開會，下午三點吃飯。",
        )
        for ((original, cleaned) in swapped) {
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.swapsAroundSharedMiddle(o, n), "$original → $cleaned")
            assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
        }
        val moved = listOf(
            "明天我要去台北，後天去台中" to "我明天要去台北，後天去台中。",
            "因為下雨，所以我們取消了" to "我們取消了，因為下雨。",
            "小王跟小李一起去" to "小王和小李一起去。",
            "我們今天先討論預算然後再討論時程" to "我們今天先討論預算，然後再討論時程。",
            "Me and him will fix it tomorrow" to "He and I will fix it tomorrow.",
            "at 3 pm on October 22 we meet" to "We meet on October 22 at 3 pm.",
            "tomorrow at 10 am I will call John" to "I will call John tomorrow at 10 am.",
            "幫我轉寄給小雅跟小波不是是小雅跟小潘。" to "幫我轉寄給小雅跟小潘，不是小雅跟小波。",
        )
        for ((original, cleaned) in moved) {
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.swapsAroundSharedMiddle(o, n), "$original → $cleaned")
            assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
        }
    }

    /** 數量與符號：「一杯」也是數量；英文 minus／negative、「負 14」、「LUFS-14」是負號；改口取代最近一個同單位的值；不同單位可換位置。 */
    @Test
    fun quantitiesSignsAndCorrectionTargets() {
        val wrong = listOf(
            "我要一杯拿鐵跟兩杯美式" to "我要兩杯拿鐵跟一杯美式。",
            "我買一張票，他買兩張票" to "我買兩張票，他買一張票。",
            "Set the loudness to minus 14 LUFS." to "Set the loudness to 14 LUFS.",
            "The target is negative 14 LUFS." to "The target is 14 LUFS.",
            "響度設為負 14 LUFS" to "響度設為 14 LUFS",
            "預算是100元，訂金是200元，不對，是300元" to "預算是300元，訂金是200元",
            "我3點到公司，5點開會，不對，6點" to "我6:00到公司，5:00開會",
            "三樓開會，五點吃飯" to "5點開會，3樓吃飯。",
            "I have 3 apples and 5 oranges" to "I have 5 apples and 3 oranges.",
            "LUFS-14是標準" to "LUFS 14是標準",
        )
        for ((original, cleaned) in wrong) assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
        assertTrue(CleanupFidelity.reordersNumberValues("我要一杯拿鐵跟兩杯美式", "我要兩杯拿鐵跟一杯美式。"))
        // 單位不同的值互相換走對方後面的詞＝換了主人（數值檢查本身就要擋，不靠別的檢查碰巧擋到）。同 Swift。
        assertTrue(CleanupFidelity.reordersNumberValues("三樓開會，五點吃飯", Normalizer.normalizeNumbers("5點開會，3樓吃飯。")))
        assertTrue(CleanupFidelity.introducesNumberValues("Set the loudness to minus 14 LUFS.", "Set the loudness to 14 LUFS."))
        val fine = listOf(
            "Set the loudness to minus 14 LUFS" to "Set the loudness to -14 LUFS.",
            "the gain is negative 3 dB" to "The gain is -3 dB.",
            "響度設為負 14 LUFS" to "響度設為 -14 LUFS。",
            "音量要減三dB" to "音量要 -3 dB。",
            "音量要減三dB" to "音量要減 3 dB。",
            "我要一個漢堡跟兩杯可樂" to "我要一個漢堡、兩杯可樂。",
            "我要一杯拿鐵" to "我要一杯拿鐵。",
            "明天下午三點，十月二十三號要交" to "10 月 23 日（明天）下午3點要交。",
            "三樓開會，五點吃飯" to "3樓開會，5點吃飯。",
            "我們約三點開會在5樓，不對，四點" to "我們約四點開會在5樓。",
            "我3點到公司，5點開會，不對，6點" to "我3點到公司，6點開會。",
            "at 3 pm on October 22 we meet" to "We meet on October 22 at 3 pm.",
            "LUFS-14是標準" to "-14 LUFS 是標準。",
            "A-1版本先寄" to "A-1 版本先寄。",
            "COVID-19的影響" to "COVID-19 的影響。",
        )
        for ((original, cleaned) in fine) assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
    }

    // 2026-10-22 FX-3 第三輪：第二輪獨立驗證找到的漏網與誤擋（同 Swift CleanupFidelityTests 第三輪）。

    /** 主從對調：動詞換了說法時緊鄰的字也跟著換（「我請他幫我訂」→「他要我訂」）；省掉主詞、轉述的後半句換人當主詞照樣放行。 */
    @Test
    fun subjectAndObjectCannotTradePlacesWhenTheVerbIsReworded() {
        val flipped = listOf(
            "我會叫他明天打電話給我" to "他明天會叫我打電話。",
            "我會叫他明天打電話給我" to "他明天叫我打電話。",
            "我請他幫我訂明天下午的高鐵票" to "他要我訂明天下午的高鐵票。",
            "我請他幫我訂明天下午的高鐵票" to "他拜託我訂明天下午的高鐵票。",
            "我拜託他幫我買咖啡" to "他明天拜託我買咖啡。",
            "I told him to email me the file" to "He asked me to email the file.",
            "I asked him to call me tomorrow" to "He told me to call tomorrow.",
        )
        for ((original, cleaned) in flipped) assertFalse(CleanupFidelity.keepsPerson(original, cleaned), "$original → $cleaned")
        val fine = listOf(
            "我請他幫我訂明天下午的高鐵票" to "我請他幫忙訂明天下午的高鐵票。",
            "我請他幫我訂票" to "請他幫我訂票。",
            "我跟你說他明天會來找你" to "他明天會來找你。",
            "我跟你說，他明天會來找你" to "他明天會來找你。",
            "我們跟他們說了他們明天會給我們回覆" to "我們跟他們說了，他們明天會回覆我們。",
            "我想他應該會打給我" to "我想他應該會打給我。",
            "我昨天跟他說我明天不能去" to "我昨天跟他說，我明天不能去。",
            "嗯我覺得他說的對我們就照他的做" to "我覺得他說的對，我們就照他的做。",
            "然後他就跟我說你明天不用來了" to "他跟我說你明天不用來了。",
            "是他寄給我的不是我寄給他的" to "是他寄給我的，不是我寄給他的。",
            "He told me I should call him" to "He told me to call him.",
            "I told him to email me the file" to "I told him to email me the file.",
        )
        for ((original, cleaned) in fine) assertTrue(CleanupFidelity.keepsPerson(original, cleaned), "$original → $cleaned")
    }

    /** 「不是 B 而是 A」「not B but A」是後面的 A 對；「A 而非／並非 B」「A instead of／rather than B」是 A 對。 */
    @Test
    fun turnedContrastsAndOtherContrastMarkersAreChecked() {
        val inverted = listOf(
            "開會不是星期四，而是星期三" to "開會是星期四。",
            "開會不是星期四，而是星期三" to "開會時間是星期四。",
            "要寄的不是母帶而是混音" to "要寄的是母帶。",
            "不是星期四，是星期三" to "是星期四。",
            "The meeting is not on Thursday but on Wednesday" to "The meeting is on Thursday.",
            "The meeting is not on Thursday but on Wednesday" to "The meeting is Thursday.",
            "It is not the mix but the master" to "It is the mix.",
            "我要的是三點而非四點" to "我要的是四點",
            "我要的是三點，並非四點" to "我要的是四點",
            "寄的是混音版而非母帶版" to "寄的是母帶版。",
            "I need the 3 pm slot instead of the 4 pm slot" to "I need the 4 pm slot.",
            "We want the 48k version rather than the 96k version" to "We want the 96k version.",
        )
        for ((original, cleaned) in inverted) {
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.invertsContrast(o, n), "$original → $cleaned")
            assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
        }
        val kept = listOf(
            "開會不是星期四，而是星期三" to "開會是星期三。",
            "要寄的不是母帶而是混音" to "要寄的不是母帶，而是混音。",
            "要寄的不是母帶而是混音" to "要寄的是混音，不是母帶。",
            "The meeting is not on Thursday but on Wednesday" to "The meeting is not on Thursday but on Wednesday.",
            "The meeting is not on Thursday but on Wednesday" to "The meeting is on Wednesday, not Thursday.",
            "我要的是三點而非四點" to "我要的是3點，而非4點。",
            "I need the 3 pm slot instead of the 4 pm slot" to "I need the 3 pm slot instead of the 4 pm slot.",
            "We want the 48k version rather than the 96k version" to "We want the 48k version, not the 96k version.",
        )
        for ((original, cleaned) in kept) {
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.invertsContrast(o, n), "$original → $cleaned")
            assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
        }
    }

    /** 本機版在「不是」後面換行（「我們要的是\n第二版不是\n第三版」）：換行不是停頓，對比照樣認得。 */
    @Test
    fun contrastSplitAcrossLinesByTheLocalPasteIsStillChecked() {
        val inverted = listOf(
            "我們要的是\n第二版不是\n第三版" to "我們要的是第三版。",
            "我們要的是\n第二版不是\n第三版" to "我們要第三版。",
            "我們要用\n第一版不是\n第二版" to "我們要用第二版。",
            "要交的是\n第一首不是\n第二首" to "要交的是第二首。",
        )
        for ((original, cleaned) in inverted) {
            assertTrue(CleanupFidelity.invertsContrast(original, cleaned), "$original → $cleaned")
            assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
        }
        val kept = listOf(
            "我們要的是\n第二版不是\n第三版" to "我們要的是第二版，不是第三版。",
            "我們要用\n第一版不是\n第二版" to "我們要用第一版，不是第二版。",
        )
        for ((original, cleaned) in kept) assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
    }

    /** 第二輪的誤擋：補回被併掉的重複、數量綁著同一樣東西換位置、挪「我們」、重複說一次、具名改口、B1＝負一樓；真的翻轉照樣擋。 */
    @Test
    fun harmlessRewritesFoundInRoundTwoPass() {
        val fine = listOf(
            "開會是星期三不是星期四我要出差" to "開會是星期三，不是星期四；星期四我要出差。",
            "開會是星期三不是星期四我要出差" to "開會是星期三，不是星期四，星期四我要出差。",
            "寄的是混音版不是母帶版還沒做完" to "寄的是混音版，不是母帶版；母帶版還沒做完。",
            "要調的是左聲道不是右聲道沒問題" to "要調的是左聲道，不是右聲道；右聲道沒問題。",
            "兩杯拿鐵，一杯美式" to "一杯美式，兩杯拿鐵",
            "我想要一杯咖啡跟一個蛋糕" to "我想要一個蛋糕跟一杯咖啡。",
            "如果明天下雨我們就改到室內" to "我們明天如果下雨就改到室內。",
            "我要的是三點不是四點，三點比較好，四點我有會" to "我要的是3點，不是4點，比較好；4點我有會。",
            "三點開會，五點吃飯，不對，開會是四點" to "4:00開會，5點吃飯",
            "三點開會，五點吃飯，不對，開會是四點" to "4:00開會，五點吃飯。",
            "負一樓停車場" to "B1停車場",
        )
        for ((original, cleaned) in fine) assertTrue(meaningKept(original, cleaned), "$original → $cleaned")
        val wrong = listOf(
            "開會是星期三不是星期四我要出差" to "開會是星期四；星期四我要出差。",
            "寄的是混音版不是母帶版還沒做完" to "寄的是母帶版；母帶版還沒做完。",
            "兩杯拿鐵，一杯美式" to "兩杯美式，一杯拿鐵",
            "我想要一杯咖啡跟兩個蛋糕" to "我想要兩杯咖啡跟一個蛋糕。",
            "三點開會，五點吃飯，不對，開會是四點" to "4:00開會，3點吃飯",
            "負一樓停車場" to "1樓停車場",
        )
        for ((original, cleaned) in wrong) assertFalse(meaningKept(original, cleaned), "$original → $cleaned")
    }

    // 2026-10-23 FX-7：wave 2 交叉審查（codex-adv）找到的五類漏網（V1–M4；L5 條列在 DeterministicStructureTest）。
    // 同 Swift CleanupFidelityTests 的 testFx7*（同一批句子）。core 沒有雙字詞比例那幾條，寬鬆這邊看 core 的意思檢查。

    /** FX-7 V1：版本號／點分識別碼每一段照字串比，「2.10」不等於「2.1」；一般數值的小數尾零照舊可以拿掉。 */
    @Test
    fun fx7VersionsAndDottedIdentifiersKeepEveryComponent() {
        val wrong = listOf(
            "請安裝版本2.10，這個版本比較穩定" to "請安裝版本2.1，這個版本比較穩定",
            "升級到7.10.4" to "升級到7.1.4",
            "版本V2.10上線了" to "版本V2.1上線了。",
            "升級到iOS 17.10" to "升級到iOS 17.1。",
            "升級到macOS 15.10" to "升級到 macOS 15.1",
            "IP是192.168.1.10" to "IP是192.168.1.1",
            "build 3.10先上" to "build 3.1先上。",
            "請大家安裝新的2.10版，比較穩定" to "請大家安裝新的 2.1 版，比較穩定。",
            "請安裝版本二點一零，這個版本比較穩定" to "請安裝版本2.1，這個版本比較穩定。",
            "升級到iOS十七點一零" to "升級到 iOS 17.1。",
            "這首歌的音場用七點一零點四來做混音" to "這首歌的音場用 7.1.4 來做混音。",
        )
        for ((original, cleaned) in wrong) {
            assertFalse(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertFalse(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.introducesNumberValues(o, n), "數值：$original → $cleaned")
        }
        val fine = listOf(
            "請安裝版本2.10，這個版本比較穩定" to "請安裝版本 2.10，這個版本比較穩定。",
            "升級到7.10.4" to "升級到 7.10.4。",
            "請大家安裝新的2.10版，比較穩定" to "請大家安裝新的 2.10 版，比較穩定。",
            "價格是3.50元" to "價格是3.5元。",
            "音量調到1.50倍" to "音量調到1.5倍。",
            "這個版本要3.50元" to "這個版本要3.5元。",
            "請安裝版本二點一零，這個版本比較穩定" to "請安裝版本 2.10，這個版本比較穩定。",
            "升級到iOS十七點一零" to "升級到 iOS 17.10。",
            "這首歌的音場用七點一零點四來做混音" to "這首歌的音場用 7.10.4 來做混音。",
            "這首歌的音場用七點一點四來做混音" to "這首歌的音場用 7.1.4 來做混音。",
            "音量調到一點五零倍" to "音量調到 1.5 倍。",
            "音量調到一點五零倍" to "音量調到 1.50 倍。",
            "版本號是1.0.8" to "版本號是 1.0.8。",
        )
        for ((original, cleaned) in fine) assertTrue(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
        assertTrue(CleanupFidelity.preservesContent("請安裝版本2.10，這個版本比較穩定", "請安裝版本 2.10，這個版本比較穩定。"))
        assertTrue(CleanupFidelity.preservesContent("升級到7.10.4", "升級到 7.10.4。"))
        assertTrue(CleanupFidelity.preservesContent("請大家安裝新的2.10版，比較穩定", "請大家安裝新的 2.10 版，比較穩定。"))
    }

    /** FX-7 R2：輸出裡重複的數值要有原文的根據（原文本來就說了兩次，或重複的是同一個主人）；主人與次數照原文。 */
    @Test
    fun fx7RestoredRepeatsNeedSourceEvidence() {
        val wrong = listOf(
            "預算100元，訂金200元" to "預算100元，訂金100元，合計200元",
            "預算100元，訂金200元" to "預算100元，訂金100元。",
            "預算100元訂金200元" to "預算100元訂金100元合計200元",
        )
        for ((original, cleaned) in wrong) {
            assertFalse(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertFalse(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
        }
        assertTrue(CleanupFidelity.reordersNumberValues("預算100元，訂金200元", "預算100元，訂金100元，合計200元"), "數值檢查本身就要擋")
        val fine = listOf(
            "預算100元，訂金200元" to "預算100元，訂金200元。",
            "預算100元，訂金200元" to "預算100元，預算100元，訂金200元。",
            "預算100元，訂金100元" to "預算100元，訂金100元。",
            "預算100元，訂金100元" to "預算和訂金都是100元。",
            "三點開會，五點吃飯" to "三點開會，三點開會，五點吃飯。",
            // 「下午」「星期」是數值自己的一部分，不是主人：照原話補回被併掉的重複照樣放行。
            "開會是下午三點不是下午四點我有會" to "開會是下午三點，不是下午四點；下午四點我有會。",
            "開會是星期三不是星期四我要出差" to "開會是星期三，不是星期四；星期四我要出差。",
        )
        for ((original, cleaned) in fine) assertTrue(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
        assertTrue(CleanupFidelity.preservesContent("預算100元，訂金200元", "預算100元，訂金200元。"))
    }

    /** FX-7 R3：名字在別處又出現一次時，誰對誰對調照樣要擋（錨點逐個出現位置配對，不再因為重複就丟掉）。 */
    @Test
    fun fx7RoleSwapsAreCaughtWhenANameRepeats() {
        val wrong = listOf(
            "王經理要把合約寄給李律師，王經理明天休假" to "李律師要把合約寄給王經理，王經理明天休假",
            "王經理要把合約寄給李律師，王經理明天休假" to "李律師要把合約寄給王經理，王經理明天休假。",
            "小陳把報告交給小林，小陳下午請假" to "小林把報告交給小陳，小陳下午請假。",
            "他把鑰匙給了她，他晚上才回來" to "她把鑰匙給了他，他晚上才回來。",
        )
        for ((original, cleaned) in wrong) {
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.swapsAroundSharedMiddle(o, n), "$original → $cleaned")
            assertFalse(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertFalse(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
        }
        val fine = listOf(
            "王經理要把合約寄給李律師，王經理明天休假" to "王經理要把合約寄給李律師，王經理明天休假",
            "王經理要把合約寄給李律師，王經理明天休假" to "王經理要把合約寄給李律師，王經理明天休假。",
            "王經理要把合約寄給李律師，王經理明天休假" to "王經理明天休假，要把合約寄給李律師。",
            "小陳把報告交給小林，小陳下午請假" to "小陳把報告交給小林，小陳下午請假。",
            "小陳把報告交給小林，小陳下午請假" to "小陳把報告交給小林，下午請假。",
            "小陳把報告交給小林，小陳下午請假" to "小陳下午請假，報告交給小林。",
        )
        for ((original, cleaned) in fine) {
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.swapsAroundSharedMiddle(o, n), "$original → $cleaned")
            assertTrue(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
        }
        assertTrue(CleanupFidelity.preservesContent("王經理要把合約寄給李律師，王經理明天休假", "王經理要把合約寄給李律師，王經理明天休假。"))
    }

    /** FX-7 M4：減號後面隔了空白還是負號（−、－ 一律是；半形 - 要緊接在非空白字後面）；行首「- 」是項目符號、「3 - 5」是區間。 */
    @Test
    fun fx7MinusSignFollowedBySpacesIsStillASign() {
        val wrong = listOf(
            "目標響度是− 14 LUFS，請照這個輸出" to "目標響度是14 LUFS，請照這個輸出",
            "目標響度是14 LUFS，請照這個輸出" to "目標響度是− 14 LUFS，請照這個輸出",
            "目標響度是−14 LUFS，請照這個輸出" to "目標響度是14 LUFS，請照這個輸出。",
            "目標響度是－ 14 LUFS" to "目標響度是14 LUFS",
            "目標響度是- 14 LUFS" to "目標響度是14 LUFS",
            "響度是 − 14 LUFS" to "響度是 14 LUFS",
        )
        for ((original, cleaned) in wrong) {
            assertFalse(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertFalse(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
            val (o, n) = normalized(original, cleaned)
            assertTrue(CleanupFidelity.introducesNumberValues(o, n), "數值：$original → $cleaned")
        }
        val fine = listOf(
            "目標響度是− 14 LUFS，請照這個輸出" to "目標響度是 -14 LUFS，請照這個輸出。",
            "目標響度是- 14 LUFS" to "目標響度是 -14 LUFS",
            "目標響度是－ 14 LUFS" to "目標響度是 -14 LUFS。",
            "響度是 − 14 LUFS" to "響度是 -14 LUFS",
            "大概3 - 5天" to "大概3-5天",
            "大概3 - 5天" to "大概 3 - 5 天。",
            "待辦：\n- 14號交報告\n- 15號開會" to "待辦：\n14號交報告\n15號開會",
        )
        for ((original, cleaned) in fine) {
            assertTrue(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertTrue(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.introducesNumberValues(o, n), "數值：$original → $cleaned")
        }
    }

    /**
     * FX-9：把關拿掉行首清單編號時，把開頭的小數（「3.5元」的「3.」）和開頭的一串數字（「三、一百」的「三、」）也當編號拿掉了。
     * 編號後面直接接數字（中間沒有空白）就是數值的一部分。同 Swift CleanupFidelityTests.testFx9LeadingNumbersAreValuesNotListNumbers。
     */
    @Test
    fun fx9LeadingNumbersAreValuesNotListNumbers() {
        val fine = listOf(
            "3.5元的咖啡" to "3.5元的咖啡。",
            "3.5元" to "3.5元。",
            "3.5元的咖啡很好喝" to "3.5元的咖啡很好喝",
            "3.5元的咖啡很好喝" to "3.5元的咖啡，很好喝。",
            "2.10版比較穩定" to "2.10版比較穩定",
            "1.5倍速度比較好" to "1.5倍速度比較好。",
            "1.1 ms" to "1.1 ms。",
            "10.5 ms" to "10.5 ms。",
            "8.3倍" to "8.3倍",
            "三、一百" to "三、一百。",
            "五、三萬就好" to "五、三萬就好",
            "三、1 ms" to "三、1 ms。",
            "一、一萬" to "一、一萬。",
        )
        for ((original, cleaned) in fine) {
            assertTrue(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertTrue(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
            val (o, n) = normalized(original, cleaned)
            assertFalse(CleanupFidelity.reordersNumberValues(o, n), "數值先後：$original → $cleaned")
        }
        val wrong = listOf(
            "3.5元" to "4.5元",
            "2.10版比較穩定" to "3.10版比較穩定",
            "1.1 ms" to "2.1 ms",
            "8.3倍" to "9.3倍",
            "3.5元的咖啡" to "4.5元的咖啡。",
            "3.5元的咖啡" to "5.3元的咖啡。",
            "3.5元的咖啡" to "35元的咖啡。",
            "1.1 ms" to "11 ms",
            "2.10版比較穩定" to "2.1版比較穩定",
            "3.5元的咖啡很好喝" to "4.5元的咖啡很好喝",
            "1.5倍速度比較好" to "2.5倍速度比較好",
            "三、一百" to "四、一百。",
            "五、三萬就好" to "五、四萬就好",
            "一、3:00開會" to "二、3:00開會。",
        )
        for ((original, cleaned) in wrong) {
            assertFalse(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertFalse(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
        }
        // 真的清單編號（後面隔空白、或接數字以外的字）照舊拿掉再比。
        val lists = listOf(
            "1. 3:00開會" to "3:00開會。",
            "二、報告寫完" to "報告寫完。",
            "- 報告寫完" to "報告寫完。",
            "報告寫完" to "1. 報告寫完",
        )
        for ((original, cleaned) in lists) {
            assertTrue(meaningKept(original, cleaned), "relaxed：$original → $cleaned")
            assertTrue(CleanupFidelity.preservesContent(original, cleaned), "strict：$original → $cleaned")
        }
    }

    // MARK: - FX-13 G1：數字句掉一個值（沒有明講改口）＝無聲的資料遺失。與 Swift CleanupFidelityTests 同一份句對。

    /** FX-13 oracle 的 G1 句對：一個值不見了就擋（值要看幾個，不是看有沒有）。 */
    @Test
    fun numberOnlyTextMustNotDropAValue() {
        val drops = listOf(
            "100，200" to "100", "100，200" to "200", "一萬二，兩萬一" to "12,000",
            "100，200，300" to "100，300", "100 200" to "100", "100、200" to "100",
            "1200，2400" to "2400", "100，200" to "100。", "12,000，21,000" to "12,000",
            "100，100" to "100", "100，200元" to "100元", "100元，200元" to "200元",
            "3:00，4:00" to "3:00", "2026，2027" to "2026",
        )
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        // 連字號分段重新寫法不算掉（值只是換了分段的樣子）。同 Swift。
        assertFalse(CleanupFidelity.dropsNumberValues("2026年10月22日", "2026-10-22"))
        assertFalse(CleanupFidelity.dropsNumberValues("0912，345678", "0912-345678"))
    }

    /** 換一種寫法不算掉；明講改口掉的才放行。 */
    @Test
    fun numberOnlyTextKeepsEveryValueUnlessCorrected() {
        val mustAccept = listOf(
            "100，200" to "100，200。", "100，200" to "100、200", "一萬二，兩萬一" to "12,000，21,000",
            "100 200" to "100 200", "一萬二" to "12,000", "12000" to "12,000",
            "一萬不對兩萬" to "兩萬。", "一萬，不對，兩萬" to "兩萬。", "一萬我是說兩萬" to "兩萬。",
            "1200，不對，12000" to "12000。", "1200不對不對12000" to "12000。",
            "1200，我是說，12000" to "12000。", "1200啊不對12000" to "12000。",
            "12,000，不對，兩萬一" to "兩萬一。", "12,000，我是說，一萬二" to "12,000",
            "100，200，300" to "100，200，300。", "3.5，4.5" to "3.5、4.5",
        )
        for ((original, cleaned) in mustAccept) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        assertTrue(CleanupFidelity.dropsNumberValues("100，不對，200", "100"), "改口後的新值也沒留，不算改口")
        // 改口後面還是同一個值（「12000，我是說，12000」→「12000」）本來就只留一個，不算掉值。
        assertFalse(CleanupFidelity.dropsNumberValues("12000，我是說，12000", "12000"))
    }

    /** 有實詞的句子不在這條規則的範圍內，照原判定。 */
    @Test
    fun textsWithWordsKeepTheBaseDecision() {
        val withWords = listOf(
            "預算100，運費200" to "預算100",
            "三點五萬塊" to "35,000塊",
            "我要100個，不對，200個" to "我要200個。",
        )
        for ((original, cleaned) in withWords) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "有實詞＝不歸這條管：$original → $cleaned")
        }
    }
    /**
     * FX-13 修復 R1：輸出的連字號分段可以各自配一格——「100～200」→「100-200」兩個值都還在，不算掉值；
     * 真的少一個還是擋（「100～200」→「100」）。日期與電話重新分段也不算掉。同 Swift。
     */
    @Test
    fun rangeAndHyphenRewriteKeepsEveryValue() {
        val keeps = listOf(
            "100～200" to "100-200", "100，200" to "100-200",
            "2026年10月22日" to "2026-10-22", "0912，345678" to "0912-345678",
            "100，200" to "100、200",
        )
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        val drops = listOf(
            "100～200" to "100", "100～200" to "100-300",
            "2026年10月22日" to "2026-10", "0912，345678" to "0912",
        )
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
    }

    /**
     * FX-13 修復 R1：年、圓、分鐘這些必要的單位字算數字句的一部分，掉一個值就要擋；
     * 忠實的排版與改寫照放行；實詞（預算、運費、我要）還是不歸這條規則管。同 Swift。
     */
    @Test
    fun unitsCountAsNumberOnlyText() {
        val drops = listOf(
            "2026年，2027年" to "2026年", "100圓，200圓" to "100圓",
            "30分鐘，40分鐘" to "30分鐘", "2026年，2027年" to "2027年",
            "10月，11月" to "10月", "3點，4點" to "3點",
        )
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        val keeps = listOf(
            "2026年，2027年" to "2026年、2027年", "2026年，2027年" to "2026年 2027年",
            "100圓，200圓" to "100圓、200圓", "30分鐘，40分鐘" to "30分鐘、40分鐘",
            "2026年，2027年" to "2026年、2027年。",
        )
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        assertFalse(CleanupFidelity.dropsNumberValues("預算100圓，運費200圓", "預算100圓"), "有實詞＝不歸這條管")
        assertFalse(CleanupFidelity.dropsNumberValues("我要100個，不對，200個", "我要100個"), "有實詞＝不歸這條管")
    }

    // MARK: - FX-13 修復 R2：名額獨佔、單位詞不拆實詞、英文單位認得出來。與 Swift CleanupFidelityTests 同一份句對。

    /**
     * FX-13 修復 R2 ①：輸出的名額是獨佔的。整串與另一種讀法（「1.0」的兩種讀法）是同一個名額的兩種讀法，
     * 用掉一種另一種就不能再用；連字號的值要嘛當整串、要嘛當它每一段，不能兩種都來。
     * 名額被重複使用＝其實少了一個值，必須擋。同 Swift。
     */
    @Test
    fun outputCapacityIsExclusive() {
        val drops = listOf("100-200，100" to "100-200", "1，1.0" to "1.0")
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        // 名額沒有被重複使用時照放行：連字號分段各自配一格、電話與日期重新分段。
        val keeps = listOf(
            "100～200" to "100-200", "100，200" to "100-200",
            "2026年10月22日" to "2026-10-22", "0912，345678" to "0912-345678",
        )
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
    }

    /**
     * FX-13 修復 R2 ②：單位要看完整的單位詞，不能把單一字分開看（「條件」＝條＋件），
     * 有實詞的句子照原判定，不歸這條規則管；真正的單位詞還是算數字句的一部分。同 Swift。
     */
    @Test
    fun unitDomainDoesNotDecomposeWords() {
        val withWords = listOf(
            "條件100，200" to "條件100",
            "預算100，運費200" to "預算100",
            "我要100個，不對，200個" to "我要100個",
        )
        for ((original, cleaned) in withWords) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "有實詞＝不歸這條管：$original → $cleaned")
        }
        val drops = listOf(
            "2026年，2027年" to "2026年", "100圓，200圓" to "100圓", "30分鐘，40分鐘" to "30分鐘",
        )
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        // 單位詞跟改口詞黏在一起還是算數字句（「三點不對應該是四點」）：改口後的新值沒留就要擋。同 Swift。
        assertTrue(CleanupFidelity.dropsNumberValues("三點不對應該是四點", "三點。"), "改口後的新值沒留，不算改口")
        assertFalse(CleanupFidelity.dropsNumberValues("三點不對應該是四點", "四點。"), "明講改口而且新值有留")
    }

    /**
     * FX-13 修復 R2 ③：英文的單位要認得出來（標點分開的「kg，kg」也算），但不能把實詞當單位。同 Swift。
     */
    @Test
    fun englishUnitsAreRecognizedWithoutAdmittingWords() {
        val drops = listOf("100kg，200kg" to "100kg", "100 kg，200 kg" to "100 kg")
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        val keeps = listOf("100kg，200kg" to "100kg，200kg", "100 kg，200 kg" to "100 kg，200 kg")
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        // 英文的實詞不是單位：有實詞的句子照原判定。
        assertFalse(CleanupFidelity.dropsNumberValues("100apple，200apple", "100apple"), "英文實詞不該當單位")
    }

    // MARK: - FX-13 修復 R3：重複的一段只吃一次；必要的完整單位詞（公里／公分／小時…）。與 Swift 同一份句對。

    /**
     * FX-13 修復 R3 ①：輸出的連字號分段可以各自配一格，同樣的值出現兩次也只配掉一段——
     * 「100，100」→「100-100」兩個值都還在，不算掉值；名額還是獨佔的（「100-200，100」照樣擋）。同 Swift。
     */
    @Test
    fun duplicatePartsConsumeOneOccurrence() {
        val keeps = listOf("100～100" to "100-100", "100，100" to "100-100")
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        val drops = listOf("100-200，100" to "100-200", "1，1.0" to "1.0")
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
    }

    /**
     * FX-13 修復 R3 ②：必要的完整單位詞（公里、公分、毫米、小時、個小時、毫秒）算數字句的一部分，
     * 掉一個值就要擋；忠實的清單照放行；實詞（條件）還是不歸這條規則管。同 Swift。
     */
    @Test
    fun compoundUnitsCountAsNumberOnlyText() {
        val drops = listOf(
            "3公里，4公里" to "3公里", "3公分，4公分" to "3公分",
            "10小時，20小時" to "10小時", "3個小時，4個小時" to "3個小時",
            "3毫米，4毫米" to "3毫米", "100毫秒，200毫秒" to "100毫秒",
            "100kg，200kg" to "100kg",
        )
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        val keeps = listOf(
            "3公里，4公里" to "3公里、4公里", "10小時，20小時" to "10小時、20小時",
            "100kg，200kg" to "100kg，200kg",
        )
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        assertFalse(CleanupFidelity.dropsNumberValues("條件100，200", "條件100"), "有實詞＝不歸這條管")
    }

    // MARK: - FX-13 修復 R4：單獨的「萬」不是數值，沒有值可掉。與 Swift 同一份句對。

    /**
     * FX-13 修復 R4：單獨的「萬」（「三 萬 塊」裡的萬）本來就沒有值，不是掉值。
     * 原文與輸出一樣（連句號都一樣）要放行；真的有值不見了照樣擋。同 Swift。
     */
    @Test
    fun standaloneMagnitudeIsNotADroppedValue() {
        val keeps = listOf(
            "萬 塊" to "萬 塊", "萬 塊" to "萬 塊。",
            "一點一 萬 塊" to "一點一 萬 塊", "一點一 萬 塊" to "一點一 萬 塊。",
            "一、二 萬 塊" to "一、二 萬 塊", "第二點五 萬 塊" to "第二點五 萬 塊",
            "一點半三 萬 塊" to "1:30三 萬 塊", "一點半三 萬 塊" to "1:30三 萬 塊。",
            "週五一點半三 萬 塊" to "週五1:30三 萬 塊",
        )
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        // 單獨的「萬」在旁邊時，真的值不見了還是要擋。
        val drops = listOf(
            "萬 塊，100 塊" to "萬 塊", "萬 塊，200 塊" to "萬 塊", "三 萬 塊，100 塊" to "三 萬 塊",
        )
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
    }

    // MARK: - FX-13 修復 R5：數字清單裡的頓號不能把值當成清單編號。與 Swift 同一份句對。

    /**
     * FX-13 修復 R5：掉值這條規則掃描時，「100、一百」裡的 100 是值不是清單編號——
     * 原文用逗號、輸出用頓號，兩個值都還在，不算掉值；真的有值不見了照樣擋；
     * 隔空格的清單編號（「1. 一百」）照舊是編號，只有一個值。同 Swift。
     */
    @Test
    fun numericListPunctuationKeepsValues() {
        val keeps = listOf(
            "100，一百" to "100、一百。", "100 一百" to "100、一百",
            "100；一百" to "100、一百。", "100，兩百" to "100、兩百。",
            "12000，一百" to "12000、一百", "100，一百" to "100，一百。",
            "7，一百" to "7、一百。",
        )
        for ((original, cleaned) in keeps) {
            assertFalse(CleanupFidelity.dropsNumberValues(original, cleaned), "不該算掉值：$original → $cleaned")
        }
        val drops = listOf("100，一百" to "100", "100、一百" to "100", "100，一百" to "100。")
        for ((original, cleaned) in drops) {
            assertTrue(CleanupFidelity.dropsNumberValues(original, cleaned), "掉值沒擋：$original → $cleaned")
        }
        assertFalse(CleanupFidelity.dropsNumberValues("1. 一百", "100"), "隔空格的清單編號不是值")
    }
}
