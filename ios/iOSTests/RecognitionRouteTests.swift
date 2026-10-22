import XCTest
@testable import UTUVOTypeiOS

/// IOS2：辨識走本機還是雲端的決策，必須是明示的。
final class RecognitionRouteTests: XCTestCase {
    func testKeyboardCloudDoesNotRequireAppleAndLocalNeverUploads() {
        XCTAssertEqual(KeyboardRecognitionPlan.decide(mode: .cloud, localAvailable: false, cloudAvailable: true), .cloudOnly)
        XCTAssertEqual(KeyboardRecognitionPlan.decide(mode: .cloud, localAvailable: true, cloudAvailable: true), .cloudWithLocalFallback)
        XCTAssertEqual(KeyboardRecognitionPlan.decide(mode: .local, localAvailable: true, cloudAvailable: true), .local)
        XCTAssertEqual(KeyboardRecognitionPlan.decide(mode: .local, localAvailable: false, cloudAvailable: true), .unavailable)
        XCTAssertEqual(KeyboardRecognitionPlan.decide(mode: .cloud, localAvailable: true, cloudAvailable: false), .local)
    }

    func testMigrationPreservesPrivacyAndExistingGroqUsers() {
        XCTAssertEqual(DictationRouteSettings.migratedMode(localOnly: true, hasCloudKey: true, cloudASREnabled: true), .local)
        XCTAssertEqual(DictationRouteSettings.migratedMode(localOnly: false, hasCloudKey: true, cloudASREnabled: false), .cloud)
        XCTAssertEqual(DictationRouteSettings.migratedMode(localOnly: false, hasCloudKey: false, cloudASREnabled: false), .local)
    }


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

    func testExplicitCloudPreferenceUsesAppleServerWhenAllowed() {
        XCTAssertEqual(
            RecognitionRoutePolicy.decide(supportsOnDevice: true, onDeviceOnly: false, preferCloud: true),
            .allow(.server)
        )
    }

    func testOnDeviceOnlyOverridesCloudPreference() {
        XCTAssertEqual(
            RecognitionRoutePolicy.decide(supportsOnDevice: true, onDeviceOnly: true, preferCloud: true),
            .allow(.onDevice)
        )
        XCTAssertEqual(
            RecognitionRoutePolicy.decide(supportsOnDevice: false, onDeviceOnly: true, preferCloud: true),
            .blockedOnDeviceUnavailable
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
        // 驗的是「兩條路徑給不同的徽章」，不是徽章的字面。
        XCTAssertNotEqual(RecognitionRoute.onDevice.badgeText, RecognitionRoute.server.badgeText)
        assertLocalizedEquals("允許雲端辨識・音訊可能送到 Apple", RecognitionRoute.server.badgeText)
        assertLocalizedEquals("裝置端辨識・音訊不離機", RecognitionRoute.onDevice.badgeText)
    }
}
