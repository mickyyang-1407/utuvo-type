import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let channelCount: Int
    let isDefault: Bool

    var displayName: String {
        channelCount > 1 ? "\(name) · \(channelCount) channels" : name
    }
}

enum AudioInputChannel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case average
    case channel1
    case channel2
    case channel3
    case channel4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .average: return "Average all channels"
        case .channel1: return "Channel 1"
        case .channel2: return "Channel 2"
        case .channel3: return "Channel 3"
        case .channel4: return "Channel 4"
        }
    }

    var channelIndex: Int? {
        switch self {
        case .average: return nil
        case .channel1: return 0
        case .channel2: return 1
        case .channel3: return 2
        case .channel4: return 3
        }
    }

    static func available(for channelCount: Int) -> [AudioInputChannel] {
        allCases.filter { option in
            option.channelIndex.map { $0 < channelCount } ?? true
        }
    }
}

enum AudioDeviceCatalog {
    static func inputDevices() -> [AudioDeviceOption] {
        devices(scope: kAudioObjectPropertyScopeInput, defaultUID: defaultInputUID())
    }

    static func outputDevices() -> [AudioDeviceOption] {
        devices(scope: kAudioObjectPropertyScopeOutput, defaultUID: defaultOutputUID())
    }

    static func deviceID(for uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return deviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) == uid }
    }

    static func defaultInputUID() -> String? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
            .flatMap { stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) }
    }

    static func defaultOutputUID() -> String? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
            .flatMap { stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) }
    }

    static func setCurrentInputDevice(uid: String, on audioUnit: AudioUnit?) -> Bool {
        setCurrentDevice(uid: uid, on: audioUnit)
    }

    static func setCurrentOutputDevice(uid: String, on audioUnit: AudioUnit?) -> Bool {
        setCurrentDevice(uid: uid, on: audioUnit)
    }

    static func outputMuted(uid: String) -> Bool? {
        guard let deviceID = deviceID(for: uid) else { return nil }
        return muteProperty(deviceID: deviceID)
    }

    @discardableResult
    static func setOutputMuted(uid: String, muted: Bool) -> Bool {
        guard let deviceID = deviceID(for: uid) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &value
        ) == noErr
    }

    private static func setCurrentDevice(uid: String, on audioUnit: AudioUnit?) -> Bool {
        guard let audioUnit, let selectedDeviceID = deviceID(for: uid) else { return false }
        var deviceID = selectedDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    private static func devices(
        scope: AudioObjectPropertyScope,
        defaultUID: String?
    ) -> [AudioDeviceOption] {
        deviceIDs().compactMap { deviceID in
            let channels = channelCount(deviceID: deviceID, scope: scope)
            guard channels > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID) else {
                return nil
            }
            return AudioDeviceOption(
                id: uid,
                name: name,
                channelCount: channels,
                isDefault: uid == defaultUID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var result = Array(repeating: AudioDeviceID(0), count: count)
        let status = result.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(kAudio_ParamError) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        return status == noErr ? result : []
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        return status == noErr ? deviceID : nil
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementWildcard
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func muteProperty(deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        return status == noErr ? value != 0 : nil
    }
}
