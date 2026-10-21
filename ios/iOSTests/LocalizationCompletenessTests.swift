import XCTest

/// 工單 ios-D：英文介面完整性。
///
/// 三份字串目錄（App 與鍵盤共用的 Localizable、兩份 InfoPlist）都要滿足：
///   1. 每個該翻的 key 都有英文（`shouldTranslate: false` 的除外——那是給模型看的提示詞或空白字面）。
///   2. 英文的 state 是 `translated`，不是 `new`／`needs_review`（擺了不等於翻好了）。
///   3. 格式化參數（%@／%lld／%1$@…）的**數量、順序、型別**與繁中原文完全一致——
///      這條抓的是「英文漏了一個 %@」或「把 %1$@／%2$@ 對調」這種會在執行時炸掉或出錯字的。
///   4. 英文不是空字串、也不是把繁中原文原樣貼回去（後者是「沒翻」）。
///
/// 鍵盤 extension 的介面語言跟系統走（iOS 不准對 extension 單獨覆寫），所以這裡只驗**有沒有翻**，
/// 不驗鍵盤會不會跟著 App 的語言設定切換——那件事在 SettingsScreen 的說明文字裡誠實寫明了。
final class LocalizationCompletenessTests: XCTestCase {

    // MARK: - 目錄

    private struct Catalog {
        let name: String
        let url: URL
        let object: [String: Any]

        /// 真正出現在畫面上的 key（`shouldTranslate: false` 的是提示詞片段／空白，不該有英文）。
        var translatable: [(key: String, node: [String: Any])] {
            let all = object["strings"] as? [String: [String: Any]] ?? [:]
            return all.keys.sorted().compactMap { key in
                guard let node = all[key], node["shouldTranslate"] as? Bool != false else { return nil }
                return (key: key, node: node)
            }
        }

        func unit(_ node: [String: Any], _ locale: String) -> [String: Any]? {
            let locs = node["localizations"] as? [String: [String: Any]] ?? [:]
            return (locs[locale]?["stringUnit"] as? [String: Any])
        }

        /// 這條 key 的**中文**說法，去重、順序為「來源語言優先」。
        ///
        /// 目錄的 `sourceLanguage` 是 `zh-Hant`，所以 key 本身就是繁中原文（少數 key 另有 zh-Hant 單元）；
        /// `zh-Hans` 只是同一句話的簡中版。
        ///
        /// 工單 ios-D-repair1 的第 8 點就在這：舊版這裡 `zh-Hans ?? zh-Hant ?? key`，
        /// 拿簡中當「繁中原文」去比——繁簡用字不同的 key（例如「資訊與電腦」／「信息与计算机」）
        /// 只要英文剛好貼上其中一種，「英文就是沒翻」與格式化參數兩道檢查就一起被繞過。
        /// 現在兩道檢查都對**每一個**中文變體逐一比對，貼上哪一種都會紅。
        func chineseVariants(_ key: String, _ node: [String: Any]) -> [String] {
            let hant = unit(node, "zh-Hant")?["value"] as? String
            let hans = unit(node, "zh-Hans")?["value"] as? String
            let isCJK: (String) -> Bool = { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
            var out: [String] = []
            // 順序＝來源語言優先：key 本身是繁中原文（中文 key 才有）→ zh-Hant 單元 → zh-Hans 譯文。
            // 純 ASCII 的 key（例如 vocab.pack.computing.name）不是中文變體，不進來。
            for value in [isCJK(key) ? key : nil, hant, hans] {
                if let value, !value.isEmpty, !out.contains(value) { out.append(value) }
            }
            return out
        }
    }

    private static let iosRoot = URL(fileURLWithPath: #filePath)   // ios/iOSTests/LocalizationCompletenessTests.swift
        .deletingLastPathComponent()
        .deletingLastPathComponent()                                // ios/

    private static let catalogPaths = [
        "Shared/Localizable.xcstrings",
        "App/InfoPlist.xcstrings",
        "Keyboard/InfoPlist.xcstrings",
    ]

    private func loadCatalog(_ relative: String) throws -> Catalog {
        let name = (relative as NSString).lastPathComponent
        let url = Self.iosRoot.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                    "\(name) 不是 JSON 物件")
        return Catalog(name: name, url: url, object: object)
    }

