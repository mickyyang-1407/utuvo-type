import AVFoundation
import XCTest
@testable import UTUVOTypeApp

/// 「哪些聲道真的有訊號」這一份黏性集合（mac-input-repair1 #3）。
///
/// 這台機器的 SDK 造不出 >2 聲道的 `AVAudioPCMBuffer`，所以 64 軌的政策走
/// `measure(peaks:meanSquares:)` 這個純陣列入口；≤2 軌的 buffer 讀寫才真的走
/// `measure(_ buffer:)` 與 `mix`／`copy`。
final class AudioChannelActivityTests: XCTestCase {
    // MARK: - 64 軌政策（純陣列）

    func testOnlyOneActiveChannelOutOf64KeepsItsLevel() throws {
        let activity = AudioChannelActivity()
        var peaks = [Float](repeating: 0, count: 64)
        var meanSquares = [Double](repeating: 0, count: 64)
        peaks[0] = 1; meanSquares[0] = 0.5                      // 2026-10-14：人聲只在第 1 軌
        activity.measure(peaks: peaks, meanSquares: meanSquares)
        XCTAssertEqual(activity.averageRMS, sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(activity.downmixScale()), 1.0, "只有一軌有訊號時不能被除以 64")
        XCTAssertTrue(activity.isActive(0))
        XCTAssertFalse(activity.isActive(63))
    }

    func testNaiveAverageOver64SilentChannelsLoses36dB() {
        let activity = AudioChannelActivity()
        var peaks = [Float](repeating: 0, count: 64)
        var meanSquares = [Double](repeating: 0, count: 64)
        peaks[0] = 1; meanSquares[0] = 1
        activity.measure(peaks: peaks, meanSquares: meanSquares)
        let naive = 1 / 64.0     // 64 軌一般平均＝除以 64
        XCTAssertEqual(20 * log10(activity.averageRMS / naive), 36.12, accuracy: 0.01)
    }

    func testEveryActiveChannelStillAveragesNormally() throws {
        let activity = AudioChannelActivity()
        let peaks: [Float] = [1, 0.5, 0.25, 1, 1, 0.5, 1, 0.5]
        let meanSquares = peaks.map { Double($0 * $0) / 2 }
        activity.measure(peaks: peaks, meanSquares: meanSquares)
        XCTAssertEqual(try XCTUnwrap(activity.downmixScale()), 1.0 / 8, accuracy: 1e-6)
        let expected = meanSquares.reduce(0, +) / 8
        XCTAssertEqual(activity.averageRMS * activity.averageRMS, expected, accuracy: 1e-12)
    }

    // MARK: - 黏性（本次修復的核心）

    /// 逐 buffer 重算會讓 downmix 的除數在停頓時跳動 → 增益階梯 → 爆音。
    /// 黏性之後：第 1 格只有第 3 軌有訊號，第 2 格第 3 軌安靜（但第 5 軌出聲），
    /// 除數必須**還是** 2，不能退回 1 也不能跳成別的數。
    func testActiveSetIsStickyAcrossBuffersSoGainNeverSteps() throws {
        let activity = AudioChannelActivity()
        var first = [Float](repeating: 0, count: 8)
        first[3] = 0.5
        activity.measure(peaks: first, meanSquares: first.map { Double($0 * $0) })

        var second = [Float](repeating: 0, count: 8)
        second[5] = 0.5
        activity.measure(peaks: second, meanSquares: second.map { Double($0 * $0) })

        XCTAssertEqual(try XCTUnwrap(activity.downmixScale()), 0.5, "第 3 軌在第 2 格安靜了，但集合不能縮小")
        XCTAssertEqual(activity.activeCount, 2)
        XCTAssertTrue(activity.isActive(3))
        XCTAssertTrue(activity.isActive(5))
    }

