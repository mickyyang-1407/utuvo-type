import XCTest
@testable import UTUVOTypeCore

/// 本機整理（沒有雲端 key、或模型輸出被擋時）的條列與分段（2026-10-22 W2-6，Typeless 對打 ls01–ls05／lp01–lp04 量測）。
/// 輸入是 Groq 真人錄音的辨識結果（半形逗號、小型標點照原樣）；Kotlin 版用同一批輸入的 golden 逐條比對。
final class DeterministicStructureTests: XCTestCase {
    let n = Normalizer()

    func done(_ s: String) -> String { SentenceMood.finish(n.normalize(s).cleaned) }

    static let ls01 = "接下來有三件事,第一是把low end收乾淨,第二是把delay收短,第三是重做母帶,記得喔!"
    static let ls02 = "今天的工作清單是第一更新Pro Tools,第二匯出Stems,第三寫交付說明"
    static let ls03 = "幫我準備四樣東西\u{FE50}播放器、耳機、線材、還有轉接頭\u{FE50}"
    static let ls05 = "兩個重點,第一,響度對齊到-14 LUFS,第二,不要壓dynamic range,一定要記得"
    static let lp01 = "這次案子分成三個部分,第一個部分是前期的素材整理,主要把客戶給的Multi-Track收進來,然後檢查每一軌的完整性。另外第二個部分是實際的混音,這部分大概會花三天,重點在於人生的空間感。總之交付的時候記得付一份Mixing Note"
    static let lp02 = "先講一下目前錄音室的狀況,那個隔音其實還不錯,但是麥克風的位置需要再重新架一下,另外低頻的殘響有點重,可能要加吸音棉。對了,錄音室的空調聲要在錄音前先關掉,不然後面的去除會很麻煩。總之,先把環境弄好再錄,效率會比以前高很多。"
    static let lp03 = "講一下這張專輯的製作流程,首先我們花了三個禮拜做demo,收集了12首候選曲,接著選曲,過程中刪掉了一半,留下的6首都請客戶聽過,另外編曲的部分交給外面的一位編曲人,他一個月交3首,總之,專輯預計11月中上架。"
    static let lp04 = "關於版權這件事我要多講幾句,首先,同一首歌詞在兩張專輯上面法律上是允許的,但是唱片公司不一定接受。對了,如果你的歌有授權給別人表演,表演收錄的分配要另外談,總之簽約之前,務必把這些條款看清楚。"
    static let questionThenOpener = "大家覺得這個版本的混音可以直接交給客戶了嗎，另外錄音室的冷氣修好了，可以開始排下週的錄音，對了母帶的時程也要再確認一下，總之有問題再跟我說，謝謝大家這陣子的幫忙。"
    static let midClauseOpeners = "那個我另外買了一個混音器，我們今天下午在錄音室把所有的分軌整理好，大概花了三個小時，還要做母帶，進度還算順利，下週再確認時程，謝謝大家今天的幫忙，辛苦了大家，我們下次見，記得把檔案備份好，另外的部分再說。"

    /// 給 GoldenExportTests：Kotlin 版逐條比對。
    static let goldenInputs = [
        ls01, ls02, ls03, ls05, lp01, lp02, lp03, lp04, questionThenOpener, midClauseOpeners,
        "第一次來台北，覺得很好玩", "他是第一名，第二次來", "第一個部分是素材，第二個部分是混音。", "第一是A，第三是B", "第二是先買菜，第三是煮飯",
        "我說三件事。第一是買菜，第二是煮飯，第三是洗碗。", "第一是不是要先開會，第二是誰負責", "1. 買牛奶\n2. 回信",
        "有三件事，第一，買菜，第二，煮飯，第三，洗碗，然後就可以休息了",
        "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。明天要用。", "幫我準備四樣東西，播放器、耳機、線材", "我準備了東西，播放器、耳機、線材",
        "我買了三樣東西，紙、筆、橡皮擦，然後就回家了", "需要三樣東西，把所有分軌檔案都重新命名一次、匯出、上傳", "幫我準備四樣東西，播放器、耳機、線材、轉接頭？",
        "有三點：響度、動態、空間感", "他說要準備十樣東西，A、B、C",
        "我們約三點開會，不是四點", "我們約下午三點見，還是四點", "我要的是三點不是四點", "三點開會，重點有兩點", "我們約三點開會。不是四點",
        "三點開會，不是一點點", "我們三點半開會，不是四點", "十二點吃飯，不是十一點", "明天下午三點開會，還是四點吧",
        // 2026-10-22 審查修正（其餘探針在 structure-probes.json，GoldenExportTests 一起匯出）
        "幫我準備四樣東西，播放器、耳機、線材、以及轉接頭", "首先整理桌面其次回信最後趕稿，", "今天有三件事第一買牛奶第二回email第三寫報告。明天再說。",
        "今天的錄音整體來說很順利，鼓組跟貝斯都一次就錄好了，吉他的部分花了比較多時間，但是最後的效果大家都很滿意，人聲的部分明天再繼續，混音師說他會先處理 vocal tuning,另外下週要跟客戶確認最後的 mix,總之大家辛苦了，謝謝大家。",
        "Hi team, quick update on the album. We finished mixing all twelve songs this week and the client is happy with the overall sound so far. Also, the mastering engineer needs the final stems by Friday, so please export them tonight if you can. Anyway, thanks again for all the hard work on this project, and let me know if anything is missing.",
        String(lp03.dropLast()) + ",", "我買了三件，黑的、白的、灰的",
    ] + fx7ListCopula.map(\.0)

    /// FX-7 L5：條列只拿掉當「是」用的那個字；後面是「是非」「是否」「是不是」開頭的詞就留著（「第一是是非題」只拿掉一個「是」）。
    static let fx7ListCopula: [(String, String)] = [
        ("考卷分兩部分，第一是非題，第二是選擇題", "考卷分兩部分：\n1. 是非題\n2. 選擇題"),
        ("第一是是非題，第二是選擇題", "1. 是非題\n2. 選擇題"),
        ("第一是否要延期，第二是預算多少", "1. 是否要延期\n2. 預算多少"),
        ("第一是報告，第二是預算", "1. 報告\n2. 預算"),
        ("第一是不是要延期，第二是預算多少", "1. 是不是要延期\n2. 預算多少"),
        // 「個是」「點是」「就是」後面的「是」也是同一條規則（e0e608b 會變成「否要延期」「非題」「不是要延期」）。
        ("第一個是否要延期，第二個是預算多少", "1. 是否要延期\n2. 預算多少"),
        ("第一點是是非題，第二點是選擇題", "1. 是非題\n2. 選擇題"),
        ("第一就是是不是要延期，第二就是預算", "1. 是不是要延期\n2. 預算"),
        // 「是非常」的「是」是繫詞，照舊拿掉。
        ("第一是非常重要的事，第二是預算", "1. 非常重要的事\n2. 預算")
    ]

    // MARK: - 1. 序數行 → 編號清單

