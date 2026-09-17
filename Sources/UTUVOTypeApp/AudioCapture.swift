import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

struct AudioCaptureResult: Sendable {
    let audioURL: URL
    let speechTranscript: String
    let duration: TimeInterval
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
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var converter: AVAudioConverter?
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
    private var conversionInputFormat: AVAudioFormat?
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

    func start(enableSpeechFallback: Bool) throws -> AsyncThrowingStream<Data, Error> {
        guard !isRunning else { throw AudioCaptureError.engineStartFailed("已有錄音工作") }
        let input = engine.inputNode
        if let inputDeviceUID, !inputDeviceUID.isEmpty,
           !AudioDeviceCatalog.setCurrentInputDevice(uid: inputDeviceUID, on: input.audioUnit) {
            throw AudioCaptureError.noInputDevice
        }
        muteOutputIfRequested()
        let format = input.outputFormat(forBus: 0)
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

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try file.write(from: buffer)
            } catch {
                self.finishStream(throwing: error)
                return
            }

            if let data = self.convertToPCM16Mono(self.bufferForConversion(buffer)) {
                self.lock.lock()
                self.continuation?.yield(data)
                let request = self.speechRequest
                self.lock.unlock()
                request?.append(buffer)
            }
            if self.voiceActivityDetection,
               self.shouldFinishForSilence(buffer: buffer) {
                self.onSilenceDetected?()
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            restoreOutputMute()
            finishStream(throwing: error)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
        isRunning = true
        return stream
    }

    func stop() async -> AudioCaptureResult? {
        guard isRunning else { return nil }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        try? await Task.sleep(nanoseconds: 350_000_000)
        let finalText = currentSpeechText()
        speechTask?.cancel()
        speechTask = nil
        speechRequest = nil
        speechRecognizer = nil
        resetVoiceActivityState()

        guard let url else { return nil }
        return AudioCaptureResult(
            audioURL: url,
            speechTranscript: finalText,
            duration: Date().timeIntervalSince(started ?? Date())
        )
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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

    private func shouldFinishForSilence(buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return false }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for channel in 0 ..< channelCount {
            let samples = channels[channel]
            for index in 0 ..< frames {
                let sample = samples[index]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(max(1, frames * channelCount)))
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
              now.timeIntervalSince(lastVoiceAt) >= 0.9 else {
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

    private func makeConversionInputFormat(from format: AVAudioFormat) -> AVAudioFormat? {
        guard inputChannel.channelIndex != nil, format.channelCount > 1 else { return format }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    private func bufferForConversion(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let selectedChannel = inputChannel.channelIndex,
              selectedChannel < Int(buffer.format.channelCount),
              let conversionInputFormat,
              conversionInputFormat.channelCount == 1,
              let selected = AVAudioPCMBuffer(
                pcmFormat: conversionInputFormat,
                frameCapacity: buffer.frameLength
              ) else {
            return buffer
        }

        let frameCount = Int(buffer.frameLength)
        if let source = buffer.floatChannelData,
           let destination = selected.floatChannelData {
            destination[0].update(from: source[selectedChannel], count: frameCount)
            selected.frameLength = buffer.frameLength
            return selected
        }
        if let source = buffer.int16ChannelData,
           let destination = selected.int16ChannelData {
            destination[0].update(from: source[selectedChannel], count: frameCount)
            selected.frameLength = buffer.frameLength
            return selected
        }
        return buffer
    }

    private func convertToPCM16Mono(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        let inputRate = max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * 16_000 / inputRate).rounded(.up) + 64)
        let outputFormat = converter.outputFormat
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if inputState.supplied {
                status.pointee = .endOfStream
                return nil
            }
            inputState.supplied = true
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
