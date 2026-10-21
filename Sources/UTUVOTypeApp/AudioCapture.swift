import Foundation
import OSLog
@preconcurrency import AVFoundation
@preconcurrency import Speech

private let audioLog = Logger(subsystem: "com.utuvo.type", category: "audio")

struct AudioCaptureResult: Sendable {
    let audioURL: URL
    let speechTranscript: String
    let duration: TimeInterval
    /// 整段錄音的峰值（dBFS）與實際寫進檔案的格數：判斷「麥克風其實沒收到聲音」與「0 秒空檔」。
    var peakDBFS: Float = 0
    var framesWritten: Int64 = 1
    /// 這次實際使用的輸入裝置名稱（給使用者看的提示）。
    var inputDeviceName: String = ""
}

extension AudioCaptureResult {
    /// 峰值低於這個＝幾乎沒收到聲音（2026-09-24 實機：AirPods 搶走輸入，max −39～−43 dB）。
    static let silentPeakDBFS: Float = -35
    var soundsSilent: Bool { peakDBFS < Self.silentPeakDBFS }
}

enum AudioCaptureError: Error, CustomStringConvertible {
    case microphoneDenied
    case noInputDevice
    case engineStartFailed(String)
    case audioFileFailed(String)

    var description: String {
        switch self {
        case .microphoneDenied: return "麥克風權限未開啟"
        case .noInputDevice: return "找不到可用的麥克風"
        case .engineStartFailed(let message): return "麥克風啟動失敗：\(message)"
        case .audioFileFailed(let message): return "音訊暫存失敗：\(message)"
        }
    }
}

/// 多聲道 → 單聲道：只平均「這格 buffer 裡真的有訊號」的聲道。
///
/// 多軌介面卡（MTRX／BlackHole 64ch 之類）只在一兩軌接人聲，其餘是數位靜音。
/// 把 64 軌全部平均會讓唯一有訊號的那軌被稀釋 10·log10(64) ≈ 36 dB，
/// ASR 只聽得到氣音、吐出空字串（2026-10-14 實機）。雙軌以下維持原本的平均，
/// 因為那種情況下各軌都是真的在錄東西。
enum AudioChannelDownmix {
    /// −60 dBFS。數位靜音與一般麥克風的雜訊地板都在這以下，要辨識的語音遠高於它。
    static let activePeakThreshold: Float = 0.001

    /// 這個 buffer 的輸出聲道數超過 2 才有理由自己混（見 AudioCaptureSession）。
    static func needsManualDownmix(channelCount: Int) -> Bool { channelCount > 2 }

    /// 政策核心：這一次該平均哪些聲道的 meanSquares。
    ///
    /// - `sticking`：黏性遮罩（`AudioChannelActivity` 在一次錄音裡累積的那一份）。
    ///   `nil`＝≤2 軌，維持原本的直接平均。
    /// - 遮罩還沒黏住任何一軌（＝整段都沒有聲道過門檻）時退回全部平均，
    ///   這樣真的安靜時安靜偵測才會成立。
    /// - 回 `nil` 代表沒有聲道可以平均。
    static func averageMeanSquare(meanSquares: [Double], sticking: [Bool]?) -> Double? {
        guard !meanSquares.isEmpty else { return nil }
        guard let sticking, sticking.contains(true) else {
            return meanSquares.reduce(0, +) / Double(meanSquares.count)
        }
        var sum: Double = 0
        var used = 0
        for (index, value) in meanSquares.enumerated() where index < sticking.count && sticking[index] {
            sum += value
            used += 1
        }
        return used > 0 ? sum / Double(used) : nil
    }

    /// 這一格峰值過門檻的聲道。一次錄音的黏性集合是逐格 union 起來的
    /// （見 `AudioChannelActivity.updateSticky`）。
    static func aboveThreshold(channels: Int, peaks: [Float],
                               threshold: Float = activePeakThreshold) -> [Bool] {
        var mask = [Bool](repeating: false, count: max(0, channels))
        for channel in 0..<min(channels, peaks.count) where peaks[channel] > threshold {
            mask[channel] = true
        }
        return mask
    }
}