    func testOrdinalLinesBecomeNumberedList() {
        XCTAssertEqual(done(Self.ls01), "接下來有三件事：\n1. 把low end收乾淨\n2. 把delay收短\n3. 重做母帶，記得喔！")
        XCTAssertEqual(done(Self.ls02), "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明")
        XCTAssertEqual(done(Self.ls05), "兩個重點：\n1. 響度對齊到-14 LUFS\n2. 不要壓dynamic range，一定要記得")
        // 前一句已經收在句號：引言不改；「第N是不是」的「是」不能拿掉（意思會變）。
        XCTAssertEqual(done("我說三件事。第一是買菜，第二是煮飯，第三是洗碗。"), "我說三件事。\n1. 買菜\n2. 煮飯\n3. 洗碗", "每一項結尾的標點一律拿掉（含最後一項的「。」）")
        XCTAssertEqual(done("第一是不是要先開會，第二是誰負責"), "1. 是不是要先開會\n2. 誰負責")
    }

    func testFx7ListCopulaKeepsWordsThatStartWithShi() {
        for (raw, expected) in Self.fx7ListCopula {
            XCTAssertEqual(done(raw), expected, raw)
        }
    }

    func testOrdinalsThatAreNotAListStayAsBefore() {
        // 單一個「第一」、句子裡的序數：沒有切行，也不編號。
        XCTAssertEqual(done("第一次來台北，覺得很好玩"), "第一次來台北，覺得很好玩")
        // 第三輪政策（2026-10-22）：不符合條列規則的序數串整句原樣，連切行也不做（第二輪前這幾句會被切成好幾行）。
        XCTAssertEqual(done("他是第一名，第二次來"), "他是第一名，第二次來", "量詞開頭（名／次）：不編號也不切行")
        XCTAssertEqual(done("第一個部分是素材，第二個部分是混音。"), "第一個部分是素材，第二個部分是混音", "「第一個部分」是段落講法：不編號也不切行")
        // 不是從第一開始、或不連續：不編號也不切行。
        XCTAssertEqual(done("第一是A，第三是B"), "第一是A，第三是B")
        XCTAssertEqual(done("第二是先買菜，第三是煮飯"), "第二是先買菜，第三是煮飯")
        // 已經是 markdown／編號清單：原樣。
        XCTAssertEqual(done("1. 買牛奶\n2. 回信"), "1. 買牛奶\n2. 回信")
        XCTAssertEqual(n.normalize("- 第一點\n- 第二點").cleaned, "- 第一點\n- 第二點")
    }

    func testOrdinalHelpers() {
        XCTAssertEqual(Normalizer.parseOrdinalLine("第三是重做母帶，")?.value, 3)
        XCTAssertEqual(Normalizer.parseOrdinalLine("第三是重做母帶，")?.body, "重做母帶")
        XCTAssertEqual(Normalizer.parseOrdinalLine("第一，響度")?.body, "響度")
        XCTAssertNotNil(Normalizer.parseOrdinalLine("第一名，"))
        XCTAssertNil(Normalizer.parseOrdinalLine("第一名，")?.body, "量詞開頭：整串不編號")
        XCTAssertNil(Normalizer.parseOrdinalLine("他是第一名"))
        XCTAssertEqual(Normalizer.listIntro("接下來有三件事,"), "接下來有三件事：")
        XCTAssertEqual(Normalizer.listIntro("今天的工作清單是"), "今天的工作清單是：")
        XCTAssertEqual(Normalizer.listIntro("我說三件事。"), "我說三件事。")
    }

    // MARK: - 2. 明講數量的頓號列舉 → 編號清單

    func testCountedEnumerationBecomesNumberedList() {
        XCTAssertEqual(done(Self.ls03), "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭")
        XCTAssertEqual(done("有三點：響度、動態、空間感"), "有三點：\n1. 響度\n2. 動態\n3. 空間感")
        // 後面另起一句：清單之後換行接著寫。
        XCTAssertEqual(done("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。明天要用。"),
                       "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭\n明天要用。")
    }

    func testEnumerationsThatDoNotQualifyStayUntouched() {
        for s in ["幫我準備四樣東西，播放器、耳機、線材",               // 數量對不上
                  "他說要準備十樣東西，A、B、C",                        // 數量對不上
                  "我準備了東西，播放器、耳機、線材",                     // 沒有數量
                  "需要三樣東西，把所有分軌檔案都重新命名一次、匯出、上傳",  // 項目太長
                  "我買了三樣東西，紙、筆、橡皮擦，然後就回家了",           // 列舉後面還有話
                  "幫我準備四樣東西，播放器、耳機、線材、轉接頭？"] {        // 問句
            XCTAssertFalse(n.normalize(s).cleaned.contains("\n"), s)
            XCTAssertEqual(done(s), SentenceMood.finish(s), s)
        }
    }

    // MARK: - 3. 長文分段：句中轉折詞

    func testDiscourseMarkersSplitParagraphsLikeTypeless() {
        XCTAssertEqual(done(Self.lp01), "這次案子分成三個部分。\n\n第一個部分是前期的素材整理，主要把客戶給的Multi-Track收進來，然後檢查每一軌的完整性。\n\n另外第二個部分是實際的混音，這部分大概會花三天，重點在於人生的空間感。\n\n總之交付的時候記得付一份Mixing Note")
        XCTAssertEqual(done(Self.lp02), "先講一下目前錄音室的狀況，隔音其實還不錯，但是麥克風的位置需要再重新架一下。\n\n另外低頻的殘響有點重，可能要加吸音棉。\n\n對了，錄音室的空調聲要在錄音前先關掉，不然後面的去除會很麻煩。\n\n總之，先把環境弄好再錄，效率會比以前高很多。")
        XCTAssertEqual(done(Self.lp03), "講一下這張專輯的製作流程。\n\n首先我們花了三個禮拜做demo，收集了12首候選曲。\n\n接著選曲，過程中刪掉了一半，留下的6首都請客戶聽過。\n\n另外編曲的部分交給外面的一位編曲人，他一個月交3首。\n\n總之，專輯預計11月中上架。")
        // lp04 只有 96 字、2 個句號：轉折詞有三個，照樣分（Typeless 4 段）。
        XCTAssertEqual(done(Self.lp04), "關於版權這件事我要多講幾句。\n\n首先，同一首歌詞在兩張專輯上面法律上是允許的，但是唱片公司不一定接受。\n\n對了，如果你的歌有授權給別人表演，表演收錄的分配要另外談。\n\n總之簽約之前，務必把這些條款看清楚。")
    }

    func testSplitAtCommaBecomesSentenceEndWithMood() {
        XCTAssertEqual(done(Self.questionThenOpener), "大家覺得這個版本的混音可以直接交給客戶了嗎？\n\n另外錄音室的冷氣修好了，可以開始排下週的錄音。\n\n對了母帶的時程也要再確認一下。\n\n總之有問題再跟我說，謝謝大家這陣子的幫忙！")
        XCTAssertEqual(Normalizer.splitAtClauseOpeners("狀況還不錯，另外低頻有點重，可能要加吸音棉。"), ["狀況還不錯，", "另外低頻有點重，可能要加吸音棉。"])
    }

