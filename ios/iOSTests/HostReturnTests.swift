import XCTest
@testable import UTUVOTypeiOS

/// 自動跳回：PID 對照表「可以沒答案、不能答錯」的規則，以及 scheme 表。
final class HostReturnTests: XCTestCase {

    func testResolvesOnlyWithinCurrentAppearance() {
        var table = HostPidTable()
        table.noteAppearance()
        table.record(bundleId: "jp.naver.line", forPid: 501)
        XCTAssertEqual(table.bundleId(forPid: 501), "jp.naver.line")
        // 換 app → 鍵盤重新出現：舊證據退役
        table.noteAppearance()
        XCTAssertNil(table.bundleId(forPid: 501), "上一次出現記到的不能拿來答")
        XCTAssertTrue(table.hasEverSeen(pid: 501))
        XCTAssertEqual(table.trustedCount, 0)
    }

    /// PID 被回收：同一個 PID 換成別的 app，新的直接取代。
    func testRecycledPidIsOverwritten() {
        var table = HostPidTable()
        table.record(bundleId: "com.apple.mobilenotes", forPid: 44177)
        table.record(bundleId: "com.apple.MobileSMS", forPid: 44177)
        XCTAssertEqual(table.bundleId(forPid: 44177), "com.apple.MobileSMS")
        XCTAssertEqual(table.count, 1)
    }

    func testIgnoresEmptyAndInvalid() {
        var table = HostPidTable()
        table.record(bundleId: "", forPid: 10)
        table.record(bundleId: "com.x.y", forPid: 0)
        table.record(bundleId: "com.x.y", forPid: -3)
        XCTAssertEqual(table.count, 0)
        XCTAssertNil(table.bundleId(forPid: 999), "沒看過的 PID 沒答案")
    }

    func testBoundedAtMaxEntriesOldestEvicted() {
        var table = HostPidTable()
        for pid in 1...(HostPidTable.maxEntries + 5) {
            table.record(bundleId: "com.app.\(pid)", forPid: pid)
        }
        XCTAssertEqual(table.count, HostPidTable.maxEntries)
        XCTAssertNil(table.bundleId(forPid: 1), "最舊的先淘汰")
        XCTAssertEqual(table.bundleId(forPid: HostPidTable.maxEntries + 5), "com.app.\(HostPidTable.maxEntries + 5)")
    }

    func testKnownSchemes() {
        XCTAssertEqual(KnownAppSchemes.returnURL(forHostId: "com.apple.MobileSMS")?.absoluteString, "ichat://", "訊息用 ichat:// 不是 sms://")
        XCTAssertEqual(KnownAppSchemes.returnURL(forHostId: "jp.naver.line")?.absoluteString, "line://")
        XCTAssertNil(KnownAppSchemes.returnURL(forHostId: "com.apple.mobilesafari"), "Safari 沒有可用 scheme，走 LSApplicationWorkspace")
        XCTAssertTrue(KnownAppSchemes.knownNoSchemeHosts.contains("com.utuvo.type.ios"))
        for (id, scheme) in KnownAppSchemes.schemesByBundleId {
            XCTAssertNotNil(URL(string: scheme), "\(id) 的 scheme 不是合法 URL")
        }
    }
}
