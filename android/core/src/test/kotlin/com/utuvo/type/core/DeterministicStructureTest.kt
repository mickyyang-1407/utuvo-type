package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 本機整理的條列與分段（2026-10-22 W2-6，Typeless 對打 ls01–ls05／lp01–lp04）。
 * 與 Swift Tests/UTUVOTypeCoreTests/DeterministicStructureTests.swift 案例逐字相同；行為以 Swift 為準（同批輸入也在 golden）。
 */
class DeterministicStructureTest {
    private val n = Normalizer()
    private fun done(s: String) = SentenceMood.finish(n.normalize(s).cleaned)

    private val ls01 = "接下來有三件事,第一是把low end收乾淨,第二是把delay收短,第三是重做母帶,記得喔!"
    private val ls02 = "今天的工作清單是第一更新Pro Tools,第二匯出Stems,第三寫交付說明"
    private val ls03 = "幫我準備四樣東西﹐播放器、耳機、線材、還有轉接頭﹐"
    private val ls05 = "兩個重點,第一,響度對齊到-14 LUFS,第二,不要壓dynamic range,一定要記得"
    private val lp01 = "這次案子分成三個部分,第一個部分是前期的素材整理,主要把客戶給的Multi-Track收進來,然後檢查每一軌的完整性。另外第二個部分是實際的混音,這部分大概會花三天,重點在於人生的空間感。總之交付的時候記得付一份Mixing Note"
    private val lp02 = "先講一下目前錄音室的狀況,那個隔音其實還不錯,但是麥克風的位置需要再重新架一下,另外低頻的殘響有點重,可能要加吸音棉。對了,錄音室的空調聲要在錄音前先關掉,不然後面的去除會很麻煩。總之,先把環境弄好再錄,效率會比以前高很多。"
    private val lp03 = "講一下這張專輯的製作流程,首先我們花了三個禮拜做demo,收集了12首候選曲,接著選曲,過程中刪掉了一半,留下的6首都請客戶聽過,另外編曲的部分交給外面的一位編曲人,他一個月交3首,總之,專輯預計11月中上架。"
    private val lp04 = "關於版權這件事我要多講幾句,首先,同一首歌詞在兩張專輯上面法律上是允許的,但是唱片公司不一定接受。對了,如果你的歌有授權給別人表演,表演收錄的分配要另外談,總之簽約之前,務必把這些條款看清楚。"
    private val questionThenOpener = "大家覺得這個版本的混音可以直接交給客戶了嗎，另外錄音室的冷氣修好了，可以開始排下週的錄音，對了母帶的時程也要再確認一下，總之有問題再跟我說，謝謝大家這陣子的幫忙。"
    private val midClauseOpeners = "那個我另外買了一個混音器，我們今天下午在錄音室把所有的分軌整理好，大概花了三個小時，還要做母帶，進度還算順利，下週再確認時程，謝謝大家今天的幫忙，辛苦了大家，我們下次見，記得把檔案備份好，另外的部分再說。"

    // 1. 序數行 → 編號清單

    @Test fun ordinalLinesBecomeNumberedList() {
        assertEquals("接下來有三件事：\n1. 把low end收乾淨\n2. 把delay收短\n3. 重做母帶，記得喔！", done(ls01))
        assertEquals("今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明", done(ls02))
        assertEquals("兩個重點：\n1. 響度對齊到-14 LUFS\n2. 不要壓dynamic range，一定要記得", done(ls05))
        assertEquals("我說三件事。\n1. 買菜\n2. 煮飯\n3. 洗碗", done("我說三件事。第一是買菜，第二是煮飯，第三是洗碗。"))
        assertEquals("1. 是不是要先開會\n2. 誰負責", done("第一是不是要先開會，第二是誰負責"))
    }

    /** FX-7 L5：條列只拿掉當「是」用的那個字；「是非」「是否」「是不是」開頭的詞留著。同 Swift testFx7ListCopulaKeepsWordsThatStartWithShi。 */
    @Test fun fx7ListCopulaKeepsWordsThatStartWithShi() {
        val rows = listOf(
            "考卷分兩部分，第一是非題，第二是選擇題" to "考卷分兩部分：\n1. 是非題\n2. 選擇題",
            "第一是是非題，第二是選擇題" to "1. 是非題\n2. 選擇題",
            "第一是否要延期，第二是預算多少" to "1. 是否要延期\n2. 預算多少",
            "第一是報告，第二是預算" to "1. 報告\n2. 預算",
            "第一是不是要延期，第二是預算多少" to "1. 是不是要延期\n2. 預算多少",
            // 「個是」「點是」「就是」後面的「是」也是同一條規則。
            "第一個是否要延期，第二個是預算多少" to "1. 是否要延期\n2. 預算多少",
            "第一點是是非題，第二點是選擇題" to "1. 是非題\n2. 選擇題",
            "第一就是是不是要延期，第二就是預算" to "1. 是不是要延期\n2. 預算",
            // 「是非常」的「是」是繫詞，照舊拿掉。
            "第一是非常重要的事，第二是預算" to "1. 非常重要的事\n2. 預算",
        )
        for ((raw, expected) in rows) assertEquals(expected, done(raw), raw)
    }

    @Test fun ordinalsThatAreNotAListStayAsBefore() {
        assertEquals("第一次來台北，覺得很好玩", done("第一次來台北，覺得很好玩"))
        // 第三輪政策（同 Swift）：不符合條列規則的序數串整句原樣，連切行也不做。
        assertEquals("他是第一名，第二次來", done("他是第一名，第二次來"))
        assertEquals("第一個部分是素材，第二個部分是混音", done("第一個部分是素材，第二個部分是混音。"))
        assertEquals("第一是A，第三是B", done("第一是A，第三是B"))
        assertEquals("第二是先買菜，第三是煮飯", done("第二是先買菜，第三是煮飯"))
        assertEquals("1. 買牛奶\n2. 回信", done("1. 買牛奶\n2. 回信"))
        assertEquals("- 第一點\n- 第二點", n.normalize("- 第一點\n- 第二點").cleaned)
    }