    /// 新一次錄音從空白開始，黏性不得跨錄音殘留。
    func testResetClearsTheStickySet() {
        let activity = AudioChannelActivity()
        var live = [Float](repeating: 0, count: 8)
        live[2] = 0.5
        activity.measure(peaks: live, meanSquares: live.map { Double($0 * $0) })
        XCTAssertEqual(activity.activeCount, 1)
        activity.reset()
        XCTAssertEqual(activity.activeCount, 0)
        activity.measure(peaks: [Float](repeating: 0, count: 8),
                         meanSquares: [Double](repeating: 0, count: 8))
        XCTAssertNil(activity.downmixScale(), "重置後還沒黏住任何一軌")
        XCTAssertEqual(activity.averageRMS, 0)
    }

    /// 聲道數變了（換裝置／換節點）必須重配並清掉舊集合，否則舊的 index 會指到別的軌。
    func testChannelCountChangeResizesAndClearsTheSet() {
        let activity = AudioChannelActivity()
        var eight = [Float](repeating: 0, count: 8)
        eight[7] = 0.5
        activity.measure(peaks: eight, meanSquares: eight.map { Double($0 * $0) })
        XCTAssertTrue(activity.isActive(7))

        let four = [Float](repeating: 0, count: 4)
        activity.measure(peaks: four, meanSquares: four.map { Double($0 * $0) })
        XCTAssertEqual(activity.channelCount, 4)
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertFalse(activity.isActive(7))
    }

    /// 全靜音時沒有聲道過門檻 → 不能自己混（`downmixScale()` 回 nil），
    /// 但電平要讀得到「現在有多安靜」，安靜偵測才會成立。
    func testSilentBufferHasNoDownmixButStillReportsSilence() {
        let activity = AudioChannelActivity()
        let quiet = [Float](repeating: 0.0009, count: 64)      // −61 dBFS，門檻之下
        activity.measure(peaks: quiet, meanSquares: quiet.map { Double($0 * $0) })
        XCTAssertNil(activity.downmixScale())
        XCTAssertLessThan(activity.averageRMS, 0.015, "低於安靜自動結束的門檻")
    }

    /// 門檻邊界 −60 dBFS：之上才算有訊號。
    func testThresholdBoundaryIsMinusSixtyDBFS() throws {
        let activity = AudioChannelActivity()
        let peaks: [Float] = [0.0009, 0.2, 0, 0]
        activity.measure(peaks: peaks, meanSquares: peaks.map { Double($0 * $0) })
        XCTAssertFalse(activity.isActive(0))
        XCTAssertTrue(activity.isActive(1))
        XCTAssertEqual(try XCTUnwrap(activity.downmixScale()), 1.0)
    }

    // MARK: - ≤2 軌：行為完全不變

    func testTwoChannelDevicesKeepPlainAverage() {
        let activity = AudioChannelActivity()
        let peaks: [Float] = [0.5, 0]
        activity.measure(peaks: peaks, meanSquares: [0.125, 0])
        XCTAssertFalse(activity.needsManualDownmix)
        XCTAssertNil(activity.downmixScale(), "2 軌以內照舊直接平均，不自己混")
        XCTAssertEqual(activity.averageRMS, sqrt(0.0625), accuracy: 1e-12,
                       "2 軌＝整軌平方平均再開根號，不是只有有訊號的那一軌")
    }

    /// 指定單一聲道時，集合永遠只有那一軌，安靜偵測也只看那一軌。
    func testSelectedChannelCollapsesTheSetToThatChannel() {
        let activity = AudioChannelActivity()
        activity.selectedChannel = 1
        let peaks: [Float] = [0, 0.9, 0.9]
        activity.measure(peaks: peaks, meanSquares: peaks.map { Double($0 * $0) })
        XCTAssertEqual(activity.activeCount, 1)
        XCTAssertTrue(activity.isActive(1))
        XCTAssertFalse(activity.isActive(2))
        XCTAssertNil(activity.downmixScale(), "指定聲道走抽軌，不是平均")
        XCTAssertEqual(activity.averageRMS, 0.9, accuracy: 1e-6)
    }

    // MARK: - buffer 讀寫（AVAudioPCMBuffer 只能建 ≤2 聲道）

