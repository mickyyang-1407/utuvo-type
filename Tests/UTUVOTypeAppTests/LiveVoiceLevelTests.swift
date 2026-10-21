import XCTest
import AVFoundation
@testable import UTUVOTypeApp

/// 球的電平表。它不再自己掃 buffer——來源是 `AudioChannelActivity` 那一份黏性集合，
/// 跟 downmix、安靜偵測共用（mac-input-repair1 #3）。
final class LiveVoiceLevelTests: XCTestCase {
    func testPublishesTheSharedRmsAndClampsToMinusOneTwenty() {
        let meter = LiveVoiceLevel()
        meter.publish(rms: 0.5, now: 10)
        XCTAssertEqual(meter.read(now: 10)!, -6.0206, accuracy: 0.001)
        meter.publish(rms: 0, now: 10)
        XCTAssertEqual(meter.read(now: 10), -120, "靜音要是地板而不是 −∞")
        meter.publish(rms: 4, now: 10)
        XCTAssertEqual(meter.read(now: 10), 0, "不會超過 0 dBFS")
    }

    func testStaleFutureAndClearedSamplesDoNotKeepOrbExcited() {
        let meter = LiveVoiceLevel()
        meter.publish(rms: 0.5, now: 10)
        XCTAssertNotNil(meter.read(now: 10.3))
        XCTAssertNil(meter.read(now: 10.36))
        XCTAssertNil(meter.read(now: 9))
        XCTAssertNil(meter.read(now: .nan))
        meter.clear()
        XCTAssertNil(meter.read(now: 10))
    }

    func testNonFiniteRmsNeverReachesTheMeter() {
        let meter = LiveVoiceLevel()
        meter.publish(rms: .nan, now: 10)
        XCTAssertEqual(meter.read(now: 10), -120)
        meter.publish(rms: -.infinity, now: 10)
        XCTAssertEqual(meter.read(now: 10), -120)
    }

    /// 逐 buffer、非黏性的政策版本仍留在這裡當契約（只給測試與一次性檢查用）。
    func testActiveChannelRMSKeepsTheOriginalPolicy() {
        var ms = [Double](repeating: 0, count: 64), pk = [Double](repeating: 0, count: 64)
        ms[0] = 0.01; pk[0] = 0.3                           // 第 1 軌 RMS 0.1（−20 dBFS）
        XCTAssertEqual(LiveVoiceLevel.activeChannelRMS(meanSquares: ms, peaks: pk), 0.1, accuracy: 1e-9)
        // 舊做法（全軌平均）會掉到 0.1/8，低於自動結束門檻——這就是當初的問題。
        XCTAssertLessThan(sqrt(ms.reduce(0, +) / 64), 0.015)

        XCTAssertEqual(LiveVoiceLevel.activeChannelRMS(meanSquares: [0.25, 0], peaks: [0.5, 0]),
                       sqrt(0.125), accuracy: 1e-12)
        XCTAssertTrue(LiveVoiceLevel.activeChannelRMS(meanSquares: [], peaks: []) == 0)
        // 峰值 −61 dBFS 的軌不算有訊號（多軌才有防呆；≤2 軌照舊直接平均）。
        XCTAssertEqual(
            LiveVoiceLevel.activeChannelRMS(meanSquares: [1e-8, 0.01, 0, 0], peaks: [0.0009, 0.2, 0, 0]),
            0.1, accuracy: 1e-9
        )
        let pair = [1e-8, 0.01]
        XCTAssertEqual(LiveVoiceLevel.activeChannelRMS(meanSquares: pair, peaks: [0.0009, 0.2]),
                       sqrt(pair.reduce(0, +) / 2), accuracy: 1e-12, "2 軌以內維持原本的直接平均")
    }

    func testAdaptiveNormalizerAndReleaseStayBounded() {
        var normalizer = VoiceLevel.Normalizer()
        var quiet: Float = 0
        for _ in 0..<600 { quiet = normalizer.energy(dbfs: -55, dt: 1.0 / 30) }
        XCTAssertLessThan(quiet, 0.05)
        XCTAssertGreaterThan(normalizer.energy(dbfs: -20, dt: 1.0 / 30), 0.5)
        XCTAssertLessThan(VoiceLevel.smooth(1, toward: 0, dt: 0.3), 0.3)
    }
}
