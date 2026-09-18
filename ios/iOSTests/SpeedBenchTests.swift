import XCTest
@preconcurrency import AVFAudio
@preconcurrency import Speech
#if canImport(Translation)
import Translation
#endif
@testable import UTUVOTypeiOS

/// 速度基準（非回歸測試）：`TEST_RUNNER_UTUVO_BENCH=1 xcodebuild test -only-testing:UTUVOTypeiOSTests/SpeedBenchTests`
/// 以「即時速度」把 zh-TW 測試音檔餵給辨識器，量第一段字出現與講完到定稿的時間；另量兩種翻譯引擎。
/// 結果行以 BENCH 開頭。
final class SpeedBenchTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UTUVO_BENCH"] == "1", "benchmark only")
    }

    private var sampleURL: URL {
        Bundle(for: Self.self).url(forResource: "zhtw-sample", withExtension: "wav")!
    }

    private func loadBuffers(format: AVAudioFormat?) throws -> (buffers: [AVAudioPCMBuffer], seconds: Double) {
        let file = try AVAudioFile(forReading: sampleURL)
        let src = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        let whole = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: total)!
        try file.read(into: whole)
        var working = whole
        if let format, format != src {
            let converter = AVAudioConverter(from: src, to: format)!
            let cap = AVAudioFrameCount(Double(total) * format.sampleRate / src.sampleRate) + 1024
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap)!
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return whole
            }
            working = out
        }
        let chunkFrames = AVAudioFrameCount(working.format.sampleRate * 0.1)
        var chunks: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < working.frameLength {
            let n = min(chunkFrames, working.frameLength - offset)
            let c = AVAudioPCMBuffer(pcmFormat: working.format, frameCapacity: n)!
            c.frameLength = n
            let ch = Int(working.format.channelCount)
            for i in 0..<ch {
                if let d = working.floatChannelData, let dd = c.floatChannelData {
                    dd[i].update(from: d[i].advanced(by: Int(offset)), count: Int(n))
                } else if let d = working.int16ChannelData, let dd = c.int16ChannelData {
                    dd[i].update(from: d[i].advanced(by: Int(offset)), count: Int(n))
                }
            }
            chunks.append(c)
            offset += n
        }
        return (chunks, Double(working.frameLength) / working.format.sampleRate)
    }

    // MARK: - 辨識

    func testBenchSFSpeechRecognizer() async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), recognizer.isAvailable else {
            print("BENCH SF unavailable"); return
        }
        let (chunks, secs) = try loadBuffers(format: nil)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if ProcessInfo.processInfo.environment["UTUVO_BENCH_HINTS"] == "1" { request.contextualStrings = ["Atmos", "ADM", "母帶", "交付規格"] }
        let t0 = Date()
        let box = BenchBox()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                box.mark(first: Date().timeIntervalSince(t0))
                box.text = result.bestTranscription.formattedString
                if result.isFinal { box.finalAt = Date() }
            }
            if let error { box.error = error.localizedDescription; box.finalAt = box.finalAt ?? Date() }
        }
        for c in chunks { request.append(c); try await Task.sleep(for: .milliseconds(100)) }
        let audioEnd = Date()
        request.endAudio()
        for _ in 0..<150 where box.finalAt == nil { try await Task.sleep(for: .milliseconds(100)) }
        task.cancel()
        print(String(format: "BENCH SF audio=%.1fs firstText=%.2fs endToFinal=%.2fs error=%@ text=%@",
                     secs, box.first ?? -1, box.finalAt.map { $0.timeIntervalSince(audioEnd) } ?? -1, box.error ?? "-", box.text))
    }

    func testBenchDictationTranscriber() async throws {
        guard #available(iOS 26.0, *) else { return }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-TW")) else {
            print("BENCH Dictation locale-unsupported"); return
        }
        let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        try await runAnalyzer(label: "Dictation(\(locale.identifier))", module: module) { module.results.map { ($0.text, $0.isFinal) } }
    }

    func testBenchSpeechTranscriber() async throws {
        guard #available(iOS 26.0, *) else { return }
        guard SpeechTranscriber.isAvailable else { print("BENCH SpeechTranscriber unavailable"); return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-TW")) else {
            print("BENCH SpeechTranscriber locale-unsupported"); return
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await runAnalyzer(label: "SpeechTranscriber(\(locale.identifier))", module: module) { module.results.map { ($0.text, $0.isFinal) } }
    }

    @available(iOS 26.0, *)
    private func runAnalyzer<S: AsyncSequence & Sendable>(label: String, module: any SpeechModule,
                                                         results: () -> S) async throws where S.Element == (AttributedString, Bool) {
        let tInstall = Date()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await req.downloadAndInstall()
        }
        let installSecs = Date().timeIntervalSince(tInstall)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (chunks, secs) = try loadBuffers(format: format)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        let t0 = Date()
        try await analyzer.start(inputSequence: stream)
        let box = BenchBox()
        let seq = results()
        let reader = Task {
            var finalized = ""
            do {
                for try await (text, isFinal) in seq {
                    box.mark(first: Date().timeIntervalSince(t0))
                    let s = String(text.characters)
                    if isFinal { finalized += s; box.text = finalized; box.finalAt = Date() } else { box.text = finalized + s }
                }
            } catch { box.error = error.localizedDescription }
        }
        for c in chunks { cont.yield(AnalyzerInput(buffer: c)); try await Task.sleep(for: .milliseconds(100)) }
        let audioEnd = Date()
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let endToFinal = Date().timeIntervalSince(audioEnd)
        _ = await reader.result
        print(String(format: "BENCH %@ install=%.1fs audio=%.1fs firstText=%.2fs endToFinal=%.2fs error=%@ text=%@",
                     label, installSecs, secs, box.first ?? -1, endToFinal, box.error ?? "-", box.text))
    }

    // MARK: - 標點

    /// 跟主 app 同一條路：buffer 即時餵辨識器＋LevelLog 記音量 → 靜音段斷句 → Apple Intelligence 補（長句）。
    @MainActor
    func testBenchPunctuation() async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), recognizer.isAvailable else {
            print("BENCH punct SF unavailable"); return
        }
        let file = try AVAudioFile(forReading: Bundle(for: Self.self).url(forResource: "zhtw-long", withExtension: "wav")!)
        let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: whole)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.064)   // 約等於 1024 frame @16k
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let levels = LevelLog()
        AIPunctuator.shared.prewarm()   // 跟 app 一樣：一開始錄就預熱
        let gate = OnceGate()
        var tokens: [TimedToken] = []
        var text = ""
        let done = OnceGate()
        let finished = AsyncStream<Void>.makeStream()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal, gate.claim() {
                tokens = result.bestTranscription.segments.map { TimedToken(text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                text = result.bestTranscription.formattedString
                if done.claim() { finished.continuation.finish() }
            } else if error != nil, done.claim() { finished.continuation.finish() }
        }
        var offset: AVAudioFrameCount = 0
        while offset < whole.frameLength {
            let n = min(chunk, whole.frameLength - offset)
            let c = AVAudioPCMBuffer(pcmFormat: whole.format, frameCapacity: n)!
            c.frameLength = n
            c.floatChannelData![0].update(from: whole.floatChannelData![0].advanced(by: Int(offset)), count: Int(n))
            request.append(c)
            levels.record(c)
            offset += n
            try await Task.sleep(for: .milliseconds(64))
        }
        let stop = Date()
        request.endAudio()
        for await _ in finished.stream {}
        let recognizeEnd = Date().timeIntervalSince(stop)
        task.cancel()
        let silences = SilenceDetector.intervals(levels.snapshot)
        print("BENCH punct recognizer(\(String(format: "%.2f", recognizeEnd))s): \(text)")
        print("BENCH punct silences: " + silences.map { String(format: "%.2f+%.2f", $0.start, $0.duration) }.joined(separator: " "))
        let paused = PausePunctuator.punctuate(tokens, silences: silences)
        print("BENCH punct pause: \(paused) keepsText=\(PunctuationGuard.preservesText(original: text, candidate: paused))")
        for run in 1...2 {
            if run == 2 { AIPunctuator.shared.prewarm(); try await Task.sleep(for: .seconds(3)) }
            let t0 = Date()
            let refined = await AIPunctuator.shared.refine(paused, timeout: .seconds(6))
            print(String(format: "BENCH punct AI run%d %.2fs: %@", run, Date().timeIntervalSince(t0), refined ?? "nil (timeout/rejected/unavailable)"))
        }
    }

    // MARK: - 翻譯

    private let sentence = "明天下午三點我們在錄音室對 Atmos 母帶，記得帶 ADM 檔案，然後順便確認一下交付規格。"

    func testBenchTranslateFoundationModels() async throws {
        let target = TranslationTarget.all.first { $0.code == "en" }!
        for run in 1...2 {
            let t0 = Date()
            do {
                let out = try await OnDeviceAssistant.translate(sentence, to: target)
                print(String(format: "BENCH translate.FM run%d %.2fs %@", run, Date().timeIntervalSince(t0), out))
            } catch {
                print("BENCH translate.FM error \(error.localizedDescription)"); return
            }
        }
    }

    @MainActor
    func testBenchFastTranslatorPrewarmed() async throws {
        let t0 = Date()
        await FastTranslator.shared.prewarm(sourceRaw: "zh-TW", targetCode: "en")
        let prewarm = Date().timeIntervalSince(t0)
        let t1 = Date()
        let out = try await FastTranslator.shared.translate(sentence, sourceRaw: "zh-TW", targetCode: "en")
        print(String(format: "BENCH FastTranslator prewarm=%.2fs translateAfterPrewarm=%.2fs %@", prewarm, Date().timeIntervalSince(t1), out))
    }

    func testBenchTranslateFramework() async throws {
        guard #available(iOS 26.0, *) else { return }
        let src = Locale.Language(identifier: "zh-Hant")
        let dst = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: src, to: dst)
        print("BENCH translate.TF status \(status)")
        let session = TranslationSession(installedSource: src, target: dst)
        for run in 1...2 {
            let t0 = Date()
            do {
                let out = try await session.translate(sentence)
                print(String(format: "BENCH translate.TF run%d %.2fs %@", run, Date().timeIntervalSince(t0), out.targetText))
            } catch {
                print("BENCH translate.TF error \(error.localizedDescription)"); return
            }
        }
    }
}

final class BenchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _first: Double?, _text = "", _finalAt: Date?, _error: String?
    var first: Double? { lock.withLock { _first } }
    func mark(first t: Double) { lock.withLock { if _first == nil { _first = t } } }
    var text: String { get { lock.withLock { _text } } set { lock.withLock { _text = newValue } } }
    var finalAt: Date? { get { lock.withLock { _finalAt } } set { lock.withLock { _finalAt = newValue } } }
    var error: String? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
}