    private func eachCatalog(_ body: (Catalog) throws -> Void) throws {
        for relative in Self.catalogPaths {
            try body(loadCatalog(relative))
        }
    }

    // MARK: - 1. 每個 key 都有英文

    func testEveryTranslatableKeyHasEnglish() throws {
        var total = 0
        try eachCatalog { catalog in
            let missing = catalog.translatable.compactMap { entry -> String? in
                guard catalog.unit(entry.node, "en") == nil else { return nil }
                return entry.key
            }
            XCTAssertTrue(missing.isEmpty,
                          "\(catalog.name) 有 \(missing.count) 個 key 沒有英文：\(missing.prefix(10).map { "\"\($0)\"" })")
            total += catalog.translatable.count
        }
        // 這份目錄現在有 600 出頭個 key；數量掉下去代表有人刪了 key 而沒人發現這道閘門失效。
        XCTAssertGreaterThan(total, 550, "可翻譯的 key 數量異常（\(total)），確認目錄沒被清空")
    }

    // MARK: - 2. 英文必須是已審的翻譯，不是擺在那裡的 new

    func testEnglishUnitsAreMarkedTranslatedAndNonEmpty() throws {
        try eachCatalog { catalog in
            for entry in catalog.translatable {
                guard let unit = catalog.unit(entry.node, "en") else { continue }
                let value = unit["value"] as? String ?? ""
                XCTAssertEqual(unit["state"] as? String, "translated",
                               "\(catalog.name)「\(entry.key)」的英文還是 \(unit["state"] as? String ?? "無 state")")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(catalog.name)「\(entry.key)」的英文是空字串")
            }
        }
    }

    // MARK: - 2b. 權限說明的揭露與承諾，英文要跟中文對得上（工單 ios-D-repair1 第 1、2 點）

    /// 鍵盤與主 App 各自的 InfoPlist 權限說明，英文要**逐點對上**各自的中文：
    /// 中文寫了「音訊會送到 Apple」，英文就不能省；中文寫了「只在你按下麥克風鍵時錄音」，
    /// 英文也不能只剩泛泛的 "uses the microphone"。少一點是隱私揭露不實，多一點是承諾做不到。
    func testPermissionDisclosuresInEnglishMatchChinese() throws {
        let keyboard = try loadCatalog("Keyboard/InfoPlist.xcstrings")
        let app = try loadCatalog("App/InfoPlist.xcstrings")

        func value(_ catalog: Catalog, _ key: String, _ locale: String) throws -> String {
            let node = try XCTUnwrap(catalog.translatable.first { $0.key == key }, "\(catalog.name) 沒有 \(key)")
            return try XCTUnwrap(catalog.unit(node.node, locale)?["value"] as? String,
                                 "\(catalog.name)「\(key)」沒有 \(locale)")
        }

        // 鍵盤版：中文揭露「音訊會送到 Apple」，英文必須有。
        let keyboardSpeech = try value(keyboard, "NSSpeechRecognitionUsageDescription", "en")
        let keyboardSpeechZH = try value(keyboard, "NSSpeechRecognitionUsageDescription", "zh-Hant")
        XCTAssertTrue(keyboardSpeechZH.contains("送到 Apple"), "中文前提：鍵盤版要揭露音讯會送到 Apple")
        XCTAssertTrue(keyboardSpeech.contains("Apple"), "英文漏了「音讯会送到 Apple」这个关键揭露：\(keyboardSpeech)")
        XCTAssertTrue(keyboardSpeech.contains("sent to Apple"), "英文要明写 audio is sent to Apple：\(keyboardSpeech)")
        // 送去的是 Apple 的伺服器，不是 UTUVO 的；「our server」會讓人以為音訊送到我們這裡。
        XCTAssertFalse(keyboardSpeech.lowercased().contains("our server"), "伺服器是 Apple 的，不是我們的：\(keyboardSpeech)")

        // 鍵盤版麥克風：中文承諾「只在你按下麥克風鍵時錄音」「插入游標處」，英文要點點對上。
        let keyboardMic = try value(keyboard, "NSMicrophoneUsageDescription", "en")
        let keyboardMicZH = try value(keyboard, "NSMicrophoneUsageDescription", "zh-Hant")
        XCTAssertTrue(keyboardMicZH.contains("只在你按下麥克風鍵時錄音"), "中文前提：只在你按下麥克風鍵時錄音")
        XCTAssertTrue(keyboardMicZH.contains("插入游標處"), "中文前提：插入游標處")
        XCTAssertTrue(keyboardMic.contains("microphone button"),
                      "英文要保留「only while you press the mic button」这个承诺：\(keyboardMic)")
        XCTAssertTrue(keyboardMic.contains("only"), "英文要写明只在按下时录音：\(keyboardMic)")
        XCTAssertTrue(keyboardMic.contains("cursor"), "英文要保留「插入游標處」：\(keyboardMic)")
        // 鍵盤是點一下開始、再點一下結束，不是按住說話；寫 hold 等於描述了不存在的操作。
        XCTAssertFalse(keyboardMic.lowercased().contains("hold"), "鍵盤是點按切換，不是按住：\(keyboardMic)")
        // 鍵盤擴充的麥克风说明不该写主 App 的行为（「你在 UTUVO Type 鍵盤開啟語音」在这裡語意錯亂）。
        XCTAssertFalse(keyboardMic.lowercased().contains("from the utuvo type keyboard"),
                       "鍵盤擴充自己的麥克风说明不该提「從鍵盤開啟語音」：\(keyboardMic)")

        // 主 App 的麥克风说明是另一句，兩邊不得互換。
        let appMic = try value(app, "NSMicrophoneUsageDescription", "en")
        XCTAssertTrue(appMic.contains("dictate"), "主 App 麥克风说明要讲听写：\(appMic)")
        XCTAssertNotEqual(appMic, keyboardMic, "主 App 與鍵盤的麥克风说明是兩句不同的話")
    }

