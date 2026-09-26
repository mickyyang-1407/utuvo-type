import XCTest
import AVFAudio
@testable import UTUVOTypeiOS

/// 實機才跑（MLX 需要 GPU）：用 App 自己資料夾裡的模型，走與鍵盤相同的 PCMAccumulator → LocalQwenASR.transcribe 路徑。
/// 模型沒下載就跳過（不是失敗）。
@MainActor
final class LocalQwenDeviceTests: XCTestCase {
    func testQwenTranscribesBundledClipWithHotwords() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX 需要實機")
        #else
        guard LocalQwenASR.shared.isReady else { throw XCTSkip("模型尚未下載") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "zhtw-sample", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let acc = PCMAccumulator()
        acc.reset(enabled: true)
        acc.append(buffer)
        let samples = acc.snapshot
        let start = Date()
        let text = await LocalQwenASR.shared.transcribe(samples, language: "zh-TW", hotwords: ["Atmos", "ADM", "母帶", "交付規格"])
        let seconds = Date().timeIntervalSince(start)
        print("QWEN-DEVICE \(String(format: "%.2f", seconds))s: \(text ?? "nil")")
        let out = try XCTUnwrap(text, "本機辨識回 nil＝會退回 Apple")
        XCTAssertTrue(out.contains("Atmos"), out)
        XCTAssertTrue(out.contains("ADM"), out)
        XCTAssertFalse(out.contains("录") || out.contains("规"), "要轉成繁體：\(out)")
        let warm = Date()
        _ = await LocalQwenASR.shared.transcribe(samples, language: "zh-TW", hotwords: ["Atmos", "ADM"])
        print("QWEN-DEVICE warm \(String(format: "%.2f", Date().timeIntervalSince(warm)))s for \(String(format: "%.1f", Double(samples.count) / 16_000))s audio")
        #endif
    }
}
