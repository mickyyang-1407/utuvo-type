import XCTest
@testable import UTUVOTypeApp

/// AXReplacementGate 是 production AppModel 在套用 background cleanup 結果前唯一守門員。
/// 任何回歸（停用 CAS、放寬 prefix 比對）都會在這裡被抓到。
final class AXReplacementGateTests: XCTestCase {

    private func makeTicket(axIdentifier: String = "field-a",
                            insertedText: String = "我今天約禮拜五去開會",
                            insertedLocation: Int = 4,
                            context: String = "前面文字") -> AXInsertionTicket {
        return AXInsertionTicket(
            processIdentifier: 1234,
            bundleIdentifier: "com.utuvo.type.qa.synthetic-host",
            appName: "UTUVO Type Test Host",
            axIdentifier: axIdentifier,
            axRole: "AXTextArea",
            insertedUTF16Location: insertedLocation,
            insertedUTF16Length: insertedText.utf16.count,
            contextBeforePrefix: context,
            insertedText: insertedText,
            capturedAt: Date()
        )
    }

    private func liveSnapshot(rangeText: String = "我今天約禮拜五去開會",
                              contextBefore: String = "前面文字",
                              axIdentifier: String = "field-a",
                              pid: Int32 = 1234,
                              bundle: String = "com.utuvo.type.qa.synthetic-host") -> AXReplacementGate.LiveSnapshot {
        return AXReplacementGate.LiveSnapshot(
            processIdentifier: pid,
            bundleIdentifier: bundle,
            axIdentifier: axIdentifier,
            axRole: "AXTextArea",
            focused: true,
            rangeText: rangeText,
            contextBefore: contextBefore
        )
    }

    func testHappyPath() {
        let ticket = makeTicket()
        let verdict = AXReplacementGate.verdict(ticket: ticket, current: liveSnapshot())
        XCTAssertEqual(verdict, .ok)
    }

    func testProcessMismatchRejects() {
        let ticket = makeTicket()
        let verdict = AXReplacementGate.verdict(ticket: ticket, current: liveSnapshot(pid: 5678))
        XCTAssertEqual(verdict, .processMismatch(expected: 1234, actual: 5678))
    }

    func testBundleMismatchRejects() {
        let ticket = makeTicket()
        let verdict = AXReplacementGate.verdict(ticket: ticket,
                                                current: liveSnapshot(bundle: "com.example.other"))
        XCTAssertEqual(verdict, .bundleMismatch(expected: "com.utuvo.type.qa.synthetic-host",
                                                actual: "com.example.other"))
    }

    func testContentChangedRejects() {
        let ticket = makeTicket()
        let verdict = AXReplacementGate.verdict(ticket: ticket,
                                                current: liveSnapshot(rangeText: "我今天約禮拜三去開會"))
        XCTAssertEqual(verdict, .contentChanged(expected: "我今天約禮拜五去開會",
                                                actual: "我今天約禮拜三去開會"))
    }

    func testRangeLengthMismatchRejects() {
        let ticket = makeTicket()
        let verdict = AXReplacementGate.verdict(ticket: ticket,
                                                current: liveSnapshot(rangeText: "我今天約禮拜五"))
        XCTAssertEqual(verdict, .contentChanged(expected: "我今天約禮拜五去開會",
                                                actual: "我今天約禮拜五"))
    }

    func testContextDriftRejects() {
        let ticket = makeTicket(context: "前面文字")
        let verdict = AXReplacementGate.verdict(ticket: ticket,
                                                current: liveSnapshot(contextBefore: "完全不同的前綴"))
        XCTAssertEqual(verdict, .contextDrift(expected: "前面文字", actual: "完全不同的前綴"))
    }

    func testIdentifierMismatchOnReliableColumnRejects() {
        let ticket = makeTicket(axIdentifier: "field-a")
        let verdict = AXReplacementGate.verdict(ticket: ticket,
                                                current: liveSnapshot(axIdentifier: "field-b"))
        XCTAssertEqual(verdict, .identifierMismatch(expected: "field-a", actual: "field-b"))
    }

    func testCjkWithEmojiExactMatch() {
        // CJK + emoji UTF-16：插入瞬間與 live 兩邊都對得起來就算 ok。
        let ticket = AXInsertionTicket(
            processIdentifier: 1234,
            bundleIdentifier: "com.utuvo.type.qa.synthetic-host",
            appName: "UTUVO Type Test Host",
            axIdentifier: "field-a",
            axRole: "AXTextArea",
            insertedUTF16Location: 0,
            insertedUTF16Length: "合成測試🙂".utf16.count,
            contextBeforePrefix: "前面",
            insertedText: "合成測試🙂",
            capturedAt: Date()
        )
        let verdict = AXReplacementGate.verdict(ticket: ticket, current: liveSnapshot(
            rangeText: "合成測試🙂",
            contextBefore: "前面"
        ))
        XCTAssertEqual(verdict, .ok)
    }

    func testUnreliableIdentifierWithoutContextFails() {
        // 沒有 axIdentifier 也不可信（role 不是 text field）→ 直接擋掉；
        // 這層不做 CAS 冒險。
        let ticket = AXInsertionTicket(
            processIdentifier: 1234,
            bundleIdentifier: "com.utuvo.type.qa.synthetic-host",
            appName: "UTUVO Type Test Host",
            axIdentifier: "",
            axRole: "AXUnknown",
            insertedUTF16Location: 0,
            insertedUTF16Length: 4,
            contextBeforePrefix: "前面",
            insertedText: "abcd",
            capturedAt: Date()
        )
        let live = AXReplacementGate.LiveSnapshot(
            processIdentifier: 1234,
            bundleIdentifier: "com.utuvo.type.qa.synthetic-host",
            axIdentifier: "",
            axRole: "AXUnknown",
            focused: true,
            rangeText: "abcd",
            contextBefore: "前面"
        )
        // Similar text cannot substitute for a supported field identity.
        let verdict = AXReplacementGate.verdict(ticket: ticket, current: live)
        XCTAssertNotEqual(verdict, .ok)
    }
}