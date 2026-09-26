import Foundation

/// Owns only a unique suite and a unique child directory. Never adopts live state.
struct IsolatedContext {
    let userDefaults: UserDefaults
    let applicationSupportDirectory: URL
    let recordingsDirectory: URL
    let logDirectory: URL
    let suiteName: String
    let cleanupProvidersFolder: URL
    private let ownedRoot: URL
    private let ownershipToken: String
    let disableCloudSync = true
    let skipGlobalShortcut = true
    let disableMicrophonePermission = true
    let allowRealCleanupNetwork = false
    static let isolationMarkerKey = "utuvo.type.isolationMarker"
    static let defaultSuiteName = "com.utuvo.type.isolated.tests"

    static func make(suiteName: String = defaultSuiteName, baseDirectory: URL? = nil) throws -> IsolatedContext {
        let token = UUID().uuidString
        let name = "com.utuvo.type.isolated.\(token)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let root = (baseDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("utuvo-type-isolated-\(token)", isDirectory: true)
        let support = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let recordings = support.appendingPathComponent("Recordings", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let cleanup = root.appendingPathComponent("Cleanup", isDirectory: true)
        for directory in [support, recordings, logs, cleanup] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try token.write(to: root.appendingPathComponent(".owner"), atomically: true, encoding: .utf8)
        defaults.set(name, forKey: isolationMarkerKey)
        return IsolatedContext(userDefaults: defaults, applicationSupportDirectory: support,
            recordingsDirectory: recordings, logDirectory: logs, suiteName: name,
            cleanupProvidersFolder: cleanup, ownedRoot: root, ownershipToken: token)
    }

    static func preview() throws -> IsolatedContext { try make() }

    func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        guard ownedRoot.lastPathComponent == "utuvo-type-isolated-\(ownershipToken)",
              (try? String(contentsOf: ownedRoot.appendingPathComponent(".owner"), encoding: .utf8)) == ownershipToken else { return }
        try? FileManager.default.removeItem(at: ownedRoot)
    }
}
