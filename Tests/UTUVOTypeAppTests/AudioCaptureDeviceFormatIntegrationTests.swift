import AVFoundation
import XCTest
@testable import UTUVOTypeApp

/// 硬體整合測試（opt-in）：選了不是系統預設的錄音裝置時，錄到的檔案必須是
/// 那台裝置的聲道格式，不能是預設裝置的（2026-10-14 MTRX 64ch 把人聲稀釋掉 36 dB）。
///
/// 需要真的有一台非預設輸入裝置與一路訊號進去。預設不跑：
///   UTVO_AUDIO_INTEGRATION=1 swift test --filter AudioCaptureDeviceFormatIntegrationTests
///
/// 情境（裝置／播放器）走同一個環境變數：這個 harness 只放行第一個 `UTUVO_*`
/// 變數，而且值裡有 `=` 會被吃掉，所以用冒號當分隔：
///   UTVO_AUDIO_INTEGRATION='device:BlackHole 64ch,player:15'
///   device  目標裝置名稱，預設 BlackHole 2ch
///   player  ffmpeg audiotoolbox 輸出裝置 index（`ffmpeg -f audiotoolbox -list_devices true` 的編號）
/// 只給 `1` 就是預設情境。
final class AudioCaptureDeviceFormatIntegrationTests: XCTestCase {
    private static let artifactURL = URL(fileURLWithPath: "/tmp/utuvo-audio-format-test.caf")

    func testRecordingMatchesSelectedDeviceFormatNotSystemDefault() async throws {
        let scenario = Self.scenario()
        try XCTSkipUnless(scenario != nil, "opt-in hardware test；設 UTVO_AUDIO_INTEGRATION=1 才跑")
        let (wantedName, playerIndex) = scenario!

        let devices = AudioDeviceCatalog.inputDevices()
        guard let device = devices.first(where: { $0.name == wantedName }) else {
            throw XCTSkip("找不到測試裝置 \(wantedName)：\(devices.map(\.name).joined(separator: ", "))")
        }

        // 440 Hz 從 ffmpeg 進指定裝置，作為「有人聲」的替代訊號。
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-re",
            "-f", "lavfi", "-i", "sine=f=440:d=12", "-ac", "2",
        ]
        arguments += ["-f", "audiotoolbox", "-audio_device_index", playerIndex, "-"]
        player.arguments = arguments
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        try player.run()
        defer { player.terminate() }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let session = AudioCaptureSession(
            inputDeviceUID: device.id,
            inputChannel: .average,
            transcriptionLanguageIdentifier: "en-US"
        )
        let stream = try session.start(enableSpeechFallback: false)
        let collector = Task { () -> [UInt8] in
            var bytes: [UInt8] = []
            do {
                for try await chunk in stream { bytes.append(contentsOf: chunk) }
            } catch {
                print("[audio-format-integration] stream ended with \(error)")
            }
            return bytes
        }
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let stopped = await session.stop()
        let result = try XCTUnwrap(stopped)
        let pcm = await collector.value

        try? FileManager.default.removeItem(at: Self.artifactURL)
        try FileManager.default.copyItem(at: result.audioURL, to: Self.artifactURL)

        let recorded = try AVAudioFile(forReading: Self.artifactURL)
        let channels = Int(recorded.processingFormat.channelCount)
        let perChannel = try channelReport(file: recorded)
        let mono = MonoReport(pcm: pcm)

        print("""
        [audio-format-integration]
        device=\(device.name) channels=\(device.channelCount)
        defaultInput=\(AudioDeviceCatalog.defaultInputUID() ?? "-")
        recordedChannels=\(channels) frames=\(recorded.length) file=\(Self.artifactURL.path)
        recordedPerChannel=\(perChannel.text)
        asrStream16kMonoRMS=\(mono.rmsDBFS) dBFS peak=\(mono.peakDBFS) dBFS goertzel440=\(mono.goertzel440DB)
        """)

