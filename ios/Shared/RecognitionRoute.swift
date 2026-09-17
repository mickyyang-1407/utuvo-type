import Foundation

/// 辨識走本機還是雲端——iOS 的唯一決策點（IOS2／2026-09-11）。
///
/// v1 在不支援裝置端辨識時**靜默**退回伺服器辨識，使用者以為音訊沒離機。
/// 這裡把它變成看得見的狀態，並提供「只用裝置端」的硬性拒絕路徑。
enum RecognitionRoute: String, Equatable, Sendable {
    /// 音訊不離開裝置。
    case onDevice
    /// 音訊送到 Apple 的伺服器辨識。
    case server

    var badgeText: String {
        switch self {
        case .onDevice: return "裝置端辨識・音訊不離機"
        case .server: return "雲端辨識・音訊會送到 Apple 伺服器"
        }
    }

    var isPrivate: Bool { self == .onDevice }
}

enum RecognitionRouteDecision: Equatable, Sendable {
    case allow(RecognitionRoute)
    /// 使用者要求只用裝置端，但這台裝置／這個語言辦不到。
    case blockedOnDeviceUnavailable
}

enum RecognitionRoutePolicy: Sendable {
    /// - Parameters:
    ///   - supportsOnDevice: `SFSpeechRecognizer.supportsOnDeviceRecognition`
    ///   - onDeviceOnly: 使用者是否開了「只用裝置端辨識」
    static func decide(supportsOnDevice: Bool, onDeviceOnly: Bool) -> RecognitionRouteDecision {
        if supportsOnDevice { return .allow(.onDevice) }
        if onDeviceOnly { return .blockedOnDeviceUnavailable }
        return .allow(.server)
    }

    /// 給 UI 用：這個決策要不要對使用者示警（音訊會離機）。
    static func warnsUser(_ decision: RecognitionRouteDecision) -> Bool {
        switch decision {
        case .allow(let route): return !route.isPrivate
        case .blockedOnDeviceUnavailable: return true
        }
    }
}
