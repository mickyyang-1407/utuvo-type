#if canImport(CoreML)
import AudioCommon
import CoreML
import Foundation

struct SmartTurnModelConfiguration: Decodable, Equatable {
    let modelType: String
    let sampleRate: Int
    let windowSamples: Int
    let inputName: String
    let outputName: String
    let compiledModel: String

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case sampleRate = "sample_rate"
        case windowSamples = "window_samples"
        case inputName = "input_name"
        case outputName = "output_name"
        case compiledModel = "compiled_model"
    }
}

/// Core ML end-of-turn classifier based on Pipecat Smart Turn v3.2.
///
/// Given the last eight seconds of the user's turn, returns the probability
/// that the user has finished speaking. It listens to the audio itself
/// (prosody, pace, intonation) rather than a transcript, covers 23 languages,
/// and is meant to run once per VAD pause: a finished sentence gets an
/// immediate reply while a mid-sentence pause keeps the agent waiting.
///
/// The compiled model embeds the Whisper log-mel front-end, including the
/// zero-mean / unit-variance waveform normalisation the upstream model was
/// trained with, so callers pass raw 16 kHz PCM. Shorter turns are zero-padded
/// at the front; longer turns keep their last eight seconds.
public final class SmartTurnModel: TurnCompletionProvider {
    public static let defaultModelId = "aufklarer/Smart-Turn-v3.2-CoreML"
    public static let sampleRate = 16_000
    public static let windowSeconds = 8
    public static let windowSamples = 128_000
    public static let defaultThreshold: Float = 0.5
    static let compiledModelName = "smart_turn.mlmodelc"

    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    /// Download and load the compiled Smart Turn Core ML model.
    public static func fromPretrained(
        modelId: String = defaultModelId,
        cacheDir: URL? = nil,
        offlineMode: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> SmartTurnModel {
        let cacheDir = try cacheDir
            ?? HuggingFaceDownloader.getCacheDirectory(for: modelId)

        progressHandler?(0.0, "Downloading Smart Turn model...")
        try await HuggingFaceDownloader.downloadWeights(
            modelId: modelId,
            to: cacheDir,
            additionalFiles: ["\(compiledModelName)/**", "config.json"],
            offlineMode: offlineMode,
            progressHandler: { progress in
                progressHandler?(progress * 0.8, "Downloading Smart Turn model...")
            }
        )

        progressHandler?(0.8, "Loading Smart Turn model...")
        let configuration = try loadConfiguration(
            at: cacheDir.appendingPathComponent("config.json"),
            modelId: modelId)
        let modelURL = cacheDir.appendingPathComponent(
            configuration.compiledModel, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw AudioModelError.modelLoadFailed(
                modelId: modelId,
                reason: "Core ML model not found at \(modelURL.path)")
        }

        let loaded: MLModel
        do {
            loaded = try CoreMLLoader.load(
                url: modelURL,
                computeUnits: .cpuAndNeuralEngine,
                name: "smart-turn-v3.2")
        } catch {
            throw AudioModelError.modelLoadFailed(
                modelId: modelId,
                reason: "Failed to load compiled Core ML model",
                underlying: error)
        }

        progressHandler?(1.0, "Ready")
        return SmartTurnModel(model: loaded)
    }

    static func decodeConfiguration(_ data: Data) throws -> SmartTurnModelConfiguration {
        let configuration = try JSONDecoder().decode(
            SmartTurnModelConfiguration.self, from: data)
        guard configuration.modelType == "smart-turn-v3-coreml",
            configuration.sampleRate == sampleRate,
            configuration.windowSamples == windowSamples,
            configuration.inputName == "audio",
            configuration.outputName == "probability",
            configuration.compiledModel == compiledModelName
        else {
            throw AudioModelError.invalidConfiguration(
                model: "Smart Turn v3.2",
                reason: "config.json does not match the compiled turn-detection runtime")
        }
        return configuration
    }

    private static func loadConfiguration(
        at url: URL,
        modelId: String
    ) throws -> SmartTurnModelConfiguration {
        do {
            return try decodeConfiguration(Data(contentsOf: url))
        } catch {
            throw AudioModelError.modelLoadFailed(
                modelId: modelId,
                reason: "Missing or incompatible config.json",
                underlying: error)
        }
    }

    /// Probability in `[0, 1]` that the user has finished their turn.
    ///
    /// - Parameters:
    ///   - audio: PCM Float32 audio of the turn so far (any length; the last
    ///     eight seconds are used).
    ///   - sampleRate: Sample rate of `audio`; resampled to 16 kHz if needed.
    public func turnCompleteProbability(audio: [Float], sampleRate: Int) throws -> Float {
        let resampled = try Self.resampled(audio, sampleRate: sampleRate)
        return try predict(Self.preparedWindow(resampled))
    }

    /// Compile and execute the graph once before latency-sensitive use.
    public func prewarm() throws {
        var waveform = [Float](repeating: 0, count: Self.windowSamples)
        for index in (Self.windowSamples - Self.sampleRate)..<Self.windowSamples {
            waveform[index] = 0.05 * sin(
                2 * Float.pi * 173 * Float(index) / Float(Self.sampleRate))
        }
        _ = try predict(waveform)
    }

    /// The last `windowSamples` of `samples`, left-padded with zeros when the
    /// turn is shorter than eight seconds.
    static func preparedWindow(_ samples: [Float]) throws -> [Float] {
        guard samples.allSatisfy(\.isFinite) else {
            throw AudioModelError.invalidConfiguration(
                model: "Smart Turn v3.2",
                reason: "audio contains a non-finite sample")
        }
        if samples.count == windowSamples {
            return samples
        }
        if samples.count > windowSamples {
            return Array(samples.suffix(windowSamples))
        }
        var window = [Float](repeating: 0, count: windowSamples)
        let offset = windowSamples - samples.count
        for (index, sample) in samples.enumerated() {
            window[offset + index] = sample
        }
        return window
    }

    private static func resampled(_ audio: [Float], sampleRate: Int) throws -> [Float] {
        if sampleRate == Self.sampleRate { return audio }
        guard sampleRate > 0 else {
            throw AudioModelError.invalidConfiguration(
                model: "Smart Turn v3.2",
                reason: "sample rate must be greater than zero")
        }
        // Only the tail matters; trim before resampling to keep long turns cheap.
        let keep = Int(Double(windowSamples + sampleRate) * Double(sampleRate) / Double(Self.sampleRate))
        let tail = audio.count > keep ? Array(audio.suffix(keep)) : audio
        return AudioFileLoader.resample(tail, from: sampleRate, to: Self.sampleRate)
    }

    private func predict(_ window: [Float]) throws -> Float {
        let input = try MLMultiArray(
            shape: [1, Self.windowSamples as NSNumber],
            dataType: .float32)
        let inputPointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        window.withUnsafeBufferPointer { source in
            inputPointer.update(from: source.baseAddress!, count: window.count)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: input),
        ])
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw AudioModelError.inferenceFailed(
                operation: "Smart Turn end-of-turn",
                reason: error.localizedDescription)
        }

        guard let values = output.featureValue(for: "probability")?.multiArrayValue,
            values.count >= 1
        else {
            throw AudioModelError.inferenceFailed(
                operation: "Smart Turn end-of-turn",
                reason: "missing 'probability' output")
        }
        let probability = values[0].floatValue
        guard probability.isFinite else {
            throw AudioModelError.inferenceFailed(
                operation: "Smart Turn end-of-turn",
                reason: "model returned a non-finite probability")
        }
        return min(1, max(0, probability))
    }
}
#endif