/// 為了對齊輸入格式而臨時接上去的節點，其生命週期。
///
/// mac-input-repair1 #1：節點 attach 了卻只在「下一次 start」才拆，stop／cancel／
/// 啟動失敗三條路徑都會把它留在 graph 上（熱插拔或啟動失敗時更是永遠不會有下一次 start）。
/// 反過來，對**沒有接過線**的節點呼叫 `disconnectNodeOutput` 也不是 AVFoundation 的契約：
/// stop 路徑上 input 早已沒有出線。所以每一步都先確認真的有接線。
enum AudioEngineGraph {
    /// 拆掉 `node`（連帶它接在 `input` 出線上的那一條）。回傳這次有沒有真的拆掉東西。
    @discardableResult
    static func detach(_ node: AVAudioMixerNode?, from engine: AVAudioEngine, input: AVAudioNode) -> Bool {
        guard let node, engine.attachedNodes.contains(node) else { return false }
        if !engine.outputConnectionPoints(for: input, outputBus: 0).isEmpty {
            engine.disconnectNodeOutput(input)
        }
        if !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty {
            engine.disconnectNodeOutput(node)
        }
        engine.detach(node)
        return true
    }
}

enum PermissionGate {
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }
}

/// Captures one microphone session. The raw PCM stream is consumed by the
/// Bailian WebSocket adapter; a CAF file is retained only for a configured
/// local ASR process. No audio is persisted after the session finishes.
final class AudioCaptureSession: @unchecked Sendable {
    private final class ConverterInputState: @unchecked Sendable {
        var supplied = false
    }

    private let lock = NSLock()
    private let voiceLevel = LiveVoiceLevel()
    var currentVoiceLevel: Float? { voiceLevel.read() }
    private let engine = AVAudioEngine()
    /// 只為了讓換裝置後的輸入格式重新對齊而接上去的節點。start／stop／cancel／啟動失敗
    /// 都會拆掉它，否則同一個 session 連續 start/stop 會在 graph 上愈疊愈多節點
    /// （mac-input-repair1 #1）。
    private var formatNegotiationNode: AVAudioMixerNode?
    /// 一次錄音共用的「哪些聲道真的有訊號」（黏性）。downmix、電平表、安靜偵測共用這一份。
    let channelActivity = AudioChannelActivity()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    var converter: AVAudioConverter?
    /// converter 的輸入狀態重複使用；每次 `convert` 前清成 false。
    private let converterInputState = ConverterInputState()
    /// 轉換輸出緩衝：`start` 時依 tap 的 bufferSize 配好，tap 裡不再配置記憶體。
    var conversionOutputBuffer: AVAudioPCMBuffer?
    /// 單軌化用的緩衝（同樣在 `start` 配好、重複使用）。
    var monoConversionBuffer: AVAudioPCMBuffer?
    /// 這一格要不要先混／抽軌成單軌才送進 converter（`makeConversionInputFormat` 的判斷）。
    var needsMonoConversion = false
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechText = ""
    private var audioURL: URL?
    private var startedAt: Date?
    private var isRunning = false
    private let inputDeviceUID: String?
    private let inputChannel: AudioInputChannel
    private let transcriptionLanguageIdentifier: String
    private let outputDeviceUID: String?
    private let muteWhileRecording: Bool
    var conversionInputFormat: AVAudioFormat?
    private var mutedOutputDeviceUID: String?
    private var previousOutputMute: Bool?
    private let voiceActivityDetection: Bool
    private var detectedVoice = false
    private var lastVoiceAt: Date?
    private var silenceTriggered = false

    init(
        inputDeviceUID: String? = nil,
        inputChannel: AudioInputChannel = .average,
        transcriptionLanguageIdentifier: String = "zh-TW",
        outputDeviceUID: String? = nil,
        muteWhileRecording: Bool = false,
        voiceActivityDetection: Bool = true
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.inputChannel = inputChannel
        self.transcriptionLanguageIdentifier = transcriptionLanguageIdentifier
        self.outputDeviceUID = outputDeviceUID
        self.muteWhileRecording = muteWhileRecording
        self.voiceActivityDetection = voiceActivityDetection
    }

