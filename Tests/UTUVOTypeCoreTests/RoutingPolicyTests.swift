import XCTest
@testable import UTUVOTypeCore

final class RoutingPolicyTests: XCTestCase {

    // MARK: - isShortSentence 基礎

    func testShortSentenceDetection() {
        let inp = RoutingInput(
            text: "你好嗎",
            mode: .smart,
            hasListCues: false,
            hasSelfCorrection: false,
            hasMarkdown: false
        )
        XCTAssertTrue(Router.isShortSentence(inp))
    }

    func testShortSentenceTooLong() {
        let inp = RoutingInput(
            text: "你好嗎我今天天氣不錯想去走走",
            mode: .smart
        )
        XCTAssertFalse(Router.isShortSentence(inp))
    }

    func testShortSentenceHasListCue() {
        let inp = RoutingInput(
            text: "第一買牛奶",
            mode: .smart,
            hasListCues: true
        )
        XCTAssertFalse(Router.isShortSentence(inp))
    }

    func testShortSentenceHasSelfCorrection() {
        let inp = RoutingInput(
            text: "不是A是B",
            mode: .smart,
            hasSelfCorrection: true
        )
        XCTAssertFalse(Router.isShortSentence(inp))
    }

    func testShortSentenceHasMarkdown() {
        let inp = RoutingInput(
            text: "## 標題",
            mode: .smart,
            hasMarkdown: true
        )
        XCTAssertFalse(Router.isShortSentence(inp))
    }

    // MARK: - 短句禁大模型（核心承諾）

    func testShortSentenceSmartNeverAllowsLargeModel() {
        let inp = RoutingInput(
            text: "我今天很累",
            mode: .smart
        )
        let decision = Router.decide(inp)
        XCTAssertFalse(decision.allowedLargeModel)
        // primaryModel 必須是 flash，不該是 plus／max
        XCTAssertNotNil(decision.primaryModel)
        XCTAssertEqual(decision.primaryModel, .flash37)
    }

    func testShortSentenceEditSelectionNeverAllowsLargeModel() {
        let inp = RoutingInput(
            text: "改一下",
            mode: .editSelection,
            hasSelectedBlock: true
        )
        let decision = Router.decide(inp)
        XCTAssertFalse(decision.allowedLargeModel)
        XCTAssertEqual(decision.primaryModel, .flash37)
    }

    func testShortSentenceFastSkipsLLM() {
        let inp = RoutingInput(
            text: "我到了",
            mode: .fast
        )
        let decision = Router.decide(inp)
        XCTAssertTrue(decision.skipLLM)
        XCTAssertNil(decision.primaryModel)
        XCTAssertFalse(decision.allowedLargeModel)
    }

    func testLongTextFastStillSkipsLLM() {
        let inp = RoutingInput(
            text: String(repeating: "這是一段較長的普通聽寫內容。", count: 20),
            mode: .fast
        )
        let decision = Router.decide(inp)
        XCTAssertTrue(decision.skipLLM)
        XCTAssertNil(decision.primaryModel)
        XCTAssertTrue(decision.fallbackChain.isEmpty)
        XCTAssertFalse(decision.allowedLargeModel)
    }

    func testSmartLongThresholdAllowsPlusOnlyWhenOptedIn() {
        let longText = String(repeating: "這是一段長文。", count: 60)
        let withoutThreshold = Router.decide(RoutingInput(text: longText, mode: .smart))
        XCTAssertEqual(withoutThreshold.primaryModel, .flash37)
        XCTAssertFalse(withoutThreshold.allowedLargeModel)

        let withThreshold = Router.decide(RoutingInput(
            text: longText,
            mode: .smart,
            longTextOptIn: true
        ))
        XCTAssertEqual(withThreshold.primaryModel, .plus37)
        XCTAssertTrue(withThreshold.allowedLargeModel)
    }

    // MARK: - Edit Selection：長 / 高品質才升 plus

    func testEditSelectionShortUsesFlash() {
        let inp = RoutingInput(
            text: "改這個字",
            mode: .editSelection,
            hasSelectedBlock: true
        )
        let decision = Router.decide(inp)
        XCTAssertEqual(decision.primaryModel, .flash37)
        XCTAssertFalse(decision.allowedLargeModel)
    }

    func testEditSelectionLongHighQualityUsesPlus() {
        let longText = String(repeating: "這是一段被選取的內容。", count: 10) // > 80 chars
        let inp = RoutingInput(
            text: longText,
            mode: .editSelection,
            hasSelectedBlock: true,
            highQuality: true
        )
        let decision = Router.decide(inp)
        XCTAssertEqual(decision.primaryModel, .plus37)
        XCTAssertTrue(decision.allowedLargeModel)
    }

