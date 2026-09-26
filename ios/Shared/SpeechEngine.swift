import Foundation
@preconcurrency import AVFAudio
import Speech

/// 辨識結果回呼：(目前全文, 是否定稿, 錯誤碼, 錯誤訊息, 定稿時的片段時間戳)。兩個引擎共用，呼叫端邏輯不用分。
typealias SpeechResultHandler = @MainActor @Sendable (String?, Bool, Int?, String?, [TimedToken]) -> Void

/// 一次辨識工作階段。append 在音訊執行緒呼叫；endAudio／cancel 在主執行緒。
protocol SpeechStream: AnyObject, Sendable {
    /// 給狀態／除錯用："analyzer"（SpeechTranscriber）或 "legacy"（SFSpeechRecognizer）。
    var engineName: String { get }
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
    func cancel()
}

/// 麥克風 → 辨識的接頭（音訊執行緒與主執行緒共用）。
/// 新引擎建起來要一點時間（查模型、設提示詞、開 analyzer）；這段期間講的話先存著，接上後依序補送，開頭不掉字。
final class SpeechFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SpeechStream?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var armed = false
    /// 最多先存 10 秒（48 kHz）；引擎一直起不來就丟最舊的，不讓記憶體長上去。
    static let maxPendingFrames: AVAudioFramePosition = 48_000 * 10

    var current: SpeechStream? { lock.lock(); defer { lock.unlock() }; return stream }

    /// 開始新的一次：之後進來的音訊先存著，等 attach。
    func arm() {
        lock.lock(); armed = true; stream = nil; pending.removeAll(); pendingFrames = 0; lock.unlock()
    }

    /// 接上引擎並補送先存的音訊（在鎖裡補送，保證順序）。
    func attach(_ s: SpeechStream) {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return }
        for b in pending { s.append(b) }
        pending.removeAll(); pendingFrames = 0
        stream = s
    }

    /// 結束這次：之後的音訊丟掉。回傳原本接著的引擎（呼叫端決定 endAudio 或 cancel）。
    @discardableResult
    func disarm() -> SpeechStream? {
        lock.lock(); defer { lock.unlock() }
        armed = false
        pending.removeAll(); pendingFrames = 0
        let s = stream; stream = nil
        return s
    }

    /// 音訊執行緒。
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let stream { stream.append(buffer); return }
        guard armed, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        pending.append(copy)
        pendingFrames += AVAudioFramePosition(copy.frameLength)
        while pendingFrames > Self.maxPendingFrames, !pending.isEmpty {
            pendingFrames -= AVAudioFramePosition(pending.removeFirst().frameLength)
        }
    }
}

enum SpeechEngine {
    /// 設 true＝強制用舊引擎（對照／緊急退路）。預設新引擎。
    static let legacyKey = "utuvo.type.speech.legacyEngine"

    /// 新引擎（SpeechTranscriber，iOS 26+）能用就用，否則舊引擎（SFSpeechRecognizer）。
    /// 2026-09-19 Mac 同模型實測（48 段：美佳／婷婷 × 正常／快 × 乾淨／噪音＋回音）：
    /// 字錯率 舊 22.6% → 新 8.0%；快語速 33.9% → 8.3%；舊模型長句會整段掉詞。
    /// 新引擎模型還沒下載時，這次先用舊的、背景下載，下次就是新的。
    @MainActor
    static func start(language: String, legacy recognizer: SFSpeechRecognizer?, onDevice: Bool,
                      contextualStrings: [String], onResult: @escaping SpeechResultHandler) async -> SpeechStream? {
        // RUNTIME-INTEGRATION-FINDINGS #3：提示詞在入口組一次，Legacy 與 Analyzer 吃同一份
        // （個人字典／聯絡人優先 → 產品名 → VocabularyPacks.contextualHints() 的公平輪流 seed，上限 200）。
        // 先前只有 Analyzer 有補詞庫 hints、Legacy 只吃呼叫端的 100 詞——legacy 引擎下新詞庫完全沒進提示詞。
        let hints = Self.unifiedHints(personal: contextualStrings)
        if onDevice, !UserDefaults.standard.bool(forKey: legacyKey), #available(iOS 26.0, *),
           let analyzer = await AnalyzerSpeechStream.make(language: language, contextualStrings: hints, onResult: onResult) {
            return analyzer
        }
        guard let recognizer else { return nil }
        return LegacySpeechStream(recognizer: recognizer, onDevice: onDevice, contextualStrings: hints, onResult: onResult)
    }

    /// 統一提示詞：呼叫端的個人詞（含文字替換／聯絡人）在最前，補產品名與詞庫 hints，去重後上限 200。
    /// 純函式，測試直接打這裡驗證 Legacy／Analyzer 同源。
    static func unifiedHints(personal: [String]) -> [String] {
        var seen = Set<String>()
        return Array((personal + ["UTUVO Type", "UTUVO"] + VocabularyPacks.contextualHints())
            .filter { seen.insert($0).inserted }
            .prefix(200))
    }
}