    /// 工單 ios-D-repair1 第 5 點：翻譯弧的說明，中文是「滑到語言放開、**講中文**，就貼上翻譯」。
    /// 英文寫成 "speak to paste the translation"，把「講中文」這個前提漏掉了——
    /// 外語使用者會以為講任何語言都會貼翻譯。這道測試把前提釘住。
    func testTranslateArcEnglishKeepsTheSpeakChinesePremise() throws {
        let catalog = try loadCatalog("Shared/Localizable.xcstrings")
        let entry = try XCTUnwrap(catalog.translatable.first { $0.key.hasPrefix("長按鍵盤的光球") },
                                  "找不到翻譯弧的說明那句")
        let node = entry.node
        // 這句的繁中原文就是 key 本身（目錄 sourceLanguage = zh-Hant）。
        XCTAssertTrue(entry.key.contains("講中文"), "中文前提：講中文，就貼上翻譯")
        let chinese = entry.key
        let english = try XCTUnwrap(catalog.unit(node, "en")?["value"] as? String)
        XCTAssertTrue(english.contains("speak Chinese"),
                      "英文要保留「講中文」這個前提，否則外語使用者會以為講哪種語言都行：\(english)")
        // 格式化參數仍然要對（%lld 最多幾個語言）——這句常被改壞。
        XCTAssertEqual(Self.specifiers(in: english), Self.specifiers(in: chinese))
    }

// MARK: - 3. 格式化參數一致（數量／順序／型別）

