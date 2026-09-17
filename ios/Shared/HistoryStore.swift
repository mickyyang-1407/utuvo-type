import Foundation

/// 聽寫歷史（iOS 版）。JSON 檔存在 App Group container，鍵盤可讀最近一筆。
/// 與 macOS HistoryRecord 不共用型別（macOS 版綁 AppKit preferences），語意對齊即可。
struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()
    var raw: String
    var cleaned: String
    var starred: Bool = false
    /// 這筆是從哪裡進來的（app 主畫面或鍵盤）。舊檔沒有這個欄位＝主畫面。
    var source: Source = .app

    enum Source: String, Codable, Sendable {
        case app
        case keyboard
    }
}

struct HistoryStore: Sendable {
    /// 上限與 macOS historyLimit 精神一致；測試會釘住這個數字。
    static let maxRecords = 500

    static let shared = HistoryStore()

    private let fileURL: URL?
    private let queue = DispatchQueue(label: "utuvo.type.ios.history")

    /// - Parameters:
    ///   - directory: 直接指定資料夾（測試用；正式路徑不傳）。
    ///   - defaults: 舊有的 `utuvo.type.ios.historyDir` 覆寫路徑。
    init(directory: URL? = nil, defaults: UserDefaults? = nil) {
        if let directory {
            self.fileURL = directory.appendingPathComponent("history.json")
        } else if let defaults,
           let dir = defaults.url(forKey: "utuvo.type.ios.historyDir") {
            self.fileURL = dir.appendingPathComponent("history.json")
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.utuvo.type") {
            self.fileURL = container.appendingPathComponent("history.json")
        } else {
            // group 不可用：退回 app 自己的 Documents（app 內功能完整，僅鍵盤讀不到）
            self.fileURL = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("history.json")
        }
    }

    func load() -> [DictationRecord] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([DictationRecord].self, from: data) else {
            return []
        }
        return records
    }

    func append(_ record: DictationRecord) {
        queue.sync {
            var records = load()
            records.insert(record, at: 0)
            if records.count > Self.maxRecords {
                records.removeLast(records.count - Self.maxRecords)
            }
            save(records)
        }
    }

    func save(_ records: [DictationRecord]) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
