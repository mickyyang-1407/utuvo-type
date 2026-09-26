import Foundation
import AudioCommon

/// Events emitted by the streaming VAD processor.
public enum VADEvent: Sendable {
    /// Speech has been detected and confirmed (duration ≥ minSpeechDuration).
    case speechStarted(time: Float)
    /// Speech has ended (silence ≥ minSilenceDuration).
    case speechEnded(segment: SpeechSegment)
}

/// Event-driven streaming VAD processor.
///
/// Wraps a `SileroVADModel` (or any `StreamingVADProvider`) to provide
/// event-based speech detection. Accepts audio samples of any length, buffers
/// them into model-sized chunks, runs the model, and applies hysteresis with
/// duration filtering via a four-state machine.
///
/// An optional `TurnCompletionProvider` (see `SmartTurnModel`) turns silence
/// detection into turn detection: a confirmed pause only ends the segment when
/// the classifier says the speaker is done. Otherwise the segment stays open —
/// the speaker resuming continues it, and `TurnCompletionConfig.maxSilenceDuration`
/// of further silence ends it regardless.
///
/// - Warning: This class is not thread-safe. Create separate instances for concurrent use.
///
/// ```swift
/// let model = try await SileroVADModel.fromPretrained()
/// let processor = StreamingVADProcessor(model: model)
///
/// // Feed audio samples (any length)
/// let events = processor.process(samples: audioBuffer)
/// for event in events {
///     switch event {
///     case .speechStarted(let time):
///         print("Speech started at \(time)s")
///     case .speechEnded(let segment):
///         print("Speech: \(segment.startTime)s - \(segment.endTime)s")
///     }
/// }
///
/// // At end of stream, flush any pending segment
/// let finalEvents = processor.flush()
/// ```
public final class StreamingVADProcessor {

    private let model: any StreamingVADProvider
    private let config: VADConfig
    private let chunkSize: Int
    private let sampleRate: Int
    private let chunkDuration: Float  // seconds per chunk (0.032)

    private let turnCompletion: TurnCompletionProvider?
    private let turnConfig: TurnCompletionConfig

    /// Buffer for accumulating samples until we have a full chunk
    private var buffer: [Float] = []
    /// Number of chunks processed so far
    private var chunkCount: Int = 0

    /// Rolling audio kept for the turn-completion classifier (only when one is
    /// attached): the most recent `SmartTurnModel.windowSamples` samples.
    private var recentAudio: [Float] = []
    /// Absolute sample position of `recentAudio.last + 1`.
    private var processedSamples: Int = 0
    /// Absolute sample position where the current turn's audio starts.
    private var turnStartSample: Int = 0

    /// Completion probability from the last classifier call, if any.
    public private(set) var lastTurnCompletionProbability: Float?

    /// State machine for hysteresis + duration filtering
    private enum State {
        /// No speech detected
        case silence
        /// Onset threshold crossed, waiting for minSpeechDuration
        case pendingSpeech(startTime: Float)
        /// Speech confirmed and speechStarted emitted
        case speech(startTime: Float)
        /// Offset threshold crossed, waiting for minSilenceDuration
        case pendingSilence(speechStart: Float, silenceStart: Float)
        /// Silence confirmed but the turn classifier vetoed it; waiting for
        /// more speech or the silence cap.
        case held(speechStart: Float, pauseStart: Float)
        /// Speech resumed inside a held turn, waiting for minSpeechDuration.
        case heldPendingSpeech(speechStart: Float, pauseStart: Float, resumeStart: Float)
    }

    private var state: State = .silence

    /// Create a streaming VAD processor.
    ///
    /// - Parameters:
    ///   - model: Silero VAD model instance
    ///   - config: VAD configuration (thresholds, durations)
    ///   - turnCompletion: optional end-of-turn classifier consulted on every
    ///     confirmed pause (see `SmartTurnModel`)
    ///   - turnCompletionConfig: threshold and silence cap for the classifier
    public convenience init(
        model: SileroVADModel,
        config: VADConfig = .sileroDefault,
        turnCompletion: TurnCompletionProvider? = nil,
        turnCompletionConfig: TurnCompletionConfig = .default
    ) {
        self.init(
            provider: model,
            config: config,
            turnCompletion: turnCompletion,
            turnCompletionConfig: turnCompletionConfig)
    }

