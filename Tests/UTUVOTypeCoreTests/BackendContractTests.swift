import XCTest
@testable import UTUVOTypeCore

final class BackendContractTests: XCTestCase {
    func testBailianASRDefaultsMatchProductDecision() {
        let config = BailianASRConfiguration()
        XCTAssertEqual(config.model, "qwen-audio-3.0-asr-flash-streaming")
        XCTAssertTrue(config.supportsPartialTranscript)
        XCTAssertEqual(config.protocolName, "websocket-or-official-realtime-protocol")
    }

    func testLocalASRDoesNotAutoDownload() {
        let config = LocalASRConfiguration()
        XCTAssertEqual(config.modelName, "Qwen3-ASR-0.6B")
        XCTAssertFalse(config.autoDownload)
    }

    func testContextIsBoundedDataOnly() {
        let context = LimitedAppContext(
            foregroundBundleIdentifier: "com.example.editor",
            appName: "Editor",
            focusedFieldRole: "text-field",
            selectedText: "一小段文字",
            surroundingText: "有限上下文"
        )
        XCTAssertFalse(context.promptSummary.contains("screenshot"))
        XCTAssertTrue(context.promptSummary.contains("bundle=com.example.editor"))
    }

    func testFallbackKeepsRawSeparatelyAndPastesUsableText() {
        let normalized = NormalizedText(
            original: "嗯我今天很累",
            cleaned: "我今天很累",
            appliedSteps: ["filler"]
        )
        let result = DeterministicFallback.resolve(normalized, error: .timeout)
        XCTAssertEqual(result.text, "我今天很累")
        XCTAssertEqual(result.rawTranscript, "嗯我今天很累")
        XCTAssertEqual(result.reason, "formatter timeout")
        XCTAssertFalse(result.text.contains("[raw]"))
    }
}