    /// 「接著」跟首先／另外／總之同一組轉折詞（整理提示詞點名的五個；lp03 Typeless 在「接著選曲」前分段）。
    func testJieZheOpensAParagraphLikeTheOtherMarkers() {
        // 要切：逗號後面的「接著」
        XCTAssertEqual(Normalizer.splitAtClauseOpeners("收集了12首候選曲，接著選曲，過程中刪掉了一半"), ["收集了12首候選曲，", "接著選曲，過程中刪掉了一半"])
        XCTAssertEqual(done("先說明一下今天錄音的流程，首先大家九點到錄音室集合，確認麥克風跟耳機都正常，接著我們先錄鼓的部分，大概要花兩個小時，另外貝斯跟吉他排在下午，總之晚上之前要全部錄完。"),
                       "先說明一下今天錄音的流程。\n\n首先大家9:00到錄音室集合，確認麥克風跟耳機都正常。\n\n接著我們先錄鼓的部分，大概要花兩個小時。\n\n另外貝斯跟吉他排在下午。\n\n總之晚上之前要全部錄完。")
        // 不切：前面不是逗號（緊接著、我接著說）、「接著的」、轉述的話、短文
        for s in ["他講完以後緊接著換我上台", "我接著說明這次的混音方向", "大家都很投入，接著的部分就交給大家討論", "他在信裡面寫，接著要先選曲"] {
            XCTAssertEqual(Normalizer.splitAtClauseOpeners(s), [s], s)
        }
        XCTAssertEqual(done("收集完素材，接著選曲。"), "收集完素材，接著選曲")
    }

    func testMarkersInsideAClauseOrShortTextDoNotSplit() {
        // 「我另外買了」前面不是逗號、「另外的部分」是形容：都不切。
        XCTAssertEqual(done(Self.midClauseOpeners), "我另外買了一個混音器，我們今天下午在錄音室把所有的分軌整理好，大概花了三個小時，還要做母帶，進度還算順利，下週再確認時程，謝謝大家今天的幫忙，辛苦了大家，我們下次見，記得把檔案備份好，另外的部分再說")
        XCTAssertEqual(Normalizer.splitAtClauseOpeners("我另外買了一個，要另外談，另外的部分再說"), ["我另外買了一個，要另外談，另外的部分再說"])
        // 短文：轉折詞再多也不分。
        XCTAssertEqual(done("今天開會，另外記得買咖啡，最後回信，總之先這樣。"), "今天開會，另外記得買咖啡，最後回信，總之先這樣")
        // 已經有換行：不動。
        let lined = "第一行。\n" + Self.lp02
        XCTAssertEqual(Normalizer.paragraphize(lined), lined)
    }

    // MARK: - 4. 同一句的鐘點寫法一致

    func testContrastedHourFollowsConvertedFormat() {
        XCTAssertEqual(done("我們約三點開會，不是四點"), "我們約3:00開會，不是4:00")
        XCTAssertEqual(done("我們三點半開會，不是四點"), "我們3:30開會，不是4:00")
        XCTAssertEqual(done("明天下午三點開會，還是四點吧"), "明天下午3:00開會，還是4:00吧")
        XCTAssertEqual(done("我們約下午三點見，還是四點"), "我們約下午3點見，還是4點")
        XCTAssertEqual(Normalizer.normalizeNumbers("我們約三點開會，不是四點"), "我們約3:00開會，不是4:00")
    }

    func testHoursWithoutAConvertedPartnerStayUntouched() {
        XCTAssertEqual(done("我要的是三點不是四點"), "我要的是三點不是四點", "兩個都沒轉：本來就一致")
        XCTAssertEqual(done("三點開會，重點有兩點"), "3:00開會，重點有兩點", "沒有對比詞")
        XCTAssertEqual(done("我們約三點開會。不是四點"), "我們約3:00開會。不是四點", "不同句")
        XCTAssertEqual(done("三點開會，不是一點點"), "3:00開會，不是一點點", "「一點」不收")
        XCTAssertEqual(done("十二點吃飯，不是十一點"), "十二點吃飯，不是十一點", "這句沒有轉好的鐘點")
    }

    /// 寫法一致之後，把關也看得出「三點開會，不是四點」被整理成「4:00開會」是意思反過來（規則 8c 的連帶效果；CleanupFidelity 本身沒改）。
    func testConsistentHoursLetTheGateSeeAFlippedContrast() {
        XCTAssertFalse(CleanupFidelity.passesRelaxed(original: "我們約三點開會，不是四點", cleaned: "我們約4:00開會"))
        XCTAssertTrue(CleanupFidelity.passesRelaxed(original: "我們約三點開會，不是四點", cleaned: "我們約3:00開會，不是4:00"))
    }

    // MARK: - 單行輸入框

    func testSingleLineKeepsNumberedItemsApart() {
        XCTAssertEqual(OutputShape.singleLine("今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告。"), "今天有三件事：1. 買牛奶 2. 回email 3. 寫報告。")
        XCTAssertEqual(OutputShape.singleLine("今天有三件事\n第一買牛奶\n第二回email。"), "今天有三件事第一買牛奶第二回email。", "沒有編號的行照舊直接接上")
    }

    /// 單行框（numberedLists = false）：不出編號清單，維持整理前的逗號／頓號寫法（修正前接成「：1. 播放器 2. 耳機…」）。
    func testSingleLineFieldsKeepTheCommaForm() {
        let single = Normalizer(options: NormalizerOptions(numberedLists: false))
        func shaped(_ s: String) -> String { OutputShape.singleLine(SentenceMood.finish(single.normalize(s).cleaned)) }
        XCTAssertEqual(shaped("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。"), "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭")
        XCTAssertEqual(shaped("今天有三件事，買牛奶、回email、寫報告。"), "今天有三件事，買牛奶、回email、寫報告")
        XCTAssertEqual(single.normalize("今天有三件事，第一買牛奶，第二回email，第三寫報告。").cleaned, "今天有三件事，\n第一買牛奶，\n第二回email，\n第三寫報告。", "只切行、不編號")
        // 第四輪（2026-10-22）政策 (A)：沒有標點的連續序數串不是條列，連切行也不做（第三輪這句會切成四行）。
        XCTAssertEqual(single.normalize("今天有三件事第一買牛奶第二回email第三寫報告。").cleaned, "今天有三件事第一買牛奶第二回email第三寫報告。")
        XCTAssertFalse(shaped(Self.ls01).contains("1. "))
    }

    // MARK: - 5. 2026-10-22 審查修正：誤判與吃字

    /// 「第N」後面接名詞／量詞＝名詞片語，不是條列：「第一／第二」留著（修正前「第一軌是 kick」→「1. 軌是 kick」）。
    /// 第三輪政策（2026-10-22）：整句原樣，連切行也不做（第二輪的預期是每個「第N」前面換行）。
    func testOrdinalNounPhrasesKeepTheirOrdinals() {
        let cases: [(String, String)] = [
            ("第一軌是 kick，第二軌是 snare。", "第一軌是 kick，第二軌是 snare"),
            ("我第一台電腦是 iMac，第二台是 Mac Studio。", "我第一台電腦是 iMac，第二台是 Mac Studio"),
            ("第一遍聽的時候覺得還好，第二遍就覺得低頻太多了。", "第一遍聽的時候覺得還好，第二遍就覺得低頻太多了！"),
            ("第一小提琴太大聲，第二小提琴有點被蓋掉。", "第一小提琴太大聲，第二小提琴有點被蓋掉"),
            ("我的第一選擇是 Pro Tools，第二選擇是 Logic Pro。", "我的第一選擇是 Pro Tools，第二選擇是 Logic Pro"),
            ("我覺得第一跟第二都可以，你決定。", "我覺得第一跟第二都可以，你決定"),
            ("第一拍要重一點，第二拍輕一點。", "第一拍要重一點，第二拍輕一點"),
            ("第一聲道是左，第二聲道是右。", "第一聲道是左，第二聲道是右"),
        ]
        for (input, expected) in cases { XCTAssertEqual(done(input), expected, input) }
        // 直接接內容的序數串：前面要有清單引言（數量等於項數，或以下／如下／清單）才是條列。
        XCTAssertEqual(done(Self.ls02), "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明")
        // 第三輪：「軌」在量詞表裡＝「第一軌」是名詞片語，內容是 nil（第二輪這裡是「直接接內容」direct == true）。
        XCTAssertNil(Normalizer.parseOrdinalLine("第一軌是 kick，")?.body)
        XCTAssertEqual(Normalizer.parseOrdinalLine("第一是買菜；")?.body, "買菜")
    }