    func testMixAndCopyReadFloat32PlanarInt16PlanarAndInterleaved() throws {
        for interleaved in [false, true] {
            for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
                let source = try XCTUnwrap(self.buffer(
                    amplitudes: [0.5, 0], interleaved: interleaved, commonFormat: commonFormat
                ))
                let activity = AudioChannelActivity()
                activity.measure(source)

                // Average + 2 軌 → 不自己混（copy 測的是指定聲道的路徑）。
                let scratch = try XCTUnwrap(UnsafeMutablePointer<Float>.allocate(capacity: 64))
                defer { scratch.deallocate() }
                scratch.update(repeating: 0, count: 64)
                activity.selectedChannel = 0
                XCTAssertTrue(activity.copy(channel: 0, into: scratch, from: source, frameLimit: 64))
                XCTAssertEqual(scratch[0], 0.5, accuracy: 0.002,
                               "float32=\(commonFormat == .pcmFormatFloat32) interleaved=\(interleaved)")
                XCTAssertEqual(source.frameLength, 64, "讀寫不能動到來源 buffer")
                if let untouched = source.floatChannelData?[0][0] {
                    XCTAssertEqual(untouched, 0.5, "讀寫不能動到來源 buffer")
                }
            }
        }
    }

    func testNaNAndEmptyBuffersNeverProduceSignal() {
        let source = try? XCTUnwrap(buffer(amplitudes: [0.5, 0.5]))
        guard let source else { return }
        for channel in 0 ..< 2 {
            for index in 0 ..< 64 { source.floatChannelData![channel][index] = .nan }
        }
        let activity = AudioChannelActivity()
        XCTAssertEqual(activity.measure(source), 2, "還是要讀得出版面")
        XCTAssertEqual(activity.activeCount, 0, "NaN 不算訊號")
        source.frameLength = 0
        XCTAssertEqual(activity.measure(source), 0)
    }

    func testOutOfRangeChannelCountIsRejected() {
        XCTAssertEqual(AudioChannelActivity().measure(peaks: [], meanSquares: []), 0)
        XCTAssertEqual(AudioChannelActivity().measure(peaks: [1], meanSquares: [1, 1]), 0)
    }

    // MARK: - helpers

    private func buffer(
        amplitudes: [Float],
        frames: Int = 64,
        interleaved: Bool = false,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32
    ) -> AVAudioPCMBuffer? {
        // AVAudioPCMBuffer 不支援 interleaved float32，所以那一格改用 int16。
        let format = commonFormat == .pcmFormatFloat32 && interleaved
            ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                            channels: AVAudioChannelCount(amplitudes.count), interleaved: true)
            : AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000,
                            channels: AVAudioChannelCount(amplitudes.count), interleaved: interleaved)
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = amplitudes.count
        let int16 = buffer.format.commonFormat == .pcmFormatInt16
        for (channel, amplitude) in amplitudes.enumerated() {
            for frame in 0..<frames {
                let value = amplitude
                let offset = interleaved ? frame * channels + channel : frame
                if int16 {
                    buffer.int16ChannelData![interleaved ? 0 : channel][offset] = Int16(value * 32767)
                } else {
                    buffer.floatChannelData![channel][offset] = value
                }
            }
        }
        return buffer
    }

    /// 64 軌介面一格常大於預配容量（實測 BlackHole 64ch 閃退在 AudioConverter 釋放＝堆積被寫壞）。
    /// mix／copy 只准寫 frameLimit 格，後面的記憶體一格都不能動。
    func testMixAndCopyNeverWritePastFrameLimit() throws {
        let source = try XCTUnwrap(self.buffer(amplitudes: [0.5, 0.5], interleaved: false, commonFormat: .pcmFormatFloat32))
        let activity = AudioChannelActivity()
        activity.measure(source)
        let limit = 16, guardCount = 64
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: limit + guardCount)
        defer { scratch.deallocate() }
        for useCopy in [false, true] {
            scratch.update(repeating: 0, count: limit)
            (scratch + limit).update(repeating: 42, count: guardCount)
            if useCopy { _ = activity.copy(channel: 0, into: scratch, from: source, frameLimit: limit) }
            else { _ = activity.mix(into: scratch, from: source, frameLimit: limit) }
            for k in 0..<guardCount { XCTAssertEqual(scratch[limit + k], 42, "寫出界：\(useCopy ? "copy" : "mix") 第 \(limit + k) 格") }
        }
    }
}
