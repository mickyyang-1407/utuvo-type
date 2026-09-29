import XCTest
@testable import UTUVOTypeiOS

/// 09-29 Micky：紫色光球（說出要怎麼改）每次都「失敗」。iOS 27.0 的 Apple Intelligence 回報可用，
/// 但每次生成都被系統的內容安全模型擋掉（SensitiveContentAnalysisML 15 → ModelManagerError 1001），
/// 舊碼沒有退路。這裡驗：裝置端失敗 → 用智慧整理的雲端 key；錯誤訊息說得出原因。
final class OnDeviceAssistantTests: XCTestCase {
    /// 跟真機／macOS 27 實測到的錯誤鏈同形。
    private func systemGuardrailError() -> NSError {
        let inner = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1001)
        let mid = NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15, userInfo: [NSUnderlyingErrorKey: inner])
        return NSError(domain: "FoundationModels.LanguageModelError", code: -1, userInfo: [NSMultipleUnderlyingErrorsKey: [mid]])
    }

    func testOnDeviceSuccessDoesNotTouchCloud() async throws {
        let out = try await OnDeviceAssistant.run(system: "s", user: "u",
                                                  onDevice: { _, _ in "改好了" },
                                                  cloud: { _, _ in XCTFail("不該走雲端"); return "x" })
        XCTAssertEqual(out, "改好了")
    }

    func testOnDeviceFailureFallsBackToCloud() async throws {
        let err = systemGuardrailError()
        let out = try await OnDeviceAssistant.run(system: "s", user: "原文",
                                                  onDevice: { _, _ in throw err },
                                                  cloud: { system, user in "雲端：\(user)" })
        XCTAssertEqual(out, "雲端：原文")
    }

    func testOnDeviceFailureWithoutCloudExplainsAndSuggestsKey() async {
        let err = systemGuardrailError()
        do {
            _ = try await OnDeviceAssistant.run(system: "s", user: "u", onDevice: { _, _ in throw err }, cloud: nil)
            XCTFail("應該丟錯")
        } catch {
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("Apple Intelligence 暫時不能用"), "要說出是 Apple Intelligence 壞了：\(msg)")
            XCTAssertTrue(msg.contains("Groq"), "要告訴使用者怎麼補：\(msg)")
            XCTAssertFalse(msg.contains("無法完成作業"), "不能再是空泛的系統訊息：\(msg)")
            // 顯示寬度：中文算 1、英數算 0.5。鍵盤提示兩行約 30 個中文字寬（模擬器截圖實測這句剛好兩行放完）。
            let width = msg.reduce(0.0) { $0 + ($1.isASCII ? 0.5 : 1.0) }
            XCTAssertLessThanOrEqual(width, 30, "鍵盤提示只有兩行，太長會把補救方法截掉（寬 \(width)）：\(msg)")
        }
    }

    func testBothFailReportsCloudReason() async {
        let err = systemGuardrailError()
        do {
            _ = try await OnDeviceAssistant.run(system: "s", user: "u",
                                                onDevice: { _, _ in throw err },
                                                cloud: { _, _ in throw SmartCleanup.Failure.http(429) })
            XCTFail("應該丟錯")
        } catch {
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("和雲端都失敗") && msg.contains("429"), msg)
        }
    }

    func testNothingConfigured() async {
        do {
            _ = try await OnDeviceAssistant.run(system: "s", user: "u", onDevice: nil, cloud: nil)
            XCTFail("應該丟錯")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("智慧整理"), error.localizedDescription)
        }
    }

    func testEmptyOnDeviceOutputFallsBack() async throws {
        let out = try await OnDeviceAssistant.run(system: "s", user: "u", onDevice: { _, _ in "" }, cloud: { _, _ in "ok" })
        XCTAssertEqual(out, "ok")
    }

    // MARK: - 雲端 client（假網路）

    func testCloudCompletionUsesProviderEndpointKeyAndModel() async throws {
        let seen = Captured()
        let out = try await SmartCleanup.complete(system: "SYS", user: "USER", provider: .groq, key: "fake-groq-key",
                                                  transport: { req in
            await seen.add(req)
            let json = #"{"choices":[{"message":{"content":"  正式版本  "}}]}"#
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(out, "正式版本")
        let reqs = await seen.all
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].url?.absoluteString, SmartCleanup.Provider.groq.endpoint)
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Authorization"), "Bearer fake-groq-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: reqs[0].httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, SmartCleanup.Provider.groq.defaultModel)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["content"] }, ["SYS", "USER"])
    }

    func testCloudCompletionRetriesWithoutExtraBodyOn400() async throws {
        let seen = Captured()
        let out = try await SmartCleanup.complete(system: "S", user: "U", provider: .gemini, key: "fake-gemini-key",
                                                  transport: { req in
            await seen.add(req)
            let first = await seen.all.count == 1
            let json = #"{"choices":[{"message":{"content":"ok"}}]}"#
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: first ? 400 : 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(out, "ok")
        let reqs = await seen.all
        XCTAssertEqual(reqs.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: reqs[1].httpBody ?? Data()) as? [String: Any])
        XCTAssertNil(second["reasoning_effort"], "400 之後重送要拿掉 extraBody")
    }

    func testCloudCompletionWithoutKeyThrows() async {
        do {
            _ = try await SmartCleanup.complete(system: "S", user: "U", provider: .groq, key: "")
            XCTFail("沒 key 要丟錯")
        } catch {
            XCTAssertEqual(error as? SmartCleanup.Failure, .notConfigured)
        }
    }
}

private actor Captured {
    var all: [URLRequest] = []
    func add(_ r: URLRequest) { all.append(r) }
}