    /// 列舉最後一項開頭的單字「和／跟」是詞的一部分（和弦、和聲、和牛、跟拍、和平、和菓子），不拿；只拿「還有／以及」。
    func testSingleCharacterConnectorsStayInTheItem() {
        XCTAssertEqual(done("我要買三樣東西，豬肉、雞肉、和牛"), "我要買三樣東西：\n1. 豬肉\n2. 雞肉\n3. 和牛")
        XCTAssertEqual(done("我想吃三樣東西，牛排、壽司、和菓子"), "我想吃三樣東西：\n1. 牛排\n2. 壽司\n3. 和菓子")
        XCTAssertEqual(done("這段要注意兩點，節奏、和弦。"), "這段要注意兩點：\n1. 節奏\n2. 和弦", "注意＋兩點＝明講在列")
        for s in ["副歌要加兩樣，弦樂、和聲。", "我點了兩樣，牛舌、和牛。", "這次要拍兩個，定點、跟拍。", "我想到兩個，戰爭、和平。"] {
            XCTAssertEqual(done(s), SentenceMood.finish(s), s)
        }
        XCTAssertEqual(done("幫我準備四樣東西，播放器、耳機、線材、以及轉接頭"), "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭")
    }

    /// 不是在列東西的頓號句：序數（第二個）、指稱（這兩個、每兩個）、鐘點（下午三點、約三點、說五點）、項目是人、
    /// 最後一項接著講事情、兩項又沒明講在列——原樣（修正前全部被編號）。
    func testCountedEnumerationFalsePositivesStayAsWritten() {
        let cases: [(String, String)] = [
            ("我買了兩個，紅的、藍的。", "我買了兩個，紅的、藍的"),
            ("這兩個，紅的、藍的都不錯。", "這兩個，紅的、藍的都不錯"),
            ("我比較喜歡第二個，乾淨、溫暖。", "我比較喜歡第二個，乾淨、溫暖"),
            ("我覺得第三個，速度、價格、品質都比較好。", "我覺得第三個，速度、價格、品質都比較好"),
            ("明天下午三點，我、阿明、小美去錄音室。", "明天下午3點，我、阿明、小美去錄音室"),
            ("會議改到四點，小明、小華、阿強、阿美都要到。", "會議改到四點，小明、小華、阿強、阿美都要到"),
            ("他說五點，你、我、他、小明、阿華都要到。", "他說五點，你、我、他、小明、阿華都要到"),
            ("那就約兩點，你、我。", "那就約兩點，你、我"),
            ("這三個，小明、小華、阿強你們負責。", "這三個，小明、小華、阿強你們負責"),
            ("給我三個，大的、中的、小的各一個。", "給我三個，大的、中的、小的各一個"),
            ("剩下兩件，明天、後天再弄。", "剩下兩件，明天、後天再弄"),
            ("我要兩個，一個給你、一個給我。", "我要兩個，一個給你、一個給我"),
            ("每兩個，紅的、藍的。", "每兩個，紅的、藍的"),
            ("明天三點，小明、小華、小美都會來", "明天3點，小明、小華、小美都會來"),
            ("我們約三點，小明、小華、小美都會來", "我們約三點，小明、小華、小美都會來"),
            ("下午兩點，阿明、阿華", "下午2點，阿明、阿華"),
        ]
        for (input, expected) in cases { XCTAssertEqual(done(input), expected, input) }
        // 三項、數量對得上：照樣編號；同一份內容用序數講或用頓號講，結果一樣。
        XCTAssertEqual(done("今天有三件事，買牛奶、回email、寫報告。"), "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告")
        XCTAssertEqual(done("今天有三件事，第一買牛奶，第二回email，第三寫報告。"), done("今天有三件事，買牛奶、回email、寫報告。"))
    }

    /// 當限定詞／形容用的轉折詞（另外一個、最後一天、最後半小時、最後面、最後還是、對了一半）與轉述（強調，首先…）不分段。
    func testDeterminerAndReportedSpeechOpenersDoNotSplit() {
        let texts = [
            "我們這次找了兩個混音師。一個負責 stereo 版本，另外一個專門做 Atmos，兩個人的風格不太一樣。所以我會在中間協調，確保兩個版本聽起來是同一張專輯，這部分要花比較多時間溝通，大家再給我一點時間。",
            "老師上課的時候一直強調，首先要把耳朵練好，再來才是學軟體。我覺得這句話很有道理，因為很多學生一開始就急著學各種外掛。結果連基本的 EQ 都聽不出來，這樣其實很可惜，我自己以前也是這樣過來的，所以特別有感觸。",
            "小明說他今天會晚到，因為要先去接小孩，另外一個原因是車子送修，所以要搭捷運過來。我跟他說沒關係，我們先開始，最後半小時再請他補充意見就好。會議記錄我會寫好再寄給大家，有問題再跟我說。",
            "我們剛剛把整首歌又聽了一遍。主歌很好，副歌的和聲有點太多，對了一半的意見是說鼓太大聲，其實是 bass 太大聲。總之我先把 bass 降兩個 dB，明天再給大家聽，有意見再跟我說就好。",
            "我剛剛聽完你寄來的混音，你問我低頻是不是太多，對了一半，kick 的部分確實太多，但是 bass 其實剛好，另外 vocal 的齒音有點刺耳，可以再用 de-esser 處理一下，整體來說比上一版好很多。",
            "這次巡演總共跑了五個城市。台北跟台中的場地都很棒，高雄那場音響有點問題，最後一天在台南的場地反而是最好的，觀眾也最熱情。整體來說這次巡演還算順利，明年應該還會再辦一次。",
            "我們昨天討論了很久要不要把 vocal 再往前推一點。因為副歌的時候其實有點被吉他蓋住，大家意見都不太一樣，最後還是決定先維持原本的平衡。等明天用另一副耳機確認一次，如果還是覺得太後面再來調整就好。",
            "這段吉他 solo 我覺得前面都很好。中間的推弦有一點點不準，可以再補錄一次看看，最後面那個長音的尾巴太突然了，可以再拉長一點。這樣聽起來會比較自然，整體來說還是很棒的一段 solo，辛苦你了，明天見。",
        ]
        for s in texts { XCTAssertFalse(done(s).contains("\n"), s) }
        for s in ["一個負責 stereo 版本，另外一個專門做 Atmos", "老師一直強調，首先要把耳朵練好", "我們先開始，最後半小時再補充",
                  "高雄有點問題，最後一天在台南", "意見不一樣，最後還是決定維持", "可以再補錄，最後面那個長音", "你問我低頻是不是太多，對了一半"] {
            XCTAssertEqual(Normalizer.splitAtClauseOpeners(s), [s], s)
        }
        XCTAssertEqual(Normalizer.splitAtClauseOpeners("狀況還不錯，另外低頻有點重"), ["狀況還不錯，", "另外低頻有點重"], "真的轉折照切")
    }