    /// `%1$@` 的位置引數也要抓：蘋果的處理是位置決定對應到第幾個引數，對調了就會把兩個
    /// 參數塞反檔。這裡把位置前綴拿掉後比對 `%@`／`%lld` 的**序列**。
    func testEnglishFormatSpecifiersMatchChinese() throws {
        try eachCatalog { catalog in
            for entry in catalog.translatable {
                guard let english = catalog.unit(entry.node, "en")?["value"] as? String else { continue }
                let actual = Self.specifiers(in: english)
                let enPositions = Self.positions(in: english)
                // 對**每一個**中文變體（繁中原文、zh-Hant 單元、zh-Hans）都要一致——
                // 只比一種會讓「英文跟另一種中文一樣」或「跟另一種中文參數不同」變成漏網之魚。
                for chinese in catalog.chineseVariants(entry.key, entry.node) {
                    let expected = Self.specifiers(in: chinese)
                    XCTAssertEqual(actual, expected,
                                   "\(catalog.name)「\(entry.key)」格式化參數不一致：中文 \(chinese) 的 \(expected) vs 英文 \(actual)")
                    // 兩邊都寫了位置引數時，順序也要一致（%2$@／%1$@ 對調會把兩個參數塞反）。
                    let zhPositions = Self.positions(in: chinese)
                    if !zhPositions.isEmpty && !enPositions.isEmpty {
                        XCTAssertEqual(enPositions, zhPositions,
                                       "\(catalog.name)「\(entry.key)」的位置引數順序不一致：中文 \(zhPositions) vs 英文 \(enPositions)")
                    }
                }
            }
        }
    }