    var onPartial: (@Sendable (String) -> Void)?
    var onSilenceDetected: (@Sendable () -> Void)?
    /// 錄音中輸入裝置被換掉（例如 AirPods 連上）：AVAudioEngine 會停，之後的聲音收不到。
    var onInputDeviceChanged: (@Sendable () -> Void)?
    private var peakLinear: Float = 0
    private var framesWritten: Int64 = 0
    private var configurationObserver: NSObjectProtocol?

    /// 目前（最近一次 start）使用的輸入裝置名稱。
    private(set) var inputDeviceName = ""

    /// 到目前為止的峰值（dBFS）；錄音中顯示「好像沒收到聲音」用。
    var peakDBFSSoFar: Float {
        lock.lock(); defer { lock.unlock() }
        return peakLinear > 0 ? 20 * log10(peakLinear) : -160
    }

    func start(enableSpeechFallback: Bool) throws -> AsyncThrowingStream<Data, Error> {
        guard !isRunning else { throw AudioCaptureError.engineStartFailed("已有錄音工作") }
        voiceLevel.clear()
        // 黏性集合是「一次錄音」範圍的：新錄音從空白開始。
        channelActivity.reset()
        channelActivity.selectedChannel = inputChannel.channelIndex
        if let inputDeviceUID, !inputDeviceUID.isEmpty,
           !AudioDeviceCatalog.setCurrentInputDevice(uid: inputDeviceUID, on: engine.inputNode.audioUnit) {
            throw AudioCaptureError.noInputDevice
        }
        muteOutputIfRequested()
        let effectiveUID = (inputDeviceUID?.isEmpty == false ? inputDeviceUID : nil) ?? AudioDeviceCatalog.defaultInputUID()
        inputDeviceName = effectiveUID.flatMap { uid in AudioDeviceCatalog.inputDevices().first { $0.id == uid }?.name } ?? ""
        lock.lock(); peakLinear = 0; framesWritten = 0; lock.unlock()
        let format = resolveInputFormat(deviceUID: effectiveUID)
        let input = engine.inputNode
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("utuvo-type-\(UUID().uuidString).caf")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            throw AudioCaptureError.audioFileFailed(error.localizedDescription)
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
        conversionInputFormat = makeConversionInputFormat(from: format)
        converter = outputFormat.flatMap {
            AVAudioConverter(from: conversionInputFormat ?? format, to: $0)
        }
        prepareConversionBuffers(for: format)
        audioURL = url
        startedAt = Date()
        speechText = ""
        detectedVoice = false
        silenceTriggered = false
        lastVoiceAt = Date()

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }

        if enableSpeechFallback {
            startOnDeviceSpeechIfAvailable(languageIdentifier: transcriptionLanguageIdentifier)
        }

        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // 一次掃描，全錄音共用：黏性集合 → downmix、電平表、安靜偵測。
            self.channelActivity.measure(buffer)
            self.voiceLevel.publish(rms: self.channelActivity.averageRMS)
            do {
                try file.write(from: buffer)
            } catch {
                self.finishStream(throwing: error)
                return
            }
            self.lock.lock()
            self.peakLinear = max(self.peakLinear, self.peak(of: buffer))
            self.framesWritten += Int64(buffer.frameLength)
            self.lock.unlock()

