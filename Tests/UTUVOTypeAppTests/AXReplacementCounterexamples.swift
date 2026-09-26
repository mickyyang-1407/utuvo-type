import Foundation
import XCTest
@testable import UTUVOTypeApp

final class AXReplacementGateCounterexamples: XCTestCase {
    private func ticket(identifier: String = "field-a", location: Int = 16) -> AXInsertionTicket {
        AXInsertionTicket(
            processIdentifier: 42, bundleIdentifier: "test.synthetic.host", appName: "Synthetic Host",
            axIdentifier: identifier, axRole: "AXTextArea",
            insertedUTF16Location: location, insertedUTF16Length: 4,
            contextBeforePrefix: "", insertedText: "測試🙂", capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func snapshot(identifier: String = "field-a", focused: Bool = true) -> AXReplacementGate.LiveSnapshot {
        AXReplacementGate.LiveSnapshot(
            processIdentifier: 42, bundleIdentifier: "test.synthetic.host",
            axIdentifier: identifier, axRole: "AXTextArea", focused: focused,
            rangeText: "測試🙂", contextBefore: ""
        )
    }

    func testLostFocusMustRejectEvenWhenIdentifierAndTextStillMatch() {
        let verdict = AXReplacementGate.verdict(ticket: ticket(), current: snapshot(focused: false))
        XCTAssertNotEqual(verdict, .ok, "Same identifier/text cannot authorize writing after focus was lost")
    }

    func testMissingIdentifierAndNoContextMustRejectAmbiguousField() {
        let verdict = AXReplacementGate.verdict(ticket: ticket(identifier: ""), current: snapshot(identifier: ""))
        XCTAssertNotEqual(verdict, .ok, "Neither a field identity nor any context proof exists")
    }

    func testNegativeInsertionLocationMustRejectImpossibleRange() {
        let verdict = AXReplacementGate.verdict(ticket: ticket(location: -1), current: snapshot())
        XCTAssertNotEqual(verdict, .ok, "An impossible insertion range cannot be accepted merely because text matches")
    }

    func testPrefixBudgetCountsUTF16UnitsInsteadOfUnicodeScalars() {
        let input = String(repeating: "🙂", count: 200)
        let prefix = AXReplacementGate.prefix(from: input, maxUTF16: 256)
        XCTAssertLessThanOrEqual(prefix.utf16.count, 256, "200 emoji are 400 UTF-16 units, not 200")
        XCTAssertTrue(input.hasSuffix(prefix), "The bounded context should remain a suffix of the source")
    }

    func testControlMatchingContentPassesButSameLengthEditIsRejected() {
        XCTAssertEqual(AXReplacementGate.verdict(ticket: ticket(), current: snapshot()), .ok)
        var changed = snapshot()
        changed.rangeText = "改字🙂"
        XCTAssertEqual(changed.rangeText.utf16.count, ticket().insertedUTF16Length)
        XCTAssertNotEqual(AXReplacementGate.verdict(ticket: ticket(), current: changed), .ok)
    }
}
