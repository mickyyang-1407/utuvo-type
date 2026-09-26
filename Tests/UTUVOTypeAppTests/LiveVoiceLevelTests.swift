import XCTest
import AVFoundation
@testable import UTUVOTypeApp

final class LiveVoiceLevelTests: XCTestCase {
    private func buffer(interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buffer.frameLength = 64
        for channel in 0..<2 {
            for i in 0..<64 {
                buffer.floatChannelData![interleaved ? 0 : channel][interleaved ? i * 2 + channel : i] = channel == 0 ? 0.5 : 0
            }
        }
        return buffer
    }
    func testSelectedChannelUsesActualPCMWithoutChangingIt() {
        for interleaved in [false, true] {
            let input = buffer(interleaved: interleaved), meter = LiveVoiceLevel()
            meter.capture(input, selectedChannel: 0, now: 10)
            XCTAssertEqual(meter.read(now: 10)!, -6.0206, accuracy: 0.001)
            meter.capture(input, selectedChannel: 1, now: 10)
            XCTAssertEqual(meter.read(now: 10), -120)
            meter.capture(input, now: 10)
            XCTAssertEqual(meter.read(now: 10)!, -9.0309, accuracy: 0.001)
            XCTAssertEqual(input.floatChannelData![0][0], 0.5)
            XCTAssertEqual(input.frameLength, 64)
        }
    }
    func testStaleFutureAndClearedSamplesDoNotKeepOrbExcited() {
        let meter = LiveVoiceLevel()
        meter.capture(buffer(), now: 10)
        XCTAssertNotNil(meter.read(now: 10.3))
        XCTAssertNil(meter.read(now: 10.36))
        XCTAssertNil(meter.read(now: 9))
        XCTAssertNil(meter.read(now: .nan))
        meter.clear()
        XCTAssertNil(meter.read(now: 10))
    }
    func testInvalidPCMAndEmptyBuffersRemainFiniteOrSilent() {
        let input = buffer(), meter = LiveVoiceLevel()
        for i in 0..<64 { input.floatChannelData![0][i] = .nan }
        meter.capture(input, now: 10)
        XCTAssertEqual(meter.read(now: 10), -120)
        input.frameLength = 0
        meter.capture(input, now: 10)
        XCTAssertNil(meter.read(now: 10))
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
