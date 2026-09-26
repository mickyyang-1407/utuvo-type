import Foundation

/// 辨識走本機還是雲端——iOS 的唯一決策點（IOS2／2026-09-11）。
///
/// v1 在不支援裝置端辨識時**靜默**退回伺服器辨識，使用者以為音訊沒離機。
/// 這裡把它變成看得見的狀態，並提供「只用裝置端」的硬性拒絕路徑。
enum RecognitionRoute: String, Equatable, Sendable {
    /// 音訊不離開裝置。
    case onDevice
    /// 允許 Apple Speech 使用伺服器辨識；最終由 Apple Speech 決定實際處理路徑。
    case server

    var badgeText: String {
        switch self {
        case .onDevice: return String(localized: "裝置端辨識・音訊不離機")
        case .server: return String(localized: "允許雲端辨識・音訊可能送到 Apple")
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
    ///   - preferCloud: 使用者選擇 Apple Speech 的雲端可用路徑；由 Apple Speech 決定實際處理位置
    static func decide(supportsOnDevice: Bool, onDeviceOnly: Bool, preferCloud: Bool = false) -> RecognitionRouteDecision {
        if onDeviceOnly { return supportsOnDevice ? .allow(.onDevice) : .blockedOnDeviceUnavailable }
        if preferCloud { return .allow(.server) }
        if supportsOnDevice { return .allow(.onDevice) }
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
