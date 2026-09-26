import XCTest
@testable import UTUVOTypeiOS

/// 打字手感的設定與判斷（震動本身只能 Micky 手指去感覺）。
final class KeyFeedbackTests: XCTestCase {
    override func tearDown() {
        KeyFeedback.defaults.removeObject(forKey: KeyFeedback.strengthKey)
        KeyFeedback.defaults.removeObject(forKey: KeyFeedback.soundKey)
        super.tearDown()
    }

    func testDefaultsAreMediumAndSoundOn() {
        KeyFeedback.defaults.removeObject(forKey: KeyFeedback.strengthKey)
        KeyFeedback.defaults.removeObject(forKey: KeyFeedback.soundKey)
        XCTAssertEqual(KeyFeedback.strength, .medium)
        XCTAssertTrue(KeyFeedback.soundEnabled)
    }

    func testStrengthRoundTripAndIntensityOrder() {
        KeyFeedback.strength = .strong
        XCTAssertEqual(KeyFeedback.strength, .strong)
        KeyFeedback.strength = .off
        XCTAssertEqual(KeyFeedback.strength, .off)
        XCTAssertEqual(KeyFeedback.Strength.off.intensity, 0)
        XCTAssertLessThan(KeyFeedback.Strength.light.intensity, KeyFeedback.Strength.medium.intensity)
        XCTAssertLessThan(KeyFeedback.Strength.medium.intensity, KeyFeedback.Strength.strong.intensity)
    }

    /// 沒開「允許完整存取」時系統會靜默忽略震動——不要假裝有。
    func testNoHapticWithoutFullAccessOrWhenOff() {
        XCTAssertFalse(KeyFeedback.wantsHaptic(strength: .strong, hasFullAccess: false))
        XCTAssertFalse(KeyFeedback.wantsHaptic(strength: .off, hasFullAccess: true))
        XCTAssertTrue(KeyFeedback.wantsHaptic(strength: .light, hasFullAccess: true))
    }

    /// 功能鍵比一般鍵重、連續刪除最輕，而且都不超過 1.0。
    func testKindWeights() {
        let s = KeyFeedback.Strength.strong.intensity
        XCTAssertGreaterThan(KeyFeedback.Kind.special.multiplier, KeyFeedback.Kind.character.multiplier)
        XCTAssertLessThan(KeyFeedback.Kind.repeatTick.multiplier, KeyFeedback.Kind.character.multiplier)
        XCTAssertLessThanOrEqual(min(1.0, s * KeyFeedback.Kind.special.multiplier), 1.0)
    }
}
