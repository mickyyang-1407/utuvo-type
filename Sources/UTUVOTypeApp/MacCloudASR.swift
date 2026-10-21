import Foundation
import os
import UTUVOTypeCore

/// Mac 雲端辨識（選配，使用者自備 Groq key；2026-10-19）：同 iOS／Android 0.3.1 的 Groq Whisper 路徑。
///
/// 錄音時 16 kHz 單聲道 PCM 已經在 `AudioCaptureSession` 的串流裡，這裡收齊後剪安靜段、包 WAV、
/// 一次送 Groq；拿回來的文字過同一套把關（簡轉繁、字幕結尾句幻覺、解碼迴圈）。
/// 任何失敗、逾時都回 nil，由呼叫端退回本機 Qwen3-ASR。key 用「智慧整理」頁存的那把 Groq key
/// （Keychain `com.utuvo.type.mac.smartcleanup`／`groq`），不另存一份。
enum MacCloudASR {
    private static let log = Logger(subsystem: "com.utuvo.type", category: "cloud-asr")

    /// OpenCC 字典跟著 App bundle 走（`TraditionalFixer` 預設找 Bundle.main，SwiftPM 版放在 Bundle.module）。
    private static let configureFixer: Void = {
        if let url = Bundle.module.url(forResource: "OpenCC", withExtension: nil) {
            TraditionalFixer.directory = url
        }
    }()

    static func supports(language: String) -> Bool { WhisperAudio.languageCode(for: language) != nil }

    /// 環境變數 `UTUVO_TYPE_GROQ_API_KEY` 優先（量測工具用 `open --env` 帶入，跟百鍊 key 的環境變數同一套），
    /// 否則用智慧整理頁存的 Groq key。
    static func key(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let value = environment["UTUVO_TYPE_GROQ_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty { return value }
        return SmartCleanup.key(for: .groq)
    }

    /// 16-bit PCM LE → Float（-1...1）。
    static func samples(fromPCM16 data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { raw in
            for i in 0..<out.count {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }

    /// 雲端文字 → 可交給整理的逐字稿；nil＝不採用（空、整段是幻覺、迴圈）。
    static func accept(_ raw: String, language: String, outputScript: OutputScript, seconds: Double) -> String? {
        _ = configureFixer
        var text: String
        switch outputScript {
        case .traditional:
            guard let cleaned = TranscriptGuard.clean(raw, language: language) else { return nil }
            text = cleaned
        case .simplified:
            text = WhisperHallucination.normalizeSmallFormPunctuation(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        case .asIs:
            text = WhisperHallucination.normalizeSmallFormPunctuation(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = TranscriptGuard.dropOutroHallucination(text)
        guard !text.isEmpty, !TranscriptGuard.looksLooping(text, seconds: seconds) else { return nil }
        return text
    }

    enum Outcome: Equatable, Sendable {
        case ok(String)
        case skipped(String)
        case failed(String)
    }

    /// 一次送整段。`transport` 測試可注入；正式走拒絕跨 host redirect 的 session。
    static func transcribe(pcm16: Data, language: String, hotwords: [String], outputScript: OutputScript,
                           key: String, transport: CleanupTransport = StrictCleanupSession.shared) async -> Outcome {
        let samples = samples(fromPCM16: pcm16)
        let seconds = Double(samples.count) / 16_000
        let skip: String? = seconds < 0.25 ? "too-short" : seconds > 300 ? "too-long"
            : key.isEmpty ? "no-key" : !supports(language: language) ? "language" : nil
        if let skip {
            log.error("groq skipped (\(skip, privacy: .public)): \(pcm16.count, privacy: .public) bytes")
            return .skipped(skip)
        }
        let started = Date()
        let audio = WhisperAudio.wav(WhisperAudio.trimSilence(samples))
        let request = WhisperAudio.groqRequest(key: key, wav: audio, language: language, hotwords: hotwords)
        let box = OutcomeBox()
        let text = await SmartCleanup.withinDeadline(seconds: WhisperAudio.timeLimit(seconds: seconds)) {
            do {
                let (data, response) = try await transport.send(request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    box.set("http:\(http.statusCode)"); return nil
                }
                guard let raw = WhisperAudio.parseGroq(data) else { box.set("malformed"); return nil }
                guard let accepted = accept(raw, language: language, outputScript: outputScript, seconds: seconds) else {
                    box.set("empty"); return nil
                }
                return accepted
            } catch {
                box.set("transport"); return nil
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let text {
            log.info("groq ok: \(ms, privacy: .public) ms, audio \(seconds, format: .fixed(precision: 2), privacy: .public) s")
            return .ok(text)
        }
        let reason = box.value ?? "timeout"
        log.error("groq \(reason, privacy: .public): \(ms, privacy: .public) ms")
        return .failed(reason)
    }

    /// 錄音一開始就先連上 Groq（只送 HEAD，不帶 key 與音訊），停下來時省掉 TLS 握手。
    static func warmUp() {
        var request = URLRequest(url: WhisperAudio.groqEndpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 3)
        request.httpMethod = "HEAD"
        StrictCleanupSession.shared.session.dataTask(with: request).resume()
    }

    /// `pcm16` 從第 `offset` byte 起是否全是安靜（20 ms 一格峰值都低於 `WhisperAudio.silenceThreshold`）。
    static func isQuiet(_ pcm16: Data, from offset: Int) -> Bool {
        guard offset < pcm16.count else { return true }
        let limit = Int16(WhisperAudio.silenceThreshold * 32768)
        return pcm16.withUnsafeBytes { raw in
            var i = offset & ~1
            while i + 1 < raw.count {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))
                if v >= limit || v <= -limit { return false }
                i += 2
            }
            return true
        }
    }

    /// 錄音中偵測「講完一段、停下來」：講話累積 ≥ `minVoice` 秒後，連續安靜 ≥ `minPause` 秒就觸發一次；
    /// 之後要再講過話才會再觸發，一次錄音最多 `maxTriggers` 次（每次＝一次 Groq＋一次整理請求）。
    struct PauseDetector {
        var minVoice: Double = 0.3
        var minPause: Double = 0.45
        var maxTriggers = 3
        private(set) var triggers = 0
        private var voicedFrames = 0
        private var quietFrames = 0
        private var pending: [Int16] = []
        private static let frame = 320   // 20 ms @ 16 kHz

        /// 餵一段 PCM16；回 true＝現在是停頓點，可以先處理。
        mutating func feed(_ chunk: Data) -> Bool {
            chunk.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count - 1, by: 2) {
                    pending.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self)))
                }
            }
            let limit = Int16(WhisperAudio.silenceThreshold * 32768)
            var fire = false
            while pending.count >= Self.frame {
                let loud = pending[0..<Self.frame].contains { $0 >= limit || $0 <= -limit }
                pending.removeFirst(Self.frame)
                if loud { voicedFrames += 1; quietFrames = 0; continue }
                quietFrames += 1
                if triggers < maxTriggers,
                   Double(voicedFrames) * 0.02 >= minVoice, Double(quietFrames) * 0.02 >= minPause {
                    triggers += 1
                    voicedFrames = 0
                    fire = true
                }
            }
            return fire
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: String?
        func set(_ value: String) { lock.lock(); reason = value; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return reason }
    }
}
