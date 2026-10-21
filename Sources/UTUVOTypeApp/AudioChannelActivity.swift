import Foundation
import AVFoundation

/// 一次錄音共用一份的「哪些聲道真的有訊號」判定。
///
/// 2026-10-14 審查（mac-input-repair1 #3）：原本**每個 buffer 都重算一次**這份集合，
/// 講話停頓時跨越 −60 dBFS 門檻會讓 downmix 的除數跳動 → 增益階梯 → 爆音。
/// 改成**黏性**：某軌一旦在這次錄音裡過門檻，就一路留到錄音結束。
/// 同一份集合同時餵給 downmix、球的電平與「安靜自動結束」，三者不會各講各的。
///
/// 這是即時音訊路徑：陣列只在第一次（或聲道數變大）配置，之後只用下標存取；
/// 每個 buffer 的累加都從 0 起算，不會把上一塊的殘留帶進來。
/// 只在 tap thread 上讀寫，不加鎖——`start` 重置時 tap 還沒裝，`stop` 時 tap 已拆。
final class AudioChannelActivity: @unchecked Sendable {
    /// 使用者在介面指定單一聲道時（例如 Channel 3）：集合永遠只有那一軌。
    var selectedChannel: Int?

    private var peaks: [Float] = []
    private var meanSquares: [Double] = []
    private var active: [Bool] = []
    private(set) var channelCount = 0
    private(set) var activeCount = 0

    /// ≤2 軌維持原本的直接平均（一般麥克風／立體聲，見 `needsManualDownmix`）。
    var needsManualDownmix: Bool { AudioChannelDownmix.needsManualDownmix(channelCount: channelCount) }

    /// 新一次錄音開始：把黏性集合清空。
    func reset() {
        for index in active.indices { active[index] = false }
        activeCount = 0
        channelCount = 0
    }

    // MARK: - 量測

