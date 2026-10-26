import XCTest
@testable import UTUVOTypeiOS
import UTUVOTypeCore

@MainActor
final class CleanupLatencyTests: XCTestCase {
    func testSuccessfulClaudeDoesNotResolveLocalModelAvailability() async {
        let state = CleanupFixtureState()
        let localModel: @Sendable () -> SmartCleanup.OnDeviceCompletion? = {
            state.fallback()
            return { _, _ in Self.input }
        }
        let result = await SmartCleanup.finalize(Self.input, language: "zh-TW",
            configuration: { Self.config(.claude) }, terms: { _ in [] },
            transport: { request in state.request(request); return Self.response(request) },
            onDevice: localModel(), log: { _, _, _, _ in })
        XCTAssertEqual(result, Self.output)
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(state.fallbacks, 0, "A healthy cloud request must not query Apple/Gemma readiness")
    }

    func testFailedClaudeResolvesLocalModelOnceAndKeepsFallback() async {
        let state = CleanupFixtureState()
        let localModel: @Sendable () -> SmartCleanup.OnDeviceCompletion? = {
            state.fallback()
            return { _, _ in "我們明天下午三點開會。" }
        }
        let result = await SmartCleanup.finalize(Self.input, language: "zh-TW",
            configuration: { Self.config(.claude) }, terms: { _ in [] },
            transport: { request in state.request(request); return Self.response(request, code: 503) },
            onDevice: localModel(), log: { outcome, _, _, _ in state.log(outcome) })
        XCTAssertEqual(result, Self.output)
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(state.fallbacks, 1)
        XCTAssertEqual(state.logs, ["http(503)", "local:candidate"])
    }

    func testDirectCloudCleanAlsoSkipsLocalAvailability() async {
        let state = CleanupFixtureState()
        let localModel: @Sendable () -> SmartCleanup.OnDeviceCompletion? = {
            state.fallback()
            return nil
        }
        let result = await SmartCleanup.clean(Self.input, language: "zh-TW",
            configuration: { Self.config(.claude) }, terms: { _ in [] },
            transport: { Self.response($0) }, onDevice: localModel(), log: { _, _, _, _ in })
        XCTAssertEqual(result, Self.output)
        XCTAssertEqual(state.fallbacks, 0)
    }