        XCTAssertEqual(channels, device.channelCount, "錄到的聲道數必須等於所選裝置的輸入聲道數")

        // 目標裝置整段都是數位靜音＝測試訊號沒有被路由過去（環境事實，不是程式問題）。
        // 這種狀況測不出「平均有沒有把聲音稀釋掉」，要明講出來而不是假綠或假紅。
        let loudest = perChannel.levels.max() ?? -160
        try XCTSkipUnless(
            loudest > -60,
            "\(device.name) 整段沒有訊號（最高聲道 \(loudest) dBFS）；檢查 player:\(playerIndex) 有沒有路由到這台裝置"
        )
        if channels > 2 {
            // 多軌介面只有少數軌有訊號時，平均會把有訊號的軌稀釋掉
            // （64 軌＝−36 dB）。轉給 ASR 的單聲道必須貼住有訊號的那一軌。
            XCTAssertEqual(mono.rmsDBFS, loudest, accuracy: 1.0,
                           "多軌平均把有訊號的聲道稀釋掉了（聲道 RMS \(perChannel.levels) vs 單聲道 \(mono.rmsDBFS)）")
        } else {
            XCTAssertGreaterThan(mono.rmsDBFS, -30, "整段峰值太低，聲音還是被多聲道平均稀釋掉了")
        }

        // 再錄一次：確認為了對齊聲道數接上去的節點，下一次 start 前有拆乾淨，
        // 不會把上一輪的裝置／格式留在 graph 上。
        let again = AudioCaptureSession(
            inputDeviceUID: device.id,
            inputChannel: .average,
            transcriptionLanguageIdentifier: "en-US"
        )
        let secondStream = try again.start(enableSpeechFallback: false)
        let secondDrain = Task { () -> Int in
            var count = 0
            do { for try await _ in secondStream { count += 1 } } catch { }
            return count
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let secondStopped = await again.stop()
        let secondResult = try XCTUnwrap(secondStopped)
        _ = await secondDrain.value
        let secondFile = try AVAudioFile(forReading: secondResult.audioURL)
        let secondChannels = Int(secondFile.processingFormat.channelCount)
        print("[audio-format-integration] secondStartChannels=\(secondChannels)")
        XCTAssertEqual(secondChannels, device.channelCount, "第二次錄音的聲道數也必須等於所選裝置")
    }

    /// 節點生命週期（mac-input-repair1 #1）：連續 10 次 start/stop，中間不重開 engine。
    /// 格式對齊用的 mixer 每一次都必須在 stop 就拆掉；節點數只增不減就是 attach 漏拆。
    /// 不需要真的有訊號進去——只要那台裝置存在。
    func testRepeatedStartStopDoesNotAccumulateEngineNodes() async throws {
        let scenario = Self.scenario()
        try XCTSkipUnless(scenario != nil, "opt-in hardware test；設 UTVO_AUDIO_INTEGRATION=1 才跑")
        let (wantedName, _) = scenario!
        let devices = AudioDeviceCatalog.inputDevices()
        guard let device = devices.first(where: { $0.name == wantedName }) else {
            throw XCTSkip("找不到測試裝置 \(wantedName)")
        }

        let repeated = AudioCaptureSession(
            inputDeviceUID: device.id,
            inputChannel: .average,
            transcriptionLanguageIdentifier: "en-US"
        )
        var nodeCounts: [Int] = []
        var runningNodeCounts: [Int] = []
        for round in 1 ... 10 {
            let stream = try repeated.start(enableSpeechFallback: false)
            let drain = Task { () -> Void in
                do { for try await _ in stream { } } catch { }
            }
            try await Task.sleep(nanoseconds: 700_000_000)
            runningNodeCounts.append(repeated.attachedNodeCount)
            let result = await repeated.stop()
            await drain.value
            let url = try XCTUnwrap(result?.audioURL)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Int(file.processingFormat.channelCount), device.channelCount,
                           "第 \(round) 輪的聲道數也必須等於所選裝置")
            XCTAssertGreaterThan(file.length, 0, "第 \(round) 輪沒有寫到任何資料")
            nodeCounts.append(repeated.attachedNodeCount)
        }
        print("[audio-format-integration] attachedNodesWhileRunning=\(runningNodeCounts)")
        print("[audio-format-integration] attachedNodesAfterStop=\(nodeCounts)")
        XCTAssertEqual(Set(nodeCounts).count, 1,
                       "節點數在 10 次 start/stop 之間不一致＝有 attach 沒 detach")
        XCTAssertGreaterThanOrEqual(
            runningNodeCounts.max() ?? 0, nodeCounts[0],
            "錄音中掛的節點必須 >= 停完之後（格式對齊用的 mixer 是 start 期間才存在的）"
        )
    }
}

