import Foundation

/// ASR backend boundary. M0 only fixes the contract; no network or model
/// runtime is started by this package.
public enum ASRBackend: String, Codable, Sendable, CaseIterable {
    case bailian
    case local
}

public struct ASRContext: Codable, Equatable, Sendable {
    public var languageIdentifier: String
    public var allowMixedChineseEnglish: Bool
    public var hotwords: [String]
    public var limitedContext: String

    public init(
        languageIdentifier: String = "zh-TW",
        allowMixedChineseEnglish: Bool = true,
        hotwords: [String] = [],
        limitedContext: String = ""
    ) {
        self.languageIdentifier = languageIdentifier
        self.allowMixedChineseEnglish = allowMixedChineseEnglish
        self.hotwords = hotwords
        self.limitedContext = limitedContext
    }
}

public struct ASRPartial: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public protocol StreamingASRClient: Sendable {
    /// The caller owns microphone capture. An implementation may send audio
    /// to a streaming provider or a local runtime, but must emit partials.
    func transcribe(
        audio: AsyncThrowingStream<Data, Error>,
        context: ASRContext
    ) -> AsyncThrowingStream<ASRPartial, Error>
}

public struct BailianASRConfiguration: Codable, Equatable, Sendable {
    public let model: String
    public let protocolName: String
    public let supportsPartialTranscript: Bool
    public let apiKeySource: String

    public init(
        model: String = "qwen-audio-3.0-asr-flash-streaming",
        protocolName: String = "websocket-or-official-realtime-protocol",
        supportsPartialTranscript: Bool = true,
        apiKeySource: String = "macOS-Keychain-or-environment-outside-repo"
    ) {
        self.model = model
        self.protocolName = protocolName
        self.supportsPartialTranscript = supportsPartialTranscript
        self.apiKeySource = apiKeySource
    }
}

public struct LocalASRConfiguration: Codable, Equatable, Sendable {
    public let runtimeName: String
    public let modelName: String
    public let autoDownload: Bool

    public init(
        runtimeName: String = "local-asr-adapter",
        modelName: String = "Qwen3-ASR-0.6B",
        autoDownload: Bool = false
    ) {
        self.runtimeName = runtimeName
        self.modelName = modelName
        self.autoDownload = autoDownload
    }
}