    /// 量一次 buffer 的每一軌（一次掃描就同時得到 RMS 與峰值），過門檻的黏進集合。
    /// 回傳量到的聲道數；0 表示這個 buffer 不能用。
    @discardableResult
    func measure(_ buffer: AVAudioPCMBuffer,
                 threshold: Float = AudioChannelDownmix.activePeakThreshold) -> Int {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return 0 }
        prepare(channels: channels)
        let interleaved = buffer.format.isInterleaved
        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                let values = data[interleaved ? 0 : channel]
                var sum: Double = 0
                var peak: Float = 0
                for index in 0..<frames {
                    let sample = values[interleaved ? index * channels + channel : index]
                    guard sample.isFinite else { continue }
                    sum += Double(sample) * Double(sample)
                    peak = max(peak, abs(sample))
                }
                meanSquares[channel] = sum / Double(frames)
                peaks[channel] = peak
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                let values = data[interleaved ? 0 : channel]
                var sum: Double = 0
                var peak: Float = 0
                for index in 0..<frames {
                    let sample = Double(values[interleaved ? index * channels + channel : index]) / 32768
                    sum += sample * sample
                    peak = max(peak, Float(abs(sample)))
                }
                meanSquares[channel] = sum / Double(frames)
                peaks[channel] = peak
            }
        } else { return 0 }
        updateSticky(threshold: threshold)
        return channels
    }

    /// 純陣列版的量測。這台機器的 SDK 造不出 >2 聲道的 `AVAudioPCMBuffer`，
    /// 所以 64 軌介面卡的政策只能從這裡驗（見 `AudioChannelActivityTests`）。
    @discardableResult
    func measure(peaks: [Float], meanSquares: [Double],
                 threshold: Float = AudioChannelDownmix.activePeakThreshold) -> Int {
        guard peaks.count == meanSquares.count, !peaks.isEmpty else { return 0 }
        prepare(channels: peaks.count)
        for index in 0..<peaks.count {
            self.peaks[index] = peaks[index]
            self.meanSquares[index] = meanSquares[index]
        }
        updateSticky(threshold: threshold)
        return peaks.count
    }

    private func prepare(channels: Int) {
        guard active.count != channels else { return }
        // 換裝置／換節點造成聲道數變化：重新配置，並清掉舊集合。
        peaks = [Float](repeating: 0, count: channels)
        meanSquares = [Double](repeating: 0, count: channels)
        active = [Bool](repeating: false, count: channels)
        activeCount = 0
        channelCount = channels
    }

    /// 黏性：只會從「沒有」變成「有」，一次錄音裡不會再掉回去。
    private func updateSticky(threshold: Float) {
        if let selected = selectedChannel, selected >= 0, selected < channelCount {
            for channel in 0..<channelCount { active[channel] = channel == selected }
            activeCount = 1
            return
        }
        for channel in 0..<channelCount where peaks[channel] > threshold && !active[channel] {
            active[channel] = true
            activeCount += 1
        }
    }

    func isActive(_ channel: Int) -> Bool {
        channel >= 0 && channel < active.count && active[channel]
    }

    // MARK: - 消費這份集合

    /// 電平表與「安靜自動結束」共用：這次錄音要平均的聲道的 RMS。
    /// 整段都沒有聲道過門檻（＝真的安靜，或錄音才剛開始）時回 0，安靜偵測照常生效。
    var averageRMS: Double {
        guard let meanSquare = AudioChannelDownmix.averageMeanSquare(
            meanSquares: meanSquares,
            sticking: needsManualDownmix ? active : nil
        ) else { return 0 }
        return sqrt(meanSquare)
    }

    /// downmix 要乘上的係數。`nil`＝不需要（也做不到）自己混：
    /// - ≤2 軌：照舊直接平均，行為完全不變；
    /// - 指定單一聲道：走抽軌路徑，不是平均；
    /// - \>2 軌但還沒有任何一軌過門檻：這格本來就沒有訊號。**呼叫端要送一格靜音的單軌，
    ///   不要把多軌的原 buffer 交回給 converter**——converter 的輸入格式是單軌，
    ///   格式不符會直接報錯，這一格就被整個丟掉（mac-input-repair1 #2）。
    func downmixScale() -> Float? {
        guard selectedChannel == nil, needsManualDownmix, activeCount > 0 else { return nil }
        return 1 / Float(activeCount)
    }

    /// 把有訊號的聲道平均寫進 `destination`（caller 負責先清零）。回 false 表示這格沒混。
    @discardableResult
    /// `frameLimit`：`destination` 的容量。只寫這麼多格——寫超過＝堆積溢位（64 軌介面一格常大於 2048，實測閃退）。
    func mix(into destination: UnsafeMutablePointer<Float>, from buffer: AVAudioPCMBuffer, frameLimit: Int) -> Bool {
        guard let scale = downmixScale() else { return false }
        let channels = Int(buffer.format.channelCount)
        let frames = min(Int(buffer.frameLength), frameLimit)
        let interleaved = buffer.format.isInterleaved
        if let data = buffer.floatChannelData {
            for channel in 0..<channels where isActive(channel) {
                let values = data[interleaved ? 0 : channel]
                for index in 0..<frames {
                    let sample = values[interleaved ? index * channels + channel : index]
                    guard sample.isFinite else { continue }
                    destination[index] += sample * scale
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels where isActive(channel) {
                let values = data[interleaved ? 0 : channel]
                for index in 0..<frames {
                    let sample = Float(data[interleaved ? 0 : channel][interleaved ? index * channels + channel : index]) / 32768
                    destination[index] += sample * scale
                }
            }
        } else { return false }
        return true
    }

    /// 抽單一聲道寫進 `destination`（caller 負責先清零）。回 false 表示抽不到。
    @discardableResult
    func copy(channel selected: Int, into destination: UnsafeMutablePointer<Float>, from buffer: AVAudioPCMBuffer,
              frameLimit: Int) -> Bool {
        guard selected >= 0, selected < Int(buffer.format.channelCount) else { return false }
        let frames = min(Int(buffer.frameLength), frameLimit)
        let interleaved = buffer.format.isInterleaved
        if let data = buffer.floatChannelData {
            let values = data[interleaved ? 0 : selected]
            for index in 0..<frames {
                let sample = values[interleaved ? index * Int(buffer.format.channelCount) + selected : index]
                destination[index] = sample.isFinite ? sample : 0
            }
            return true
        }
        if let data = buffer.int16ChannelData {
            let values = data[interleaved ? 0 : selected]
            for index in 0..<frames {
                let sample = Float(values[interleaved ? index * Int(buffer.format.channelCount) + selected : index]) / 32768
                destination[index] = sample
            }
            return true
        }
        return false
    }
}
