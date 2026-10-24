import AVFoundation
import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// repair round 2（2026-10-22）：只有 Groq 時的錄音上限在 tap 端**按樣本數**硬截，不靠 MainActor 每秒一次的檢查。
///
/// c9b411c 只靠每秒輪詢：最壞情況交給 Groq 296.4 s，跨上限那一次檢查只要晚到約 4 秒（主執行緒卡住），
/// PCM 就超過 `MacCloudASR.maxSeconds`（300 s）、被拒收（"too-long"），變成重試也救不回來的失敗紀錄。
/// 這裡用 `prepareCapture`＋`ingest`（跟 tap 同一條路，不開麥克風）餵到上限之後還多很多秒，**完全不做輪詢**
/// ＝主執行緒一直卡著：送出去的 PCM、存下來的 .caf 都不能超過上限。
final class RecordingHardCapTests: XCTestCase {
    private func format(sampleRate: Double, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
                                    interleaved: false))
    }

    /// 一格 440 Hz、振幅 0.3 的合成音（一直重複用同一格）。
    private func toneBuffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = 0.3 * Float(sin(Double(index) * 2 * .pi * 440 / format.sampleRate))
            }
        }
        return buffer
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct Fed {
        var pcm: Data
        var limitCallbacks: Int
        var capturedSeconds: TimeInterval
    }

    /// 開一個 session（上限 `limit`）、餵 `seconds` 秒（每格 `frames`），最後把 PCM 串流收齊。
    private func feed(sampleRate: Double, channels: AVAudioChannelCount = 1, frames: AVAudioFrameCount,
                      seconds: Double, limit: TimeInterval?, file: AVAudioFile? = nil) async throws -> Fed {
        let format = try format(sampleRate: sampleRate, channels: channels)
        let session = AudioCaptureSession(voiceActivityDetection: false)
        session.captureLimitSeconds = limit
        let callbacks = Counter()
        session.onCaptureLimitReached = { callbacks.increment() }
        let stream = session.prepareCapture(format: format)
        let buffer = try toneBuffer(format, frames: frames)
        let count = Int((seconds * sampleRate / Double(frames)).rounded(.up))
        for _ in 0..<count { session.ingest(buffer, into: file) }
        let captured = session.capturedSeconds
        session.finishPCMStream()
        var pcm = Data()
        for try await chunk in stream { pcm.append(chunk) }
        return Fed(pcm: pcm, limitCallbacks: callbacks.count, capturedSeconds: captured)
    }

    /// 只有 Groq（上限 295 s）一直講到 305 s、一次都沒輪詢：送出去的 PCM ≤ 上限、Groq 收得下；
    /// 存下來的 .caf 剛好是上限，重試時重新解碼（`pcm16Mono16k`）也收得下。上限通知只有一次。
    func testGroqOnlyCapIsAHardStopOnCapturedSamples() async throws {
        let cap = RecordingLimits.maxDuration(cloudOnly: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-type-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let fed: Fed
        do {
            let file = try AVAudioFile(forWriting: url, settings: try format(sampleRate: 48_000).settings)
            fed = try await feed(sampleRate: 48_000, frames: 2_048, seconds: cap + 10, limit: cap, file: file)
        }
        XCTAssertEqual(fed.limitCallbacks, 1, "到上限通知一次")
        let pcmSeconds = Double(fed.pcm.count) / 32_000
        XCTAssertLessThanOrEqual(pcmSeconds, cap, "送給 Groq 的 PCM（\(pcmSeconds) s）不能超過上限")
        XCTAssertGreaterThan(pcmSeconds, cap - 0.5, "也不能少收（上限前的都要在）")
        XCTAssertLessThanOrEqual(fed.capturedSeconds, cap)

        let transport = MockCleanupTransport()
        transport.register(host: "api.groq.com", bodyJSON: ["text": "合成測試文字"])
        let live = await MacCloudASR.transcribe(pcm16: fed.pcm, language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                key: "fake-groq-key", transport: transport)
        XCTAssertEqual(live, .ok("合成測試文字"), "Groq 收得下（不是 too-long）")

        let recording = try AVAudioFile(forReading: url)
        XCTAssertEqual(recording.length, AVAudioFramePosition(cap * 48_000), "存下來的錄音剛好到上限")
        let retried = try AudioCaptureSession.pcm16Mono16k(fromRecording: url, inputChannel: .average)
        XCTAssertLessThanOrEqual(Double(retried.count) / 32_000, MacCloudASR.maxSeconds)
        let retry = await MacCloudASR.transcribe(pcm16: retried, language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                 key: "fake-groq-key", transport: transport)
        XCTAssertEqual(retry, .ok("合成測試文字"), "重試重新解碼也收得下")
    }

    /// 取樣率 × tap 格數掃一遍（上限 2.5 s、餵 4 s）：寫進檔案的格數剛好是上限、PCM 不超過上限、通知一次。
    func testHardCapHoldsAcrossSampleRatesAndBufferSizes() async throws {
        let limit = 2.5
        for sampleRate in [16_000.0, 44_100, 48_000, 96_000] {
            for frames: AVAudioFrameCount in [512, 2_048, 4_800, 9_600] {
                for channels: AVAudioChannelCount in [1, 2] {
                    let label = "\(Int(sampleRate)) Hz × \(frames) frames × \(channels) ch"
                    let fed = try await feed(sampleRate: sampleRate, channels: channels, frames: frames, seconds: 4, limit: limit)
                    XCTAssertEqual(fed.limitCallbacks, 1, label)
                    XCTAssertLessThanOrEqual(fed.pcm.count, Int(limit * 32_000), label)
                    XCTAssertGreaterThan(fed.pcm.count, Int((limit - 0.2) * 32_000), label)
                    XCTAssertLessThanOrEqual(fed.capturedSeconds, limit, label)
                    XCTAssertGreaterThanOrEqual(fed.capturedSeconds, limit - 1 / sampleRate, "\(label)：檔案收到剛好上限")
                }
            }
        }
    }

    /// 不該擋的：沒設上限、或錄音比上限短，一格都不少、不通知（閘門誤擋跟漏擋一樣是缺陷）。
    func testRecordingsUnderTheCapAreUntouched() async throws {
        let uncapped = try await feed(sampleRate: 48_000, frames: 4_800, seconds: 3, limit: nil)
        XCTAssertEqual(uncapped.limitCallbacks, 0)
        XCTAssertEqual(uncapped.capturedSeconds, 3, accuracy: 0.001)

        let under = try await feed(sampleRate: 48_000, frames: 4_800, seconds: 3, limit: RecordingLimits.maxDuration(cloudOnly: true))
        XCTAssertEqual(under.limitCallbacks, 0)
        XCTAssertEqual(under.capturedSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(under.pcm.count, uncapped.pcm.count, "比上限短：跟沒上限一模一樣")
    }

    /// 第二關：PCM 照位元組截（不管 resampler 怎麼進位都不超過上限），一律整個樣本（偶數 bytes）。
    func testPCMAllowanceNeverPassesTheLimit() {
        XCTAssertEqual(AudioCaptureSession.pcmAllowance(count: 4_096, yielded: 0, limit: nil), 4_096, "沒上限：全部")
        XCTAssertEqual(AudioCaptureSession.pcmAllowance(count: 4_096, yielded: 0, limit: 1), 4_096, "還沒到：全部")
        XCTAssertEqual(AudioCaptureSession.pcmAllowance(count: 4_096, yielded: 30_000, limit: 1), 2_000, "到上限為止")
        XCTAssertEqual(AudioCaptureSession.pcmAllowance(count: 4_096, yielded: 32_000, limit: 1), 0, "滿了：一個都不送")
        XCTAssertEqual(AudioCaptureSession.pcmAllowance(count: 4_096, yielded: 40_000, limit: 1), 0)
        XCTAssertEqual(AudioCaptureSession.pcmAllowance(count: 4_096, yielded: 0, limit: 0.1000313), 3_200, "不切半個樣本")
        let cap = RecordingLimits.maxDuration(cloudOnly: true)
        var yielded = 0
        for chunk in [683, 1_366, 4_097, 9_600].map({ $0 * 2 }) {
            for _ in 0..<20_000 {   // 有上限的迴圈：上限壞掉時測試失敗，不會卡住
                let allowed = AudioCaptureSession.pcmAllowance(count: chunk, yielded: yielded, limit: cap)
                guard allowed > 0 else { break }
                yielded += allowed
            }
        }
        XCTAssertEqual(yielded, Int(cap * 32_000), "一直送也剛好停在上限")
        XCTAssertLessThanOrEqual(Double(yielded) / 32_000, MacCloudASR.maxSeconds)
    }

    /// 截到上限的那一格是前面那一段的複本（內容一樣、tap 給的 buffer 不動）。
    func testPrefixCopiesTheLeadingFrames() throws {
        let format = try format(sampleRate: 48_000, channels: 2)
        let buffer = try toneBuffer(format, frames: 1_000)
        let head = try XCTUnwrap(AudioCaptureSession.prefix(of: buffer, frames: 300))
        XCTAssertEqual(head.frameLength, 300)
        XCTAssertEqual(buffer.frameLength, 1_000, "原本那格不動")
        for channel in 0..<2 {
            for index in 0..<300 {
                XCTAssertEqual(head.floatChannelData![channel][index], buffer.floatChannelData![channel][index])
            }
        }
        XCTAssertNil(AudioCaptureSession.prefix(of: buffer, frames: 1_001))
    }
}
