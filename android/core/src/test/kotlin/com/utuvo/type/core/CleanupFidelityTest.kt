package com.utuvo.type.core

import kotlin.test.Test
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
}
