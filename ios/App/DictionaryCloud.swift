import Foundation
import UTUVOTypeCore

/// 個人字典 iPhone↔Mac 同步（2026-09-20 產品決定：iCloud＋匯出匯入）。
/// iCloud 鍵值儲存放一份 DictionarySync（每筆時間＋刪除墓碑），兩邊都用「最後改的贏」合併，所以誰先誰後都一樣。
/// 沒登入 iCloud／沒網路時 NSUbiquitousKeyValueStore 什麼都不做，本機照常用。
/// 鍵盤自動學到的字寫在 App Group，下次開主 app 時一起送上去。
protocol CloudKeyValues {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension NSUbiquitousKeyValueStore: CloudKeyValues {}

@MainActor
enum DictionaryCloud {
    static let key = "utuvo.type.dictionary.v1"
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { sync(); return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { _ in MainActor.assumeIsolated { sync() } }
        NSUbiquitousKeyValueStore.default.synchronize()
        sync()
    }

    /// 拉雲端那份合併進本機，本機結果跟雲端不同就推上去。
    static func sync(store: CloudKeyValues = NSUbiquitousKeyValueStore.default, local: DictionaryStore = .shared) {
        let remote = store.data(forKey: key).flatMap { try? DictionarySync.decode($0) }
        if let remote { local.merge(remote) }
        let merged = local.syncState.pruned(now: Date().timeIntervalSince1970)
        if merged != remote {
            store.set(merged.encoded(), forKey: key)
        }
    }
}
