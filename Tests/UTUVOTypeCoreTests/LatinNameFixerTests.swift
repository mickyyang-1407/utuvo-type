import XCTest
@testable import UTUVOTypeCore

/// 語料來自 Micky 手機上的整理紀錄（2026-09-20 17:18–23:26 實機）與 09-19 回報，不是我編的。
final class LatinNameFixerTests: XCTestCase {
    /// 詞庫包「AI 與科技」的詞＋他個人字典會有的幾個。
    private let terms = [
        "Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Claude Code", "Anthropic", "Perplexity", "Copilot",
        "GitHub", "Cursor", "Codex", "Midjourney", "DeepSeek", "Qwen", "Llama", "Grok", "Kimi", "MiniMax", "GLM",
        "Typeless", "Chatterfly", "Notion", "Figma", "Slack", "Telegram", "LINE", "Threads", "Instagram",
        "NVIDIA", "TSMC", "Apple", "Tesla", "Android", "Pixel", "prompt", "session", "Tonmeister", "Dolby Atmos",
        "Dominik", "Tsubasa", "Schmalfuss"
    ]

    private func fix(_ s: String) -> String { LatinNameFixer.fix(s, terms: terms) }

    func testRealMisrecognitionsFromPhone() {
        // 17:18 那一段：「AppleNVidia，Tesla OpenAIChatGPT。，grook。clote coate，clotecoateGLMKimi。minimax」
        XCTAssertEqual(fix("AppleNVidia"), "Apple NVIDIA")
        XCTAssertEqual(fix("OpenAIChatGPT"), "OpenAI ChatGPT")
        XCTAssertEqual(fix("grook"), "Grok")
        XCTAssertEqual(fix("clote coate"), "Claude Code")
        XCTAssertEqual(fix("minimax"), "MiniMax")
        XCTAssertEqual(fix("Gimani"), "Gemini")
        XCTAssertEqual(fix("Coldex"), "Codex")
        XCTAssertEqual(fix("promt"), "prompt")
        XCTAssertEqual(fix("sesion"), "session")
        XCTAssertEqual(fix("Cloud coat"), "Claude Code")
        // 音缺太多的本機救不回來（rprecity 少了開頭的 per）：留給雲端智慧整理，不亂猜。
        XCTAssertEqual(fix("rprecity"), "rprecity")
    }

    func testInsideChineseSentence() {
        XCTAssertEqual(fix("我在測試 Gimani 的智慧整理"), "我在測試 Gemini 的智慧整理")
        // 「coate」單獨出現可能是 Code 也可能是 Claude Code，而 code 是常用英文字（不准亂動）→ 保持原樣。
        XCTAssertEqual(fix("然後 chat 完以後打包成 promt，在 coate 裡面開 sesion。"),
                       "然後 chat 完以後打包成 prompt，在 coate 裡面開 session。")
        XCTAssertEqual(fix("這個 GLMKimi 都要測"), "這個 GLM Kimi 都要測")
    }

    /// 誤擋跟漏擋一樣是缺陷：正常英文、沒在詞庫裡的字、人名都不准被改。
    func testDoesNotTouchOrdinaryEnglish() {
        let untouched = [
            "I put the apple pie on the bed",
            "open the file and check the code",
            "the line is too long, please fix it",
            "we need a new object for the stem",
            "Let's chat about the mixing session tomorrow",   // session 在詞庫裡但本來就拼對
            "他叫 Robert，不是 Roberta",
            "型號是 A13 Bionic",
            "https://github.com/mickyyang-1407/utuvo-type",
            "早上九點的 meeting 改到十點",
        ]
        for s in untouched { XCTAssertEqual(fix(s), s, "不該動：\(s)") }
    }

    func testCorrectSpellingsAreLeftAloneOrOnlyRecased() {
        XCTAssertEqual(fix("Claude Code 很好用"), "Claude Code 很好用")
        XCTAssertEqual(fix("chatgpt 跟 openai"), "ChatGPT 跟 OpenAI")
        XCTAssertEqual(fix("nvidia 的股價"), "NVIDIA 的股價")
        // 只差首字大寫的普通詞不動（不然英文句子裡的 apple、tesla 會被改成公司名）
        XCTAssertEqual(fix("I ate an apple"), "I ate an apple")
        XCTAssertEqual(fix("apple 的股價"), "apple 的股價")
    }

    /// 2026-09-20 實機那一整句（智慧整理紀錄 17:18），一次驗完整條：分開講的、黏在一起的、大小寫。
    func testFullRealSentence() {
        let terms = self.terms + ["Google", "Microsoft", "Meta"]
        let input = "一樣測試看看 AI的公司名稱。AppleNVidia，Tesla OpenAIChatGPT。，grook。clote coate，clotecoateGLMKimi。minimax"
        let expected = "一樣測試看看 AI的公司名稱。Apple NVIDIA，Tesla OpenAI ChatGPT。，Grok。Claude Code，Claude Code GLM Kimi。MiniMax"
        XCTAssertEqual(LatinNameFixer.fix(input, terms: terms), expected)
    }