    func testEditSelectionLongWithoutHighQualityStaysOnFlash() {
        let longText = String(repeating: "這是一段被選取的內容。", count: 10)
        let inp = RoutingInput(
            text: longText,
            mode: .editSelection,
            hasSelectedBlock: true,
            highQuality: false
        )
        let decision = Router.decide(inp)
        XCTAssertEqual(decision.primaryModel, .flash37)
        XCTAssertFalse(decision.allowedLargeModel)
    }

    func testEditSelectionLongThresholdAllowsPlus() {
        let longText = String(repeating: "這是一段被選取的內容。", count: 10)
        let decision = Router.decide(RoutingInput(
            text: longText,
            mode: .editSelection,
            hasSelectedBlock: true,
            longTextOptIn: true
        ))
        XCTAssertEqual(decision.primaryModel, .plus37)
        XCTAssertTrue(decision.allowedLargeModel)
    }

    // MARK: - Deep mode：opt-in 才允許 plus / 27B

    func testDeepWithoutOptInDowngradesToSmart() {
        let inp = RoutingInput(
            text: String(repeating: "開會內容。", count: 50),
            mode: .deep,
            deepOptIn: false
        )
        let decision = Router.decide(inp)
        XCTAssertEqual(decision.primaryModel, .flash37)
        XCTAssertFalse(decision.allowedLargeModel)
        XCTAssertFalse(decision.useLocalDeep)
    }

    func testDeepWithOptInUsesPlus() {
        let inp = RoutingInput(
            text: String(repeating: "開會內容。", count: 50),
            mode: .deep,
            deepOptIn: true,
            localDeepAvailable: false
        )
        let decision = Router.decide(inp)
        XCTAssertEqual(decision.primaryModel, .plus37)
        XCTAssertTrue(decision.allowedLargeModel)
        XCTAssertFalse(decision.useLocalDeep)
    }

    func testDeepWithOptInAndLocalAvailableUsesLocalDeep() {
        let inp = RoutingInput(
            text: String(repeating: "開會內容。", count: 50),
            mode: .deep,
            deepOptIn: true,
            localDeepAvailable: true
        )
        let decision = Router.decide(inp)
        XCTAssertTrue(decision.useLocalDeep)
        // 本機路徑 primaryModel 可以是 nil（不走雲端）
        XCTAssertNil(decision.primaryModel)
    }

    // MARK: - Fallback chain

    func testStandardFallbackChainExcludesPlusAndMax() {
        let chain = BailianModel.standardFallbackChain
        XCTAssertFalse(chain.contains(.plus37))
        XCTAssertFalse(chain.contains(.max37))
        XCTAssertEqual(chain.first, .flash37)
    }

    func testEditSelectionHighQualityFallbackStartsFromFlash() {
        let inp = RoutingInput(
            text: String(repeating: "這是一段被選取的內容。", count: 10),
            mode: .editSelection,
            hasSelectedBlock: true,
            highQuality: true
        )
        let decision = Router.decide(inp)
        XCTAssertEqual(decision.fallbackChain.first, .flash37)
    }

    // MARK: - InputFeatures

    func testHasListCues() {
        XCTAssertTrue(InputFeatures.hasListCues("首先"))
        XCTAssertTrue(InputFeatures.hasListCues("接下來"))
        XCTAssertTrue(InputFeatures.hasListCues("第一買牛奶"))
        XCTAssertFalse(InputFeatures.hasListCues("今天天氣不錯"))
    }

    func testHasSelfCorrection() {
        XCTAssertTrue(InputFeatures.hasSelfCorrection("不是A是B"))
        XCTAssertTrue(InputFeatures.hasSelfCorrection("這個不對"))
        XCTAssertTrue(InputFeatures.hasSelfCorrection("改成這樣"))
        XCTAssertFalse(InputFeatures.hasSelfCorrection("今天是週一"))
    }

    func testHasMarkdown() {
        XCTAssertTrue(InputFeatures.hasMarkdown("# 標題"))
        XCTAssertTrue(InputFeatures.hasMarkdown("- 列表"))
        XCTAssertTrue(InputFeatures.hasMarkdown("**粗體**"))
        XCTAssertFalse(InputFeatures.hasMarkdown("普通文字"))
    }

    func testHasSelectedBlock() {
        XCTAssertTrue(InputFeatures.hasSelectedBlock("<selected>...</selected>"))
        XCTAssertFalse(InputFeatures.hasSelectedBlock("沒有 marker"))
    }
}