    /// 規則 8c 只對齊「時間規則轉出來的鐘點」：數量（重點有三點、列了五點重點、只要講三點）後面的「四點／六點」不動。
    func testContrastedCountsAreNotClockTimes() {
        XCTAssertEqual(done("下午兩點開會，重點有三點，不是四點。"), "下午2:00開會，重點有三點，不是四點")
        XCTAssertEqual(done("三點開會，這次只要講三點，還是四點？"), "3:00開會，這次只要講三點，還是四點？")
        XCTAssertEqual(done("下午三點開會，我列了五點重點，還是六點？"), "下午3:00開會，我列了五點重點，還是六點？")
        XCTAssertEqual(done("明天三點開會，要講的重點有三點，不是兩點"), "明天3:00開會，要講的重點有三點，不是兩點")
        XCTAssertEqual(done("下午三點的會議，重點還是兩點"), "下午3點的會議，重點還是兩點")
        XCTAssertEqual(done("比數是3:05，不是四點"), "比數是3:05，不是四點")
    }

    /// 有換行的結果（清單、分段）收尾不吊著「，」（修正前 SentenceMood.finish 看到換行就不動，Groq 結尾的「,」留下來）。
    func testMultiLineResultsDoNotEndOnAComma() {
        XCTAssertEqual(done(String(Self.lp03.dropLast()) + ","),
                       "講一下這張專輯的製作流程。\n\n首先我們花了三個禮拜做demo，收集了12首候選曲。\n\n接著選曲，過程中刪掉了一半，留下的6首都請客戶聽過。\n\n另外編曲的部分交給外面的一位編曲人，他一個月交3首。\n\n總之，專輯預計11月中上架")
        XCTAssertEqual(done("今天的session很順利,我們把vocal tuning都做完了,另外drum的部分還要再調整一下,對了client說deadline可能會提前,總之大家加油,"),
                       "今天的session很順利，我們把vocal tuning都做完了。\n\n另外drum的部分還要再調整一下。\n\n對了client說deadline可能會提前。\n\n總之大家加油")
        XCTAssertEqual(done("幫我準備三樣東西，A、B、C。明天要用，"), "幫我準備三樣東西：\n1. A\n2. B\n3. C\n明天要用")
        XCTAssertEqual(done("首先整理桌面其次回信最後趕稿，"), "首先整理桌面\n其次回信\n最後趕稿")
        XCTAssertEqual(Normalizer.dropDanglingEndOfLines("第一段，\n\n第二段，"), "第一段，\n\n第二段")
        XCTAssertEqual(Normalizer.dropDanglingEndOfLines("單行，"), "單行，", "單行留給 SentenceMood.finish")
    }

    /// 清單每一項的結尾一樣：「，、；：。」一律拿掉，不管是序數清單還是頓號列舉；最後一項後面的句子另起一行。
    func testListItemsEndTheSameWay() {
        XCTAssertEqual(done("第一是買菜；第二是煮飯；第三是洗碗"), "1. 買菜\n2. 煮飯\n3. 洗碗")
        XCTAssertEqual(done("第一是買菜:第二是煮飯:第三是洗碗"), "1. 買菜\n2. 煮飯\n3. 洗碗")
        XCTAssertEqual(done("今天有三件事，第一買牛奶，第二回email，第三寫報告。明天再說。"), "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告\n明天再說。")
        XCTAssertEqual(Normalizer.trimListItem("洗碗；。 "), "洗碗")
    }

    /// 英文為主的短訊息（三句、十幾個字）不分段；60 字以上才分。
    func testShortEnglishMessagesStayOneParagraph() {
        for s in ["Thanks for the update. Also, can you send the file? Anyway, see you tomorrow at the studio.",
                  "Got your message about the mix. Also, the client called. Anyway, call me back when you can.",
                  "Hi team, the mix is approved. Also, the master is due Friday. Finally, thanks for your hard work!"] {
            XCTAssertEqual(done(s), s, s)
        }
        let long = "Hi team, quick update on the album. We finished mixing all twelve songs this week and the client is happy with the overall sound so far. Also, the mastering engineer needs the final stems by Friday, so please export them tonight if you can. Anyway, thanks again for all the hard work on this project, and let me know if anything is missing."
        XCTAssertEqual(done(long).components(separatedBy: "\n\n").count, 3, "63 個英文字：照樣分段")
    }

    /// 段落收在英文（字母或數字）後面：用英文句點「.」，不是「。」。
    func testParagraphEndingInEnglishClosesWithAPeriod() {
        XCTAssertEqual(Normalizer.closeParagraph("混音師說他會先處理 vocal tuning,"), "混音師說他會先處理 vocal tuning.")
        XCTAssertEqual(Normalizer.closeParagraph("先處理到 track 12，"), "先處理到 track 12.")
        XCTAssertEqual(Normalizer.closeParagraph("可能要加吸音棉，"), "可能要加吸音棉。")
        XCTAssertEqual(done("今天的錄音整體來說很順利，鼓組跟貝斯都一次就錄好了，吉他的部分花了比較多時間，但是最後的效果大家都很滿意，人聲的部分明天再繼續，混音師說他會先處理 vocal tuning,另外下週要跟客戶確認最後的 mix,總之大家辛苦了，謝謝大家。"),
                       "今天的錄音整體來說很順利，鼓組跟貝斯都一次就錄好了，吉他的部分花了比較多時間，但是最後的效果大家都很滿意，人聲的部分明天再繼續，混音師說他會先處理 vocal tuning.\n\n另外下週要跟客戶確認最後的 mix.\n\n總之大家辛苦了，謝謝大家！")
    }

    /// 整理兩次跟一次一樣：清單＋分段同時出現的長句（審查員的例子）、疊字後才露出的贅詞、段落之間的空行。
    func testCleaningTwiceGivesTheSameResult() {
        let s = "這次錄音我需要三樣東西，麥克風、耳機、線材，另外錄音室的冷氣要先修好，不然錄起來會有很明顯的底噪，對了客戶說交期可能會提前一週，總之大家先把時間空出來，謝謝大家。"
        let once = n.normalize(s).cleaned
        XCTAssertEqual(once, "這次錄音我需要三樣東西，麥克風、耳機、線材。\n\n另外錄音室的冷氣要先修好，不然錄起來會有很明顯的底噪。\n\n對了客戶說交期可能會提前一週。\n\n總之大家先把時間空出來，謝謝大家！")
        XCTAssertEqual(n.normalize(once).cleaned, once)
        XCTAssertEqual(n.normalize("然後然後那個高頻好像有點毛,你再聽一下").cleaned, "高頻好像有點毛，你再聽一下")
        XCTAssertEqual(Normalizer.collapseWhitespace("第一段。\n\n第二段。"), "第一段。\n\n第二段。")
    }

