import XCTest
@testable import UTUVOTypeCore

/// 2026-09-11 實測：訂閱制 key 打 dashscope 一律 401，換 token-plan 網域後 formatter 200、
/// ASR WebSocket 握手 101。這組常數就是那次實測的結論，別手改。
final class BailianEndpointPresetTests: XCTestCase {

    func testPayAsYouGoUsesDashscope() {
        XCTAssertTrue(BailianEndpointPreset.payAsYouGo.formatter.contains("dashscope.aliyuncs.com"))
        XCTAssertTrue(BailianEndpointPreset.payAsYouGo.asr.hasPrefix("wss://"))
    }

    func testSubscriptionUsesTokenPlanHost() {
        XCTAssertTrue(BailianEndpointPreset.tokenPlan.formatter.contains("token-plan.cn-beijing.maas.aliyuncs.com"))
        XCTAssertTrue(BailianEndpointPreset.tokenPlan.asr.contains("token-plan.cn-beijing.maas.aliyuncs.com"))
    }

    func testBothPresetsKeepTheCompatibleModePath() {
        for preset in [BailianEndpointPreset.payAsYouGo, .tokenPlan] {
            XCTAssertTrue(preset.formatter.hasSuffix("/compatible-mode/v1/chat/completions"),
                          "formatter 必須是 OpenAI 相容路徑，BailianFormatterClient 只會這個格式")
            XCTAssertTrue(preset.asr.hasSuffix("/api-ws/v1/inference"))
        }
    }

    func testFormatterEndpointsUseHTTPSAndASRUsesWSS() {
        for preset in [BailianEndpointPreset.payAsYouGo, .tokenPlan] {
            XCTAssertTrue(preset.formatter.hasPrefix("https://"), "client 會拒絕非 https")
            XCTAssertTrue(preset.asr.hasPrefix("wss://"))
        }
    }

    func testKindDetection() {
        XCTAssertEqual(BailianEndpointPreset.kind(forFormatterEndpoint: BailianEndpointPreset.tokenPlan.formatter), "subscription")
        XCTAssertEqual(BailianEndpointPreset.kind(forFormatterEndpoint: BailianEndpointPreset.payAsYouGo.formatter), "pay-as-you-go")
        XCTAssertEqual(BailianEndpointPreset.kind(forFormatterEndpoint: "https://example.com/v1/chat"), "custom")
    }

    func testTwoPresetsAreDifferent() {
        XCTAssertNotEqual(BailianEndpointPreset.payAsYouGo, BailianEndpointPreset.tokenPlan)
    }
}