    @Test fun ordinalHelpers() {
        assertEquals(3, Normalizer.parseOrdinalLine("第三是重做母帶，")?.first)
        assertEquals("重做母帶", Normalizer.parseOrdinalLine("第三是重做母帶，")?.second)
        assertEquals("響度", Normalizer.parseOrdinalLine("第一，響度")?.second)
        assertNotNull(Normalizer.parseOrdinalLine("第一名，"))
        assertNull(Normalizer.parseOrdinalLine("第一名，")?.second)
        assertNull(Normalizer.parseOrdinalLine("他是第一名"))
        assertEquals("接下來有三件事：", Normalizer.listIntro("接下來有三件事,"))
        assertEquals("今天的工作清單是：", Normalizer.listIntro("今天的工作清單是"))
        assertEquals("我說三件事。", Normalizer.listIntro("我說三件事。"))
    }

    // 2. 明講數量的頓號列舉 → 編號清單

    @Test fun countedEnumerationBecomesNumberedList() {
        assertEquals("幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭", done(ls03))
        assertEquals("有三點：\n1. 響度\n2. 動態\n3. 空間感", done("有三點：響度、動態、空間感"))
        assertEquals("幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭\n明天要用。",
            done("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。明天要用。"))
    }

    @Test fun enumerationsThatDoNotQualifyStayUntouched() {
        for (s in listOf(
            "幫我準備四樣東西，播放器、耳機、線材",
            "他說要準備十樣東西，A、B、C",
            "我準備了東西，播放器、耳機、線材",
            "需要三樣東西，把所有分軌檔案都重新命名一次、匯出、上傳",
            "我買了三樣東西，紙、筆、橡皮擦，然後就回家了",
            "幫我準備四樣東西，播放器、耳機、線材、轉接頭？",
        )) {
            assertFalse(n.normalize(s).cleaned.contains("\n"), s)
            assertEquals(SentenceMood.finish(s), done(s), s)
        }
    }

    // 3. 長文分段：句中轉折詞

    @Test fun discourseMarkersSplitParagraphsLikeTypeless() {
        assertEquals("這次案子分成三個部分。\n\n第一個部分是前期的素材整理，主要把客戶給的Multi-Track收進來，然後檢查每一軌的完整性。\n\n另外第二個部分是實際的混音，這部分大概會花三天，重點在於人生的空間感。\n\n總之交付的時候記得付一份Mixing Note", done(lp01))
        assertEquals("先講一下目前錄音室的狀況，隔音其實還不錯，但是麥克風的位置需要再重新架一下。\n\n另外低頻的殘響有點重，可能要加吸音棉。\n\n對了，錄音室的空調聲要在錄音前先關掉，不然後面的去除會很麻煩。\n\n總之，先把環境弄好再錄，效率會比以前高很多。", done(lp02))
        assertEquals("講一下這張專輯的製作流程。\n\n首先我們花了三個禮拜做demo，收集了12首候選曲。\n\n接著選曲，過程中刪掉了一半，留下的6首都請客戶聽過。\n\n另外編曲的部分交給外面的一位編曲人，他一個月交3首。\n\n總之，專輯預計11月中上架。", done(lp03))
        assertEquals("關於版權這件事我要多講幾句。\n\n首先，同一首歌詞在兩張專輯上面法律上是允許的，但是唱片公司不一定接受。\n\n對了，如果你的歌有授權給別人表演，表演收錄的分配要另外談。\n\n總之簽約之前，務必把這些條款看清楚。", done(lp04))
    }

    @Test fun splitAtCommaBecomesSentenceEndWithMood() {
        assertEquals("大家覺得這個版本的混音可以直接交給客戶了嗎？\n\n另外錄音室的冷氣修好了，可以開始排下週的錄音。\n\n對了母帶的時程也要再確認一下。\n\n總之有問題再跟我說，謝謝大家這陣子的幫忙！", done(questionThenOpener))
        assertEquals(listOf("狀況還不錯，", "另外低頻有點重，可能要加吸音棉。"), Normalizer.splitAtClauseOpeners("狀況還不錯，另外低頻有點重，可能要加吸音棉。"))
    }

    /** 「接著」跟首先／另外／總之同一組轉折詞（同 Swift testJieZheOpensAParagraphLikeTheOtherMarkers）。 */
    @Test fun jieZheOpensAParagraphLikeTheOtherMarkers() {
        assertEquals(listOf("收集了12首候選曲，", "接著選曲，過程中刪掉了一半"), Normalizer.splitAtClauseOpeners("收集了12首候選曲，接著選曲，過程中刪掉了一半"))
        assertEquals("先說明一下今天錄音的流程。\n\n首先大家9:00到錄音室集合，確認麥克風跟耳機都正常。\n\n接著我們先錄鼓的部分，大概要花兩個小時。\n\n另外貝斯跟吉他排在下午。\n\n總之晚上之前要全部錄完。",
            done("先說明一下今天錄音的流程，首先大家九點到錄音室集合，確認麥克風跟耳機都正常，接著我們先錄鼓的部分，大概要花兩個小時，另外貝斯跟吉他排在下午，總之晚上之前要全部錄完。"))
        for (s in listOf("他講完以後緊接著換我上台", "我接著說明這次的混音方向", "大家都很投入，接著的部分就交給大家討論", "他在信裡面寫，接著要先選曲")) {
            assertEquals(listOf(s), Normalizer.splitAtClauseOpeners(s), s)
        }
        assertEquals("收集完素材，接著選曲", done("收集完素材，接著選曲。"))
    }

    @Test fun markersInsideAClauseOrShortTextDoNotSplit() {
        assertEquals("我另外買了一個混音器，我們今天下午在錄音室把所有的分軌整理好，大概花了三個小時，還要做母帶，進度還算順利，下週再確認時程，謝謝大家今天的幫忙，辛苦了大家，我們下次見，記得把檔案備份好，另外的部分再說", done(midClauseOpeners))
        assertEquals(listOf("我另外買了一個，要另外談，另外的部分再說"), Normalizer.splitAtClauseOpeners("我另外買了一個，要另外談，另外的部分再說"))
        assertEquals("今天開會，另外記得買咖啡，最後回信，總之先這樣", done("今天開會，另外記得買咖啡，最後回信，總之先這樣。"))
        val lined = "第一行。\n" + lp02
        assertEquals(lined, Normalizer.paragraphize(lined))
    }

    // 4. 同一句的鐘點寫法一致