    // MARK: - 6. 2026-10-22 第二輪審查修正

    /// 規則 8c：對比詞前面最近的「N點」是數量（重點有三點、我列了五點）＝不動，鐘點寫在後面也一樣；
    /// 對比詞那一小段前面另有主詞（議程還是兩點、要報告的還是三點）＝在講那個東西，不動。
    func testContrastedCountsStayCountsWhenTheClockTimeComesLater() {
        let cases: [(String, String)] = [
            ("重點有三點，不是四點，我們下午兩點開會。", "重點有三點，不是四點，我們下午2:00開會"),
            ("我覺得重點有兩點，不是三點，下午四點再討論。", "我覺得重點有兩點，不是三點，下午4點再討論"),
            ("我列了五點，不是六點，明天早上九點討論。", "我列了五點，不是六點，明天早上9點討論"),
            ("這次只要講三點，不是四點，晚上七點前交。", "這次只要講三點，不是四點，晚上7點前交"),
            ("他提了兩點，不是三點，明天下午兩點再談。", "他提了兩點，不是三點，明天下午2點再談"),
            ("三點開會，議程還是兩點。", "3:00開會，議程還是兩點"),
            ("十點開會，要報告的還是三點。", "10:00開會，要報告的還是三點"),
        ]
        for (input, expected) in cases { XCTAssertEqual(done(input), expected, input) }
        // 真的在對比鐘點：照樣對齊（含同一小段、半形冒號的 3:00、連續兩個對比）。
        XCTAssertEqual(done("我們約三點開會還是四點"), "我們約3:00開會還是4:00")
        XCTAssertEqual(done("我們約三點開會，不是四點，還是五點？"), "我們約3:00開會，不是4:00，還是5:00？")
        XCTAssertEqual(done("晚上八點吃飯，還是九點？"), "晚上8點吃飯，還是9點？")
        XCTAssertEqual(done("他上午十點到，下午還是兩點。"), "他上午10:00到，下午還是2:00", "前面只有時間詞")
        XCTAssertEqual(done("我們約三點開會，應該不是四點"), "我們約3:00開會，應該不是4:00", "前面只有副詞")
    }

    /// 最後一項接著講事情（黑的很好看、C比較好、雞蛋已經放冰箱、綠不錯）＝列舉沒講完，不編號；不再靠一張動詞清單，
    /// 改看最後一項是不是跟前面幾項一樣長（多兩個單位以上就不是一個東西）。
    func testRunOnLastItemIsNotAListItem() {
        let cases: [(String, String)] = [
            ("我買了三個，紅的、藍的、黑的很好看。", "我買了三個，紅的、藍的、黑的很好看"),
            ("我試了三個，A、B、C比較好。", "我試了三個，A、B、C比較好"),
            ("我吃了三個，蘋果、香蕉、芭樂好飽。", "我吃了三個，蘋果、香蕉、芭樂好飽"),
            ("我想到三個，A方案、B方案、C方案還不錯。", "我想到三個，A方案、B方案、C方案還不錯"),
            ("剛剛三個，A、B、C好像有問題。", "剛剛三個，A、B、C好像有問題"),
            ("我看了三個，iPhone、Pixel、Galaxy最喜歡。", "我看了三個，iPhone、Pixel、Galaxy最喜歡"),
            ("買了三樣，牛奶、麵包、雞蛋已經放冰箱。", "買了三樣，牛奶、麵包、雞蛋已經放冰箱"),
            ("我有三個，大的、中的、小的比較貴。", "我有三個，大的、中的、小的比較貴"),
            ("三件，上衣、褲子、外套太大了。", "三件，上衣、褲子、外套太大了！"),
            ("我挑了四個，紅、橙、黃、綠不錯。", "我挑了四個，紅、橙、黃、綠不錯"),
            ("我買了三個，紅的、藍的、黑的好。", "我買了三個，紅的、藍的、黑的好"),
            ("我挑了三個，A、B、C讚。", "我挑了三個，A、B、C讚"),
            ("我有三個，大的、中的、小的便宜。", "我有三個，大的、中的、小的便宜"),
        ]
        for (input, expected) in cases { XCTAssertEqual(done(input), expected, input) }
        // 每一項一樣是「一個東西」：照樣編號。
        XCTAssertEqual(done("我挑了四個，紅、橙、黃、綠"), "我挑了四個：\n1. 紅\n2. 橙\n3. 黃\n4. 綠")
        XCTAssertEqual(done("我看了三個，iPhone、Pixel、Galaxy"), "我看了三個：\n1. iPhone\n2. Pixel\n3. Galaxy")
        XCTAssertEqual(done("幫我準備三樣東西，筆電、充電線、還有行動電源"), "幫我準備三樣東西：\n1. 筆電\n2. 充電線\n3. 行動電源")
        XCTAssertEqual(done(Self.ls03), "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭")
        XCTAssertEqual(Normalizer.itemUnits("回email"), 2)
        XCTAssertEqual(Normalizer.itemUnits("Galaxy最喜歡"), 4)
        XCTAssertEqual(Normalizer.itemUnits("A 方案"), 3)
    }

    /// 「N點」要接在列重點的動詞後面（有／注意／講／提／列／以下…）才是在數；光一個「三點」＝約時間。
    func testBareHourBeforeAnEnumerationIsAClockTime() {
        XCTAssertEqual(done("三點，小明、小華、小美集合。"), "三點，小明、小華、小美集合")
        XCTAssertEqual(done("大家三點，A組、B組、C組。"), "大家三點，A組、B組、C組")
        XCTAssertEqual(done("重點有三點，響度、動態、空間感"), "重點有三點：\n1. 響度\n2. 動態\n3. 空間感")
        XCTAssertEqual(done("要講三點，混音、母帶、交付"), "要講三點：\n1. 混音\n2. 母帶\n3. 交付")
        XCTAssertEqual(done("以下三點，響度、動態、空間感"), "以下三點：\n1. 響度\n2. 動態\n3. 空間感")
        XCTAssertEqual(done("三點重點：品質、速度、價格。"), "三點重點：\n1. 品質\n2. 速度\n3. 價格")
    }

