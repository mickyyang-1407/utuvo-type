import Foundation

/// 開源防呆：偵測使用者硬體，判斷能不能走完全本機路徑。
/// 全部用系統 API，毫秒級、無網路、無副作用。判定表見 docs/OPEN-SOURCE-READINESS.md。
enum HardwareProfile {
    enum Recommendation: Sendable {
        /// Apple Silicon＋RAM 充足：完全本機（ASR＋小型 editor）。
        case fullLocal
        /// Apple Silicon 但 RAM 偏小：本機 ASR、關本機 editor（Fast only）。
        case localASROnly
        /// 非 Apple Silicon：本機 mlx 引擎不可用，建議雲端＋on-device Speech fallback。
        case cloudPreferred
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// repo／app 所在磁碟剩餘空間（GB）；查不到時回 nil（呼叫端自行決定是否放行）。
    static func freeDiskGB(at path: String = NSHomeDirectory()) -> Double? {
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return Double(capacity) / 1_073_741_824
    }

    static func recommendation() -> Recommendation {
        guard isAppleSilicon else { return .cloudPreferred }
        return physicalMemoryGB >= 8 ? .fullLocal : .localASROnly
    }
}
