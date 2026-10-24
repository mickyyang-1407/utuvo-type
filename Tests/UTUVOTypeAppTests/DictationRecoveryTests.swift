import AVFoundation
import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// delivery-learning-1＋app-shell-3（2026-10-22）：Mac 辨識失敗／處理中取消的聽寫留在歷史、可以重試，
/// 不留孤兒錄音。全部在隔離模式跑：不開麥克風、不碰剪貼簿、Keychain、網路。
@MainActor
final class DictationRecoveryTests: XCTestCase {

    // MARK: - 舊的歷史檔要讀得出來（status 是新欄位）

    /// 0.2.x 寫的歷史：沒有 note、沒有 status。
    private let oldHistoryJSON = """
    [{"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0001","date":782000000,"rawTranscript":"合成測試文字",\
    "output":"合成測試文字。","duration":3.2,"mode":"smart","appName":"Notes",\
    "bundleIdentifier":"com.apple.Notes","audioPath":"/nonexistent/old.caf","isStarred":true}]
    """

    func testOldHistoryJSONDecodesWithNilStatus() throws {
        let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(oldHistoryJSON.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].status, "舊紀錄沒有 status＝正常完成")
        XCTAssertNil(records[0].note)
        XCTAssertEqual(records[0].output, "合成測試文字。")
        XCTAssertTrue(records[0].isStarred)
        // 正常的紀錄寫回去也不帶 status：舊版 App 讀得回來，格式跟以前一樣。
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        XCTAssertFalse(encoded.contains("status"), encoded)
    }

    func testStatusRoundTripsAndUnknownStatusDoesNotBreakTheWholeHistory() throws {
        let failed = HistoryRecord(rawTranscript: "", output: "", duration: 2, mode: .fast, status: .failed)
        let decoded = try JSONDecoder().decode([HistoryRecord].self, from: JSONEncoder().encode([failed]))
        XCTAssertEqual(decoded, [failed])
        // 之後版本寫了這版不認得的狀態：那一筆當正常，整份歷史照樣讀得出來。
        let future = oldHistoryJSON.replacingOccurrences(of: "\"isStarred\":true}", with: "\"isStarred\":true,\"status\":\"fallback\"}")
        let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(future.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].status)
    }

    // MARK: - 收尾：失敗、靜音、取消

    private func makeModel(_ context: IsolatedContext) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.mode = .fast
        return AppModel(preferences: preferences)
    }

    /// 暫存錄音（正式路徑是 /tmp 裡的 .caf，收尾時搬進 Recordings 或刪掉）。
    private func temporaryRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-type-test-\(UUID().uuidString).caf")
        try Data("synthetic-audio".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Recordings 裡每個檔都有一筆紀錄指著它。
    private func assertNoOrphans(_ preferences: AppPreferences, file: StaticString = #filePath, line: UInt = #line) {
        let folder = preferences.recordingsDirectory
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { folder.appendingPathComponent($0).standardizedFileURL.path }
        let referenced = Set(preferences.historyRecords.compactMap { $0.audioPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        for path in files {
            XCTAssertTrue(referenced.contains(path), "孤兒錄音：\(path)", file: file, line: line)
        }
    }

    func testRecognitionFailureKeepsAFailedRowWithAudioAndNoStats() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) { ("", URLError(.notConnectedToInternet)) }

        let records = model.preferences.historyRecords
        XCTAssertEqual(records.count, 1, "辨識失敗也要留一筆")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.rawTranscript, "")
        XCTAssertEqual(record.output, "")
        XCTAssertEqual(record.mode, .fast)
        XCTAssertNotNil(record.note, "原因寫在 note")
        let audio = try XCTUnwrap(record.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio), "錄音留著才能重新辨識")
        XCTAssertTrue(audio.hasPrefix(model.preferences.recordingsDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "暫存檔搬走了")
        XCTAssertEqual(model.preferences.usageStats, UsageStats(), "失敗的紀錄不算使用數據")
        XCTAssertTrue(model.statusMessage.contains(model.preferences.tr("重試", "Retry")), model.statusMessage)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(model.lastOutput, "", "沒有貼任何東西")
        assertNoOrphans(model.preferences)
    }

    func testSilenceLeavesNoRowAndNoRecording() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2, soundsSilent: true) { ("", nil) }
        XCTAssertTrue(model.preferences.historyRecords.isEmpty, "靜音不寫紀錄")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: model.preferences.recordingsDirectory.path)) ?? []
        XCTAssertEqual(files, [], "靜音的錄音不留")
        XCTAssertTrue(model.statusMessage.contains("dB"), "照舊講是哪支麥克風、峰值多少")
    }

    /// 辨識途中按取消：寫一筆「已取消」，逐字稿和錄音都留著；不貼、不算使用數據。
    func testCancelDuringRecognitionKeepsACancelledRow() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) {
            model.cancelProcessing()
            return ("合成測試文字", nil)
        }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.rawTranscript, "合成測試文字")
        XCTAssertEqual(record.output, "", "沒有貼上任何東西")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.audioPath)))
        XCTAssertEqual(model.preferences.usageStats, UsageStats())
        XCTAssertEqual(model.lastOutput, "")
        XCTAssertFalse(model.isProcessing)
        XCTAssertTrue(model.statusMessage.contains(model.preferences.tr("歷史紀錄", "History")), model.statusMessage)
        assertNoOrphans(model.preferences)
    }

    /// repair-batch1：辨識途中取消、但錄音存不進 Recordings（資料夾不能寫、磁碟滿）：逐字稿照樣留一筆（沒有錄音），
    /// 跟整理途中取消一樣——以前直接 return，已經辨識好的話整段不見。
    func testCancelDuringRecognitionWhenRecordingCannotBeStoredKeepsTranscript() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        // Recordings 的位置被一個檔案佔住：建資料夾失敗＝storeRecording 回 nil。
        try? FileManager.default.removeItem(at: model.preferences.recordingsDirectory)
        XCTAssertTrue(FileManager.default.createFile(atPath: model.preferences.recordingsDirectory.path,
                                                    contents: Data("not a folder".utf8)))
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) {
            model.cancelProcessing()
            return ("取消前已經辨識好的一段話", nil)
        }
        XCTAssertEqual(model.preferences.historyRecords.count, 1, "逐字稿要留一筆")
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.rawTranscript, "取消前已經辨識好的一段話")
        XCTAssertNil(record.audioPath, "錄音存不進去就沒有錄音")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "暫存檔照樣刪")
        XCTAssertEqual(model.preferences.usageStats, UsageStats())
    }

    /// 錄音存不進去、也沒有逐字稿：沒有任何東西可留，不寫空紀錄。
    func testCancelWithNothingToKeepWritesNoRow() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        try? FileManager.default.removeItem(at: model.preferences.recordingsDirectory)
        XCTAssertTrue(FileManager.default.createFile(atPath: model.preferences.recordingsDirectory.path,
                                                    contents: Data("not a folder".utf8)))
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) {
            model.cancelProcessing()
            return ("", nil)
        }
        XCTAssertTrue(model.preferences.historyRecords.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    /// 轉錄還沒出字就取消：錄音照樣收好（之後重試會重新辨識），不是丟在暫存資料夾。
    func testCancelBeforeAnyTranscriptKeepsAudioOnlyCancelledRow() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) {
            model.cancelProcessing()
            return ("", nil)
        }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(record.isAudioOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        assertNoOrphans(model.preferences)
    }

    /// 智慧整理途中取消（formatAndPaste 在 token 檢查直接 return）：以前逐字稿沒進歷史、錄音變孤兒。
    func testCancelDuringCleanupKeepsTranscriptAndAudio() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        let model = AppModel(preferences: preferences)
        model.captureContext = { _, _ in LimitedAppContext(appName: "Mail") }
        model.cleanupRunner = { _, _ in
            await model.cancelProcessing()
            return "合成測試文字。"
        }
        model.startRecording(mode: .smart)   // 隔離模式：抓目的地＋脈絡後就停在麥克風前
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) { ("合成測試文字", nil) }

        XCTAssertEqual(preferences.historyRecords.count, 1)
        let record = try XCTUnwrap(preferences.historyRecords.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.rawTranscript, "合成測試文字")
        XCTAssertEqual(record.mode, .smart)
        XCTAssertEqual(record.appName, "Mail", "用開始聽寫時抓的 App")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.audioPath)))
        XCTAssertEqual(preferences.usageStats, UsageStats())
        assertNoOrphans(preferences)
    }

    /// 正常完成的聽寫不受影響：一筆、沒有 status、錄音有紀錄指著。
    func testSuccessfulCaptureIsUnchanged() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) { ("合成測試文字", nil) }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertNil(record.status)
        XCTAssertEqual(record.output, "合成測試文字")
        XCTAssertNotEqual(model.preferences.usageStats, UsageStats(), "正常的照樣算")
        assertNoOrphans(model.preferences)
    }

    // MARK: - 重試：就地重新辨識

    private func failedEntry(_ model: AppModel) async throws -> HistoryRecord {
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) { ("", URLError(.timedOut)) }
        return try XCTUnwrap(model.preferences.historyRecords.first)
    }

    func testRetryOnFailedEntryRetranscribesTheSameRow() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let record = try await failedEntry(model)
        var transcribed: [URL] = []
        model.recordingTranscriber = { url in transcribed.append(url); return ("合成測試文字", nil) }
        var events: [String] = []
        model.onDeliveryEvent = { events.append($0) }

        model.retryHistory(record)
        await model.waitForHistoryRetry()

        XCTAssertEqual(transcribed.map(\.path), [record.audioPath], "用存下來的那個錄音檔")
        let records = model.preferences.historyRecords
        XCTAssertEqual(records.count, 1, "不新增一筆")
        let updated = try XCTUnwrap(records.first)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.date, record.date)
        XCTAssertNil(updated.status, "完成了：狀態清掉")
        XCTAssertEqual(updated.rawTranscript, "合成測試文字")
        XCTAssertEqual(updated.output, "合成測試文字")
        XCTAssertEqual(updated.audioPath, record.audioPath)
        XCTAssertEqual(model.isolatedClipboard, "合成測試文字", "結果放剪貼簿（不貼到 Type 自己）")
        XCTAssertEqual(model.retriedHistoryID, record.id)
        XCTAssertFalse(events.contains("inserted"))
        XCTAssertEqual(model.preferences.usageStats.totalSessions, 1, "失敗時沒算，救回來算一次")
        XCTAssertEqual(model.preferences.mode, .fast, "不改預設模式")
        XCTAssertFalse(model.isProcessing)
    }

    func testRetryThatStillFailsKeepsTheFailedRow() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let record = try await failedEntry(model)
        model.recordingTranscriber = { _ in (nil, "合成的失敗原因") }
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.note, "合成的失敗原因", "原因換成這一次的")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(updated.audioPath)))
        XCTAssertEqual(model.preferences.usageStats, UsageStats())
        XCTAssertFalse(model.isProcessing)
        XCTAssertNil(model.isolatedClipboard)
    }

    /// 隔離模式沒有注入辨識：一律失敗，不讀 Keychain、不連網。
    func testIsolatedRetranscribeWithoutInjectionNeverReachesEngines() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let record = try await failedEntry(model)
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        XCTAssertEqual(model.preferences.historyRecords.first?.status, .failed)
        XCTAssertFalse(model.isProcessing)
    }

    /// 取消的紀錄有逐字稿：重試＝重新整理（不重新辨識），完成後算一次使用數據；再重試一次不再算。
    func testRetryOnCancelledEntryReformatsAndCountsOnce() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 2) {
            model.cancelProcessing()
            return ("合成測試文字", nil)
        }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        var transcriberCalls = 0
        model.recordingTranscriber = { _ in transcriberCalls += 1; return ("不該用到", nil) }
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        XCTAssertEqual(transcriberCalls, 0, "有逐字稿就不重新辨識")
        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertNil(updated.status)
        XCTAssertEqual(updated.output, "合成測試文字")
        XCTAssertEqual(model.preferences.usageStats.totalSessions, 1)
        model.retryHistory(updated)
        await model.waitForHistoryRetry()
        XCTAssertEqual(model.preferences.usageStats.totalSessions, 1, "已經算過的不再算")
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
    }

    /// 錄音已被保留期限刪掉的失敗紀錄：沒有東西可重跑，不進處理中。
    func testFailedEntryWithoutAudioHasNothingToRetry() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let record = try await failedEntry(model)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(record.audioPath))
        var calls = 0
        model.recordingTranscriber = { _ in calls += 1; return ("x", nil) }
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(model.preferences.historyRecords.first?.status, .failed)
    }

    // MARK: - 存下來的 .caf → 16 kHz 單聲道 PCM（給 Groq 重新辨識）

    private func writeSine(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double,
                           loudChannel: Int? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-type-decode-\(UUID().uuidString).caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                 channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let amplitude: Float = loudChannel == nil || loudChannel == channel ? 0.3 : 0
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = amplitude * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func peak(_ pcm: Data) -> Int16 {
        pcm.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map { abs(Int(raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) }
                .max().map { Int16(clamping: $0) } ?? 0
        }
    }

    func testStoredStereoRecordingDecodesTo16kMono() throws {
        let url = try writeSine(sampleRate: 48_000, channels: 2, seconds: 1)
        let pcm = try AudioCaptureSession.pcm16Mono16k(fromRecording: url, inputChannel: .average)
        // 1 秒 @ 16 kHz × 2 bytes ＝ 32,000；resampler 會留一小段在內部（同錄音當下的串流），容許 10%。
        XCTAssertGreaterThan(pcm.count, 28_800, "只轉出 \(pcm.count) bytes")
        XCTAssertLessThanOrEqual(pcm.count, 32_000 + 256)
        XCTAssertGreaterThan(peak(pcm), 6_000, "聲音要在")
    }

    func testStoredMonoRecordingAtOtherRateDecodes() throws {
        let url = try writeSine(sampleRate: 44_100, channels: 1, seconds: 0.5)
        let pcm = try AudioCaptureSession.pcm16Mono16k(fromRecording: url, inputChannel: .average)
        XCTAssertGreaterThan(pcm.count, 14_400)
        XCTAssertGreaterThan(peak(pcm), 6_000)
    }

    /// 指定聲道：跟錄音當下同一條整流——只取那一軌。
    func testStoredRecordingHonoursTheSelectedChannel() throws {
        let url = try writeSine(sampleRate: 48_000, channels: 2, seconds: 0.5, loudChannel: 1)
        let second = try AudioCaptureSession.pcm16Mono16k(fromRecording: url, inputChannel: .channel2)
        let first = try AudioCaptureSession.pcm16Mono16k(fromRecording: url, inputChannel: .channel1)
        XCTAssertGreaterThan(peak(second), 6_000)
        XCTAssertLessThan(peak(first), 100, "第 1 軌是靜音")
    }
}
