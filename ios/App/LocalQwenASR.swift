import Foundation
import UIKit
@preconcurrency import AVFAudio
import UTUVOTypeCore
#if !targetEnvironment(simulator)
import Qwen3ASR
import MLX
#endif

/// 本機高準確度辨識：Qwen3-ASR 0.6B（MLX，裝置端，音訊不離機）。2026-09-24 Micky 核准 iPhone 方案 a。
///
/// iPhone 17 Pro Max 實機（24 段 zh-TW 合成語音，含專有名詞）：Apple SpeechTranscriber 字錯率 28.4%、
/// Qwen3-ASR＋個人字典熱詞 11.2%；每段約 6 秒的話 0.21 秒辨識完；模型已在手機上時載入 1.6 秒；
/// MLX 快取上限 128 MB 時峰值 1.3 GB、閒置常駐 786 MB。
///
/// 用法：鍵盤即時字幕照舊用 Apple 引擎；講完後用這裡對整段錄音重辨識，當作最後貼出的文字。
/// 模型沒下載、載入失敗、逾時或輸出不像話 → 回 nil，呼叫端用 Apple 的結果。
@MainActor
final class LocalQwenASR: ObservableObject {
    static let shared = LocalQwenASR()
    static let modelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static let downloadMB = 712
    /// 鍵盤工作階段結束後多久把模型移出記憶體。
    static let idleUnload: Duration = .seconds(300)

    enum State: Equatable {
        case unsupported            // 模擬器（MLX 需要實機 GPU）
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State
    private let engine = QwenEngine()
    private var unloadTask: Task<Void, Never>?

    private var memoryObserver: NSObjectProtocol?

    private init() {
        #if targetEnvironment(simulator)
        state = .unsupported
        #else
        state = Self.isDownloaded ? .ready : .notDownloaded
        #endif
        // 閒置常駐約 786 MB：系統喊記憶體不足就先放掉，下次講話時再載（約 1.6 秒，期間用 Apple 的結果）。
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { LocalQwenASR.shared.unloadNow() } }
    }

    // MARK: - 下載與儲存（Application Support，不進 iCloud 備份）

    nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QwenASR/Qwen3-ASR-0.6B-MLX-4bit", isDirectory: true)
    }

    /// 下載完成才寫 .complete：中斷的半套模型不算已安裝。
    nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(".complete").path)
    }

    /// 2026-09-24 實機：iOS 不准背景 App 用 GPU——鍵盤聽寫時主 app 在背景，MLX 一送 Metal 指令就被 abort
    /// （mlx::core::gpu::check_error，連續 5 次當機，鍵盤卡在「整理中」）。只在 app 位於前景時才用。
    var isReady: Bool { state == .ready && UIApplication.shared.applicationState == .active }
    var isDownloaded: Bool { state == .ready }

    func download() async {
        #if !targetEnvironment(simulator)
        if case .downloading = state { return }
        state = .downloading(0)
        do {
            var dir = Self.cacheDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try await engine.load(cacheDirectory: dir, offline: false) { progress in
                Task { @MainActor in
                    if case .downloading = LocalQwenASR.shared.state { LocalQwenASR.shared.state = .downloading(progress) }
                }
            }
            try Data().write(to: dir.appendingPathComponent(".complete"))
            state = .ready
            scheduleUnload()
        } catch {
            state = .failed(error.localizedDescription)
        }
        #endif
    }

    func delete() async {
        await engine.unload()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        #if targetEnvironment(simulator)
        state = .unsupported
        #else
        state = .notDownloaded
        #endif
    }

    // MARK: - 辨識

    /// 開始錄音就先載入（實機約 1.6 秒），講完時多半已經好了。
    func prewarm() {
        guard isReady else { return }
        unloadTask?.cancel()
        let engine = engine, dir = Self.cacheDirectory
        Task.detached(priority: .userInitiated) { try? await engine.load(cacheDirectory: dir, offline: true, progress: nil) }
    }

    /// 整段錄音（16 kHz 單聲道）→ 文字。回 nil＝用 Apple 的結果。
    func transcribe(_ samples: [Float], language: String, hotwords: [String]) async -> String? {
        guard isReady, let qwenLanguage = Self.qwenLanguage(for: language), samples.count >= 16_000 / 4 else { return nil }
        unloadTask?.cancel()
        let seconds = Double(samples.count) / 16_000
        // 模型沒載好也要載：冷啟動 1.6 秒＋辨識；總上限依錄音長度，逾時就用 Apple 的結果（寧可快也不要卡）。
        let limit = Duration.seconds(min(20, 3 + seconds * 0.5))
        let context = hotwords.prefix(80).joined(separator: ", ")
        let engine = engine, dir = Self.cacheDirectory
        let raw: String? = await Self.race(limit) {
            try? await engine.load(cacheDirectory: dir, offline: true, progress: nil)
            return await engine.transcribe(samples, language: qwenLanguage, context: context, maxTokens: Self.tokenCap(seconds))
        }
        scheduleUnload()
        guard let raw, let text = Self.clean(raw, language: language), !Self.looksLooping(text, seconds: seconds) else { return nil }
        return text
    }

    func scheduleUnload() {
        unloadTask?.cancel()
        let engine = engine
        unloadTask = Task {
            do { try await Task.sleep(for: Self.idleUnload) } catch { return }
            await engine.unload()
        }
    }

    func unloadNow() { unloadTask?.cancel(); let engine = engine; Task { await engine.unload() } }

    // MARK: - 純函式（可測）

    /// Qwen3-ASR 原生的語言提示（與 Mac 版 runtime 相同寫法）；不支援的語言回 nil＝不用 Qwen。
    nonisolated static func qwenLanguage(for language: String) -> String? {
        if language.hasPrefix("zh") { return "Chinese" }
        if language.hasPrefix("en") { return "English" }
        return nil
    }

    /// 約每秒 8 token、至少 256：講話用不到更多，模型卡迴圈時也會提早停。
    nonisolated static func tokenCap(_ seconds: Double) -> Int { max(256, Int(seconds * 8) + 64) }

    /// 本體在 `TranscriptGuard`（Shared，Mac 量測工具也用得到）；這兩個名字留著給既有呼叫端與測試。
    nonisolated static func clean(_ raw: String, language: String) -> String? {
        TranscriptGuard.clean(raw, language: language)
    }

    nonisolated static func looksLooping(_ text: String, seconds: Double) -> Bool {
        TranscriptGuard.looksLooping(text, seconds: seconds)
    }

    /// 先到先贏；逾時不等工作結束（MLX 推論不能中途取消，讓它在背景跑完）。
    nonisolated static func race<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let gate = OnceGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task.detached(priority: .userInitiated) {
                let value = await work()
                if gate.claim() { cont.resume(returning: value) }
            }
            Task.detached {
                try? await Task.sleep(for: limit)
                if gate.claim() { cont.resume(returning: nil) }
            }
        }
    }
}

