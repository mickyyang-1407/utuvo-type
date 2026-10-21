import Foundation
import AVFoundation

/// A bounded in-memory meter. The audio tap writes one scalar; rendering only polls it.
///
/// 電平表的來源是 `AudioChannelActivity` 那一份黏性集合（downmix 與安靜偵測用同一份），
/// 所以球的電平不會跟「實際送給 ASR 的音量」各講各的。
final class LiveVoiceLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (db: Float, time: TimeInterval)?
    static let maxAge: TimeInterval = 0.35

    /// tap thread 每格呼叫一次；只寫一個純量，不配置記憶體。
    func publish(rms: Double, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let level = rms.isFinite && rms > 0 ? rms : 0
        let db = Float(max(-120, min(0, 20 * log10(max(0.000001, level)))))
        lock.lock(); latest = (db, now); lock.unlock()
    }
    func read(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, now.isFinite else { return nil }
        let age = now - latest.time
        return age >= 0 && age <= Self.maxAge ? latest.db : nil
    }
    func clear() { lock.lock(); latest = nil; lock.unlock() }

    /// 多聲道介面（例如 64 軌，只有第 1 軌接了麥克風）不能把靜音軌也算進平均——
    /// 會把人聲稀釋幾十 dB，球的電平與「安靜自動結束」都會失準。
    /// 跟 `AudioChannelDownmix.needsManualDownmix` 同一個邊界：2 軌以內（一般麥克風／立體聲）
    /// 維持原本的直接平均。
    ///
    /// ⚠️ 這是**逐 buffer、非黏性**的版本，只留給政策測試與一次性檢查；
    /// 錄音路徑用 `AudioChannelActivity.averageRMS`（黏性），不要在 tap 裡呼叫這裡。
    static let activeChannelPeak: Double = Double(AudioChannelDownmix.activePeakThreshold)
    static func activeChannelRMS(meanSquares: [Double], peaks: [Double]) -> Double {
        let sticking = AudioChannelDownmix.needsManualDownmix(channelCount: meanSquares.count)
            ? AudioChannelDownmix.aboveThreshold(channels: meanSquares.count, peaks: peaks.map(Float.init))
            : nil
        guard let meanSquare = AudioChannelDownmix.averageMeanSquare(
            meanSquares: meanSquares, sticking: sticking
        ) else { return 0 }
        return sqrt(meanSquare)
    }
}
