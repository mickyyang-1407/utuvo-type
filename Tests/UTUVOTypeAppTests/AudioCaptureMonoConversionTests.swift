import AVFoundation
import XCTest
@testable import UTUVOTypeApp

/// 送進 converter 之前的整流（mac-input-repair1 #2）。
///
/// 從前「這一格沒有任何聲道過門檻」時是把多軌的原 buffer 交回去，但 converter 的
/// 輸入格式是單軌 → 格式不符 → `convert` 報錯 → 整格被丟。錄音在靜音段落會一格一格漏。
/// 正確退路是送一格**同格式的靜音單軌**。
///
/// 這台機器的 SDK 造不出 >2 聲道的 `AVAudioPCMBuffer`，所以退路用「指定聲道超出範圍」
/// 觸發——同樣是「要單軌化但這一格沒有東西可以放進去」。
final class AudioCaptureMonoConversionTests: XCTestCase {
    private func twoChannelBuffer(amplitude: Float, frames: Int = 512) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for index in 0..<frames { buffer.floatChannelData![channel][index] = amplitude }
        }
        return buffer
    }

    /// 替 session 裝好「單軌化」的轉換設定（`start` 裡做的事，測試直接驅動）。
    private func prepared(_ inputChannel: AudioInputChannel) throws -> (AudioCaptureSession, AVAudioFormat) {
        let deviceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let session = AudioCaptureSession(inputChannel: inputChannel)
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        session.conversionInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )
        session.converter = AVAudioConverter(from: session.conversionInputFormat!, to: outputFormat)
        session.prepareConversionBuffers(for: deviceFormat)
        return (session, deviceFormat)
    }

    // MARK: - 串流：每一格都要轉出來

    /// 2026-10-19：轉換回呼每格回 `.endOfStream`，converter 從第二格起就只吐 0 格——
    /// 16 kHz PCM 串流（百鍊串流辨識、Groq 雲端辨識）整段只剩第一格 0.1 秒。
    func testConsecutiveBuffersAllConvert() throws {
        let (session, _) = try prepared(.channel1)
        var bytes = 0
        for _ in 0..<10 {
            let input = try twoChannelBuffer(amplitude: 0.3, frames: 4_800)
            session.channelActivity.measure(input)
            bytes += session.convertToPCM16Mono(session.bufferForConversion(input))?.count ?? 0
        }
        // 10 格 × 0.1 秒 @ 16 kHz × 2 bytes ＝ 32,000；resampler 會留一小段在內部（實測 30,112），容許 10%。
        // 修之前：0（這個測試）／3,200（實機整段錄音）。
        XCTAssertGreaterThan(bytes, 28_800, "只轉出 \(bytes) bytes")
    }

    // MARK: - 退路：格式必須一致，不准丟資料

    func testSilentBufferStillConvertsAsMonoInsteadOfFallingBackToMultiChannel() throws {
        // 指定第 9 軌，但裝置只有 2 軌 → 這一格抽不到東西。
        let (session, _) = try prepared(.channel4)
        XCTAssertTrue(session.needsMonoConversion)
        let input = try twoChannelBuffer(amplitude: 0)
        session.channelActivity.measure(input)

        let converted = session.bufferForConversion(input)
        XCTAssertEqual(converted.format.channelCount, 1,
                       "交回多軌 buffer 會讓單軌 converter 報錯、整格資料被丟")
        XCTAssertEqual(converted.format.sampleRate, 48_000, accuracy: 0.001)
        let conversionFormat = try XCTUnwrap(session.conversionInputFormat)
        XCTAssertEqual(converted.format.commonFormat, conversionFormat.commonFormat)
        XCTAssertEqual(converted.format.isInterleaved, conversionFormat.isInterleaved)
        XCTAssertEqual(Int(converted.frameLength), 512, "格數不能因為退路而少一截")
        XCTAssertEqual(converted.floatChannelData![0][100], 0, "退路這一格是靜音")
    }

    func testConverterAcceptsEveryBufferWeHandItIncludingTheSilentFallback() throws {
        let (session, _) = try prepared(.channel4)
        let live = try twoChannelBuffer(amplitude: 0.4)
        let silent = try twoChannelBuffer(amplitude: 0)
        session.channelActivity.measure(live)

        var delivered = 0
        for input in [live, silent, live, silent] {
            let converted = session.bufferForConversion(input)
            XCTAssertEqual(converted.format.channelCount, session.converter!.inputFormat.channelCount)
            var error: NSError?
            let buffer = converted
            let status = session.converter!.convert(
                to: session.conversionOutputBuffer!, error: &error
            ) { _, inputStatus in
                inputStatus.pointee = .haveData
                return buffer
            }
            XCTAssertEqual(status, .haveData, "converter 不該因為格式不符報錯——報錯就是整格被丟")
            XCTAssertNil(error)
            delivered += 1
        }
        XCTAssertEqual(delivered, 4, "四格都要送得出去")
    }

    func testReusedMonoBufferIsZeroedSoNoGainDriftAccumulates() throws {
        let (session, _) = try prepared(.channel1)
        let loud = try twoChannelBuffer(amplitude: 0.8)
        let silent = try twoChannelBuffer(amplitude: 0)
        session.channelActivity.measure(loud)

        XCTAssertEqual(session.bufferForConversion(loud).floatChannelData![0][0], 0.8, accuracy: 0.01)
        // 緩衝是跨 buffer 重用的：下一格是靜音，就必須真的是 0，不能留著上一格的殘留。
        let after = session.bufferForConversion(silent)
        XCTAssertEqual(after.floatChannelData![0][0], 0)
        for index in 0..<512 { XCTAssertEqual(after.floatChannelData![0][index], 0) }
    }

    func testSelectedChannelIsCopiedNotAveraged() throws {
        let (session, _) = try prepared(.channel2)
        let input = try twoChannelBuffer(amplitude: 0.4)
        input.floatChannelData![0][0] = 0.9                    // 第 0 軌故意不同
        session.channelActivity.measure(input)
        let converted = session.bufferForConversion(input)
        XCTAssertEqual(converted.floatChannelData![0][0], 0.4, accuracy: 0.01, "抽的是第 1 軌")
        XCTAssertEqual(input.floatChannelData![0][0], 0.9, "來源 buffer 不能被改寫")
    }

    // MARK: - ≤2 軌：行為完全不變

    func testTwoChannelAverageNeedsNoMonoConversionAtAll() throws {
        let session = AudioCaptureSession(inputChannel: .average)
        let deviceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        session.converter = AVAudioConverter(from: deviceFormat, to: outputFormat)
        session.prepareConversionBuffers(for: deviceFormat)

        XCTAssertFalse(session.needsMonoConversion, "2 軌 + Average 不該自己混")
        let input = try twoChannelBuffer(amplitude: 0.3)
        let converted = session.bufferForConversion(input)
        XCTAssertEqual(converted.format.channelCount, 2, "原 buffer 原封不動送進 converter")
        XCTAssertEqual(Int(converted.frameLength), 512)
    }
}