    private nonisolated static let input = "我們明天下午三點開會"
    /// 模型回「三點」；輸出與先貼出的本機版同一套數字格式（2026-09-24 起整理結果也過 normalizeNumbers）。
    private nonisolated static let output = "我們明天下午3:00開會。"
    private nonisolated static func config(_ provider: SmartCleanup.Provider = .gemini) -> SmartCleanup.Configuration {
        .init(enabled: true, provider: provider, endpoint: "https://synthetic.invalid/cleanup", model: "fixture-model", key: "fixture-key")
    }
    private nonisolated static func response(_ request: URLRequest, code: Int = 200) -> (Data, URLResponse) {
        let data = Data(#"{"choices":[{"message":{"content":"我們明天下午三點開會。"}}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
    private nonisolated static func ignoreCancellation(_ milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { continuation.resume() }
        }
    }

    func testGroqCorrectionIsFinalizedBeforeDelivery() async {
        let raw = "我昨天是要四點不對不對三點出發"
        let result = await SmartCleanup.finalize(raw, language: "zh-TW", configuration: { Self.config(.groq) },
            terms: { _ in [] }, transport: { request in
                let data = Data(#"{"choices":[{"message":{"content":"我昨天是要三點出發"}}]}"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, onDevice: { _, _ in XCTFail("Successful Groq must not fall back"); return raw }, log: { _, _, _, _ in })
        XCTAssertEqual(result, "我昨天是要3:00出發")
    }

    func testCloudTimeoutStillGetsIndependentFullLocalPolish() async {
        let result = await SmartCleanup.finalize(Self.input, language: "zh-TW", configuration: { Self.config(.groq) },
            terms: { _ in [] }, transport: { request in
                await Self.ignoreCancellation(100)
                return Self.response(request)
            }, onDevice: { _, _ in "我們明天下午三點開會。" }, log: { _, _, _, _ in }, cloudTimeout: 0.02)
        XCTAssertEqual(result, Self.output)
    }

    func testForcedLocalNeverUsesCloudEvenWithStoredCredential() async {
        let result = await SmartCleanup.finalize(Self.input, language: "zh-TW", forceLocal: true,
            configuration: { Self.config(.groq) }, terms: { _ in [] },
            transport: { _ in XCTFail("Local mode must not transmit text"); throw CancellationError() },
            onDevice: { _, _ in "我們明天下午三點開會。" }, log: { _, _, _, _ in })
        XCTAssertEqual(result, Self.output)
    }

    func testUnavailableLocalPreservesRawAndLogsFallback() async {
        let state = CleanupFixtureState()
        let result = await SmartCleanup.finalize(Self.input, language: "zh-TW", forceLocal: true,
            configuration: { Self.config() }, terms: { _ in [] },
            transport: { _ in XCTFail("Local mode must not transmit text"); throw CancellationError() },
            onDevice: nil, log: { outcome, _, _, _ in state.log(outcome) })
        XCTAssertEqual(result, Self.input)
        XCTAssertEqual(state.logs, ["raw-fallback"])
    }

    func testCancelledFinalizeDoesNotDeliverOrStartLocalFallback() async {
        let state = CleanupFixtureState()
        let task = Task {
            await SmartCleanup.finalize(Self.input, language: "zh-TW", configuration: { Self.config() },
                terms: { _ in [] }, transport: { request in
                    state.request(request)
                    await Self.ignoreCancellation(150)
                    return Self.response(request)
                }, onDevice: { _, _ in state.fallback(); return Self.input }, log: { _, _, _, _ in })
        }
        while state.requests.isEmpty { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(state.fallbacks, 0)
    }

    func testCandidatesAreNotCountedAsDelivered() {
        let summary = SmartLog.summary([["outcome": "candidate"], ["outcome": "local:candidate"], ["outcome": "delivered"]])
        XCTAssertEqual(summary.ok, 1)
        XCTAssertEqual(summary.failed, 0)
    }

    func testSuccessPreservesProviderModelPromptAndOutput() async throws {
        let state = CleanupFixtureState()
        let result = await SmartCleanup.clean(Self.input, language: "zh-TW", configuration: { Self.config(.groq) }, terms: { _ in state.hint(); return ["合成專名"] }, transport: { request in
            state.request(request)
            return Self.response(request)
        }, normalize: { text, _ in text }, log: { outcome, _, _, _ in state.log(outcome) })
        XCTAssertEqual(result, Self.output)
        XCTAssertEqual(state.hints, 1)
        XCTAssertEqual(state.requests.count, 1)
        let request = try XCTUnwrap(state.requests.first)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "fixture-model")
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let messages = body["messages"] as! [[String: String]]
        // 指示＝v3 原文套上「自動條列」設定（2026-10-19，預設開）。
        XCTAssertEqual(messages[0]["content"], CleanupPromptRules.apply(SmartCleanup.instructions, autoList: SmartCleanup.autoListEnabled) + "\n這位使用者常用的專有名詞（逐字稿裡聽起來像的，就改成這個寫法）：合成專名")
        XCTAssertEqual(state.logs, ["candidate"])
    }

    func testSlowPreprocessingConsumesWholeBudgetWithoutRequest() async {
        let state = CleanupFixtureState(), start = ContinuousClock.now
        let result = await SmartCleanup.clean(Self.input, language: "zh-TW", timeout: 0.08, configuration: { Self.config() }, terms: { _ in
            await Self.ignoreCancellation(200); return ["合成"]
        }, transport: { request in state.request(request); return Self.response(request) }, normalize: { text, _ in text }, log: { outcome, _, _, _ in state.log(outcome) })
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(170))
        await Self.ignoreCancellation(230)
        XCTAssertEqual(state.requests.count, 0)
        XCTAssertEqual(state.logs.count, 1, "Late preparation must not append another log")
    }

    func testHTTP503ReturnsPromptlyWithoutBusyRetry() async {
        let state = CleanupFixtureState(), start = ContinuousClock.now
        let result = await SmartCleanup.clean(Self.input, language: "zh-TW",
            configuration: { Self.config() }, terms: { _ in state.hint(); return [] },
            transport: { request in
                state.request(request)
                return Self.response(request, code: 503)
            }, normalize: { text, _ in text }, log: { outcome, _, _, _ in state.log(outcome) })
        XCTAssertNil(result)
        XCTAssertEqual(state.requests.count, 1, "Background cleanup must not retry a busy provider")
        XCTAssertEqual(state.hints, 1)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
        XCTAssertEqual(state.logs, ["http(503)"])
    }

    func testHTTP400ResendUsesRemainingBudgetAndOneHintBuild() async {
        let state = CleanupFixtureState(), start = ContinuousClock.now
        let result = await SmartCleanup.clean(Self.input, language: "zh-TW", timeout: 0.15, configuration: { Self.config() }, terms: { _ in state.hint(); return ["合成"] }, transport: { request in
            let number = state.request(request)
            await Self.ignoreCancellation(number == 1 ? 60 : 240)
            return Self.response(request, code: number == 1 ? 400 : 200)
        }, normalize: { text, _ in text }, log: { _, _, _, _ in })
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(240))
        XCTAssertEqual(state.hints, 1)
        XCTAssertEqual(state.requests.count, 2)
        if state.requests.count == 2 {
            XCTAssertLessThan(state.requests[1].timeoutInterval, state.requests[0].timeoutInterval - 0.03)
            let second = try? JSONSerialization.jsonObject(with: state.requests[1].httpBody!) as? [String: Any]
            XCTAssertNil(second?["reasoning_effort"])
        }
        await Self.ignoreCancellation(260)
    }

    func testParentCancellationReturnsWithoutLateLogOrFallback() async {
        let state = CleanupFixtureState()
        let task = Task {
            await SmartCleanup.finalize(Self.input, language: "zh-TW", configuration: { Self.config() },
                terms: { _ in [] }, transport: { request in
                    state.request(request); await Self.ignoreCancellation(250); return Self.response(request)
                }, onDevice: { _, _ in state.fallback(); return Self.input },
                log: { outcome, _, _, _ in state.log(outcome) })
        }
        while state.requests.isEmpty { await Task.yield() }
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        await Self.ignoreCancellation(300)
        XCTAssertTrue(state.logs.isEmpty)
        XCTAssertEqual(state.fallbacks, 0)
    }

    func testLocalTimeoutReturnsRawOnceWithinItsOwnBudget() async {
        let state = CleanupFixtureState(), start = ContinuousClock.now
        let result = await SmartCleanup.finalize(Self.input, language: "zh-TW", forceLocal: true,
            configuration: { Self.config() }, terms: { _ in [] },
            transport: { _ in XCTFail("Local attempt must not use transport"); throw CancellationError() },
            onDevice: { _, _ in await Self.ignoreCancellation(200); return Self.input },
            log: { outcome, _, _, _ in state.log(outcome) }, localTimeout: 0.08)
        XCTAssertEqual(result, Self.input)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(180))
        await Self.ignoreCancellation(220)
        XCTAssertEqual(state.logs, ["local:timeout", "raw-fallback"])
    }

    func testSameSessionSegmentsPublishButCanceledGenerationCannotReuseIdenticalText() async {
        let owner = CleanupTaskOwner()
        var published: [String] = []
        for delay in [20, 40] {
            owner.start(id: UUID(), work: { await Self.ignoreCancellation(delay); return "segment-\(delay)" }, apply: { if let value = $0 { published.append(value) } })
        }
        await Self.ignoreCancellation(70)
        XCTAssertEqual(Set(published), ["segment-20", "segment-40"])
        let reusedID = UUID()
        owner.start(id: reusedID, work: { await Self.ignoreCancellation(100); return "identical-old" }, apply: { if let value = $0 { published.append(value) } })
        owner.cancelAll()
        owner.start(id: reusedID, work: { "identical-new" }, apply: { if let value = $0 { published.append(value) } })
        let canceledID = UUID()
        owner.start(id: canceledID, work: { await Self.ignoreCancellation(50); return "canceled" }, apply: { if let value = $0 { published.append(value) } })
        owner.cancel(id: canceledID)
        await Self.ignoreCancellation(140)
        XCTAssertEqual(published.filter { $0.hasPrefix("identical") }, ["identical-new"])
        XCTAssertFalse(published.contains("canceled"))
        XCTAssertEqual(owner.pendingCount, 0)
    }
}

private final class CleanupFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var hintCount = 0, fallbackCount = 0
    private var sent: [URLRequest] = [], outcomes: [String] = []
    var hints: Int { lock.withLock { hintCount } }
    var fallbacks: Int { lock.withLock { fallbackCount } }
    var requests: [URLRequest] { lock.withLock { sent } }
    var logs: [String] { lock.withLock { outcomes } }
    func hint() { lock.withLock { hintCount += 1 } }
    func fallback() { lock.withLock { fallbackCount += 1 } }
    @discardableResult func request(_ request: URLRequest) -> Int { lock.withLock { sent.append(request); return sent.count } }
    func log(_ outcome: String) { lock.withLock { outcomes.append(outcome) } }
}
