import Foundation
import OSLog

/// 歷史紀錄存成 Application Support/UTUVO Type/history.json（app-shell-1 Part A，2026-10-22）。
///
/// 以前整份歷史是 UserDefaults 裡的一個 JSON 字串，預設只留 20 筆還撐得住；文字紀錄改成預設全部保留後，
/// 每次聽寫都要把整份 plist 重寫一次。現在：
/// - 寫入：先寫暫存檔再原子替換（`Data.write(options: .atomic)`），寫到一半當機不會留下半份檔案。
/// - 搬家只搬一次：第一次啟動把 UserDefaults 那份寫成檔案、讀回來確認筆數一樣，才刪掉 UserDefaults 那份；
///   確認不過就保留舊的，下次再搬。檔案已經在了還看到舊字串（降版再升版時舊版寫的），就併進來（同 id 以檔案為準）。
/// - 檔案讀不出來：改名成 history.unreadable-<時間>.json 留著，不拿空陣列蓋掉。
enum HistoryStorage {
    private static let log = Logger(subsystem: "com.utuvo.type", category: "history")

    static func load(fileURL: URL, defaults: UserDefaults, legacyKey: String) -> [HistoryRecord] {
        let fm = FileManager.default
        var records: [HistoryRecord] = []
        var fileReadable = false
        if fm.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), let decoded = decode(data) {
                records = decoded
                fileReadable = true
            } else {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let aside = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("history.unreadable-\(stamp).json")
                try? fm.moveItem(at: fileURL, to: aside)
                log.error("history.json unreadable; moved aside")
            }
        }
        guard let legacy = defaults.string(forKey: legacyKey) else { return records }
        guard let legacyData = legacy.data(using: .utf8), let legacyRecords = decode(legacyData) else {
            // 舊字串解不開：不動它（留著不刪），也不把它當成空的。
            log.error("legacy history string unreadable; left in place")
            return records
        }
        let known = Set(records.map(\.id))
        let merged = (records + legacyRecords.filter { !known.contains($0.id) }).sorted { $0.date > $1.date }
        guard save(merged, to: fileURL),
              let data = try? Data(contentsOf: fileURL), let readBack = decode(data), readBack.count == merged.count else {
            log.error("history migration not verified; legacy string kept")
            return fileReadable ? merged : legacyRecords
        }
        defaults.removeObject(forKey: legacyKey)
        return merged
    }

    @discardableResult
    static func save(_ records: [HistoryRecord], to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            log.error("history save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func decode(_ data: Data) -> [HistoryRecord]? {
        try? JSONDecoder().decode([HistoryRecord].self, from: data)
    }
}
