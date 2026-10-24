package com.utuvo.type

import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.NormalizerOptions
import com.utuvo.type.core.SentenceMood
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmartCleanupFidelityTest {
    @Test
    fun rejectsMeaningChangesAndAllowsFormattingCleanup() {
        assertFalse(SmartCleanup.accepts("然後送到清風教室去示範", "之後送往清風教室進行示範"))
        assertFalse(SmartCleanup.accepts("教室改成四樓，另外教材我會帶過去", "教室四樓，教材我會帶過去"))
        assertFalse(SmartCleanup.accepts("明天先確認大家收到資料再開會", "明天開會前，先確認大家是否都已收到資料。"))
        assertTrue(SmartCleanup.accepts("明天先確認大家收到資料再開會", "明天先確認大家收到資料，再開會。"))
        assertTrue(SmartCleanup.accepts("我想明天，不對，後天寄", "我想後天寄。"))
    }

    @Test
    fun acceptsOptionalFillerRemovalWithoutDroppingMeaningfulConnectors() {
        val source = "嗯,我覺得那個,就是,這個 low-end 還可以再收一點。"
        assertTrue(SmartCleanup.accepts(source, source))
        assertTrue(SmartCleanup.accepts(source, "我覺得這個 low-end 還可以再收一點。"))
        assertFalse(SmartCleanup.accepts("做完然後寄給他", "做完寄給他"))
    }

    @Test
    fun promptCandidateV2ProbeOutputsPassTheFullAndroidGate() {
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
            assertTrue("Probe case ${index + 1} was rejected", SmartCleanup.accepts(source, output))
        }
    }

    @Test
    fun q2OverEditsRemainRejectedByTheFullAndroidGate() {
        assertFalse(SmartCleanup.accepts("是不是該把主唱推到前面一點？", "該把主唱推到前面一點嗎？"))
        assertFalse(SmartCleanup.accepts("上面做的", "上做"))
        assertFalse(SmartCleanup.accepts("地點在3樓", "地點在三樓"))
        assertFalse(SmartCleanup.accepts("教室改成四樓", "教室四樓"))
        listOf("另外", "對了", "總之").forEach { transition ->
            assertFalse(SmartCleanup.accepts(
                "清單：先確認檔案，${transition}備份資料",
                "清單：\n1. 先確認檔案\n2. 備份資料"
            ))
        }
    }

    @Test
    fun q2ListProbeCasesPassTheFullAndroidGate() {
        val s17 = "今天的工作清單是,第一,更新Pro Tools,第二,匯出Stamps,第三,寫交付說明"
        assertTrue(SmartCleanup.accepts(
            s17,
            "今天的工作清單是：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ))
        assertTrue(SmartCleanup.accepts(
            s17,
            "今天的工作清單：\n1. 更新 Pro Tools\n2. 匯出 Stamps\n3. 寫交付說明"
        ))
        assertTrue(SmartCleanup.accepts(
            "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。",
            "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭"
        ))
    }

    /** 2026-10-22：人稱檢查從 iOS 搬進 core（CleanupFidelity.keepsPerson），Android 寬鬆與嚴格都檢查。 */
    @Test
    fun flippedPersonIsRejectedOnRelaxedAndStrictPaths() {
        // real-claude s5：「被搞問了」→「我被搞糊塗了」，iOS 擋、Android 以前收。
        val s5 = "Type那個 app在 Mace上叫做 Utuvortype，在手機上麵叫做 Utuvoltype，被搞問了。"
        assertFalse(SmartCleanup.accepts(s5, "Type那個 app 在 Mac 上叫做 Utuvortype，在手機上叫做 Utuvoltype，我被搞糊塗了。", relaxed = true))
        assertFalse(SmartCleanup.accepts("你覺得這個 mix 的低頻夠不夠", "我覺得這個 mix 的低頻夠了。", relaxed = true))
        assertFalse(SmartCleanup.accepts("你覺得這個版本可以直接給客戶聽嗎", "這個版本還不能直接給客戶聽。", relaxed = true))
        assertTrue(SmartCleanup.accepts("你覺得這個版本可以直接給客戶聽嗎", "你覺得這個版本可以直接給客戶聽嗎？", relaxed = true))
        assertTrue(SmartCleanup.accepts("是不是要重新開一個 session", "是不是要重新開一個 session？", relaxed = true))
        assertTrue(SmartCleanup.accepts("你覺得這個版本可以直接給客戶聽嗎", "你覺得這個版本可以直接給客戶聽嗎？"))
    }

    /** 2026-10-22：寬鬆把關（Claude）擋數值錯十倍與對比句翻轉（core 共用規則，同 Swift passesRelaxed）。 */
    @Test
    fun relaxedGateRejectsWrongValuesAndInvertedContrast() {
        assertFalse(SmartCleanup.accepts("總共是1,250塊", "總共是12,500塊", relaxed = true))
        assertFalse(SmartCleanup.accepts("下午3:30開會", "下午3:00開會", relaxed = true))
        assertFalse(SmartCleanup.accepts("我要的是三點不是四點", "我要的是四點。", relaxed = true))
        assertFalse(SmartCleanup.accepts("取樣率是48K不是96K", "取樣率是96K。", relaxed = true))
        assertTrue(SmartCleanup.accepts("我的電話是零九一二三四五六七八", "我的電話是 0912-345-678", relaxed = true))
        assertTrue(SmartCleanup.accepts("我要的是三點不是四點", "我要的是三點，不是四點。", relaxed = true))
        assertTrue(SmartCleanup.accepts("十十月十三號下午3:30，在公司的三樓會議室", "10 月 13 號下午3:30，在公司的三樓會議室", relaxed = true))
        // replay real-claude s23／s25（2026-10-17 錄的 Claude 輸出）。
        assertTrue(SmartCleanup.accepts(
            "我的電話是 0912到 345678傳真號碼是 02到 23333333。", "我的電話是 0912-345-678，傳真號碼是 02-2333-3333。", relaxed = true))
        assertFalse(SmartCleanup.accepts("預算是 30,00，第二期先付 10,00000。", "預算是 30,000，第二期先付 100,000。", relaxed = true))
    }

    /** 2026-10-22 cleanup-format-4：模型輸出先轉成第一次貼上的數字寫法（同 Mac／iOS），再過把關。 */
    @Test
    fun finishNormalizesModelNumbersBeforeTheGate() {
        // 第一次貼上是「12,000塊」，模型照原樣留中文數字：轉回同一種寫法、收下。
        assertEquals("金額是12,000塊", SmartCleanup.finishCleaned("金額是一萬兩千塊", "金額是12,000塊", relaxed = false))
        assertEquals("金額是12,000塊", SmartCleanup.finishCleaned("金額是一萬兩千塊", "金額是12,000塊", relaxed = true))
        // 樓層之類照舊不轉、照舊收下。
        assertEquals("教室改成三樓", SmartCleanup.finishCleaned("教室改成三樓", "教室改成三樓", relaxed = false))
        // 數值改錯還是擋。
        val wrong = runCatching { SmartCleanup.finishCleaned("總共是12,500塊", "總共是1,250塊", relaxed = true) }
        assertTrue(wrong.exceptionOrNull() is SmartCleanup.Rejected)
    }

    @Test
    fun timeoutUsesFourSecondsForShortTextAndCapsAtTen() {
        assertEquals(4_000L, SmartCleanup.timeoutMsFor("短".repeat(16)))
        assertEquals(10_000L, SmartCleanup.timeoutMsFor("長".repeat(56)))
        assertEquals(10_000L, SmartCleanup.timeoutMsFor("長".repeat(100)))
    }

    /** 2026-10-22 FX-3：Codex adversarial review 重現的五種「改了意思還被收下」，走 production accepts（寬鬆＋嚴格）。同 Mac。 */
    @Test
    fun meaningChangingOutputsAreRejectedOnBothPaths() {
        val wrong = listOf(
            "響度設為-14 LUFS" to "響度設為14 LUFS",
            "劑量為1.5毫克" to "劑量為5.1毫克",
            "預算是100元，訂金是200元" to "預算是200元，訂金是100元",
            "預算是100元，訂金是200元" to "預算是100元，訂金是100元",
            "開會時間是星期三不是星期四，地點不是台北" to "開會時間是星期四，地點不是台北",
            "預定的是台北不是台南，台北需要提前預約" to "預定的是台南，台北需要提前預約",
            "開會時間是星期三不是星期四" to "開會時間是星期四",
            "我明天會把報告寄給他" to "他明天會把報告寄給我",
            "You will send me the invoice tomorrow." to "I will send you the invoice tomorrow.",
            "響度設為負十四LUFS" to "響度設為14 LUFS",
            "增益是3dB" to "增益是-3dB",
            "預算是一百，訂金兩百" to "預算是兩百，訂金一百",
            "買三個蘋果和五個橘子" to "買五個蘋果和三個橘子",
            "我們約禮拜三，不是禮拜四開會，不是在公司" to "我們約禮拜四開會，不是在公司。",
            "我們會把檔案寄給他們" to "他們會把檔案寄給我們",
        )
        for ((original, cleaned) in wrong) {
            for (relaxed in listOf(true, false)) {
                assertFalse("${if (relaxed) "relaxed" else "strict"}：$original → $cleaned", SmartCleanup.accepts(original, cleaned, relaxed))
            }
        }
        // 正常整理照樣收下（兩條路都跑）。
        val fine = listOf(
            "響度設為-14 LUFS" to "響度設為 -14 LUFS。",
            "劑量為1.5毫克" to "劑量為 1.5 毫克。",
            "預算是100元，訂金是200元" to "預算是100元，訂金是200元。",
            "開會時間是星期三不是星期四，地點不是台北" to "開會時間是星期三，不是星期四，地點不是台北。",
            "我們約禮拜三，不是，禮拜五下午見" to "我們約禮拜五下午見。",
            "我明天會把報告寄給他" to "我明天會把報告寄給他。",
            "You will send me the invoice tomorrow." to "You will send me the invoice tomorrow.",
        )
        for ((original, cleaned) in fine) {
            for (relaxed in listOf(true, false)) {
                assertTrue("${if (relaxed) "relaxed" else "strict"}：$original → $cleaned", SmartCleanup.accepts(original, cleaned, relaxed))
            }
        }
        val relaxedOnly = listOf(
            "預算是100元，不對，150元，訂金是200元" to "預算是150元，訂金是200元。",
            "我明天會把報告寄給他" to "我明天會把報告寄給她。",
            "響度設為負14 LUFS" to "響度設為 -14 LUFS",
            "劑量為一點五毫克" to "劑量為 1.5 毫克。",
            "我們約3點開會，地點在5樓，不對，4點" to "我們約4點開會，地點在5樓。",
            "預定的是台北不是台南，台南那家下次再訂" to "預定的是台北，不是台南，台南那家下次再訂。",
        )
        for ((original, cleaned) in relaxedOnly) assertTrue("relaxed：$original → $cleaned", SmartCleanup.accepts(original, cleaned, relaxed = true))
    }

    /** 2026-10-22 FX-3 第二輪：獨立驗證重現的漏網，走 production accepts；寬鬆、嚴格都要擋，被誤擋的正常整理寬鬆路徑要收下。同 Mac。 */
    @Test
    fun roundTwoMeaningChangesAreRejectedAndHarmlessRewritesPass() {
        val wrong = listOf(
            "預定的是台北不是台南，台南那家下次再訂" to "預定的是台南，那家下次再訂。",
            "我要的是三點不是四點，四點我有別的會" to "我要的是4點，我有別的會。",
            "寄給客戶的是A版不是B版，B版的低頻還要再修" to "寄給客戶的是B版，低頻還要再修。",
            "要寄給小王，不是小李，小李那份明天再寄" to "要寄給小李，那份明天再寄。",
            "開會是星期三不是星期四，星期四我要出差" to "開會是星期四，我要出差。",
            "我們約禮拜三不是禮拜五下午見" to "我們約禮拜五下午見。",
            "我們約三點不是4點見面" to "我們約4點見面。",
            "開會星期三不是星期四" to "開會星期四",
            "檔案要寄給A版本不是B版本" to "那個檔案要寄B版本。",
            "我請他幫我訂明天下午的高鐵票" to "他請我訂明天下午的高鐵票。",
            "我會叫他明天打電話給我" to "他會叫我明天打電話。",
            "I told him to email me the file." to "He told me to email the file.",
            "我要一杯拿鐵跟兩杯美式" to "我要兩杯拿鐵跟一杯美式。",
            "開會時間是禮拜三不是禮拜四" to "開會時間是星期四。",
            "預定的是台北不是台南" to "預定的是臺南",
            "王經理要把合約寄給李律師" to "李律師要把合約寄給王經理。",
            "小明欠小華五百元" to "小華欠小明500元",
            "Alice owes Bob 500 dollars." to "Bob owes Alice 500 dollars.",
            "The meeting is on Wednesday, not Thursday." to "The meeting is on Thursday.",
            "I need the 3 pm slot, not the 4 pm slot." to "I need the 4 pm slot.",
            "Set the loudness to minus 14 LUFS." to "Set the loudness to 14 LUFS.",
            "響度設為負 14 LUFS" to "響度設為 14 LUFS",
            "預算是100元，訂金是200元，不對，是300元" to "預算是300元，訂金是200元",
            "我3點到公司，5點開會，不對，6點" to "我6:00到公司，5:00開會",
            "她要把錢轉給他" to "他要把錢轉給她",
            "LUFS-14是標準" to "LUFS 14是標準",
        )
        for ((original, cleaned) in wrong) {
            for (relaxed in listOf(true, false)) {
                assertFalse("${if (relaxed) "relaxed" else "strict"}：$original → $cleaned", SmartCleanup.accepts(original, cleaned, relaxed))
            }
        }
        val fine = listOf(
            "Set the loudness to minus 14 LUFS" to "Set the loudness to -14 LUFS.",
            "the gain is negative 3 dB" to "The gain is -3 dB.",
            "響度設為負 14 LUFS" to "響度設為 -14 LUFS。",
            "音量要減三dB" to "音量要 -3 dB。",
            "Me and him will fix it tomorrow" to "He and I will fix it tomorrow.",
            "me and her are going to the studio" to "She and I are going to the studio.",
            "at 3 pm on October 22 we meet" to "We meet on October 22 at 3 pm.",
            "明天下午三點，十月二十三號要交" to "10 月 23 日（明天）下午3點要交。",
            "我們約三點開會在5樓，不對，四點" to "我們約四點開會在5樓。",
            "我嗯要去，他要來" to "我要去，他要來。",
        )
        for ((original, cleaned) in fine) assertTrue("relaxed：$original → $cleaned", SmartCleanup.accepts(original, cleaned, true))
    }

    /**
     * 2026-10-22 FX-3 第三輪：第二輪獨立驗證重現的漏網與誤擋，走 production accepts。比對原文用本機第一次貼上
     * （SentenceMood.finish(Normalizer().normalize(raw).cleaned)）；寬鬆、嚴格都要擋，第二輪的誤擋寬鬆路徑要收下。同 Mac。
     */
    @Test
    fun roundThreeMeaningChangesAreRejectedAndHarmlessRewritesPass() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        val wrong = listOf(
            "我會叫他明天打電話給我" to "他明天會叫我打電話。",
            "我請他幫我訂明天下午的高鐵票" to "他要我訂明天下午的高鐵票。",
            "我拜託他幫我買咖啡" to "他明天拜託我買咖啡。",
            "I told him to email me the file" to "He asked me to email the file.",
            "I asked him to call me tomorrow" to "He told me to call tomorrow.",
            "我們要的是第二版不是第三版" to "我們要的是第三版。",
            "要交的是第一首不是第二首" to "要交的是第二首。",
            "開會不是星期四，而是星期三" to "開會是星期四。",
            "要寄的不是母帶而是混音" to "要寄的是母帶。",
            "The meeting is not on Thursday but on Wednesday" to "The meeting is on Thursday.",
            "我要的是三點而非四點" to "我要的是四點",
            "I need the 3 pm slot instead of the 4 pm slot" to "I need the 4 pm slot.",
            "We want the 48k version rather than the 96k version" to "We want the 96k version.",
        )
        for ((raw, cleaned) in wrong) {
            val original = firstPaste(raw)
            for (relaxed in listOf(true, false)) {
                assertFalse("${if (relaxed) "relaxed" else "strict"}：$original → $cleaned", SmartCleanup.accepts(original, cleaned, relaxed))
            }
        }
        val fine = listOf(
            "開會是星期三不是星期四，星期四我要出差" to "開會是星期三，不是星期四；星期四我要出差。",
            "寄的是混音版不是母帶版，母帶版還沒做完" to "寄的是混音版，不是母帶版；母帶版還沒做完。",
            "兩杯拿鐵，一杯美式" to "一杯美式，兩杯拿鐵",
            "我想要一杯咖啡跟一個蛋糕" to "我想要一個蛋糕跟一杯咖啡。",
            "如果明天下雨我們就改到室內" to "我們明天如果下雨就改到室內。",
            "我要的是三點不是四點，三點比較好，四點我有會" to "我要的是3點，不是4點，比較好；4點我有會。",
            "負一樓停車場" to "B1停車場",
            "我們要的是第二版不是第三版" to "我們要的是第二版，不是第三版。",
            "開會不是星期四，而是星期三" to "開會是星期三。",
            "我跟你說他明天會來找你" to "他明天會來找你。",
        )
        for ((raw, cleaned) in fine) {
            val original = firstPaste(raw)
            assertTrue("relaxed：$original → $cleaned", SmartCleanup.accepts(original, cleaned, true))
        }
        // 改口先重提是哪一個：本機版會把「不對，開會是四點」套到錯的值上（「3:00開會，四點吃飯」），這句用原話比。
        assertTrue(SmartCleanup.accepts("三點開會，五點吃飯，不對，開會是四點", "4:00開會，5點吃飯", true))
    }

    /**
     * FX-3 第四輪 fx-gate oracle 的每一列（G1–G5）。Swift `SmartCleanupTests.testRoundFourOracleRows` 是同一張表、同樣的期望。
     * 跟把關探針一樣：原文是本機版第一次貼上的字，整理結果先轉成同一種數字寫法再送把關。
     * 期望 false＝寬鬆、嚴格都要擋；true＝寬鬆（Claude）要放行。
     */
    @Test
    fun roundFourOracleRows() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        val rows = listOf(
            // G1 改口要換對的值：時刻「3:00」是一個值，「更正，六點」換掉的是最近的同類值（吃飯 5→6），不是 3
            Triple("三點開會，五點吃飯，更正，六點", "6點開會，5點吃飯。", false),
            Triple("三點開會，五點吃飯，不對，吃飯是六點", "6點開會，5點吃飯。", false),
            Triple("三點開會，五點吃飯，不對，六點", "6點開會，5點吃飯。", false),
            Triple("明天三點開會，後天五點吃飯，不對，六點", "明天6點開會，後天5點吃飯。", false),
            Triple("三點開會，五點吃飯，講錯了，六點", "6點開會，5點吃飯。", false),
            Triple("三點開會，五點吃飯，不對，開會是四點", "4點開會，6點吃飯。", false),
            // G2 受詞不能被升成主詞（省掉主詞的祈使句最常見）
            Triple("請他幫我訂票", "他請我訂票。", false),
            Triple("跟他說我明天會晚到", "他跟我說明天會晚到。", false),
            Triple("告訴她我明天不去", "她告訴我明天不去。", false),
            Triple("麻煩他幫我改一下", "他麻煩我改一下。", false),
            Triple("我會叫他明天打電話給我", "他明天會叫我打電話。", false),
            Triple("我拜託他幫我買咖啡", "他明天拜託我買咖啡。", false),
            Triple("我請他幫我訂明天下午的高鐵票", "他要我訂明天下午的高鐵票。", false),
            Triple("我明天會把報告寄給他", "他明天會把報告寄給我。", false),
            Triple("Tell him to send me the stems", "He told me to send the stems.", false),
            Triple("Ask her to call me tomorrow", "She asked me to call tomorrow.", false),
            Triple("Remind him to email me the mix", "He reminded me to email the mix.", false),
            Triple("I asked him to call me", "He said to call me.", false),
            Triple("I told him to email me the file", "He asked me to email the file.", false),
            Triple("You will send me the invoice tomorrow.", "I will send you the invoice tomorrow.", false),
            // G3 對比「A不是B」「A, it's not B」「A and not B」不能被整理成 B
            Triple("我要喝拿鐵不是美式", "我要喝美式。", false),
            Triple("這次用Pro Tools不是Logic", "這次用Logic。", false),
            Triple("It's Wednesday, it's not Thursday", "It's Thursday.", false),
            Triple("It's Wednesday, it isn't Thursday", "It's Thursday.", false),
            Triple("We meet on Wednesday, we don't meet on Thursday", "We meet on Thursday.", false),
            Triple("Use the 48k version, don't use the 96k version", "Use the 96k version.", false),
            Triple("Send it to Alice and not Bob", "Send it to Bob.", false),
            Triple("開會時間是星期三不是星期四", "開會時間是星期四。", false),
            Triple("開會不是星期四，而是星期三", "開會是星期四。", false),
            Triple("要寄的不是母帶而是混音", "要寄的是母帶。", false),
            Triple("我們要的是第二版不是第三版", "我們要的是第三版。", false),
            Triple("我住三樓，不是四樓", "我住四樓。", false),
            Triple("我要的是48K不是96K", "我要的是96K。", false),
            Triple("萬一不是三點呢", "三點呢？", false),
            Triple("100元，不是200元", "200元。", false),
            Triple("The meeting is not on Thursday but on Wednesday", "The meeting is on Thursday.", false),
            Triple("預定的是台北不是台南，台北需要提前預約", "預定的是台南，台北需要提前預約。", false),
            Triple("開會時間是星期三不是星期四，地點不是台北", "開會時間是星期四，地點不是台北。", false),
            // G4 負號、小數點、數值的主人不能掉或換
            Triple("響度設在負的十四LUFS", "響度設在14 LUFS。", false),
            Triple("響度設在負的三dB", "響度設在3 dB。", false),
            Triple("set it to minus fourteen LUFS", "Set it to fourteen LUFS.", false),
            Triple("響度設為-14 LUFS", "響度設為14 LUFS。", false),
            Triple("氣溫零下五度", "氣溫5度。", false),
            Triple("劑量為1.5毫克", "劑量為5.1毫克。", false),
            Triple("預算是100元，訂金是200元", "預算是200元，訂金是100元。", false),
            Triple("我買了1200元", "我買了12000元。", false),
            // G4 負號換寫法（負的三→-3、minus fourteen→-14）要放行
            Triple("響度設在負的三dB", "響度設在-3 dB。", true),
            Triple("響度設在負的十四LUFS", "響度設在-14 LUFS。", true),
            Triple("set it to minus fourteen LUFS", "Set it to -14 LUFS.", true),
            // G1 改口換對了值要放行
            Triple("三點開會，五點吃飯，更正，六點", "3點開會，6點吃飯。", true),
            Triple("三點開會，五點吃飯，不對，吃飯是六點", "3點開會，6點吃飯。", true),
            // G2 拿掉「說」「that」、原文本來就有主詞的要放行
            Triple("我想說他應該會打給我", "我想他應該會打給我。", true),
            Triple("我就想說他會等我", "我想他會等我。", true),
            Triple("我在想說他是不是忘了我", "我在想他是不是忘了我。", true),
            Triple("I told him that she will call me", "I told him she'll call me.", true),
            Triple("I told you that he loves me", "I told you he loves me.", true),
            // G3 照原話補標點的對比要放行
            Triple("是三點不是四點", "是三點，不是四點。", true),
            Triple("不是星期四而是星期三", "不是星期四，而是星期三。", true),
            Triple("我要喝拿鐵不是美式", "我要喝拿鐵，不是美式。", true),
            // 一般整理（刪贅詞、補標點、數字寫法）要放行
            Triple("呃那個我明天會把報告寄給他", "我明天會把報告寄給他。", true),
            Triple("那個他明天會來", "他明天會來。", true),
            Triple("他說他明天會來", "他說他明天會來。", true),
            Triple("三點，不對，四點出發", "4點出發。", true),
            Triple("檔名叫做Final V3,啊不對是Final V4", "檔名叫做 Final V4。", true),
            Triple("幫我轉寄給小雅跟小柏﹑不是,是小雅跟小潘﹑", "幫我轉寄給小雅跟小潘。", true),
            Triple("我請他幫我訂票", "我請他幫我訂票。", true),
            Triple("請他幫我訂票", "請他幫我訂票。", true),
            Triple("Tell him to send me the stems", "Tell him to send me the stems.", true),
            Triple("嗯我跟他說我明天會晚到", "我跟他說我明天會晚到。", true),
            Triple("他明天會把報告寄給我", "他明天會把報告寄給我。", true),
            Triple("我們明天三點開會", "我們明天3點開會。", true),
            // G5 lp01 條列整理要放行（oracle 這三列的條列是被攤平成一行的寫法）
            Triple("這次案子分成三個部分，第一個部分是前期的素材整理，主要把客戶給的 martetrack收進來。然後檢查每一軌的完整性另外第二個部分是實際的婚姻，這部分大概會花三天重點在於人生的空間感，總之交付的時候記得付一份 mixingnote", "這次案子分成三個部分： 1. 前期的素材整理，主要把客戶給的 marttrack 收進來，然後檢查每一軌的完整性。 2. 實際的混音，這部分大概會花三天，重點在於人生的空間感。 3. 交付的時候記得附一份 mixing note。", true),
            Triple("這次案子分成三個部分，第一個部分是前期的素材整理，主要把客戶給的 multitrack收進來，然後檢查每一鬼的彎。完整性另外第二個部分是實際的混音這部分大概會花三天，重點在於人生的空間感總之交付的時候記得付一份 Mikesenotes", "這次案子分成三個部分： 1. 前期的素材整理：主要把客戶給的 multitrack 收進來，然後檢查每一軌的完整性。 2. 實際的混音：這部分大概會花三天，重點在於人聲的空間感。 3. 總之，交付的時候記得附上一份 Mix notes。", true),
            Triple("這次案子分成三個部分，第一個部分是前期的素材整理，主要把客戶給的 multitrack收進來，然後檢查每一鬼的彎。完整性另外第二個部分是實際的混音這部分大概會花三天，重點在於人生的空間感總之交付的時候記得付一份 Mikesenotes", "這次案子分成三個部分： 1. 前期的素材整理，主要把客戶給的 multitrack 收進來，檢查每一軌的完整性。 2. 實際的混音，這部分大概會花三天，重點在於空間感。 3. 總之，交付時記得附上一份 Mikesenotes", true),
        )
        assertEquals(74, rows.size)
        for ((raw, candidate, accept) in rows) {
            val original = firstPaste(raw)
            val cleaned = Normalizer.normalizeNumbers(candidate)
            if (accept) {
                assertTrue("relaxed：$original → $cleaned", SmartCleanup.accepts(original, cleaned, true))
            } else {
                for (relaxed in listOf(true, false)) {
                    assertFalse("${if (relaxed) "relaxed" else "strict"}：$original → $cleaned", SmartCleanup.accepts(original, cleaned, relaxed))
                }
            }
        }
    }

    /**
     * FX-7 fx-seven oracle 的 18 列把關句（V1／R2／R3／M4；L5 條列在 core DeterministicStructureTest），加一列不帶句號的忠實照抄。
     * Swift `SmartCleanupTests.testFx7OracleRows` 是同一張表、同樣的期望。原文＝本機版第一次貼上的字，整理結果先轉成同一種數字寫法。
     * 期望：relaxed＝寬鬆（Claude）要不要放行；strict＝嚴格要不要放行（null＝oracle 沒規定）。
     */
    @Test
    fun fx7OracleRows() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        data class Row(val raw: String, val candidate: String, val relaxed: Boolean, val strict: Boolean?)
        val rows = listOf(
            // V1 版本號／點分識別碼每一段都要留（2.10 ≠ 2.1）；一般數值的小數尾零可以拿掉
            Row("請安裝版本2.10，這個版本比較穩定", "請安裝版本2.1，這個版本比較穩定", false, false),
            Row("升級到7.10.4", "升級到7.1.4", false, false),
            Row("版本V2.10上線了", "版本V2.1上線了。", false, false),
            Row("請安裝版本2.10，這個版本比較穩定", "請安裝版本 2.10，這個版本比較穩定。", true, true),
            Row("升級到7.10.4", "升級到 7.10.4。", true, true),
            Row("價格是3.50元", "價格是3.5元。", true, null),
            Row("音量調到1.50倍", "音量調到1.5倍。", true, null),
            // R2 補出來的重複數值要有原文根據；主人與次數照原文
            Row("預算100元，訂金200元", "預算100元，訂金100元，合計200元", false, false),
            Row("預算100元，訂金200元", "預算100元，訂金100元。", false, false),
            Row("預算100元，訂金200元", "預算100元，訂金200元。", true, true),
            // R3 名字在別處又出現時，誰對誰對調照樣擋
            Row("王經理要把合約寄給李律師，王經理明天休假", "李律師要把合約寄給王經理，王經理明天休假", false, false),
            Row("王經理要把合約寄給李律師，王經理明天休假", "李律師要把合約寄給王經理，王經理明天休假。", false, false),
            Row("王經理要把合約寄給李律師，王經理明天休假", "王經理要把合約寄給李律師，王經理明天休假。", true, true),
            Row("小陳把報告交給小林，小陳下午請假", "小林把報告交給小陳，小陳下午請假。", false, false),
            // M4 減號後面隔了空白還是負號
            Row("目標響度是− 14 LUFS，請照這個輸出", "目標響度是14 LUFS，請照這個輸出", false, false),
            Row("目標響度是14 LUFS，請照這個輸出", "目標響度是− 14 LUFS，請照這個輸出", false, false),
            Row("目標響度是− 14 LUFS，請照這個輸出", "目標響度是 -14 LUFS，請照這個輸出。", true, true),
            Row("目標響度是−14 LUFS，請照這個輸出", "目標響度是14 LUFS，請照這個輸出。", false, false),
            // 照原樣沒有句號也算忠實（oracle 的 R3「with or without the final 。」）
            Row("王經理要把合約寄給李律師，王經理明天休假", "王經理要把合約寄給李律師，王經理明天休假", true, true),
        )
        assertEquals(19, rows.size)
        for (row in rows) {
            val original = firstPaste(row.raw)
            val cleaned = Normalizer.normalizeNumbers(row.candidate)
            assertEquals("relaxed：$original → $cleaned", row.relaxed, SmartCleanup.accepts(original, cleaned, true))
            row.strict?.let { assertEquals("strict：$original → $cleaned", it, SmartCleanup.accepts(original, cleaned, false)) }
        }
    }

    /**
     * FX-9 fx-nine oracle 的 27 列（N1 開頭是數字的忠實照抄、N2 只有數字的一句、S1／其他改了開頭數值的句子）。
     * Swift `SmartCleanupTests.testFx9OracleRows` 是同一張表、同樣的期望。原文＝本機版第一次貼上的字，整理結果先轉成同一種數字寫法。
     * 期望：relaxed＝寬鬆（Claude）要不要放行；strict＝嚴格要不要放行（null＝oracle 沒規定）。
     */
    @Test
    fun fx9OracleRows() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        data class Row(val raw: String, val candidate: String, val relaxed: Boolean, val strict: Boolean?)
        val rows = listOf(
            // N1 開頭是小數或一串數字的忠實照抄（只補標點），兩個把關都放行
            Row("3.5元的咖啡", "3.5元的咖啡。", true, true),
            Row("3.5元", "3.5元。", true, true),
            Row("3.5元的咖啡很好喝", "3.5元的咖啡很好喝", true, true),
            Row("3.5元的咖啡很好喝", "3.5元的咖啡，很好喝。", true, null),
            Row("2.10版比較穩定", "2.10版比較穩定", true, true),
            Row("1.5倍速度比較好", "1.5倍速度比較好。", true, true),
            Row("1.1 ms", "1.1 ms。", true, true),
            Row("十點五 ms", "10.5 ms。", true, null),
            Row("八點三倍", "8.3倍", true, null),
            Row("三、一百", "三、一百。", true, true),
            Row("五、三萬就好", "五、三萬就好", true, true),
            // N2 只有數字的一句：照抄或換成千分位寫法，寬鬆把關放行；換了數值照樣擋
            Row("一萬二", "12,000。", true, null),
            Row("12000", "12,000", true, null),
            Row("一萬二", "12,000", true, null),
            Row("一萬二", "21,000。", false, false),
            Row("12000", "1,200", false, false),
            // S1 開頭的數值被改掉，兩個把關都擋
            Row("3.5元", "4.5元", false, false),
            Row("2.10版比較穩定", "3.10版比較穩定", false, false),
            Row("1.1 ms", "2.1 ms", false, false),
            Row("8.3倍", "9.3倍", false, false),
            Row("3.5元的咖啡", "4.5元的咖啡。", false, false),
            Row("3.5元的咖啡", "5.3元的咖啡。", false, false),
            Row("3.5元的咖啡", "35元的咖啡。", false, false),
            Row("1.1 ms", "11 ms", false, false),
            Row("2.10版比較穩定", "2.1版比較穩定", false, false),
            Row("3.5元的咖啡很好喝", "4.5元的咖啡很好喝", false, false),
            Row("1.5倍速度比較好", "2.5倍速度比較好", false, false),
        )
        assertEquals(27, rows.size)
        for (row in rows) {
            val original = firstPaste(row.raw)
            val cleaned = Normalizer.normalizeNumbers(row.candidate)
            assertEquals("relaxed：$original → $cleaned", row.relaxed, SmartCleanup.accepts(original, cleaned, true))
            row.strict?.let { assertEquals("strict：$original → $cleaned", it, SmartCleanup.accepts(original, cleaned, false)) }
        }
        // 只有數字的原文：寬鬆把關不把數字算進比例，但輸出是空的、或只剩標點，照樣擋。
        assertFalse(SmartCleanup.accepts("12,000", "。", true))
        assertFalse(SmartCleanup.accepts("12,000", "", true))
    }

    /**
     * FX-13：只有數字的一句被整理掉一個值＝無聲的資料遺失，寬鬆與嚴格把關都要擋；值一個不少或明講改口照放行。
     * 句對與 core 的 CleanupFidelityTest 同一份。
     */
    @Test
    fun numberOnlyCleanupMustNotDropAValue() {
        val mustReject = listOf(
            "100，200" to "100", "100，200" to "200", "一萬二，兩萬一" to "12,000",
            "100，200，300" to "100，300", "100 200" to "100", "100、200" to "100",
            "100和200" to "100", "100跟200" to "200", "3.5，4.5" to "3.5",
            "1200，2400" to "2400", "100，200" to "100。", "一百，兩百" to "100",
            "12,000，21,000" to "12,000", "100，100" to "100", "5，6，7" to "5，7",
            "100，200元" to "100元", "100元，200元" to "200元", "3:00，4:00" to "3:00",
            "2026，2027" to "2026",
            "2026年，2027年" to "2026年", "100圓，200圓" to "100圓",
            "30分鐘，40分鐘" to "30分鐘", "100～200" to "100",
        )
        // oracle／probe 拿「本機版第一次貼上的字」當原文；這裡用同樣的轉換，讓量的是同一件事。同 Swift。
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        for ((original, cleaned) in mustReject) {
            val source = firstPaste(original)
            assertFalse("寬鬆把關掉了值：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
            assertFalse("嚴格把關掉了值：$original → $cleaned", SmartCleanup.accepts(source, cleaned, false))
        }
        val mustAccept = listOf(
            "100，200" to "100，200。", "100，200" to "100、200", "一萬二，兩萬一" to "12,000，21,000",
            "100 200" to "100 200", "一萬二" to "12,000", "12000" to "12,000",
            "一萬不對兩萬" to "兩萬。", "一萬，不對，兩萬" to "兩萬。", "一萬我是說兩萬" to "兩萬。",
            "1200，不對，12000" to "12000。", "1200不對不對12000" to "12000。",
            "1200，我是說，12000" to "12000。", "1200啊不對12000" to "12000。",
            "100，200，300" to "100，200，300。", "3.5，4.5" to "3.5、4.5",
            "100～200" to "100-200", "2026年，2027年" to "2026年、2027年",
            "30分鐘，40分鐘" to "30分鐘、40分鐘",
        )
        for ((original, cleaned) in mustAccept) {
            val source = firstPaste(original)
            assertTrue("寬鬆把關擋了不該擋的：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
        val withWords = listOf(
            "預算100，運費200" to "預算100",
            "三點五萬塊" to "35,000塊",
            "我要100個，不對，200個" to "我要200個。",
        )
        for ((original, cleaned) in withWords) {
            val source = firstPaste(original)
            assertTrue("有實詞的句子照原判定：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
    }

    /**
     * FX-13 修復 R2：寬鬆把關的三個新政策——輸出的名額獨佔、單位詞不拆實詞、英文單位認得出來。
     * 這三條都是寬鬆把關本來放行、但不該放行的句子（嚴格把關本來就擋，所以這裡只量寬鬆那一道）。同 Swift。
     */
    @Test
    fun relaxedGateFollowsFx13RepairR2Policies() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        // ① 名額獨佔：整串與另一種讀法是同一個名額；連字號不能又當整串又當其中一段。
        val mustReject = listOf(
            "100-200，100" to "100-200", "1，1.0" to "1.0",
            "100kg，200kg" to "100kg", "100 kg，200 kg" to "100 kg",
        )
        for ((original, cleaned) in mustReject) {
            val source = firstPaste(original)
            assertFalse("寬鬆把關放行了掉值：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
        // ② 單位詞不拆實詞：「條件」不是單位，句子照原判定。③ 英文單位認得出來，但實詞不算單位。
        val mustAccept = listOf(
            "條件100，200" to "條件100", "100～200" to "100-200",
            "100kg，200kg" to "100kg，200kg", "100 kg，200 kg" to "100 kg，200 kg",
            "2026年，2027年" to "2026年、2027年", "100圓，200圓" to "100圓、200圓",
            "30分鐘，40分鐘" to "30分鐘、40分鐘",
        )
        for ((original, cleaned) in mustAccept) {
            val source = firstPaste(original)
            assertTrue("寬鬆把關擋了不該擋的：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
    }

    /**
     * FX-13 修復 R4：單獨的「萬」不是數值，沒有值可掉——原文與輸出一樣（連句號都一樣）要放行；
     * 真的有值不見了照樣擋。同 Swift。
     */
    @Test
    fun relaxedGateFollowsFx13RepairR4Policy() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        val mustAccept = listOf(
            "萬 塊" to "萬 塊", "萬 塊" to "萬 塊。",
            "一點一 萬 塊" to "一點一 萬 塊", "一點一 萬 塊" to "一點一 萬 塊。",
            "一、二 萬 塊" to "一、二 萬 塊", "第二點五 萬 塊" to "第二點五 萬 塊",
            "一點半三 萬 塊" to "1:30三 萬 塊", "一點半三 萬 塊" to "1:30三 萬 塊。",
            "週五一點半三 萬 塊" to "週五1:30三 萬 塊",
        )
        for ((original, cleaned) in mustAccept) {
            val source = firstPaste(original)
            assertTrue("寬鬆把關擋了不該擋的：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
        val mustReject = listOf(
            "萬 塊，100 塊" to "萬 塊", "萬 塊，200 塊" to "萬 塊", "三 萬 塊，100 塊" to "三 萬 塊",
        )
        for ((original, cleaned) in mustReject) {
            val source = firstPaste(original)
            assertFalse("寬鬆把關放行了掉值：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
    }

    /**
     * FX-13 修復 R3：重複的一段只吃一次（兩個值都還在就放行）；必要的完整單位詞（公里、公分、小時…）
     * 算數字句的一部分，掉一個值就要擋。同 Swift。
     */
    @Test
    fun relaxedGateFollowsFx13RepairR3Policies() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        val mustReject = listOf(
            "3公里，4公里" to "3公里", "3公分，4公分" to "3公分",
            "10小時，20小時" to "10小時", "100kg，200kg" to "100kg",
        )
        for ((original, cleaned) in mustReject) {
            val source = firstPaste(original)
            assertFalse("寬鬆把關放行了掉值：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
        val mustAccept = listOf(
            "100，100" to "100-100", "100～100" to "100-100",
            "3公里，4公里" to "3公里、4公里", "條件100，200" to "條件100",
        )
        for ((original, cleaned) in mustAccept) {
            val source = firstPaste(original)
            assertTrue("寬鬆把關擋了不該擋的：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
    }

    /**
     * FX-13 修復 R5：數字清單的標點（頓號）不能讓值被當成清單編號拿掉；
     * 有實詞的句子照原判定（買一百→1、一百 仍是嚴格擋、寬鬆放行）。同 Swift。
     */
    @Test
    fun relaxedGateFollowsFx13RepairR5Policies() {
        fun firstPaste(raw: String) = SentenceMood.finish(Normalizer(NormalizerOptions()).normalize(raw).cleaned)
        val mustAccept = listOf(
            "100，一百" to "100、一百。", "100 一百" to "100、一百",
            "100；一百" to "100、一百。", "100，兩百" to "100、兩百。",
            "12000，一百" to "12000、一百", "100，一百" to "100，一百。",
        )
        for ((original, cleaned) in mustAccept) {
            val source = firstPaste(original)
            assertTrue("寬鬆把關擋了不該擋的：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
        val mustReject = listOf("100，一百" to "100", "100、一百" to "100")
        for ((original, cleaned) in mustReject) {
            val source = firstPaste(original)
            assertFalse("寬鬆把關放行了掉值：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
        }
        val wordBearing = listOf("買一百" to "1、一百", "一百的" to "1、一百", "要一百" to "1、一百")
        for ((original, cleaned) in wordBearing) {
            val source = firstPaste(original)
            assertTrue("有實詞＝照原判定：$original → $cleaned", SmartCleanup.accepts(source, cleaned, true))
            assertFalse("嚴格把關照原判定：$original → $cleaned", SmartCleanup.accepts(source, cleaned, false))
        }
    }
}