    /// 轉折詞後面接指示詞／幾（另外那個版本、最後這段、最後那段、最後幾個音）＝限定詞，不分段；
    /// 轉述（他在信裡面寫，首先…／老闆告訴我們，首先…）逗號後面到句尾都是引文，裡面的轉折詞都不切。
    func testDemonstrativeOpenersAndQuotedSpeechDoNotSplit() {
        let texts = [
            "我們這次做了兩個版本，A 版本的高頻比較亮，人聲也比較前面，另外那個版本比較暗，低頻比較飽滿，客戶說兩個都想聽聽看，所以我明天會把兩個版本都寄過去給他，總之大家先聽聽看，有意見再跟我說就好。",
            "我們剛剛把整首歌又聽了一遍，主歌很好，副歌的和聲有點太多，另外那首歌的副歌要改，最後那段 bridge 也要重錄，鼓的部分大家都覺得很好不用動，明天下午再一起討論細節，大家先休息一下，辛苦了，謝謝大家今天的幫忙。",
            "他在信裡面寫，首先要把所有的 stems 整理好，另外要附上每一軌的說明，總之交付之前一定要先確認過一次，不然對方收到之後會很困擾，還要再來回溝通好幾次，這點大家要特別注意，有問題可以直接問我，我再幫大家跟對方確認清楚。",
            "老闆告訴我們，首先要把所有的 stems 整理好，另外要附上每一軌的說明，總之交付之前一定要先確認過一次，不然對方收到之後會很困擾，還要再來回溝通好幾次，這點大家要特別注意，有問題可以直接問我，我再幫大家跟對方確認清楚。",
            "這次的混音分成兩個階段，第一個階段先把所有的軌道整理乾淨，鼓組跟貝斯先處理，人聲最後再進來，另外那個 Atmos 的版本要等立體聲確認之後才開始做，最後幾天留給母帶跟交付，總之時程很緊，大家一起加油，有問題隨時跟我說。",
        ]
        for s in texts { XCTAssertFalse(done(s).contains("\n"), s) }
        for s in ["人聲也比較前面，另外那個版本比較暗", "鼓手也很穩，最後這段副歌我們錄了五次", "可以再補錄，最後幾個音的尾巴太突然了",
                  "副歌要改，最後那段 bridge 也要重錄", "他在信裡面寫，首先要整理好，另外要附上說明，總之先確認",
                  "老闆告訴我們，首先要整理好，另外要附上說明"] {
            XCTAssertEqual(Normalizer.splitAtClauseOpeners(s), [s], s)
        }
        // 不是轉述動詞結尾：照切。
        XCTAssertEqual(Normalizer.splitAtClauseOpeners("他說好，另外我們明天要開會"), ["他說好，", "另外我們明天要開會"])
        XCTAssertTrue(Normalizer.endsWithReportedSpeech("老闆告訴我們"))
        XCTAssertFalse(Normalizer.endsWithReportedSpeech("我把檔案寄給大家"))
    }

    /// 「第N」後面直接接的內容（第一小提琴…第二小提琴…第三聲部）＝名詞片語，「第一／第二」留著。
    /// 第三輪政策（2026-10-22）：不符合條列規則就整句原樣（第二輪的預期是切行）；直接接內容的序數串要有清單引言才編號
    ///（第二輪「第一買牛奶，第二買麵包，第三寫報告」沒有引言也編號，現在原樣；有「三件事」引言的照樣編號）。
    func testOrdinalNounPhrasesWithASharedHeadKeepTheirOrdinals() {
        XCTAssertEqual(done("第一小提琴太大聲，第二小提琴太小聲，第三聲部剛好。"), "第一小提琴太大聲，第二小提琴太小聲，第三聲部剛好")
        XCTAssertEqual(done("第一買牛奶，第二買麵包，第三寫報告"), "第一買牛奶，第二買麵包，第三寫報告", "沒有清單引言：原樣")
        XCTAssertEqual(done("今天有三件事，第一買牛奶，第二買麵包，第三寫報告"), "今天有三件事：\n1. 買牛奶\n2. 買麵包\n3. 寫報告", "有引言、數量對得上：照樣是條列")
        XCTAssertEqual(done(Self.ls02), "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明")
    }

    // MARK: - 7. 2026-10-22 第三輪：序數串的保守規則（取代前兩輪的特例）

