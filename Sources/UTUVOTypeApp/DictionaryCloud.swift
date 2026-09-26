import Foundation
import UTUVOTypeCore

@MainActor
protocol DictionaryCloudStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
}

@MainActor
final class UbiquitousDictionaryStore: DictionaryCloudStore {
    let store = NSUbiquitousKeyValueStore.default
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
}

@MainActor
enum DictionaryCloud {
    static let key = "utuvo.type.dictionary.v1"
    private static var observer: NSObjectProtocol?
    private static var activeStore: UbiquitousDictionaryStore?

    static func start(_ preferences: AppPreferences) {
        guard preferences.isolation == nil else { return }
        if activeStore == nil { activeStore = UbiquitousDictionaryStore() }
        guard let store = activeStore else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store.store, queue: .main
            ) { [weak preferences] _ in
                MainActor.assumeIsolated { if let preferences { sync(preferences) } }
            }
            store.store.synchronize()
        }
        sync(preferences, store: store)
    }

    /// Explicit stores run the same production merge on isolated test preferences.
    static func sync(_ preferences: AppPreferences, store injected: (any DictionaryCloudStore)? = nil) {
        guard injected != nil || preferences.isolation == nil else { return }
        guard let store = injected ?? activeStore else { return }
        let remote = store.data(forKey: key).flatMap { try? DictionarySync.decode($0) }
        if let remote { preferences.mergeDictionary(remote) }
        let merged = preferences.dictionarySync.pruned(now: Date().timeIntervalSince1970)
        if merged != remote { store.set(merged.encoded(), forKey: key) }
    }
}
