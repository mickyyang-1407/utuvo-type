import XCTest
@testable import UTUVOTypeiOS

/// IOS2：辨識走本機還是雲端的決策，必須是明示的。
final class RecognitionRouteTests: XCTestCase {

    func testOnDeviceIsUsedWhenSupported() {
        XCTAssertEqual(
            RecognitionRoutePolicy.decide(supportsOnDevice: true, onDeviceOnly: false),
            .allow(.onDevice)
        )
    }

    func testOnDeviceOnlyStillUsesOnDeviceWhenSupported() {
        XCTAssertEqual(
            RecognitionRoutePolicy.decide(supportsOnDevice: true, onDeviceOnly: true),
            .allow(.onDevice)
        )
    }

    /// 預設行為：不支援就退回雲端——但這個決策必須是 `.server`，UI 據此顯示警示。
    func testFallsBackToServerWhenNotSupported() {
        let decision = RecognitionRoutePolicy.decide(supportsOnDevice: false, onDeviceOnly: false)
        XCTAssertEqual(decision, .allow(.server))
        XCTAssertTrue(RecognitionRoutePolicy.warnsUser(decision), "退回雲端一定要示警")
    }

    /// 開了「只用裝置端」就不准靜默上雲：直接擋下。
    func testOnDeviceOnlyBlocksServerFallback() {
        let decision = RecognitionRoutePolicy.decide(supportsOnDevice: false, onDeviceOnly: true)
        XCTAssertEqual(decision, .blockedOnDeviceUnavailable)
        XCTAssertTrue(RecognitionRoutePolicy.warnsUser(decision))
    }

    func testOnDeviceRouteNeverWarns() {
        XCTAssertFalse(RecognitionRoutePolicy.warnsUser(.allow(.onDevice)))
        XCTAssertTrue(RecognitionRoute.onDevice.isPrivate)
        XCTAssertFalse(RecognitionRoute.server.isPrivate)
    }

    func testBadgeTextDistinguishesTheTwoRoutes() {
        XCTAssertNotEqual(RecognitionRoute.onDevice.badgeText, RecognitionRoute.server.badgeText)
        XCTAssertTrue(RecognitionRoute.server.badgeText.contains("雲端"))
        XCTAssertTrue(RecognitionRoute.onDevice.badgeText.contains("不離機"))
    }
}