    /// 符合條列規則的序數串才編號：(A) 每個「第N」後面都緊接分隔、空白或「是／個是／點是／就是…」；
    /// (B) 前面有講數量（等於項數）或「以下／如下／清單」的引言，而且每一項都是動作（不接量詞、不是名詞當主詞）。
    func testQualifyingOrdinalSeriesAreNumbered() {
        let cases: [(String, String)] = [
            (Self.ls01, "接下來有三件事：\n1. 把low end收乾淨\n2. 把delay收短\n3. 重做母帶，記得喔！"),
            (Self.ls02, "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明"),
            (Self.ls05, "兩個重點：\n1. 響度對齊到-14 LUFS\n2. 不要壓dynamic range，一定要記得"),
            ("今天有三件事，第一買牛奶，第二回email，第三寫報告。", "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"),
            ("今天有三件事。第一買牛奶，第二回email，第三寫報告。", "今天有三件事。\n1. 買牛奶\n2. 回email\n3. 寫報告"),
            ("以下三點：第一更新外掛，第二備份專案，第三重開機", "以下三點：\n1. 更新外掛\n2. 備份專案\n3. 重開機"),
            ("第一個是麥克風，第二個是耳機。", "1. 麥克風\n2. 耳機"),
            ("第一點是響度，第二點是動態。", "1. 響度\n2. 動態"),
            ("第一就是先備份，第二就是再更新", "1. 先備份\n2. 再更新"),
            ("第一 買牛奶 第二 回email", "1. 買牛奶\n2. 回email"),
            ("有三件事，第一，買菜，第二，煮飯，第三，洗碗，然後就可以休息了", "有三件事：\n1. 買菜\n2. 煮飯\n3. 洗碗，然後就可以休息了"),
            ("第一是買菜，然後洗菜，第二是煮飯，最後洗碗", "1. 買菜，然後洗菜\n2. 煮飯，最後洗碗"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(done(input), expected, input)
            XCTAssertEqual(n.normalize(n.normalize(input).cleaned).cleaned, n.normalize(input).cleaned, "整理兩次一樣：\(input)")
        }
    }

    /// 不符合條列規則的序數串：整句原樣——不編號、不切行、「第N」一個都不少（審查員的探針與混用的寫法）。
    func testNonQualifyingOrdinalSeriesStayVerbatim() {
        let texts = [
            // 第N 接量詞或名詞，後面幾項改用「第N是」（第二輪漏掉的混用寫法）
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
            // 第N 接名詞（開頭字各不相同）
            "第一小提琴太大聲，第二中提琴太小聲，第三大提琴剛好。",
            "第一男高音唱得很好，第二女高音有點緊，第三男低音剛好。",
            "樂團裡第一吉他是阿明，第二貝斯是小華，第三鍵盤是阿強。",
            // 有數量引言，但項目是名詞當主詞、接量詞、數量對不上、序數並列
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
            // 沒有引言、不從第一開始、不連續
            "第一買牛奶第二回email第三寫報告",
            "第一買牛奶，第二買麵包，第三寫報告",
            "第一要記得存檔，第二要備份",
            "我們要的是第二版不是第三版",
            "他是第一名，第二次來",
            "第一是A，第三是B",
            "第二是先買菜，第三是煮飯",
        ]
        for s in texts {
            XCTAssertEqual(Normalizer.normalizeListCues(s, numbered: true), s, s)
            XCTAssertEqual(Normalizer.normalizeListCues(s, numbered: false), s, "單行框也不切行：\(s)")
            XCTAssertEqual(done(s), SentenceMood.finish(s), s)
        }
    }

    func testOrdinalRuleHelpers() {
        XCTAssertEqual(Normalizer.ordinalListIntroCount("接下來有三件事,"), 3)
        XCTAssertEqual(Normalizer.ordinalListIntroCount("我說三件事。"), 3)
        XCTAssertEqual(Normalizer.ordinalListIntroCount("今天的工作清單是"), 0)
        XCTAssertEqual(Normalizer.ordinalListIntroCount("以下三點："), 3)
        XCTAssertNil(Normalizer.ordinalListIntroCount("我們錄了三遍，"), "「三遍」不是清單引言")
        XCTAssertNil(Normalizer.ordinalListIntroCount("這是第三件事，"), "第三件事＝序數")
        XCTAssertNil(Normalizer.ordinalListIntroCount("有三件事要講，然後大家，"), "只看最後一個子句")
        XCTAssertNil(Normalizer.ordinalListIntroCount("下午3點，"), "阿拉伯數字＋點＝鐘點")
        XCTAssertTrue(Normalizer.isVerbLedItem("買牛奶"))
        XCTAssertTrue(Normalizer.isVerbLedItem("更新Pro Tools，然後重開"))
        XCTAssertFalse(Normalizer.isVerbLedItem("小提琴太大聲"))
        XCTAssertFalse(Normalizer.isVerbLedItem("吉他是阿明"))
        XCTAssertFalse(Normalizer.isVerbLedItem("男高音唱得很好"))
        XCTAssertFalse(Normalizer.isVerbLedItem("跟"))
        XCTAssertNil(Normalizer.parseOrdinalLine("第一遍太快，")?.body, "量詞")
        XCTAssertNil(Normalizer.parseOrdinalLine("第一小節太快，")?.body, "兩個字的量詞")
        XCTAssertEqual(Normalizer.parseOrdinalLine("第一個是麥克風，")?.body, "麥克風")
        XCTAssertEqual(Normalizer.parseOrdinalLine("第一個是麥克風，")?.direct, false)
        XCTAssertEqual(Normalizer.parseOrdinalLine("第一 買牛奶 ")?.direct, false, "空白＝分隔")
        XCTAssertEqual(Normalizer.parseOrdinalLine("第一小提琴太大聲，")?.direct, true)
        XCTAssertNil(Normalizer.ordinalList("我們要的是第二版不是第三版", previous: nil))
        XCTAssertEqual(Normalizer.ordinalList("今天有三件事，第一買牛奶，第二回email，第三寫報告。", previous: nil)?.bodies, ["買牛奶", "回email", "寫報告。"])
        XCTAssertNil(Normalizer.ordinalList("今天有三件事第一買牛奶第二回email第三寫報告。", previous: nil), "(A) 第二、第三不在子句開頭")
    }

    // MARK: - 8. 2026-10-22 第四輪：(A) 子句開頭、(B) 封閉動詞表、(C) 量詞——有一項不過就整串原樣

    /// 審查找到的兩類：清單引言後面的「第N＋名詞」（第一小提琴＝首席小提琴，不是「小提琴」），
    /// 以及排名／口號（「第N」收在子句結尾）。第三輪把這些編號、吃掉「第N」；現在整句原樣，「第N」一個都不少。
    func testRankingsAndOrdinalNounPhrasesStayVerbatim() {
        let texts = [
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
        ]
        for s in texts {
            XCTAssertEqual(Normalizer.normalizeListCues(s, numbered: true), s, s)
            XCTAssertEqual(Normalizer.normalizeListCues(s, numbered: false), s, "單行框也不切行：\(s)")
            XCTAssertNil(Normalizer.ordinalList(s, previous: nil), s)
            let out = done(s)
            XCTAssertFalse(out.contains("1. "), "\(s) → \(out)")
            XCTAssertEqual(out.filter { $0 == "第" }.count, s.filter { $0 == "第" }.count, "「第N」一個都不能少：\(s) → \(out)")
        }
    }

    /// 反方向：每一項都過 (A)(B)(C) 的真清單照樣編號（ls01／ls02／ls05 之外的講法）。
    func testRealListsThatPassAllThreeChecksAreNumbered() {
        let cases: [(String, String)] = [
            ("今天有三件事，第一買牛奶，第二回email，第三寫報告", "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"),
            ("以下兩點：第一確認檔案，第二上傳雲端", "以下兩點：\n1. 確認檔案\n2. 上傳雲端"),
            ("清單如下，第一下載素材，第二安裝外掛", "清單如下：\n1. 下載素材\n2. 安裝外掛"),
            ("我說兩件事。第一是買菜，第二是煮飯。", "我說兩件事。\n1. 買菜\n2. 煮飯"),
            ("第一，安全；第二，速度", "1. 安全\n2. 速度"),
            ("接下來有兩個步驟，第一備份專案，第二重開機", "接下來有兩個步驟：\n1. 備份專案\n2. 重開機"),
            ("明天兩件事，第一聯絡客戶，第二預約錄音室", "明天兩件事：\n1. 聯絡客戶\n2. 預約錄音室"),
            ("今天兩件事，第一去郵局寄包裹，第二去銀行繳費", "今天兩件事：\n1. 去郵局寄包裹\n2. 去銀行繳費"),
            ("三件事：第一，買菜；第二，煮飯；第三，洗碗。", "三件事：\n1. 買菜\n2. 煮飯\n3. 洗碗"),
            ("以下兩件事 第一 買菜 第二 煮飯", "以下兩件事：\n1. 買菜\n2. 煮飯"),
            ("今天的工作清單是第一更新Pro Tools,第二匯出Stems,第三寫交付說明", "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(done(input), expected, input)
            XCTAssertEqual(n.normalize(n.normalize(input).cleaned).cleaned, n.normalize(input).cleaned, "整理兩次一樣：\(input)")
        }
    }

    func testOrdinalListVerbWhitelist() {
        // 票面列的動詞都在表上（Kotlin 是同一份，GoldenTest 逐字比對 golden/ordinal-list-verbs.json）。
        let ticket = ["買", "回", "寫", "交", "做", "改", "加", "刪", "寄", "送", "帶", "排", "繳", "洗", "煮", "倒", "拿", "找", "問", "練", "讀",
                      "修", "開", "關", "去", "準備", "更新", "匯出", "匯入", "確認", "檢查", "整理", "收", "錄", "補錄", "重錄", "重做", "上傳",
                      "下載", "安裝", "測試", "聯絡", "通知", "預約", "處理", "安排", "提醒", "規劃", "設定", "備份"]
        for v in ticket { XCTAssertTrue(Normalizer.ordinalListVerbs.contains(v), v) }
        XCTAssertEqual(Set(Normalizer.ordinalListVerbs).count, Normalizer.ordinalListVerbs.count, "沒有重複")
        for body in ["買牛奶", "回email", "確認檔案", "去郵局寄包裹", "重開機", "補錄人聲", "更新Pro Tools，然後重開", "匯出Stems"] {
            XCTAssertTrue(Normalizer.isVerbLedItem(body), body)
        }
        // 票面舉的名詞、名詞片語開頭、動詞＋「的」、助動詞／否定：都不是動作。
        for body in ["小提琴重錄", "順位改成小明", "志願填台大", "男高音補錄", "吉他是阿明", "軌是鼓", "遍太快", "台電腦",
                     "交響曲重錄", "錄音室要整理", "做法比較快", "寫的歌要重錄", "要準時", "不要遲到", "跟", ""] {
            XCTAssertFalse(Normalizer.isVerbLedItem(body), body)
        }
        // (C) 量詞優先：「第三排錄音」的「排」是量詞，內容是 nil。
        XCTAssertNil(Normalizer.parseOrdinalLine("第三排錄音，")?.body)
        XCTAssertNil(Normalizer.parseOrdinalLine("第一關先過，")?.body)
    }
}