/// 模型只在這個 actor 裡碰（Qwen3ASRModel 不是 Sendable）；推論在 actor 的背景執行緒上跑，不佔主執行緒。
actor QwenEngine {
    #if !targetEnvironment(simulator)
    private var model: Qwen3ASRModel?
    #endif

    func load(cacheDirectory: URL, offline: Bool, progress: (@Sendable (Double) -> Void)?) async throws {
        #if !targetEnvironment(simulator)
        guard model == nil else { return }
        // 快取上限 128 MB：實機峰值 2.2 GB → 1.3 GB，速度不變。
        MLX.Memory.cacheLimit = 128 * 1024 * 1024
        model = try await Qwen3ASRModel.fromPretrained(modelId: LocalQwenASR.modelId, cacheDir: cacheDirectory,
                                                       offlineMode: offline) { value, _ in progress?(value) }
        #endif
    }

    func transcribe(_ samples: [Float], language: String, context: String, maxTokens: Int) -> String? {
        #if !targetEnvironment(simulator)
        guard let model else { return nil }
        return model.transcribe(audio: samples, sampleRate: 16_000, language: language, maxTokens: maxTokens,
                                context: context.isEmpty ? nil : context)
        #else
        return nil
        #endif
    }

    func unload() {
        #if !targetEnvironment(simulator)
        model?.unload()
        model = nil
        MLX.Memory.clearCache()
        #endif
    }
}

/// 錄音中把麥克風音訊轉成 16 kHz 單聲道 Float 存起來（音訊執行緒寫、主執行緒讀）。上限 10 分鐘。
final class PCMAccumulator: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let maxSamples = 16_000 * 600
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var enabled = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    func reset(enabled: Bool) {
        lock.lock(); samples.removeAll(keepingCapacity: true); converter = nil; self.enabled = enabled; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, buffer.frameLength > 0, samples.count < Self.maxSamples else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, input in
            if consumed { input.pointee = .noDataNow; return nil }
            consumed = true; input.pointee = .haveData; return buffer
        }
        guard status != .error, let data = out.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// 取整段錄音。先把轉換器裡還沒吐出的尾巴放出來（重取樣會留約 60 ms 在內部；實測 1 秒只拿到 15,013／16,000 個樣本，
    /// 句尾最後一個字可能就在那裡）。放完後轉換器作廢，之後再 append 會重建。
    var snapshot: [Float] {
        lock.lock(); defer { lock.unlock() }
        if let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096) {
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, input in input.pointee = .endOfStream; return nil }
            if status != .error, let data = out.floatChannelData?[0], out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            self.converter = nil
        }
        return samples
    }
}
