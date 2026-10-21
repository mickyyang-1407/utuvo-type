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
    /// 錄音長度（秒）。**選填**：舊紀錄沒有這個欄位 decode 會得到 nil（＝未知），
    /// 不能讓整份 history.json 讀不出來（dictation 一次就沒了）。
    var duration: Double?

    enum Source: String, Codable, Sendable {
        case app
        case keyboard
    }

    /// 有時長的紀錄（算平均 WPM 用；沒時長的不算）。
    var knownDuration: Double? {
        guard let duration, duration > 0 else { return nil }
        return duration
    }

    /// 自己寫 `init(from:)` 會讓編譯器不再產生 memberwise init，所以補回來
    /// （呼叫端還在用 `DictationRecord(raw:cleaned:source:)` 這種寫法）。
    init(id: UUID = UUID(), date: Date = Date(), raw: String, cleaned: String,
         starred: Bool = false, source: Source = .app, duration: Double? = nil) {
        self.id = id
        self.date = date
        self.raw = raw
        self.cleaned = cleaned
        self.starred = starred
        self.source = source
        self.duration = duration
    }

    /// 手寫 decode：**舊檔會缺欄位**（沒有 source、沒有 duration）。
    /// Swift 合成的 `init(from:)` 遇到缺 key 會直接丟 keyNotFound，等於整份 history.json 讀不出來——
    /// 一次聽寫就全沒了。合成解碼**不會**拿屬性的預設值補缺，所以這裡逐欄 decodeIfPresent 自己補。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        raw = try c.decode(String.self, forKey: .raw)
        cleaned = try c.decode(String.self, forKey: .cleaned)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .app   // 舊檔＝主 app
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)        // 舊檔＝未知
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
        // 「不保留」＝之後不寫歷史（使用數據照算，在呼叫端另外記 DailyUsageStore）。
        guard RetentionSettings.policy != .none else { return }
        withExclusiveAccess { records in
            records.insert(record, at: 0)
            if records.count > Self.maxRecords {
                records.removeLast(records.count - Self.maxRecords)
            }
        }
    }

    /// 跨 process 的讀-改-寫，和 `DailyUsageStore` 同一套：外面包 `NSFileCoordinator`，
    /// 否則鍵盤與主 app 同時 append 時後寫的整份會蓋掉先寫的那筆。
    /// 協調失敗**不寫**，只記 log（無鎖寫入正是要防的覆蓋）。
    /// 測試直接呼叫它驗證「連續兩次 append 兩筆都在」。
    func withExclusiveAccess(_ body: (inout [DictationRecord]) -> Void) {
        guard let url = fileURL else { return }
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("[]".utf8).write(to: url, options: .atomic)
        }

        var coordinationError: NSError?
        var ran = false
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { _ in
            ran = true
            queue.sync {
                var records = load()
                body(&records)
                save(records)
            }
        }
        if !ran {
            UsageLog.write("HistoryStore: 拿不到檔案協調鎖，這筆歷史沒有寫入（error=\(coordinationError?.localizedDescription ?? "closure 未觸發")）")
        }
    }

    func save(_ records: [DictationRecord]) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 歷史保留期限的設定（App Group，鍵盤不必讀，主 app 寫就夠）。
enum RetentionSettings {
    static let key = "utuvo.type.ios.history.retention"

    static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard }

    static var policy: RetentionPolicy {
        get {
            guard let raw = defaults.string(forKey: key), let p = RetentionPolicy(rawValue: raw) else { return .default }
            return p
        }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