    @Test fun contrastedHourFollowsConvertedFormat() {
        assertEquals("我們約3:00開會，不是4:00", done("我們約三點開會，不是四點"))
        assertEquals("我們3:30開會，不是4:00", done("我們三點半開會，不是四點"))
        assertEquals("明天下午3:00開會，還是4:00吧", done("明天下午三點開會，還是四點吧"))
        assertEquals("我們約下午3點見，還是4點", done("我們約下午三點見，還是四點"))
        assertEquals("我們約3:00開會，不是4:00", Normalizer.normalizeNumbers("我們約三點開會，不是四點"))
    }

    @Test fun hoursWithoutAConvertedPartnerStayUntouched() {
        assertEquals("我要的是三點不是四點", done("我要的是三點不是四點"))
        assertEquals("3:00開會，重點有兩點", done("三點開會，重點有兩點"))
        assertEquals("我們約3:00開會。不是四點", done("我們約三點開會。不是四點"))
        assertEquals("3:00開會，不是一點點", done("三點開會，不是一點點"))
        assertEquals("十二點吃飯，不是十一點", done("十二點吃飯，不是十一點"))
    }

    /** 寫法一致之後，寬鬆把關（兩邊先 normalizeNumbers）看得出「4:00開會」是對比句翻轉；CleanupFidelity 本身沒改。 */
    @Test fun consistentHoursLetTheGateSeeAFlippedContrast() {
        val o = Normalizer.normalizeNumbers("我們約三點開會，不是四點")
        assertTrue(CleanupFidelity.invertsContrast(o, Normalizer.normalizeNumbers("我們約4:00開會")))
        assertFalse(CleanupFidelity.invertsContrast(o, Normalizer.normalizeNumbers("我們約3:00開會，不是4:00")))
    }

    // 單行輸入框

    @Test fun singleLineKeepsNumberedItemsApart() {
        assertEquals("今天有三件事：1. 買牛奶 2. 回email 3. 寫報告。", OutputShape.singleLine("今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告。"))
        assertEquals("今天有三件事第一買牛奶第二回email。", OutputShape.singleLine("今天有三件事\n第一買牛奶\n第二回email。"))
    }

    /** 單行框（numberedLists = false）：不出編號清單，維持整理前的逗號／頓號寫法。 */
    @Test fun singleLineFieldsKeepTheCommaForm() {
        val single = Normalizer(NormalizerOptions(numberedLists = false))
        fun shaped(s: String) = OutputShape.singleLine(SentenceMood.finish(single.normalize(s).cleaned))
        assertEquals("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭", shaped("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。"))
        assertEquals("今天有三件事，買牛奶、回email、寫報告", shaped("今天有三件事，買牛奶、回email、寫報告。"))
        assertEquals("今天有三件事，\n第一買牛奶，\n第二回email，\n第三寫報告。", single.normalize("今天有三件事，第一買牛奶，第二回email，第三寫報告。").cleaned)
        // 第四輪（2026-10-22）政策 (A)：沒有標點的連續序數串不是條列，連切行也不做（第三輪這句會切成四行）。
        assertEquals("今天有三件事第一買牛奶第二回email第三寫報告。", single.normalize("今天有三件事第一買牛奶第二回email第三寫報告。").cleaned)
        assertFalse(shaped(ls01).contains("1. "))
    }

    // 5. 2026-10-22 審查修正：誤判與吃字

    /** 第三輪政策（同 Swift）：整句原樣，連切行也不做（第二輪的預期是每個「第N」前面換行）。 */
    @Test fun ordinalNounPhrasesKeepTheirOrdinals() {
        val cases = listOf(
            "第一軌是 kick，第二軌是 snare。" to "第一軌是 kick，第二軌是 snare",
            "我第一台電腦是 iMac，第二台是 Mac Studio。" to "我第一台電腦是 iMac，第二台是 Mac Studio",
            "第一遍聽的時候覺得還好，第二遍就覺得低頻太多了。" to "第一遍聽的時候覺得還好，第二遍就覺得低頻太多了！",
            "第一小提琴太大聲，第二小提琴有點被蓋掉。" to "第一小提琴太大聲，第二小提琴有點被蓋掉",
            "我的第一選擇是 Pro Tools，第二選擇是 Logic Pro。" to "我的第一選擇是 Pro Tools，第二選擇是 Logic Pro",
            "我覺得第一跟第二都可以，你決定。" to "我覺得第一跟第二都可以，你決定",
            "第一拍要重一點，第二拍輕一點。" to "第一拍要重一點，第二拍輕一點",
            "第一聲道是左，第二聲道是右。" to "第一聲道是左，第二聲道是右",
        )
        for ((input, expected) in cases) assertEquals(expected, done(input), input)
        assertEquals("今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明", done(ls02))
        // 第三輪：「軌」在量詞表裡＝「第一軌」是名詞片語，內容是 null（第二輪這裡是「直接接內容」third == true）。
        assertNull(Normalizer.parseOrdinalLine("第一軌是 kick，")?.second)
        assertEquals("買菜", Normalizer.parseOrdinalLine("第一是買菜；")?.second)
    }

    @Test fun singleCharacterConnectorsStayInTheItem() {
        assertEquals("我要買三樣東西：\n1. 豬肉\n2. 雞肉\n3. 和牛", done("我要買三樣東西，豬肉、雞肉、和牛"))
        assertEquals("我想吃三樣東西：\n1. 牛排\n2. 壽司\n3. 和菓子", done("我想吃三樣東西，牛排、壽司、和菓子"))
        assertEquals("這段要注意兩點：\n1. 節奏\n2. 和弦", done("這段要注意兩點，節奏、和弦。"))
        for (s in listOf("副歌要加兩樣，弦樂、和聲。", "我點了兩樣，牛舌、和牛。", "這次要拍兩個，定點、跟拍。", "我想到兩個，戰爭、和平。")) {
            assertEquals(SentenceMood.finish(s), done(s), s)
        }
        assertEquals("幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭", done("幫我準備四樣東西，播放器、耳機、線材、以及轉接頭"))
    }