    /// Create a streaming VAD processor over any chunked VAD provider.
    public init(
        provider: any StreamingVADProvider,
        config: VADConfig = .sileroDefault,
        turnCompletion: TurnCompletionProvider? = nil,
        turnCompletionConfig: TurnCompletionConfig = .default
    ) {
        self.model = provider
        self.config = config
        self.chunkSize = provider.chunkSize
        self.sampleRate = provider.inputSampleRate
        self.chunkDuration = Float(provider.chunkSize) / Float(provider.inputSampleRate)
        self.turnCompletion = turnCompletion
        self.turnConfig = turnCompletionConfig
    }

    /// Feed audio samples and get VAD events back.
    ///
    /// Samples are buffered internally. Events are emitted as soon as the
    /// state machine confirms speech start/end with the configured thresholds
    /// and duration constraints.
    ///
    /// - Parameter samples: PCM Float32 samples at 16kHz (any length)
    /// - Returns: zero or more VAD events
    public func process(samples: [Float]) -> [VADEvent] {
        buffer.append(contentsOf: samples)
        var events = [VADEvent]()
        var consumed = 0

        while buffer.count - consumed >= chunkSize {
            let end = consumed + chunkSize
            let chunk = Array(buffer[consumed..<end])
            consumed = end

            let prob = model.processChunk(chunk)
            let time = Float(chunkCount) * chunkDuration
            chunkCount += 1
            rememberAudio(chunk)

            events.append(contentsOf: processProb(prob, time: time))
        }
        if consumed > 0 {
            buffer.removeFirst(consumed)
        }

        return events
    }

    /// Flush any pending speech segment at end of stream.
    ///
    /// Call this when the audio stream ends to close any open speech segment.
    ///
    /// - Returns: zero or more final VAD events
    public func flush() -> [VADEvent] {
        // Process any remaining buffered samples (zero-padded)
        var events = [VADEvent]()
        if !buffer.isEmpty {
            var lastChunk = buffer
            lastChunk.append(contentsOf: [Float](repeating: 0, count: chunkSize - lastChunk.count))
            buffer.removeAll()

            let prob = model.processChunk(lastChunk)
            let time = Float(chunkCount) * chunkDuration
            chunkCount += 1
            rememberAudio(lastChunk)
            events.append(contentsOf: processProb(prob, time: time))
        }

        let endTime = Float(chunkCount) * chunkDuration

        // Close any open state
        switch state {
        case .silence:
            break
        case .pendingSpeech(let startTime):
            // Check if pending speech meets minimum duration
            if endTime - startTime >= config.minSpeechDuration {
                events.append(.speechStarted(time: startTime))
                events.append(.speechEnded(segment: SpeechSegment(
                    startTime: startTime, endTime: endTime)))
            }
        case .speech(let startTime):
            events.append(.speechEnded(segment: SpeechSegment(
                startTime: startTime, endTime: endTime)))
        case .pendingSilence(let speechStart, let silenceStart):
            // End at the silence start point
            events.append(.speechEnded(segment: SpeechSegment(
                startTime: speechStart, endTime: silenceStart)))
        case .held(let speechStart, let pauseStart),
             .heldPendingSpeech(let speechStart, let pauseStart, _):
            // The classifier was still waiting for more speech; end of stream settles it.
            events.append(.speechEnded(segment: SpeechSegment(
                startTime: speechStart, endTime: pauseStart)))
        }

        state = .silence
        return events
    }

    /// Reset all state (model + processor).
    ///
    /// Call between processing different audio streams.
    public func reset() {
        buffer.removeAll()
        chunkCount = 0
        state = .silence
        recentAudio.removeAll()
        processedSamples = 0
        turnStartSample = 0
        lastTurnCompletionProbability = nil
        model.resetState()
    }

    /// Current time position in seconds.
    public var currentTime: Float {
        Float(chunkCount) * chunkDuration
    }

    /// True while the turn classifier has vetoed the last pause and the
    /// processor is waiting for more speech or the silence cap.
    public var isHoldingTurn: Bool {
        switch state {
        case .held, .heldPendingSpeech: return true
        default: return false
        }
    }

    // MARK: - Turn completion

    private var windowSamples: Int {
        SmartTurnModel.windowSeconds * sampleRate
    }

