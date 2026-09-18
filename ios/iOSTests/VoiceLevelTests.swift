import XCTest
import AVFAudio
@testable import UTUVOTypeiOS

/// 光球的「聽感」：音量→能量的對應、平滑、跨程序音量通道。
final class VoiceLevelTests: XCTestCase {
    func testSilenceIsZeroAndSpeechIsHigh() {
        var n = VoiceLevel.Normalizer()
        // 安靜房間 2 秒：底噪 −58 dB，能量要是 0。
        var e: Float = 1
        for _ in 0..<100 { e = n.energy(dbfs: -58, dt: 0.02) }
        XCTAssertEqual(e, 0, accuracy: 0.001)
        // 正常講話 −28 dB：高出底噪 30 dB，能量要明顯（>0.6）。
        XCTAssertGreaterThan(n.energy(dbfs: -28, dt: 0.02), 0.6)
    }

    func testNoisyRoomDoesNotKeepOrbExcited() {
        var n = VoiceLevel.Normalizer()
        // 咖啡廳：底噪 −38 dB 持續 20 秒後，底噪要追上來，能量回到接近 0。
        var e: Float = 1
        for _ in 0..<1000 { e = n.energy(dbfs: -38, dt: 0.02) }
        XCTAssertLessThan(e, 0.05)
        // 在那個環境講話（−18 dB）仍然要有反應。
        XCTAssertGreaterThan(n.energy(dbfs: -18, dt: 0.02), 0.4)
    }

    func testSpeechDoesNotBecomeTheFloor() {
        var n = VoiceLevel.Normalizer()
        for _ in 0..<50 { _ = n.energy(dbfs: -60, dt: 0.02) }
        // 連講 3 秒：底噪往上爬很慢，能量不能掉到一半以下。
        var e: Float = 0
        for _ in 0..<150 { e = n.energy(dbfs: -28, dt: 0.02) }
        XCTAssertGreaterThan(e, 0.4)
    }

    func testGarbageInputIsSafe() {
        var n = VoiceLevel.Normalizer()
        for v in [Float.nan, -.infinity, .infinity, -500, 50] {
            let e = n.energy(dbfs: v, dt: 0.02)
            XCTAssertTrue(e.isFinite && e >= 0 && e <= 1, "\(v) → \(e)")
        }
    }

    func testSmoothingAttackFasterThanRelease() {
        let up = VoiceLevel.smooth(0, toward: 1, dt: 0.05)
        let down = VoiceLevel.smooth(1, toward: 0, dt: 0.05)
        XCTAssertGreaterThan(up, 1 - down, "起音要比收尾快")
        XCTAssertEqual(VoiceLevel.smooth(0.3, toward: 0.3, dt: 0.05), 0.3, accuracy: 1e-6)
    }

    func testChannelRoundTripAndStaleness() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try XCTUnwrap(VoiceLevelChannel(directory: dir, writable: true))
        let reader = try XCTUnwrap(VoiceLevelChannel(directory: dir, writable: false))
        writer.write(db: -24.5, at: 1000)
        XCTAssertEqual(try XCTUnwrap(reader.read(now: 1000.1)), -24.5, accuracy: 0.001)
        XCTAssertNil(reader.read(now: 1000 + VoiceLevelChannel.maxAge + 0.05), "太舊要回 nil")
        writer.clear()
        XCTAssertNil(reader.read(now: 1000.1), "停止錄音後鍵盤要立刻收")
    }

    func testReaderBeforeWriterExists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 鍵盤先出現、主 app 還沒錄過：讀端不能當掉，之後檔案出現要讀得到（每秒最多重開一次）。
        let reader = try XCTUnwrap(VoiceLevelChannel(directory: dir, writable: false))
        XCTAssertNil(reader.read(now: 10))
        let writer = try XCTUnwrap(VoiceLevelChannel(directory: dir, writable: true))
        writer.write(db: -30, at: 12)
        XCTAssertEqual(try XCTUnwrap(reader.read(now: 12.1)), -30, accuracy: 0.001)
    }

    func testLevelLogFeedsLatestAndSink() throws {
        let log = LevelLog()
        XCTAssertNil(log.latest(), "還沒錄＝沒有音量")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.3) }
        log.record(buffer)
        // 0.1 振幅正弦的 RMS ≈ 0.0707 → ≈ −23 dBFS
        XCTAssertEqual(try XCTUnwrap(log.latest()), -23, accuracy: 0.5)
    }

    func testSyntheticVoiceHasSpeechAndPauses() {
        let samples = stride(from: 0.0, to: 8.4, by: 1.0 / 60).map { OrbView.syntheticEnergy($0) }
        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(samples.max()!, 0.8)
        XCTAssertGreaterThan(samples.filter { $0 == 0 }.count, 60, "要有句間停頓")
    }
}