    func testEmptyTermsIsNoOp() {
        let s = "grook 跟 clote coate"
        XCTAssertEqual(LatinNameFixer.fix(s, terms: []), s)
    }

    func testSkeletonAndDistanceBehaviour() {
        XCTAssertEqual(LatinNameFixer.skeleton("Claude Code"), LatinNameFixer.skeleton("clotecoate"))
        XCTAssertEqual(LatinNameFixer.skeleton("Gemini"), LatinNameFixer.skeleton("jeman"))
        XCTAssertNotEqual(LatinNameFixer.skeleton("Grok"), LatinNameFixer.skeleton("Slack"))
        XCTAssertEqual(LatinNameFixer.fold("ChatGPT"), LatinNameFixer.fold("chat gpt"))
        XCTAssertLessThanOrEqual(LatinNameFixer.distance(LatinNameFixer.fold("promt"), LatinNameFixer.fold("prompt"), limit: 3), 1.0)
        XCTAssertGreaterThan(LatinNameFixer.distance(LatinNameFixer.fold("apple"), LatinNameFixer.fold("android"), limit: 3), 1.5)
    }

    /// 骨架撞在一起的兩個詞（一個字串同時像兩個名字）寧可不改。
    func testAmbiguousSkeletonIsLeftAlone() {
        let ambiguous = ["Kimi", "Kimmy"]
        XCTAssertEqual(LatinNameFixer.fix("kimee", terms: ambiguous), "kimee")
    }

    func testNormalizerRunsTheStepWithTerms() {
        let n = Normalizer(options: NormalizerOptions(latinTerms: terms))
        let out = n.normalize("我在測試 Gimani 的東西")
        XCTAssertEqual(out.cleaned, "我在測試 Gemini 的東西")
        XCTAssertTrue(out.appliedSteps.contains("latin-names"), "步驟清單要看得到這一關：\(out.appliedSteps)")
    }

    /// TYPE-R03（2026-09-20）：超過 40 字元的拉丁 run 不再把後面的短 run 吃掉。
    /// 長 run 本身保留原文不動，後續的獨立 run 仍各自進詞表比對。
    func testLongRunDoesNotEatFollowingShortRuns() {
        let onlyGemini = ["Gemini"]
        let longSentence = "Please review the latest changes before tomorrow morning"
        XCTAssertGreaterThan(longSentence.count, LatinNameFixer.maxRunLength,
                             "這個長句必須 > 40，否則這條測試沒在測超長路徑")

        // 1) 過長開頭 → 後面短名要照修（工單證據：中文逗號斷 run）。
        XCTAssertEqual(
            LatinNameFixer.fix("\(longSentence)，然後打開 jeman", terms: onlyGemini),
            "\(longSentence)，然後打開 Gemini"
        )

        // 2) 中間過長 run（前後短名均可修；換行斷 run）。
        XCTAssertEqual(
            LatinNameFixer.fix("openai\n\(longSentence)\njeman", terms: terms),
            "OpenAI\n\(longSentence)\nGemini"
        )

        // 3) 只有過長 run：完全不動。
        XCTAssertEqual(
            LatinNameFixer.fix(longSentence, terms: onlyGemini),
            longSentence
        )

        // 4) 40/41 邊界：剛好 40 → 進詞表；剛好 41 → 超過上限原文保留。
        // 用「Ab」重複 20 次（40 字元）作 term，lowercased input 與 term 折完字面相同但大小寫不一樣——
        // 在 ≤40 路徑下會被 recase 回 term（驗證有走進詞表）；同樣 lowercased 但長度 +1（41）→
        // 跳過詞表、保留原文（驗證長度閘真的有擋）。
        let term40 = String(repeating: "Ab", count: 20)   // 40 chars
        let term41 = term40 + "C"                          // 41 chars
        XCTAssertEqual(LatinNameFixer.fix(term40.lowercased(), terms: [term40]), term40)
        XCTAssertEqual(LatinNameFixer.fix(term41.lowercased(), terms: [term40]), term41.lowercased())

        // 5) 中文夾一長串英文＋短 jeman：中文不動、長串原文、短名照修。
        XCTAssertEqual(
            LatinNameFixer.fix("請看 \(longSentence)，然後 jeman", terms: onlyGemini),
            "請看 \(longSentence)，然後 Gemini"
        )

        // 6) 工單舉例句逐字重現。
        XCTAssertEqual(
            LatinNameFixer.fix(
                "Please review the latest changes before tomorrow morning，然後打開 jeman",
                terms: onlyGemini
            ),
            "Please review the latest changes before tomorrow morning，然後打開 Gemini"
        )
    }
}