// MARK: - 舊引擎（SFSpeechRecognizer）

final class LegacySpeechStream: SpeechStream, @unchecked Sendable {
    let engineName = "legacy"
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer, onDevice: Bool, contextualStrings: [String], onResult: @escaping SpeechResultHandler) {
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // 個人字典的詞當提示（實機實測 Atmos→Amis、ADM→EDM）；辨識器上限 100 條。
        request.contextualStrings = contextualStrings
        request.requiresOnDeviceRecognition = onDevice
        task = Self.makeTask(recognizer: recognizer, request: request, onResult: onResult)
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func endAudio() { request.endAudio() }
    func cancel() { task?.cancel() }

    /// nonisolated：辨識回呼在背景執行緒，不能繼承 MainActor（Swift 6 執行期 SIGTRAP）。
    nonisolated private static func makeTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                             onResult: @escaping SpeechResultHandler) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let code = (error as NSError?)?.code
            let message = error?.localizedDescription
            // 定稿才需要時間戳（停頓補標點）；partial 不用，省成本。
            let tokens: [TimedToken] = isFinal ? (result?.bestTranscription.segments.map {
                TimedToken(text: $0.substring, start: $0.timestamp, duration: $0.duration)
            } ?? []) : []
            Task { @MainActor in onResult(text, isFinal, code, message, tokens) }
        }
    }
}

// MARK: - 新引擎（SpeechAnalyzer＋SpeechTranscriber）

@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerSpeechStream: SpeechStream, @unchecked Sendable {
    let engineName = "analyzer"
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private var resultsTask: Task<Void, Never>?
    private var cancelled = false

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.targetFormat = format
        self.continuation = continuation
    }

    /// 回 nil＝這次用不了（語言不支援、模型還沒下載、啟動失敗），呼叫端退回舊引擎。
    static func make(language: String, contextualStrings: [String], onResult: @escaping SpeechResultHandler) async -> AnalyzerSpeechStream? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        guard installed else {
            // 第一次：背景下載這個語言的模型，這次先用舊引擎。
            Task.detached {
                if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try? await request.downloadAndInstall()
                }
            }
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // 提示詞（RUNTIME-INTEGRATION-FINDINGS #3）：由 SpeechEngine.start 統一組一次傳進來
        // （個人詞優先 → 產品名 → VocabularyPacks.contextualHints() 公平輪流，上限 200），
        // 與 Legacy 引擎同一份；這裡不再自行 merge。
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(200))
            try? await analyzer.setContext(context)
        }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let stream = AnalyzerSpeechStream(analyzer: analyzer, format: format, continuation: continuation)
        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            continuation.finish()
            return nil
        }
        // 繁中：新引擎的繁體是逐字硬轉（回家→迴家、頭髮→頭發），按詞重轉一次（TraditionalFixer）。
        let traditional = language.hasPrefix("zh-TW") || language.hasPrefix("zh-Hant") || language.hasPrefix("zh-HK")
        stream.resultsTask = Task.detached {
            await Self.collect(transcriber, traditional: traditional, onResult: onResult)
        }
        return stream
    }

    /// 定稿片段累加；未定稿（volatile）的接在後面當即時預覽。結果流結束＝整段定稿。
    private static func collect(_ transcriber: SpeechTranscriber, traditional: Bool, onResult: @escaping SpeechResultHandler) async {
        // 繁中：先修逐字硬轉，再救讀音相同的錯字站名（元山站→圓山站）。
        let fix: (String) -> String = traditional ? { TaiwanPlaces.fixStations(TraditionalFixer.shared.fix($0)) } : { $0 }
        var finalized = AttributedString()
        var tokens: [TimedToken] = []
        do {
            for try await result in transcriber.results {
                if result.isFinal {
                    finalized += result.text
                    tokens += timedTokens(result.text)
                    let text = fix(String(finalized.characters))
                    await MainActor.run { onResult(text, false, nil, nil, []) }
                } else {
                    let text = fix(String((finalized + result.text).characters))
                    await MainActor.run { onResult(text, false, nil, nil, []) }
                }
            }
            let text = fix(String(finalized.characters))
            let finalTokens = traditional ? TraditionalFixer.shared.fix(tokens: tokens, extra: TaiwanPlaces.fixStations) : tokens
            await MainActor.run { onResult(text, true, nil, nil, finalTokens) }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { onResult(nil, false, -1, message, []) }
        }
    }

    /// 每個有時間範圍的 run 當一個片段（停頓補標點用）。
    static func timedTokens(_ text: AttributedString) -> [TimedToken] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { return nil }
            return TimedToken(text: piece, start: range.start.seconds, duration: range.duration.seconds)
        }
    }

    /// 音訊執行緒：轉成模型要的格式送進去。
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation, !cancelled, buffer.frameLength > 0 else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    /// 講完：關掉輸入，讓 analyzer 把最後一段定稿（結果流結束時回呼 isFinal）。
    func endAudio() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
        let analyzer = analyzer
        Task.detached { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task.detached { await analyzer.cancelAndFinishNow() }
    }
}