    @Test fun countedEnumerationFalsePositivesStayAsWritten() {
        val cases = listOf(
            "我買了兩個，紅的、藍的。" to "我買了兩個，紅的、藍的",
            "這兩個，紅的、藍的都不錯。" to "這兩個，紅的、藍的都不錯",
            "我比較喜歡第二個，乾淨、溫暖。" to "我比較喜歡第二個，乾淨、溫暖",
            "我覺得第三個，速度、價格、品質都比較好。" to "我覺得第三個，速度、價格、品質都比較好",
            "明天下午三點，我、阿明、小美去錄音室。" to "明天下午3點，我、阿明、小美去錄音室",
            "會議改到四點，小明、小華、阿強、阿美都要到。" to "會議改到四點，小明、小華、阿強、阿美都要到",
            "他說五點，你、我、他、小明、阿華都要到。" to "他說五點，你、我、他、小明、阿華都要到",
            "那就約兩點，你、我。" to "那就約兩點，你、我",
            "這三個，小明、小華、阿強你們負責。" to "這三個，小明、小華、阿強你們負責",
            "給我三個，大的、中的、小的各一個。" to "給我三個，大的、中的、小的各一個",
            "剩下兩件，明天、後天再弄。" to "剩下兩件，明天、後天再弄",
            "我要兩個，一個給你、一個給我。" to "我要兩個，一個給你、一個給我",
            "每兩個，紅的、藍的。" to "每兩個，紅的、藍的",
            "明天三點，小明、小華、小美都會來" to "明天3點，小明、小華、小美都會來",
            "我們約三點，小明、小華、小美都會來" to "我們約三點，小明、小華、小美都會來",
            "下午兩點，阿明、阿華" to "下午2點，阿明、阿華",
        )
        for ((input, expected) in cases) assertEquals(expected, done(input), input)
        assertEquals("今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告", done("今天有三件事，買牛奶、回email、寫報告。"))
        assertEquals(done("今天有三件事，買牛奶、回email、寫報告。"), done("今天有三件事，第一買牛奶，第二回email，第三寫報告。"))
    }

    @Test fun determinerAndReportedSpeechOpenersDoNotSplit() {
        val texts = listOf(
            "我們這次找了兩個混音師。一個負責 stereo 版本，另外一個專門做 Atmos，兩個人的風格不太一樣。所以我會在中間協調，確保兩個版本聽起來是同一張專輯，這部分要花比較多時間溝通，大家再給我一點時間。",
            "老師上課的時候一直強調，首先要把耳朵練好，再來才是學軟體。我覺得這句話很有道理，因為很多學生一開始就急著學各種外掛。結果連基本的 EQ 都聽不出來，這樣其實很可惜，我自己以前也是這樣過來的，所以特別有感觸。",
            "小明說他今天會晚到，因為要先去接小孩，另外一個原因是車子送修，所以要搭捷運過來。我跟他說沒關係，我們先開始，最後半小時再請他補充意見就好。會議記錄我會寫好再寄給大家，有問題再跟我說。",
            "我們剛剛把整首歌又聽了一遍。主歌很好，副歌的和聲有點太多，對了一半的意見是說鼓太大聲，其實是 bass 太大聲。總之我先把 bass 降兩個 dB，明天再給大家聽，有意見再跟我說就好。",
            "我剛剛聽完你寄來的混音，你問我低頻是不是太多，對了一半，kick 的部分確實太多，但是 bass 其實剛好，另外 vocal 的齒音有點刺耳，可以再用 de-esser 處理一下，整體來說比上一版好很多。",
            "這次巡演總共跑了五個城市。台北跟台中的場地都很棒，高雄那場音響有點問題，最後一天在台南的場地反而是最好的，觀眾也最熱情。整體來說這次巡演還算順利，明年應該還會再辦一次。",
            "我們昨天討論了很久要不要把 vocal 再往前推一點。因為副歌的時候其實有點被吉他蓋住，大家意見都不太一樣，最後還是決定先維持原本的平衡。等明天用另一副耳機確認一次，如果還是覺得太後面再來調整就好。",
            "這段吉他 solo 我覺得前面都很好。中間的推弦有一點點不準，可以再補錄一次看看，最後面那個長音的尾巴太突然了，可以再拉長一點。這樣聽起來會比較自然，整體來說還是很棒的一段 solo，辛苦你了，明天見。",
        )
        for (s in texts) assertFalse(done(s).contains("\n"), s)
        for (s in listOf("一個負責 stereo 版本，另外一個專門做 Atmos", "老師一直強調，首先要把耳朵練好", "我們先開始，最後半小時再補充",
                         "高雄有點問題，最後一天在台南", "意見不一樣，最後還是決定維持", "可以再補錄，最後面那個長音", "你問我低頻是不是太多，對了一半")) {
            assertEquals(listOf(s), Normalizer.splitAtClauseOpeners(s), s)
        }
        assertEquals(listOf("狀況還不錯，", "另外低頻有點重"), Normalizer.splitAtClauseOpeners("狀況還不錯，另外低頻有點重"))
    }

    @Test fun contrastedCountsAreNotClockTimes() {
        assertEquals("下午2:00開會，重點有三點，不是四點", done("下午兩點開會，重點有三點，不是四點。"))
        assertEquals("3:00開會，這次只要講三點，還是四點？", done("三點開會，這次只要講三點，還是四點？"))
        assertEquals("下午3:00開會，我列了五點重點，還是六點？", done("下午三點開會，我列了五點重點，還是六點？"))
        assertEquals("明天3:00開會，要講的重點有三點，不是兩點", done("明天三點開會，要講的重點有三點，不是兩點"))
        assertEquals("下午3點的會議，重點還是兩點", done("下午三點的會議，重點還是兩點"))
        assertEquals("比數是3:05，不是四點", done("比數是3:05，不是四點"))
    }

    @Test fun multiLineResultsDoNotEndOnAComma() {
        assertEquals("講一下這張專輯的製作流程。\n\n首先我們花了三個禮拜做demo，收集了12首候選曲。\n\n接著選曲，過程中刪掉了一半，留下的6首都請客戶聽過。\n\n另外編曲的部分交給外面的一位編曲人，他一個月交3首。\n\n總之，專輯預計11月中上架",
            done(lp03.dropLast(1) + ","))
        assertEquals("今天的session很順利，我們把vocal tuning都做完了。\n\n另外drum的部分還要再調整一下。\n\n對了client說deadline可能會提前。\n\n總之大家加油",
            done("今天的session很順利,我們把vocal tuning都做完了,另外drum的部分還要再調整一下,對了client說deadline可能會提前,總之大家加油,"))
        assertEquals("幫我準備三樣東西：\n1. A\n2. B\n3. C\n明天要用", done("幫我準備三樣東西，A、B、C。明天要用，"))
        assertEquals("首先整理桌面\n其次回信\n最後趕稿", done("首先整理桌面其次回信最後趕稿，"))
        assertEquals("第一段，\n\n第二段", Normalizer.dropDanglingEndOfLines("第一段，\n\n第二段，"))
        assertEquals("單行，", Normalizer.dropDanglingEndOfLines("單行，"))
    }

