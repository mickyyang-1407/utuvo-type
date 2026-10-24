import Foundation

/// Mac 歷史紀錄與錄音的保留規則（app-shell-1 Part A，2026-10-22）。純函式：`now` 由呼叫端傳入。
///
/// 以前只有一個「自動刪除錄音」選項，預設只留最新 20 筆——超過的不只刪錄音，連文字紀錄都刪掉。
/// 現在拆成兩個：
/// - **文字紀錄**（`text`／`textLimit`）：規則跟以前**一模一樣**（加星號的不刪；期限選項也套筆數上限）。
///   從沒動過這個設定的人預設改成「全部保留」（Typeless `historyDurationSeconds` 預設 -1＝永遠）。
/// - **錄音**（`audio`／`audioLimit`）：超出時只刪 .caf、把那筆的 `audioPath` 設成 nil，文字留著。
///   加星號的不刪；只有錄音、沒有逐字稿、**還能重試**的紀錄（辨識失敗／轉錄前取消）也不刪——錄音是那段話唯一的一份，
///   刪了就救不回來。不能重試的（Edit Selection 要重新選取原文字）照錄音規則刪（repair-batch1）。
/// - 還沒重試、錄音還在、可以重新辨識的「辨識失敗」紀錄（`HistoryRecord.holdsRetryableAudio`），文字的期限與筆數
///   也不刪它，也不佔筆數名額（repair-batch1：以前「只留最新 3 筆」會把它連錄音一起刪掉）。
///   錄音檔要**真的還在**（`audioExists`）：檔案被外部刪掉的那筆不能重試（按鈕是關的），照一般文字規則刪
///   （repair round 2：以前只看 `audioPath` 有沒有值，變成一筆不能重試、也永遠清不掉的紀錄）。
///   轉錄前就取消的紀錄沒有這個例外，照文字規則刪（設定頁註腳 `SettingsView.retentionFootnote`）。
enum HistoryRetention {
    struct Plan: Equatable {
        /// 留下來的紀錄（新到舊）；超出錄音保留的那幾筆 `audioPath` 已經是 nil。
        var kept: [HistoryRecord]
        /// 整筆刪掉的紀錄（錄音也要刪）。
        var removed: [HistoryRecord]
        /// 只刪錄音、文字留著的那幾筆原本的錄音路徑。
        var strippedAudioPaths: [String]

        /// 要刪掉的錄音檔（整筆刪的＋只刪錄音的）。
        var deletedAudioPaths: [String] { removed.compactMap(\.audioPath) + strippedAudioPaths }
    }

    static func cutoff(_ policy: AutoDeletePolicy, now: Date) -> Date? {
        switch policy {
        case .keepAll, .latestLimit: return nil
        case .afterOneDay: return now.addingTimeInterval(-86_400)
        case .afterOneWeek: return now.addingTimeInterval(-604_800)
        case .afterOneMonth: return now.addingTimeInterval(-2_592_000)
        }
    }

    /// - Parameter audioExists: 錄音檔還在不在（測試可注入）；只對「辨識失敗、還能重試」的那幾筆問。
    static func plan(_ records: [HistoryRecord], text: AutoDeletePolicy, textLimit: Int,
                     audio: AutoDeletePolicy, audioLimit: Int, now: Date,
                     audioExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan {
        // 文字：照搬原本 trimHistoryIfNeeded 的規則（行為保持）；還能重試的失敗紀錄不參與（repair-batch1）。
        let pendingIDs = Set(records.filter { record in
            guard record.holdsRetryableAudio, let path = record.audioPath else { return false }
            return audioExists(path)
        }.map(\.id))
        let pending = records.filter { pendingIDs.contains($0.id) }
        var filtered = records.filter { !pendingIDs.contains($0.id) }
        if let cutoff = cutoff(text, now: now) {
            filtered = filtered.filter { $0.isStarred || $0.date >= cutoff }
        }
        if text != .keepAll {
            let starred = filtered.filter(\.isStarred)
            let unstarred = filtered.filter { !$0.isStarred }
            let remaining = max(0, textLimit - starred.count)
            filtered = starred + Array(unstarred.prefix(remaining))
        }
        var kept = (filtered + pending).sorted { $0.date > $1.date }
        let keptIDs = Set(kept.map(\.id))
        let removed = records.filter { !keptIDs.contains($0.id) }

        // 錄音：同一套期限＋筆數，只看還有錄音、可以刪錄音的那幾筆。
        var stripped: [String] = []
        let audioCutoff = cutoff(audio, now: now)
        var withAudioSeen = 0
        for index in kept.indices {
            guard let path = kept[index].audioPath, !kept[index].isStarred,
                  !(kept[index].isAudioOnly && kept[index].isRetryable(hasAudio: true)) else { continue }
            var drop = false
            if let audioCutoff, kept[index].date < audioCutoff { drop = true }
            if audio != .keepAll, !drop {
                withAudioSeen += 1
                if withAudioSeen > max(0, audioLimit) { drop = true }
            }
            if drop {
                stripped.append(path)
                kept[index].audioPath = nil
            }
        }
        return Plan(kept: kept, removed: removed, strippedAudioPaths: stripped)
    }
}
