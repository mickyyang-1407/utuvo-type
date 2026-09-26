import Foundation
import AVFoundation

/// A bounded in-memory meter. The audio tap writes one scalar; rendering only polls it.
final class LiveVoiceLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (db: Float, time: TimeInterval)?
    static let maxAge: TimeInterval = 0.35

    func capture(_ buffer: AVAudioPCMBuffer, selectedChannel: Int? = nil,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { clear(); return }
        let selected = selectedChannel.flatMap { (0..<channels).contains($0) ? $0 : nil }
        let first = selected ?? 0, end = selected.map { $0 + 1 } ?? channels
        let interleaved = buffer.format.isInterleaved
        var sum: Double = 0
        if let data = buffer.floatChannelData {
            for channel in first..<end {
                let values = data[interleaved ? 0 : channel]
                for i in 0..<frames {
                    let sample = Double(values[interleaved ? i * channels + channel : i])
                    if sample.isFinite { sum += sample * sample }
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in first..<end {
                let values = data[interleaved ? 0 : channel]
                for i in 0..<frames {
                    let sample = Double(values[interleaved ? i * channels + channel : i]) / 32768
                    sum += sample * sample
                }
            }
        } else { clear(); return }
        let rms = sqrt(sum / Double(frames * (end - first)))
        let db = Float(max(-120, min(0, 20 * log10(max(0.000001, rms)))))
        lock.lock(); latest = (db, now); lock.unlock()
    }
    func read(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, now.isFinite else { return nil }
        let age = now - latest.time
        return age >= 0 && age <= Self.maxAge ? latest.db : nil
    }
    func clear() { lock.lock(); latest = nil; lock.unlock() }
}