    @Test fun listItemsEndTheSameWay() {
        assertEquals("1. 買菜\n2. 煮飯\n3. 洗碗", done("第一是買菜；第二是煮飯；第三是洗碗"))
        assertEquals("1. 買菜\n2. 煮飯\n3. 洗碗", done("第一是買菜:第二是煮飯:第三是洗碗"))
        assertEquals("今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告\n明天再說。", done("今天有三件事，第一買牛奶，第二回email，第三寫報告。明天再說。"))
        assertEquals("洗碗", Normalizer.trimListItem("洗碗；。 "))
    }

    @Test fun shortEnglishMessagesStayOneParagraph() {
        for (s in listOf("Thanks for the update. Also, can you send the file? Anyway, see you tomorrow at the studio.",
                         "Got your message about the mix. Also, the client called. Anyway, call me back when you can.",
                         "Hi team, the mix is approved. Also, the master is due Friday. Finally, thanks for your hard work!")) {
            assertEquals(s, done(s), s)
        }
        val long = "Hi team, quick update on the album. We finished mixing all twelve songs this week and the client is happy with the overall sound so far. Also, the mastering engineer needs the final stems by Friday, so please export them tonight if you can. Anyway, thanks again for all the hard work on this project, and let me know if anything is missing."
        assertEquals(3, done(long).split("\n\n").size)
    }

    @Test fun paragraphEndingInEnglishClosesWithAPeriod() {
        assertEquals("混音師說他會先處理 vocal tuning.", Normalizer.closeParagraph("混音師說他會先處理 vocal tuning,"))
        assertEquals("先處理到 track 12.", Normalizer.closeParagraph("先處理到 track 12，"))
        assertEquals("可能要加吸音棉。", Normalizer.closeParagraph("可能要加吸音棉，"))
        assertEquals("今天的錄音整體來說很順利，鼓組跟貝斯都一次就錄好了，吉他的部分花了比較多時間，但是最後的效果大家都很滿意，人聲的部分明天再繼續，混音師說他會先處理 vocal tuning.\n\n另外下週要跟客戶確認最後的 mix.\n\n總之大家辛苦了，謝謝大家！",
            done("今天的錄音整體來說很順利，鼓組跟貝斯都一次就錄好了，吉他的部分花了比較多時間，但是最後的效果大家都很滿意，人聲的部分明天再繼續，混音師說他會先處理 vocal tuning,另外下週要跟客戶確認最後的 mix,總之大家辛苦了，謝謝大家。"))
    }

    @Test fun cleaningTwiceGivesTheSameResult() {
        val s = "這次錄音我需要三樣東西，麥克風、耳機、線材，另外錄音室的冷氣要先修好，不然錄起來會有很明顯的底噪，對了客戶說交期可能會提前一週，總之大家先把時間空出來，謝謝大家。"
        val once = n.normalize(s).cleaned
        assertEquals("這次錄音我需要三樣東西，麥克風、耳機、線材。\n\n另外錄音室的冷氣要先修好，不然錄起來會有很明顯的底噪。\n\n對了客戶說交期可能會提前一週。\n\n總之大家先把時間空出來，謝謝大家！", once)
        assertEquals(once, n.normalize(once).cleaned)
        assertEquals("高頻好像有點毛，你再聽一下", n.normalize("然後然後那個高頻好像有點毛,你再聽一下").cleaned)
        assertEquals("第一段。\n\n第二段。", Normalizer.collapseWhitespace("第一段。\n\n第二段。"))
    }

    // 6. 2026-10-22 第二輪審查修正（與 Swift 同名測試逐字相同）

    @Test fun contrastedCountsStayCountsWhenTheClockTimeComesLater() {
        val cases = listOf(
            "重點有三點，不是四點，我們下午兩點開會。" to "重點有三點，不是四點，我們下午2:00開會",
            "我覺得重點有兩點，不是三點，下午四點再討論。" to "我覺得重點有兩點，不是三點，下午4點再討論",
            "我列了五點，不是六點，明天早上九點討論。" to "我列了五點，不是六點，明天早上9點討論",
            "這次只要講三點，不是四點，晚上七點前交。" to "這次只要講三點，不是四點，晚上7點前交",
            "他提了兩點，不是三點，明天下午兩點再談。" to "他提了兩點，不是三點，明天下午2點再談",
            "三點開會，議程還是兩點。" to "3:00開會，議程還是兩點",
            "十點開會，要報告的還是三點。" to "10:00開會，要報告的還是三點",
        )
        for ((input, expected) in cases) assertEquals(expected, done(input), input)
        assertEquals("我們約3:00開會還是4:00", done("我們約三點開會還是四點"))
        assertEquals("我們約3:00開會，不是4:00，還是5:00？", done("我們約三點開會，不是四點，還是五點？"))
        assertEquals("晚上8點吃飯，還是9點？", done("晚上八點吃飯，還是九點？"))
        assertEquals("他上午10:00到，下午還是2:00", done("他上午十點到，下午還是兩點。"), "前面只有時間詞")
        assertEquals("我們約3:00開會，應該不是4:00", done("我們約三點開會，應該不是四點"), "前面只有副詞")
    }

