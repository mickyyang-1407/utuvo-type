import Foundation
import UTUVOTypeCore

/// 個人字典儲存（App＋鍵盤擴展共享）。
/// 格式與 macOS `AppPreferences.dictionary` 對齊：JSON `[String: String]`。
/// 儲存在 App Group UserDefaults；group 不可用時 fallback 回標準 defaults
/// （此時鍵盤讀不到——僅影響擴展，app 內功能不受損）。
struct DictionaryStore {
    // UserDefaults 本身執行緒安全；struct 無可變狀態，標 unsafe 關閉 Swift 6 檢查。
    nonisolated(unsafe) static let shared = DictionaryStore()

    private let defaults: UserDefaults
    private let key = "utuvo.type.ios.dictionary"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard
    }

    var dictionary: [String: String] {
        guard let json = defaults.string(forKey: key),
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    func set(_ entries: [String: String]) {
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key)
    }

    func addTerm(source: String, output: String) {
        update { $0.set(source, output, at: Date().timeIntervalSince1970) }
    }

    func removeTerm(source: String) {
        update { $0.remove(source, at: Date().timeIntervalSince1970) }
    }

    // MARK: - 跨裝置同步（iCloud、匯出／匯入；格式見 core DictionarySync）

    private var syncKey: String { key + ".sync" }

    /// 同步紀錄（每筆時間＋刪除墓碑）；有人直接改過 dictionary（舊版、set(_:)）就先對齊。
    var syncState: DictionarySync {
        let stored = defaults.data(forKey: syncKey).flatMap { try? DictionarySync.decode($0) }
        let plain = dictionary
        guard var state = stored else { return DictionarySync(plain: plain) }
        state.reconcile(with: plain, at: Date().timeIntervalSince1970)
        return state
    }

    /// 寫入同步紀錄＋它的有效部分（鍵盤與整理流程讀的那份）。
    func write(_ state: DictionarySync) {
        defaults.set(state.encoded(), forKey: syncKey)
        set(state.live)
    }

    private func update(_ change: (inout DictionarySync) -> Void) {
        var state = syncState
        change(&state)
        write(state)
    }

    /// 匯出檔（含時間與刪除紀錄；另一台匯入時最後改的贏）。
    func exportData() -> Data {
        syncState.pruned(now: Date().timeIntervalSince1970).encoded()
    }

    /// 匯入／從 iCloud 合併；回傳有幾個詞因此新增、修改或刪除。
    @discardableResult
    func merge(_ incoming: DictionarySync) -> Int {
        let before = dictionary
        write(syncState.merged(with: incoming))
        let after = dictionary
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.count
    }
}