    /// 取出 `%@`／`%lld`／`%1$@` 這類參數，位置前綴剝掉、%%（跳過的百分比）不算。
    ///
    /// 兩種寫法都要認：位置式 `%1$lld`（蘋果從插值字串抽出來的形式）與樸素的 `%lld`。
    /// 回傳**修飾符＋轉換字**的序列（例如 `%1$lld` → `"lld"`），位置另外用 `positions(in:)` 比。
    /// 這樣中文用位置式、英文用樸素式（蘋果允許，語意一樣）不會誤報，
    /// 但英文漏一個參數、或把兩個不同型別對調，一定會被抓到。
    private static func specifiers(in s: String) -> [String] {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "%" else { i = s.index(after: i); continue }
            var j = s.index(after: i)
            // 位置引數：%3$@（可有可無）
            let afterPercent = j
            while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
            if j > afterPercent {
                guard j < s.endIndex, s[j] == "$" else { i = afterPercent; continue }
                j = s.index(after: j)
            }
            // 長度修飾符（%1$lld 的 ll、%l 的 l）
            var modifier = ""
            while j < s.endIndex, "hlLqjzt".contains(s[j]) { modifier.append(s[j]); j = s.index(after: j) }
            guard j < s.endIndex else { break }
            let conv = String(s[j])
            // 只有「合法的轉換字」才算參數。`60% fewer errors` 裡的 % 後面接的是空白，
            // 不是格式碼——不驗轉換字就會把它算成一個鬼參數，讓整份目錄誤報。
            if "dDuUxXoOfeEgGcCsSpaAn@".contains(conv) {
                out.append(modifier + conv)
            }
            i = s.index(after: j)
        }
        return out
    }

    /// 有位置前綴的那些參數，位置依序是多少（沒寫位置的回 0）。
    /// 中文用 `%1$@／%2$@`、英文用 `%@／%@` 語意相同，所以只有**兩邊都有位置**時才拿來比。
    private static func positions(in s: String) -> [Int] {
        var out: [Int] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "%" else { i = s.index(after: i); continue }
            var j = s.index(after: i)
            let afterPercent = j
            var digits = ""
            while j < s.endIndex, s[j].isNumber { digits.append(s[j]); j = s.index(after: j) }
            if digits.isEmpty || j >= s.endIndex || s[j] != "$" { i = afterPercent; continue }
            j = s.index(after: j)
            while j < s.endIndex, "hlLqjzt".contains(s[j]) { j = s.index(after: j) }
            guard j < s.endIndex, "dDuUxXoOfeEgGcCsSpaAn@".contains(s[j]) else { i = j; continue }
            out.append(Int(digits) ?? 0)
            i = s.index(after: j)
        }
        return out
    }

    // MARK: - 4. 英文不是把繁中原文貼回來

    func testEnglishIsNotTheChineseSourceVerbatim() throws {
        try eachCatalog { catalog in
            for entry in catalog.translatable {
                guard let english = catalog.unit(entry.node, "en")?["value"] as? String else { continue }
                // 對**每一個**中文變體都要判：英文只要跟繁中原文或簡中譯文任一個字字相同，
                // 就是沒翻（舊版只挑一種中文比，貼上另一種就繞過去）。
                for chinese in catalog.chineseVariants(entry.key, entry.node) {
                    // 專有名詞（UTUVO Type、Groq、Gemini…）本來就兩邊一樣，這裡放行純 ASCII 的短字串。
                    let chineseIsCJK = chinese.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                    XCTAssertFalse(chineseIsCJK && english == chinese,
                                   "\(catalog.name)「\(entry.key)」的英文跟中文原文一模一樣，等於沒翻：\(chinese)")
                }
            }
        }
    }

    // MARK: - 5. 專有名詞不翻

    func testProperNounsSurviveInEnglish() throws {
        // 這些名字在繁中裡也照原文寫；英文不得把它們「翻」掉。
        let mustKeep = ["UTUVO Type", "Groq", "Gemini", "Apple Intelligence", "Gemma", "Qwen"]
        var checked = 0
        try eachCatalog { catalog in
            for entry in catalog.translatable {
                guard let english = catalog.unit(entry.node, "en")?["value"] as? String else { continue }
                let chinese = (catalog.unit(entry.node, "zh-Hans")?["value"] as? String) ?? entry.key
                for noun in mustKeep where chinese.contains(noun) {
                    checked += 1
                    XCTAssertTrue(english.contains(noun),
                                  "\(catalog.name)「\(entry.key)」的英文把 \(noun) 翻掉了：\(english)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 30, "樣本太少，這條規則可能形同虛設（只對到 \(checked) 處）")
    }

    // MARK: - 6. 這道閘門自己得有會讓它變紅的輸入

    /// 反向驗證：拿一份刻意缺英文／參數對調的目錄跑同一套規則，必須真的抓到。
    /// 綠燈跟「沒有在檢查」長得一模一樣——所以規則本身也要被測。
    func testDetectorActuallyCatchesMissingEnglishAndSwappedSpecifiers() {
        let broken = """
        {
          "sourceLanguage" : "zh-Hant",
          "strings" : {
            "字串：%1$@、%2$@" : {
              "localizations" : {
                "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "字串：%1$@、%2$@" } },
                "en" : { "stringUnit" : { "state" : "translated", "value" : "Text: %2$@, %1$@" } }
              }
            },
            "%lld 分鐘" : {
              "localizations" : {
                "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "%lld 分鐘" } }
              }
            },
            "缺翻譯" : {
              "localizations" : {
                "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "缺翻譯" } },
                "en" : { "stringUnit" : { "state" : "new", "value" : "" } }
              }
            },
            "提示詞" : {
              "shouldTranslate" : false
            }
          },
          "version" : "1.0"
        }
        """
        let catalog = Catalog(name: "synthetic",
                              url: URL(fileURLWithPath: "/dev/null"),
                              object: (try? JSONSerialization.jsonObject(with: Data(broken.utf8))) as? [String: Any] ?? [:])
        let entries = catalog.translatable
        XCTAssertEqual(Set(entries.map(\.key)), ["字串：%1$@、%2$@", "%lld 分鐘", "缺翻譯"],
                       "shouldTranslate:false 的不該算進來")

        XCTAssertEqual(entries.filter { catalog.unit($0.node, "en") == nil }.map(\.key), ["%lld 分鐘"],
                       "缺英文要被抓到")

        // 位置對調（%1$@／%2$@ 換位）：數量與型別都對，錯的是「哪個引數進哪個洞」——
        // 這正是 Android 那張票審查抓到的坑，所以位置順序也要能被抓到。
        let swappedEnglish = "Text: %2$@, %1$@"
        XCTAssertEqual(Self.specifiers(in: swappedEnglish), ["@", "@"], "型別序列不變")
        XCTAssertEqual(Self.positions(in: swappedEnglish), [2, 1])
        XCTAssertNotEqual(Self.positions(in: swappedEnglish), Self.positions(in: "Text: %1$@, %2$@"),
                          "位置對調必須被抓到")

        // 樸素寫法（沒有位置前綴）也要認得。
        XCTAssertEqual(Self.specifiers(in: "%lld 分鐘"), ["lld"])
        XCTAssertEqual(Self.specifiers(in: "Text: %@"), ["@"])
        XCTAssertEqual(Self.specifiers(in: "Downloading… %lld%%"), ["lld"], "%% 是跳過的百分比，不是參數")
        // 參數數量／型別不同也要被抓到。
        XCTAssertNotEqual(Self.specifiers(in: "Text: %@"), Self.specifiers(in: "%lld 分鐘"))
        // 長度修飾符算進型別。
        XCTAssertNotEqual(Self.specifiers(in: "%lld"), Self.specifiers(in: "%d"))

        // 空字串＋state:new 要被抓到。
        let unreviewed = entries.first { $0.key == "缺翻譯" }!
        let unit = catalog.unit(unreviewed.node, "en")!
        XCTAssertNotEqual(unit["state"] as? String, "translated")
        XCTAssertTrue((unit["value"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty)

        // 長度修飾符要算進型別（%lld 與 %d 不同）。
        XCTAssertNotEqual(Self.specifiers(in: "%lld"), Self.specifiers(in: "%d"))
        // 中文用位置式、英文用樸素式是合法的（蘋果照樣對應到同一批引數）——
        // 這條規則不能因此誤報，否則整份目錄會被逼成兩邊都得寫位置。
        XCTAssertEqual(Self.specifiers(in: "%1$lld 毫秒：%2$@"), Self.specifiers(in: "%lld ms: %@"))
        // 敘述文字裡的百分號不是格式碼（中文寫「六成」、英文寫 "60% fewer errors"）。
        XCTAssertEqual(Self.specifiers(in: "improve noticeably (measured about 60% fewer errors)"), [])
        XCTAssertEqual(Self.positions(in: "improve noticeably (measured about 60% fewer errors)"), [])
    }

    /// 反向驗證（第 8 點的漏洞本體）：英文**只**貼上簡中譯文、跟繁中原文不同字時，
    /// 舊規則（`zh-Hans ?? zh-Hant ?? key` 優先取 zh-Hans）會剛好比到、所以過；
    /// 但那正是「沒翻」。現在規則對每一個中文變體都判，必須紅。
    func testEnglishPastedOnlyTheSimplifiedVariantIsCaught() throws {
        let sneaky = """
        {
          "sourceLanguage" : "zh-Hant",
          "strings" : {
            "資訊與電腦" : {
              "extractionState" : "manual",
              "localizations" : {
                "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "信息与计算机" } },
                "en" : { "stringUnit" : { "state" : "translated", "value" : "信息与计算机" } }
              }
            }
          },
          "version" : "1.0"
        }
        """
        let catalog = Catalog(name: "synthetic-simplified-paste",
                              url: URL(fileURLWithPath: "/dev/null"),
                              object: (try? JSONSerialization.jsonObject(with: Data(sneaky.utf8))) as? [String: Any] ?? [:])
        let entry = try XCTUnwrap(catalog.translatable.first)

        // 繁簡兩種中文說法都要拿來比（繁中原文優先，其次簡中）。
        XCTAssertEqual(catalog.chineseVariants(entry.key, entry.node), ["資訊與電腦", "信息与计算机"],
                       "繁中原文與簡中譯文都要納入比對，順序是來源語言優先")

        let english = catalog.unit(entry.node, "en")?["value"] as? String
        XCTAssertEqual(english, "信息与计算机")
        let offenders = catalog.chineseVariants(entry.key, entry.node).filter { $0 == english }
        XCTAssertEqual(offenders, ["信息与计算机"],
                       "英文跟簡中譯文一模一樣就是沒翻，必須被抓到")

        // 同一個 key 放進真的目錄跑（暫時塞壞值用）：兩個測試方法跑同一條規則。
        let real = try loadCatalog("Shared/Localizable.xcstrings")
        let computing = try XCTUnwrap(real.translatable.first { $0.key == "vocab.pack.computing.name" })
        XCTAssertEqual(real.chineseVariants(computing.key, computing.node),
                       ["資訊與電腦", "信息与计算机"],
                       "vocab.pack.computing.name 繁簡用字不同，正是會被繞過的那一類")
        XCTAssertEqual(real.unit(computing.node, "en")?["value"] as? String, "Computing")
    }
}