    @Test fun runOnLastItemIsNotAListItem() {
        val cases = listOf(
            "我買了三個，紅的、藍的、黑的很好看。" to "我買了三個，紅的、藍的、黑的很好看",
            "我試了三個，A、B、C比較好。" to "我試了三個，A、B、C比較好",
            "我吃了三個，蘋果、香蕉、芭樂好飽。" to "我吃了三個，蘋果、香蕉、芭樂好飽",
            "我想到三個，A方案、B方案、C方案還不錯。" to "我想到三個，A方案、B方案、C方案還不錯",
            "剛剛三個，A、B、C好像有問題。" to "剛剛三個，A、B、C好像有問題",
            "我看了三個，iPhone、Pixel、Galaxy最喜歡。" to "我看了三個，iPhone、Pixel、Galaxy最喜歡",
            "買了三樣，牛奶、麵包、雞蛋已經放冰箱。" to "買了三樣，牛奶、麵包、雞蛋已經放冰箱",
            "我有三個，大的、中的、小的比較貴。" to "我有三個，大的、中的、小的比較貴",
            "三件，上衣、褲子、外套太大了。" to "三件，上衣、褲子、外套太大了！",
            "我挑了四個，紅、橙、黃、綠不錯。" to "我挑了四個，紅、橙、黃、綠不錯",
            "我買了三個，紅的、藍的、黑的好。" to "我買了三個，紅的、藍的、黑的好",
            "我挑了三個，A、B、C讚。" to "我挑了三個，A、B、C讚",
            "我有三個，大的、中的、小的便宜。" to "我有三個，大的、中的、小的便宜",
        )
        for ((input, expected) in cases) assertEquals(expected, done(input), input)
        assertEquals("我挑了四個：\n1. 紅\n2. 橙\n3. 黃\n4. 綠", done("我挑了四個，紅、橙、黃、綠"))
        assertEquals("我看了三個：\n1. iPhone\n2. Pixel\n3. Galaxy", done("我看了三個，iPhone、Pixel、Galaxy"))
        assertEquals("幫我準備三樣東西：\n1. 筆電\n2. 充電線\n3. 行動電源", done("幫我準備三樣東西，筆電、充電線、還有行動電源"))
        assertEquals("幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭", done(ls03))
        assertEquals(2, Normalizer.itemUnits("回email"))
        assertEquals(4, Normalizer.itemUnits("Galaxy最喜歡"))
        assertEquals(3, Normalizer.itemUnits("A 方案"))
    }

    @Test fun bareHourBeforeAnEnumerationIsAClockTime() {
        assertEquals("三點，小明、小華、小美集合", done("三點，小明、小華、小美集合。"))
        assertEquals("大家三點，A組、B組、C組", done("大家三點，A組、B組、C組。"))
        assertEquals("重點有三點：\n1. 響度\n2. 動態\n3. 空間感", done("重點有三點，響度、動態、空間感"))
        assertEquals("要講三點：\n1. 混音\n2. 母帶\n3. 交付", done("要講三點，混音、母帶、交付"))
        assertEquals("以下三點：\n1. 響度\n2. 動態\n3. 空間感", done("以下三點，響度、動態、空間感"))
        assertEquals("三點重點：\n1. 品質\n2. 速度\n3. 價格", done("三點重點：品質、速度、價格。"))
    }

    @Test fun demonstrativeOpenersAndQuotedSpeechDoNotSplit() {
        val texts = listOf(
            "我們這次做了兩個版本，A 版本的高頻比較亮，人聲也比較前面，另外那個版本比較暗，低頻比較飽滿，客戶說兩個都想聽聽看，所以我明天會把兩個版本都寄過去給他，總之大家先聽聽看，有意見再跟我說就好。",
            "我們剛剛把整首歌又聽了一遍，主歌很好，副歌的和聲有點太多，另外那首歌的副歌要改，最後那段 bridge 也要重錄，鼓的部分大家都覺得很好不用動，明天下午再一起討論細節，大家先休息一下，辛苦了，謝謝大家今天的幫忙。",
            "他在信裡面寫，首先要把所有的 stems 整理好，另外要附上每一軌的說明，總之交付之前一定要先確認過一次，不然對方收到之後會很困擾，還要再來回溝通好幾次，這點大家要特別注意，有問題可以直接問我，我再幫大家跟對方確認清楚。",
            "老闆告訴我們，首先要把所有的 stems 整理好，另外要附上每一軌的說明，總之交付之前一定要先確認過一次，不然對方收到之後會很困擾，還要再來回溝通好幾次，這點大家要特別注意，有問題可以直接問我，我再幫大家跟對方確認清楚。",
            "這次的混音分成兩個階段，第一個階段先把所有的軌道整理乾淨，鼓組跟貝斯先處理，人聲最後再進來，另外那個 Atmos 的版本要等立體聲確認之後才開始做，最後幾天留給母帶跟交付，總之時程很緊，大家一起加油，有問題隨時跟我說。",
        )
        for (s in texts) assertFalse(done(s).contains("\n"), s)
        for (s in listOf("人聲也比較前面，另外那個版本比較暗", "鼓手也很穩，最後這段副歌我們錄了五次", "可以再補錄，最後幾個音的尾巴太突然了", "副歌要改，最後那段 bridge 也要重錄", "他在信裡面寫，首先要整理好，另外要附上說明，總之先確認", "老闆告訴我們，首先要整理好，另外要附上說明")) {
            assertEquals(listOf(s), Normalizer.splitAtClauseOpeners(s), s)
        }
        assertEquals(listOf("他說好，", "另外我們明天要開會"), Normalizer.splitAtClauseOpeners("他說好，另外我們明天要開會"))
        assertTrue(Normalizer.endsWithReportedSpeech("老闆告訴我們"))
        assertFalse(Normalizer.endsWithReportedSpeech("我把檔案寄給大家"))
    }

    /** 第三輪政策（同 Swift）：不符合條列規則就整句原樣；直接接內容的序數串要有清單引言才編號。 */
    @Test fun ordinalNounPhrasesWithASharedHeadKeepTheirOrdinals() {
        assertEquals("第一小提琴太大聲，第二小提琴太小聲，第三聲部剛好", done("第一小提琴太大聲，第二小提琴太小聲，第三聲部剛好。"))
        assertEquals("第一買牛奶，第二買麵包，第三寫報告", done("第一買牛奶，第二買麵包，第三寫報告"), "沒有清單引言：原樣")
        assertEquals("今天有三件事：\n1. 買牛奶\n2. 買麵包\n3. 寫報告", done("今天有三件事，第一買牛奶，第二買麵包，第三寫報告"), "有引言、數量對得上：照樣是條列")
        assertEquals("今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明", done(ls02))
    }

    // 7. 2026-10-22 第三輪：序數串的保守規則（與 Swift 同名測試逐字相同）