/// .caf 檔裡每一軌的 RMS（dBFS）；用來看「只有第 1 軌有訊號」。
private struct ChannelReport {
    var levels: [Float] = []
    var text: String {
        levels.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: " ")
    }
}

/// 真正餵給 ASR 的 16 kHz 單聲道 PCM16：RMS、峰值，以及 440 Hz 的 Goertzel 能量。
private struct MonoReport {
    let samples: [Float]

    init(pcm: [UInt8]) {
        var values: [Float] = []
        values.reserveCapacity(pcm.count / 2)
        var index = 0
        while index + 1 < pcm.count {
            let raw = UInt16(pcm[index]) | (UInt16(pcm[index + 1]) << 8)
            values.append(Float(Int16(bitPattern: raw)) / 32768)
            index += 2
        }
        samples = values
    }

    var rmsDBFS: Float {
        guard !samples.isEmpty else { return -160 }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        return 20 * log10(max(1e-9, rms))
    }

    var peakDBFS: Float {
        20 * log10(max(1e-9, samples.reduce(0) { max($0, abs($1)) }))
    }

    /// 單一頻點的 Goertzel 能量（dBFS）：440 Hz 清楚時應該貼近 peak。
    var goertzel440DB: Float {
        let rate: Float = 16_000, target: Float = 440
        guard samples.count > 1 else { return -160 }
        let k = 2 * Float.pi * target / rate
        let coefficient = 2 * cos(k)
        var previous: Float = 0, previousPrevious: Float = 0
        for sample in samples {
            let current = sample + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }
        let real = previous - cos(k) * previousPrevious
        let imaginary = sin(k) * previousPrevious
        let magnitude = sqrt(real * real + imaginary * imaginary) / Float(samples.count) * 2
        return 20 * log10(max(1e-9, magnitude))
    }
}

private extension AudioCaptureDeviceFormatIntegrationTests {
    /// `UTUVO_AUDIO_INTEGRATION` = `1`（預設情境）或 `device:名稱,player:index`。
    static func scenario() -> (device: String, player: String)? {
        guard let raw = ProcessInfo.processInfo.environment["UTUVO_AUDIO_INTEGRATION"] else { return nil }
        var values: [String: String] = [:]
        for field in raw.split(separator: ",") {
            let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard !values.isEmpty else { return ("BlackHole 2ch", "14") }
        return (values["device"] ?? "BlackHole 2ch", values["player"] ?? "14")
    }

    /// 每個聲道的 RMS（dBFS）；拿來看出「只有第 1 軌有訊號」這種狀況。
    func channelReport(file: AVAudioFile) throws -> ChannelReport {
        let channels = Int(file.processingFormat.channelCount)
        let total = Int(file.length)
        guard channels > 0, total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total)) else {
            return ChannelReport()
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return ChannelReport() }
        let frames = Int(buffer.frameLength)
        var report = ChannelReport()
        for channel in 0..<channels {
            var sum: Float = 0
            for index in 0..<frames { sum += data[channel][index] * data[channel][index] }
            report.levels.append(20 * log10(max(1e-9, sqrt(sum / Float(max(1, frames))))))
        }
        return report
    }
}