    private func rememberAudio(_ chunk: [Float]) {
        processedSamples += chunk.count
        guard turnCompletion != nil else { return }
        recentAudio.append(contentsOf: chunk)
        let excess = recentAudio.count - windowSamples
        if excess > 0 {
            recentAudio.removeFirst(excess)
        }
    }

    /// Mark the start of a turn at the current position, minus the pre-roll.
    private func beginTurn() {
        let preRoll = Int(turnConfig.preRollDuration * Float(sampleRate))
        turnStartSample = max(0, processedSamples - chunkSize - preRoll)
    }

    /// Audio of the current turn, at most the classifier window.
    private func turnAudio() -> [Float] {
        let available = recentAudio.count
        let firstAvailable = processedSamples - available
        let start = max(turnStartSample, firstAvailable) - firstAvailable
        return Array(recentAudio[start..<available])
    }

    /// Ask the classifier whether the turn is complete. Errors count as
    /// "complete" so a failing model never stalls the conversation.
    private func turnIsComplete() -> Bool {
        guard let turnCompletion else { return true }
        do {
            let probability = try turnCompletion.turnCompleteProbability(
                audio: turnAudio(), sampleRate: sampleRate)
            lastTurnCompletionProbability = probability
            return probability >= turnConfig.threshold
        } catch {
            lastTurnCompletionProbability = nil
            return true
        }
    }

    // MARK: - State Machine

    private func processProb(_ prob: Float, time: Float) -> [VADEvent] {
        var events = [VADEvent]()
        let nextTime = time + chunkDuration

        switch state {
        case .silence:
            if prob >= config.onset {
                beginTurn()
                state = .pendingSpeech(startTime: time)
            }

        case .pendingSpeech(let startTime):
            if prob < config.offset {
                // False alarm — speech too brief, return to silence
                state = .silence
            } else if nextTime - startTime >= config.minSpeechDuration {
                // Speech confirmed
                events.append(.speechStarted(time: startTime))
                state = .speech(startTime: startTime)
            }
            // else: still pending, keep waiting

        case .speech(let startTime):
            if prob < config.offset {
                // Speech may be ending
                state = .pendingSilence(speechStart: startTime, silenceStart: time)
            }

        case .pendingSilence(let speechStart, let silenceStart):
            if prob >= config.onset {
                // Speech resumed — cancel silence
                state = .speech(startTime: speechStart)
            } else if nextTime - silenceStart >= config.minSilenceDuration {
                if turnIsComplete() {
                    // Silence confirmed — emit speechEnded
                    events.append(.speechEnded(segment: SpeechSegment(
                        startTime: speechStart, endTime: silenceStart)))
                    // Check if new speech is starting
                    if prob >= config.onset {
                        beginTurn()
                        state = .pendingSpeech(startTime: time)
                    } else {
                        state = .silence
                    }
                } else {
                    // The classifier says the speaker is mid-turn: keep listening.
                    state = .held(speechStart: speechStart, pauseStart: silenceStart)
                }
            }
            // else: still waiting for silence confirmation

        case .held(let speechStart, let pauseStart):
            if prob >= config.onset {
                state = .heldPendingSpeech(
                    speechStart: speechStart, pauseStart: pauseStart, resumeStart: time)
            } else if heldTooLong(pauseStart: pauseStart, nextTime: nextTime) {
                events.append(.speechEnded(segment: SpeechSegment(
                    startTime: speechStart, endTime: pauseStart)))
                state = .silence
            }

        case .heldPendingSpeech(let speechStart, let pauseStart, let resumeStart):
            if heldTooLong(pauseStart: pauseStart, nextTime: nextTime) {
                // The cap wins even while a resume is pending; what follows is a new turn.
                events.append(.speechEnded(segment: SpeechSegment(
                    startTime: speechStart, endTime: pauseStart)))
                if prob >= config.offset {
                    beginTurn()
                    state = .pendingSpeech(startTime: resumeStart)
                } else {
                    state = .silence
                }
            } else if prob < config.offset {
                state = .held(speechStart: speechStart, pauseStart: pauseStart)
            } else if nextTime - resumeStart >= config.minSpeechDuration {
                // Same turn continues; no new speechStarted.
                state = .speech(startTime: speechStart)
            }
        }

        return events
    }

    private func heldTooLong(pauseStart: Float, nextTime: Float) -> Bool {
        turnConfig.maxSilenceDuration > 0
            && nextTime - pauseStart >= turnConfig.maxSilenceDuration
    }
}