    @Test fun qualifyingOrdinalSeriesAreNumbered() {
        val cases = listOf(
            ls01 to "接下來有三件事：\n1. 把low end收乾淨\n2. 把delay收短\n3. 重做母帶，記得喔！",
            ls02 to "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明",
            ls05 to "兩個重點：\n1. 響度對齊到-14 LUFS\n2. 不要壓dynamic range，一定要記得",
            "今天有三件事，第一買牛奶，第二回email，第三寫報告。" to "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告",
            "今天有三件事。第一買牛奶，第二回email，第三寫報告。" to "今天有三件事。\n1. 買牛奶\n2. 回email\n3. 寫報告",
            "以下三點：第一更新外掛，第二備份專案，第三重開機" to "以下三點：\n1. 更新外掛\n2. 備份專案\n3. 重開機",
            "第一個是麥克風，第二個是耳機。" to "1. 麥克風\n2. 耳機",
            "第一點是響度，第二點是動態。" to "1. 響度\n2. 動態",
            "第一就是先備份，第二就是再更新" to "1. 先備份\n2. 再更新",
            "第一 買牛奶 第二 回email" to "1. 買牛奶\n2. 回email",
            "有三件事，第一，買菜，第二，煮飯，第三，洗碗，然後就可以休息了" to "有三件事：\n1. 買菜\n2. 煮飯\n3. 洗碗，然後就可以休息了",
            "第一是買菜，然後洗菜，第二是煮飯，最後洗碗" to "1. 買菜，然後洗菜\n2. 煮飯，最後洗碗",
        )
        for ((input, expected) in cases) {
            assertEquals(expected, done(input), input)
            assertEquals(n.normalize(input).cleaned, n.normalize(n.normalize(input).cleaned).cleaned, "整理兩次一樣：$input")
        }
    }

    @Test fun nonQualifyingOrdinalSeriesStayVerbatim() {
        val texts = listOf(
            "這首歌的軌道，第一軌是鼓，第二是貝斯，第三是吉他，第四是人聲。",
            "第一軌是鼓，第二是貝斯，第三是吉他，第四是人聲。",
            "第一軌是 kick，第二是 snare，第三是 hihat。",
            "我們錄了三遍，第一遍太快，第二是太慢，第三剛好。",
            "我們錄了三遍，第一遍太快，第二遍太慢，第三遍剛好。",
            "我第一台電腦是 iMac，第二是 Mac mini，第三是 Mac Studio。",
            "麥克風的擺法，第一支放在大鼓前面，第二是小鼓上面，第三是 overhead。",
            "第一支麥克風收主唱，第二收木吉他，第三收鼓。",
            "我第一胎是男生，第二是女生。",
            "第一筆錢先付訂金，第二是尾款。",
            "第一趟去台北，第二是台中。",
            "第一顆鏡頭是 50mm，第二是 85mm。",
            "第一聲道是左，第二是右。",
            "我的第一選擇是 Pro Tools，第二是 Logic Pro。",
            "第一小提琴太大聲，第二中提琴太小聲，第三大提琴剛好。",
            "第一男高音唱得很好，第二女高音有點緊，第三男低音剛好。",
            "樂團裡第一吉他是阿明，第二貝斯是小華，第三鍵盤是阿強。",
            "今天有三件事，第一小提琴太大聲，第二中提琴太小聲，第三大提琴剛好。",
            "接下來有三點，第一男高音唱得很好，第二女高音有點緊，第三男低音剛好。",
            "今天有三件事，第一軌太大聲，第二軌太小聲，第三軌剛好。",
            "今天有兩件事，第一買牛奶第二回email第三寫報告。",
            "有兩件事，第一跟第二都很重要。",
            // 第四輪 (A)：「第N」不在子句開頭（沒有標點連著講；第三輪這幾句有引言、數量對得上就編號）
            "今天有三件事第一買牛奶第二回email第三寫報告。",
            "今天有三件事第一買牛奶第二回email第三寫報告",
            "以下三點第一準備簡報第二帶筆電第三提早到",
            "兩個步驟第一打開設定第二按儲存？",
            "第一買牛奶第二回email第三寫報告",
            "第一買牛奶，第二買麵包，第三寫報告",
            "第一要記得存檔，第二要備份",
            "我們要的是第二版不是第三版",
            "他是第一名，第二次來",
            "第一是A，第三是B",
            "第二是先買菜，第三是煮飯",
        )
        for (s in texts) {
            assertEquals(s, Normalizer.normalizeListCues(s, true), s)
            assertEquals(s, Normalizer.normalizeListCues(s, false), "單行框也不切行：$s")
            assertEquals(SentenceMood.finish(s), done(s), s)
        }
    }

    @Test fun ordinalRuleHelpers() {
        assertEquals(3, Normalizer.ordinalListIntroCount("接下來有三件事,"))
        assertEquals(3, Normalizer.ordinalListIntroCount("我說三件事。"))
        assertEquals(0, Normalizer.ordinalListIntroCount("今天的工作清單是"))
        assertEquals(3, Normalizer.ordinalListIntroCount("以下三點："))
        assertNull(Normalizer.ordinalListIntroCount("我們錄了三遍，"), "「三遍」不是清單引言")
        assertNull(Normalizer.ordinalListIntroCount("這是第三件事，"), "第三件事＝序數")
        assertNull(Normalizer.ordinalListIntroCount("有三件事要講，然後大家，"), "只看最後一個子句")
        assertNull(Normalizer.ordinalListIntroCount("下午3點，"), "阿拉伯數字＋點＝鐘點")
        assertTrue(Normalizer.isVerbLedItem("買牛奶"))
        assertTrue(Normalizer.isVerbLedItem("更新Pro Tools，然後重開"))
        assertFalse(Normalizer.isVerbLedItem("小提琴太大聲"))
        assertFalse(Normalizer.isVerbLedItem("吉他是阿明"))
        assertFalse(Normalizer.isVerbLedItem("男高音唱得很好"))
        assertFalse(Normalizer.isVerbLedItem("跟"))
        assertNull(Normalizer.parseOrdinalLine("第一遍太快，")?.second, "量詞")
        assertNull(Normalizer.parseOrdinalLine("第一小節太快，")?.second, "兩個字的量詞")
        assertEquals("麥克風", Normalizer.parseOrdinalLine("第一個是麥克風，")?.second)
        assertEquals(false, Normalizer.parseOrdinalLine("第一個是麥克風，")?.third)
        assertEquals(false, Normalizer.parseOrdinalLine("第一 買牛奶 ")?.third, "空白＝分隔")
        assertEquals(true, Normalizer.parseOrdinalLine("第一小提琴太大聲，")?.third)
        assertNull(Normalizer.ordinalList("我們要的是第二版不是第三版", null))
        assertEquals(listOf("買牛奶", "回email", "寫報告。"), Normalizer.ordinalList("今天有三件事，第一買牛奶，第二回email，第三寫報告。", null)?.bodies)
        assertNull(Normalizer.ordinalList("今天有三件事第一買牛奶第二回email第三寫報告。", null), "(A) 第二、第三不在子句開頭")
    }

