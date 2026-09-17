import Foundation

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
        var entries = dictionary
        entries[source] = output.isEmpty ? source : output
        set(entries)
    }

    func removeTerm(source: String) {
        var entries = dictionary
        entries.removeValue(forKey: source)
        set(entries)
    }
}
