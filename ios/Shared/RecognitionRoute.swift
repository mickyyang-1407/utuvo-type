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
    case thirdPartyCloud

    var badgeText: String {
        switch self {
        case .onDevice: return String(localized: "裝置端辨識・音訊不離機")
        case .server: return String(localized: "允許雲端辨識・音訊可能送到 Apple")
        case .thirdPartyCloud: return String(localized: "雲端辨識・音訊送到選定服務")
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

/// One user decision for the entire dictation pipeline, shared with the keyboard.
/// Local mode never sends cloud requests, including rewrite/translation.
enum DictationProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case local, cloud
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return String(localized: "本機・隱私優先")
        case .cloud: return String(localized: "雲端・準確優先")
        }
    }
}

enum DictationRouteSettings {
    static let modeKey = "utuvo.type.dictation.mode"
    static let audioConsentKey = "utuvo.type.dictation.audioUploadAuthorized"
    static let asrProviderKey = "utuvo.type.dictation.asrProvider"
    static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard }

    static func migratedMode(localOnly: Bool, hasCloudKey: Bool, cloudASREnabled: Bool) -> DictationProcessingMode {
        if localOnly { return .local }
        return hasCloudKey || cloudASREnabled ? .cloud : .local
    }

    static var mode: DictationProcessingMode {
        get {
            if let raw = defaults.string(forKey: modeKey), let mode = DictationProcessingMode(rawValue: raw) { return mode }
            let mode = migratedMode(localOnly: UserDefaults.standard.bool(forKey: "utuvo.type.ios.onDeviceOnly"),
                                    hasCloudKey: !SmartCleanup.key(for: SmartCleanup.provider).isEmpty,
                                    cloudASREnabled: UserDefaults.standard.bool(forKey: "utuvo.type.cloudASR.enabled"))
            defaults.set(mode.rawValue, forKey: modeKey)
            // Existing text-only BYOK consent does not authorize uploading recordings.
            defaults.set(UserDefaults.standard.bool(forKey: "utuvo.type.cloudASR.enabled"), forKey: audioConsentKey)
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: modeKey)
            defaults.set(newValue == .cloud, forKey: audioConsentKey)
        }
    }

    static var audioUploadAuthorized: Bool {
        get { _ = mode; return defaults.bool(forKey: audioConsentKey) }
        set { defaults.set(newValue, forKey: audioConsentKey) }
    }

    /// Explicit, pinned ASR selection; changing the polish provider never changes the audio recipient.
    static var asrProvider: SmartCleanup.Provider {
        get {
            if let raw = defaults.string(forKey: asrProviderKey), let provider = SmartCleanup.Provider(rawValue: raw),
               [.groq, .gemini, .dashscope].contains(provider) { return provider }
            let selected = SmartCleanup.provider
            let resolved = [selected, .groq, .gemini, .dashscope].first {
                [.groq, .gemini, .dashscope].contains($0) && !SmartCleanup.key(for: $0).isEmpty
            } ?? .groq
            defaults.set(resolved.rawValue, forKey: asrProviderKey)
            return resolved
        }
        set { defaults.set(newValue.rawValue, forKey: asrProviderKey) }
    }
}

/// Cloud speech must not require Apple's recognizer to be available. When it is
/// available, keep a private transcript in parallel for offline recovery.
enum KeyboardRecognitionPlan: Equatable {
    case local, cloudWithLocalFallback, cloudOnly, unavailable
    static func decide(mode: DictationProcessingMode, localAvailable: Bool, cloudAvailable: Bool) -> Self {
        if mode == .cloud, cloudAvailable { return localAvailable ? .cloudWithLocalFallback : .cloudOnly }
        return localAvailable ? .local : .unavailable
    }
    var usesCloud: Bool { self == .cloudWithLocalFallback || self == .cloudOnly }
    var usesLocal: Bool { self == .local || self == .cloudWithLocalFallback }
}