    // 8. 2026-10-22 第四輪：(A) 子句開頭、(B) 封閉動詞表、(C) 量詞——有一項不過就整串原樣（與 Swift 同名測試逐字相同）

    @Test fun rankingsAndOrdinalNounPhrasesStayVerbatim() {
        val texts = listOf(
            // (B) 第N＋名詞（不是表上的動作）
            "今天有兩件事，第一小提琴重錄，第二小提琴補錄",
            "這次有兩件事，第一順位改成小明，第二順位改成小華",
            "填志願有兩件事，第一志願填台大，第二志願填清大",
            "明天兩件事，第一男高音補錄，第二女高音補錄",
            "今天錄三樣，第一小提琴，第二中提琴，第三大提琴",
            "兩件事，第一男生去搬，第二女生去買",
            "以下兩點，第一要務是準時，第二要務是安全",
            "今天有兩件事，第一交響曲重錄，第二交響曲補錄",
            "今天兩件事，第一錄音室要整理，第二錄音室要清潔",
            "以下兩點，第一做法比較快，第二做法比較穩",
            "今天兩件事，第一寫的歌要重錄，第二寫的歌要混音",
            "今天有兩件事，第一回的內容重寫，第二回的內容刪掉",
            // (A)＋(B) 沒有標點、第N＋名詞
            "以下第一小提琴重錄第二小提琴補錄",
            // (A) 排名／口號：第N 收在子句結尾
            "安全第一，速度第二，大家小心開車",
            "友誼第一，比賽第二，大家加油",
            "他拿了第一，我拿了第二，大家都很開心",
            "小明考第一，小華考第二，小美考第三，我最後一名",
            "客戶第一，品質第二，交期第三，這是我們公司的原則",
            "我們是第一，你們是第二",
            "這次比賽我們拿第一，他們拿第二",
            // (C) 量詞（排、關也是動詞，量詞優先）
            "今天有兩件事，第一排錄音，第二排混音",
            "今天有兩件事，第一關先過，第二關再說",
            "這週有四件事，第一交母帶，第二回客戶信，第三排錄音，第四繳房租",
        )
        for (s in texts) {
            assertEquals(s, Normalizer.normalizeListCues(s, true), s)
            assertEquals(s, Normalizer.normalizeListCues(s, false), "單行框也不切行：$s")
            assertNull(Normalizer.ordinalList(s, null), s)
            val out = done(s)
            assertFalse(out.contains("1. "), "$s → $out")
            assertEquals(s.count { it == '第' }, out.count { it == '第' }, "「第N」一個都不能少：$s → $out")
        }
    }

    @Test fun realListsThatPassAllThreeChecksAreNumbered() {
        val cases = listOf(
            "今天有三件事，第一買牛奶，第二回email，第三寫報告" to "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告",
            "以下兩點：第一確認檔案，第二上傳雲端" to "以下兩點：\n1. 確認檔案\n2. 上傳雲端",
            "清單如下，第一下載素材，第二安裝外掛" to "清單如下：\n1. 下載素材\n2. 安裝外掛",
            "我說兩件事。第一是買菜，第二是煮飯。" to "我說兩件事。\n1. 買菜\n2. 煮飯",
            "第一，安全；第二，速度" to "1. 安全\n2. 速度",
            "接下來有兩個步驟，第一備份專案，第二重開機" to "接下來有兩個步驟：\n1. 備份專案\n2. 重開機",
            "明天兩件事，第一聯絡客戶，第二預約錄音室" to "明天兩件事：\n1. 聯絡客戶\n2. 預約錄音室",
            "今天兩件事，第一去郵局寄包裹，第二去銀行繳費" to "今天兩件事：\n1. 去郵局寄包裹\n2. 去銀行繳費",
            "三件事：第一，買菜；第二，煮飯；第三，洗碗。" to "三件事：\n1. 買菜\n2. 煮飯\n3. 洗碗",
            "以下兩件事 第一 買菜 第二 煮飯" to "以下兩件事：\n1. 買菜\n2. 煮飯",
            ls02 to "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明",
        )
        for ((input, expected) in cases) {
            assertEquals(expected, done(input), input)
            assertEquals(n.normalize(input).cleaned, n.normalize(n.normalize(input).cleaned).cleaned, "整理兩次一樣：$input")
        }
    }

    @Test fun ordinalListVerbWhitelist() {
        // 票面列的動詞都在表上（Swift 是同一份，GoldenTest 逐字比對 golden/ordinal-list-verbs.json）。
        val ticket = listOf("買", "回", "寫", "交", "做", "改", "加", "刪", "寄", "送", "帶", "排", "繳", "洗", "煮", "倒", "拿", "找", "問", "練", "讀",
            "修", "開", "關", "去", "準備", "更新", "匯出", "匯入", "確認", "檢查", "整理", "收", "錄", "補錄", "重錄", "重做", "上傳",
            "下載", "安裝", "測試", "聯絡", "通知", "預約", "處理", "安排", "提醒", "規劃", "設定", "備份")
        for (v in ticket) assertTrue(v in Normalizer.ordinalListVerbs, v)
        assertEquals(Normalizer.ordinalListVerbs.size, Normalizer.ordinalListVerbs.toSet().size, "沒有重複")
        for (body in listOf("買牛奶", "回email", "確認檔案", "去郵局寄包裹", "重開機", "補錄人聲", "更新Pro Tools，然後重開", "匯出Stems")) {
            assertTrue(Normalizer.isVerbLedItem(body), body)
        }
        for (body in listOf("小提琴重錄", "順位改成小明", "志願填台大", "男高音補錄", "吉他是阿明", "軌是鼓", "遍太快", "台電腦",
                            "交響曲重錄", "錄音室要整理", "做法比較快", "寫的歌要重錄", "要準時", "不要遲到", "跟", "")) {
            assertFalse(Normalizer.isVerbLedItem(body), body)
        }
        assertNull(Normalizer.parseOrdinalLine("第三排錄音，")?.second)
        assertNull(Normalizer.parseOrdinalLine("第一關先過，")?.second)
    }
}