            if let data = self.convertToPCM16Mono(self.bufferForConversion(buffer)) {
                self.lock.lock()
                self.continuation?.yield(data)
                let request = self.speechRequest
                self.lock.unlock()
                request?.append(buffer)
            }
            if self.voiceActivityDetection, self.shouldFinishForSilence() {
                self.onSilenceDetected?()
            }
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onInputDeviceChanged?() }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            detachFormatNegotiationNode()
            restoreOutputMute()
            finishStream(throwing: error)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
        isRunning = true
        return stream
    }

    /// tap 的 bufferSize。單軌化與轉換輸出的緩衝都依它一次配好，
    /// tap thread 上才不會每格都在配置記憶體。
    static let tapBufferSize: AVAudioFrameCount = 2_048

    /// 這個 buffer 的峰值（線性）。不配置任何記憶體。
    private func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0 ..< Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for index in 0 ..< Int(buffer.frameLength) {
                let value = samples[index]
                guard value.isFinite else { continue }
                peak = max(peak, abs(value))
            }
        }
        return peak
    }

    /// 換輸入裝置之後，已經建好的 `AVAudioEngine` 還帶著**舊**（預設）裝置的格式：
    /// `inputNode.outputFormat(forBus: 0)` 回的是舊裝置的格式，但資料其實已經來自
    /// 新裝置，結果就是「2 軌的 BlackHole 錄成 64 軌的檔」，多出的軌是數位靜音，
    /// 平均之後人聲被稀釋掉約 36 dB（2026-10-14 實測）。
    ///
    /// 換掉整支 engine 沒用（節點一建立就把格式定死了）。可行的是用節點自己的
    /// `inputFormat(forBus: 0)`——那才是裝置真正的格式——重新接一次出線，
    /// `outputFormat` 就會跟著換。重接有風險（接不成就退回去，維持原狀）。
    private func resolveInputFormat(deviceUID uid: String?) -> AVAudioFormat {
        let input = engine.inputNode
        detachFormatNegotiationNode()

        var format = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        // 只有「所選裝置的聲道數／取樣率跟 tap 拿到的格式不同」才重接。
        // 1～2 軌的一般麥克風兩個條件都不成立 → 完全不會接節點，行為一字不改。
        // 取樣率也要比：44.1k 的裝置接在 48k 的 graph 上，只比聲道數會漏掉。
        let usableHardware = hardware.sampleRate > 0 && hardware.channelCount > 0
        let channelMismatch = usableHardware && hardware.channelCount != format.channelCount
        let rateMismatch = usableHardware && hardware.sampleRate != format.sampleRate
        if channelMismatch || rateMismatch {
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(input, to: mixer, format: hardware)
            let renegotiated = input.outputFormat(forBus: 0)
            if renegotiated.channelCount == hardware.channelCount,
               renegotiated.sampleRate == hardware.sampleRate {
                audioLog.info(
                    "input format \(format.channelCount)ch@\(format.sampleRate)Hz → \(renegotiated.channelCount)ch@\(renegotiated.sampleRate)Hz to match device"
                )
                format = renegotiated
                formatNegotiationNode = mixer
            } else {
                audioLog.error("could not renegotiate input format; keeping \(format.channelCount, privacy: .public)ch")
                AudioEngineGraph.detach(mixer, from: engine, input: input)
            }
        }

        if let uid, let expected = AudioDeviceCatalog.inputChannelCount(uid: uid), expected > 0,
           Int(format.channelCount) != expected {
            audioLog.error(
                "recording \(format.channelCount)ch from a \(expected)ch device; channel mix will be wrong"
            )
        }
        return format
    }

    /// 拆掉為了對齊輸入格式接上去的節點。start／stop／cancel／啟動失敗四條路徑都要呼叫。
    private func detachFormatNegotiationNode() {
        guard let node = formatNegotiationNode else { return }
        AudioEngineGraph.detach(node, from: engine, input: engine.inputNode)
        formatNegotiationNode = nil
    }

    /// 測試用：目前掛在 engine 上的節點數。attach 漏拆時這個數字只增不減。
    var attachedNodeCount: Int { engine.attachedNodes.count }

    /// `speechGrace`＝等 Apple 語音預覽收尾（350 ms）；呼叫端有正式辨識（Groq／本機 Qwen）時傳 false，
    /// 預覽只是退路，用停止當下的文字就好。
    func stop(speechGrace: Bool = true) async -> AudioCaptureResult? {
        guard isRunning else { return nil }
        isRunning = false
        removeConfigurationObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // 一定要在 stop 之後拆：引擎還在跑就動 graph 會踩到正在跑的 render cycle。
        detachFormatNegotiationNode()
        voiceLevel.clear()
        restoreOutputMute()

        let state = takeStopState()
        let streamContinuation = state.continuation
        let request = state.request
        let url = state.url
        let started = state.started

        request?.endAudio()
        streamContinuation?.finish()

        // On-device Speech may emit its final hypothesis shortly after
        // endAudio. Wait briefly, but never block the app indefinitely.
        if speechGrace, request != nil { try? await Task.sleep(nanoseconds: 350_000_000) }
        let finalText = currentSpeechText()
        speechTask?.cancel()
        speechTask = nil
        speechRequest = nil
        speechRecognizer = nil
        resetVoiceActivityState()

        guard let url else { return nil }
        let (peak, frames) = lock.withLock { (peakLinear, framesWritten) }
        return AudioCaptureResult(
            audioURL: url,
            speechTranscript: finalText,
            duration: Date().timeIntervalSince(started ?? Date()),
            peakDBFS: peak > 0 ? 20 * log10(peak) : -160,
            framesWritten: frames,
            inputDeviceName: inputDeviceName
        )
    }

    private func removeConfigurationObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    func cancel() {
        removeConfigurationObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        detachFormatNegotiationNode()
        channelActivity.reset()
        voiceLevel.clear()
        restoreOutputMute()
        lock.lock()
        continuation?.finish()
        continuation = nil
        let url = audioURL
        lock.unlock()
        speechRequest?.endAudio()
        speechTask?.cancel()
        if let url { try? FileManager.default.removeItem(at: url) }
        isRunning = false
    }

    /// 開了「安靜時自動結束」才用：要安靜這麼久才停。原本 0.9 秒，講長句時想下一句就被切斷（2026-09-24 實機）。
    static let autoStopSilenceSeconds: TimeInterval = 3.0

    /// 用的是與球的電平表同一份黏性集合（`channelActivity`），不會各講各的：
    /// 64 軌只接 1 支麥克風時，全軌平均會讓 0.015 的門檻永遠達不到＝「安靜自動結束」形同關閉。
    private func shouldFinishForSilence() -> Bool {
        let rms = channelActivity.averageRMS
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if rms > 0.015 {
            detectedVoice = true
            lastVoiceAt = now
            return false
        }
        guard detectedVoice,
              !silenceTriggered,
              let lastVoiceAt,
              now.timeIntervalSince(lastVoiceAt) >= Self.autoStopSilenceSeconds else {
            return false
        }
        silenceTriggered = true
        return true
    }

    private func resetVoiceActivityState() {
        lock.lock()
        detectedVoice = false
        lastVoiceAt = nil
        silenceTriggered = false
        lock.unlock()
    }

    func deleteTemporaryAudio(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startOnDeviceSpeechIfAvailable(languageIdentifier: String) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageIdentifier))
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        speechRecognizer = recognizer
        speechRequest = request
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            self.lock.lock()
            self.speechText = text
            let callback = self.onPartial
            self.lock.unlock()
            if !text.isEmpty { callback?(text) }
        }
    }

    private func currentSpeechText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return speechText
    }

    private func takeStopState() -> (
        continuation: AsyncThrowingStream<Data, Error>.Continuation?,
        request: SFSpeechAudioBufferRecognitionRequest?,
        url: URL?,
        started: Date?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let state = (continuation, speechRequest, audioURL, startedAt)
        continuation = nil
        return state
    }

    private func finishStream(throwing error: Error) {
        lock.lock()
        continuation?.finish(throwing: error)
        continuation = nil
        lock.unlock()
    }

    private func muteOutputIfRequested() {
        guard muteWhileRecording else { return }
        let uid = outputDeviceUID.flatMap { $0.isEmpty ? nil : $0 }
            ?? AudioDeviceCatalog.defaultOutputUID()
        guard let uid, let previous = AudioDeviceCatalog.outputMuted(uid: uid) else { return }
        guard AudioDeviceCatalog.setOutputMuted(uid: uid, muted: true) else { return }
        mutedOutputDeviceUID = uid
        previousOutputMute = previous
    }

    private func restoreOutputMute() {
        guard let uid = mutedOutputDeviceUID,
              let previous = previousOutputMute else { return }
        _ = AudioDeviceCatalog.setOutputMuted(uid: uid, muted: previous)
        mutedOutputDeviceUID = nil
        previousOutputMute = nil
    }

    /// 單軌化的啟動條件：和 `makeConversionInputFormat` 同一個判斷。
    /// ≤2 軌（或 ≤2 軌且沒指定聲道）時為 false → 這一格原封不動送進 converter，
    /// 1～2 軌使用者的行為完全不變。
    private func needsMonoDownmix(for format: AVAudioFormat) -> Bool {
        format.channelCount > 1
            && (inputChannel.channelIndex != nil
                || AudioChannelDownmix.needsManualDownmix(channelCount: Int(format.channelCount)))
    }

    private func makeConversionInputFormat(from format: AVAudioFormat) -> AVAudioFormat? {
        guard needsMonoDownmix(for: format) else { return format }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// 把轉換用的兩個緩衝一次配好。tap thread 上不再配置記憶體（mac-input-repair1 #5），
    /// 輸出緩衝依最壞重採樣率算容量：tap 一格 2048 格 → 16 kHz 最少也要 683 格，給兩倍。
    func prepareConversionBuffers(for format: AVAudioFormat) {
        needsMonoConversion = needsMonoDownmix(for: format)
        monoConversionBuffer = nil
        conversionOutputBuffer = nil
        guard let outputFormat = converter?.outputFormat else { return }
        conversionOutputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: Self.tapBufferSize * 2
        )
        guard needsMonoConversion, let monoFormat = conversionInputFormat else { return }
        monoConversionBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.tapBufferSize)
    }

    /// 送進 converter 之前的整流。
    ///
    /// **永遠回傳和 `conversionInputFormat` 同一個格式的 buffer**（要單軌就一定是單軌）。
    /// mac-input-repair1 #2：從前「這格沒有任何聲道過門檻」時是把多軌的原 buffer 交回去，
    /// 但 converter 的輸入格式是單軌，格式不符 → `convert` 報錯 → 整格資料被丟掉，
    /// 錄音在靜音段落會一格一格漏掉。那種情況正確的退路是送一格**靜音的單軌**。
    func bufferForConversion(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard needsMonoConversion,
              conversionInputFormat?.channelCount == 1,
              var mono = monoConversionBuffer else { return buffer }
        // tap 要求 2048 格，但裝置可能一次給更多（64 軌介面實測會）。容量不夠就換一個夠大的
        // （偶發的一次配置，比截掉聲音或寫出界都好）。
        if buffer.frameLength > mono.frameCapacity,
           let bigger = AVAudioPCMBuffer(pcmFormat: mono.format, frameCapacity: buffer.frameLength) {
            mono = bigger
            monoConversionBuffer = bigger
        }
        guard let destination = mono.floatChannelData?.pointee else { return buffer }
        let frames = min(Int(buffer.frameLength), Int(mono.frameCapacity))
        guard frames > 0 else { return buffer }
        // 累加前先清零：這個緩衝是跨 buffer 重用的，留殘留會變成增益漂移。
        destination.update(repeating: 0, count: frames)
        if let selected = inputChannel.channelIndex {
            _ = channelActivity.copy(channel: selected, into: destination, from: buffer, frameLimit: frames)
        } else {
            // 平均：沒有聲道過門檻時什麼都不寫 → 這一格就是靜音（不是「交回多軌」）。
            _ = channelActivity.mix(into: destination, from: buffer, frameLimit: frames)
        }
        mono.frameLength = AVAudioFrameCount(frames)
        return mono
    }

    func convertToPCM16Mono(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter, var output = conversionOutputBuffer else { return nil }
        // 輸出容量依這一格實際的輸入量算（同原本的公式）；預先配的不夠就換大的，不准截掉。
        let needed = AVAudioFrameCount((Double(buffer.frameLength) * converter.outputFormat.sampleRate
            / max(buffer.format.sampleRate, 1)).rounded(.up) + 64)
        if needed > output.frameCapacity,
           let bigger = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: needed) {
            output = bigger
            conversionOutputBuffer = bigger
        }
        // 緩衝重複使用 → 每一格都要從頭開始。
        converterInputState.supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if self.converterInputState.supplied {
                // 這一格給完了，但串流還沒結束：回 .endOfStream 會讓 converter 從此只吐 0 格
                // （2026-10-19 實測整段錄音只轉出第一格 0.1 秒）。
                status.pointee = .noDataNow
                return nil
            }
            self.converterInputState.supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.int16ChannelData?.pointee else {
            return nil
        }
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}