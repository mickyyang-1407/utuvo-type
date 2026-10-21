import AVFoundation
import XCTest
@testable import UTUVOTypeApp

/// 「Average all channels」的防呆政策（2026-10-14；mac-input-repair1 #3 之後改成黏性）。
///
/// 政策核心在 `AudioChannelDownmix.averageMeanSquare`／`aboveThreshold`；
/// 黏性與 buffer 讀寫在 `AudioChannelActivityTests`。這裡守住「≤2 軌完全照舊」這條邊界。
final class AudioChannelDownmixTests: XCTestCase {
    func testManualDownmixOnlyAboveTwoChannels() {
        XCTAssertFalse(AudioChannelDownmix.needsManualDownmix(channelCount: 1))
        XCTAssertFalse(AudioChannelDownmix.needsManualDownmix(channelCount: 2))
        XCTAssertTrue(AudioChannelDownmix.needsManualDownmix(channelCount: 3))
    }

    /// `sticking == nil`（＝≤2 軌或沒指定黏性）→ 直接平均全部，行為與從前一樣。
    func testNilStickingAveragesEveryChannel() throws {
        XCTAssertEqual(
            try XCTUnwrap(AudioChannelDownmix.averageMeanSquare(meanSquares: [0.25, 0], sticking: nil)),
            0.125, accuracy: 1e-12
        )
        XCTAssertNil(AudioChannelDownmix.averageMeanSquare(meanSquares: [], sticking: nil))
    }

    func testEmptyStickingMaskFallsBackToPlainAverageSoSilenceStillReads() throws {
        // 整段都沒有聲道過門檻（＝真的安靜）時退回平均，不是回 nil：
        // 回 nil 會讓安靜偵測拿到 0 以外的行為，安靜自動結束就形同關閉。
        let meanSquares = [1e-10, 4e-10]
        XCTAssertEqual(
            try XCTUnwrap(AudioChannelDownmix.averageMeanSquare(
                meanSquares: meanSquares, sticking: [false, false]
            )),
            2.5e-10, accuracy: 1e-15
        )
    }

    func testMaskShorterThanMeanSquaresIsIgnoredNotReadOutOfBounds() throws {
        let result = try XCTUnwrap(
            AudioChannelDownmix.averageMeanSquare(meanSquares: [0.25, 0.25], sticking: [true])
        )
        XCTAssertEqual(result, 0.25, accuracy: 1e-12)
    }

    func testAboveThresholdMarksOnlyChannelsOverMinusSixtyDBFS() {
        let mask = AudioChannelDownmix.aboveThreshold(channels: 5, peaks: [0.0009, 0.0011, 0, 0, 1])
        XCTAssertEqual(mask, [false, true, false, false, true])
        XCTAssertEqual(AudioChannelDownmix.aboveThreshold(channels: 0, peaks: []).count, 0)
        // peaks 比 channels 短時不能越界。
        XCTAssertEqual(AudioChannelDownmix.aboveThreshold(channels: 3, peaks: [1]).count, 3)
    }

    func testSeveralLiveChannelsAreAveragedTogether() throws {
        let mask = AudioChannelDownmix.aboveThreshold(channels: 4, peaks: [0.5, 0.2, 0, 0])
        XCTAssertEqual(
            try XCTUnwrap(AudioChannelDownmix.averageMeanSquare(
                meanSquares: [0.04, 0.01, 0, 0], sticking: mask
            )),
            0.025, accuracy: 1e-12
        )
    }
}
