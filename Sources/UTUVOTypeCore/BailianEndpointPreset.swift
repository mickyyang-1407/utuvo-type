import Foundation

/// 百鍊的兩種帳號用不同網域（2026-09-11 實測）。
///
/// - 按量付費（一般 DashScope API key）→ `dashscope.aliyuncs.com`
/// - 訂閱制（Agent Plan／Token Plan，key 較長）→ `token-plan.cn-beijing.maas.aliyuncs.com`
///
/// 拿訂閱制的 key 去打 dashscope 會拿到 **401**——看起來像 key 壞掉，其實是網域不對。
/// 這是 M2 從開案到 2026-09-11 都沒跑通的真正原因之一。
public struct BailianEndpointPreset: Sendable, Equatable {
    public let asr: String
    public let formatter: String

    public static let payAsYouGo = BailianEndpointPreset(
        asr: "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
        formatter: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    )

    /// 訂閱制。2026-09-11 實測：formatter HTTP 200、ASR WebSocket 握手 101。
    public static let tokenPlan = BailianEndpointPreset(
        asr: "wss://token-plan.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
        formatter: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
    )

    /// 這個 formatter 網址看起來是哪一種帳號的。
    public static func kind(forFormatterEndpoint endpoint: String) -> String {
        if endpoint.contains("token-plan") { return "subscription" }
        if endpoint.contains("dashscope") { return "pay-as-you-go" }
        return "custom"
    }
}
