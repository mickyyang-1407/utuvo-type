import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// app-shell-1 Part A（2026-10-22）：Mac 歷史紀錄保留。全部在隔離 suite／資料夾跑。
@MainActor
final class HistoryRetentionTests: XCTestCase {
    private typealias Keys = AppPreferences.Keys

    /// 一筆有真的錄音檔的紀錄（第 i 筆，i 越大越新）。
    private func record(_ i: Int, in preferences: AppPreferences, starred: Bool = false,
                        transcript: String = "合成測試文字") throws -> HistoryRecord {
        let id = UUID()
        let url = preferences.recordingsDirectory.appendingPathComponent("\(id.uuidString).caf")
        try FileManager.default.createDirectory(at: preferences.recordingsDirectory, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: url)
        return HistoryRecord(id: id, date: Date().addingTimeInterval(TimeInterval(i - 1_000)), rawTranscript: transcript,
                             output: transcript, duration: 1, mode: .fast, audioPath: url.path, isStarred: starred)
    }

    private func fill(_ preferences: AppPreferences, count: Int) throws {
        for i in 0..<count { preferences.appendHistory(try record(i, in: preferences), countsTowardStats: false) }
    }

    private func recordingFiles(_ preferences: AppPreferences) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: preferences.recordingsDirectory.path)) ?? []).count
    }

    // MARK: - 預設：沒動過的人文字全部保留

    /// 以前全新安裝只留最新 20 筆（連文字一起刪）。
    func testFreshInstallKeepsMoreThanTwentyTextEntries() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.autoDeletePolicy, .keepAll)
        try fill(preferences, count: 25)
        XCTAssertEqual(preferences.historyRecords.count, 25)
        XCTAssertNil(context.userDefaults.object(forKey: Keys.autoDeletePolicy), "沒動過就不寫：永遠吃目前的預設")
        XCTAssertEqual(AppPreferences(isolation: context).historyRecords.count, 25, "重開還在")
    }

    /// 錄音照舊只留最新 20 個：超出的只刪 .caf、audioPath 設成 nil，文字留著。
    func testFreshInstallKeepsOnlyLatestTwentyRecordings() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.audioRetentionPolicy, .latestLimit)
        XCTAssertEqual(preferences.audioRetentionLimit, 20)
        try fill(preferences, count: 25)
        let records = preferences.historyRecords
        XCTAssertEqual(records.count, 25)
        XCTAssertEqual(records.prefix(20).filter { $0.audioPath != nil }.count, 20, "最新 20 筆有錄音")
        XCTAssertEqual(records.dropFirst(20).filter { $0.audioPath != nil }.count, 0, "第 21 筆以後沒有錄音")
        XCTAssertTrue(records.allSatisfy { $0.output == "合成測試文字" }, "文字都在")
        XCTAssertEqual(recordingFiles(preferences), 20, "Recordings 資料夾只剩 20 個檔")
        // 寫回去了：重開也一樣。
        XCTAssertEqual(AppPreferences(isolation: context).historyRecords.filter { $0.audioPath != nil }.count, 20)
    }

    /// 加星號的、只有錄音沒有逐字稿的（辨識失敗），錄音都不刪，也不佔 20 個名額。
    func testStarredAndAudioOnlyEntriesKeepTheirRecordings() throws {
        let now = Date()
        func entry(_ i: Int, starred: Bool = false, transcript: String = "字") -> HistoryRecord {
            HistoryRecord(date: now.addingTimeInterval(TimeInterval(-i)), rawTranscript: transcript, output: transcript,
                          duration: 1, mode: .fast, audioPath: "/r/\(i).caf", isStarred: starred)
        }
        let records = [entry(0), entry(1, transcript: ""), entry(2), entry(3, starred: true), entry(4)]
        let plan = HistoryRetention.plan(records, text: .keepAll, textLimit: 20, audio: .latestLimit, audioLimit: 1, now: now)
        XCTAssertEqual(plan.kept.map(\.audioPath), ["/r/0.caf", "/r/1.caf", nil, "/r/3.caf", nil])
        XCTAssertEqual(plan.strippedAudioPaths, ["/r/2.caf", "/r/4.caf"])
        XCTAssertTrue(plan.removed.isEmpty)
    }

    /// 文字的規則照搬（行為保持）：期限之外、加星號的不刪；期限選項也套筆數上限。
    func testTextRulesAreUnchanged() {
        let now = Date()
        let records = (0..<6).map { i in
            HistoryRecord(date: now.addingTimeInterval(TimeInterval(-i) * 86_400 - 60), rawTranscript: "字", output: "字",
                          duration: 1, mode: .fast, isStarred: i == 5)
        }
        let week = HistoryRetention.plan(records, text: .afterOneDay, textLimit: 500, audio: .keepAll, audioLimit: 1, now: now)
        XCTAssertEqual(week.kept.count, 2, "1 天內的 1 筆＋加星號的 1 筆")
        let limited = HistoryRetention.plan(records, text: .afterOneMonth, textLimit: 3, audio: .keepAll, audioLimit: 1, now: now)
        XCTAssertEqual(limited.kept.count, 3, "期限選項也套筆數上限（星號佔名額）")
        XCTAssertTrue(limited.kept.contains { $0.isStarred })
        let all = HistoryRetention.plan(records, text: .keepAll, textLimit: 1, audio: .keepAll, audioLimit: 1, now: now)
        XCTAssertEqual(all.kept.count, 6)
    }

    // MARK: - 明確選過的照原設定；錄音遷移不多刪

    func testExplicitLatestLimitChoiceIsKept() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(AutoDeletePolicy.latestLimit.rawValue, forKey: Keys.autoDeletePolicy)
        context.userDefaults.set(30, forKey: Keys.historyLimit)
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.autoDeletePolicy, .latestLimit)
        XCTAssertEqual(preferences.historyLimit, 30)
        XCTAssertEqual(preferences.audioRetentionPolicy, .latestLimit, "錄音跟以前一樣跟著文字")
        XCTAssertEqual(preferences.audioRetentionLimit, 30)
        try fill(preferences, count: 35)
        XCTAssertEqual(preferences.historyRecords.count, 30)
        XCTAssertEqual(preferences.historyRecords.filter { $0.audioPath != nil }.count, 30, "留下的 30 筆錄音一個都沒多刪")
        XCTAssertEqual(recordingFiles(preferences), 30)
    }

    /// 選過期限的人：錄音遷移成同一個期限（以前錄音跟文字一起到期），只轉一次；之後改文字的期限不會連帶改錄音。
    func testAudioRetentionMigratesOnceFromExplicitTextChoice() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(AutoDeletePolicy.afterOneWeek.rawValue, forKey: Keys.autoDeletePolicy)
        let first = AppPreferences(isolation: context)
        XCTAssertEqual(first.audioRetentionPolicy, .afterOneWeek)
        XCTAssertEqual(context.userDefaults.string(forKey: Keys.audioRetentionPolicy), AutoDeletePolicy.afterOneWeek.rawValue)
        first.autoDeletePolicy = .keepAll
        let second = AppPreferences(isolation: context)
        XCTAssertEqual(second.autoDeletePolicy, .keepAll)
        XCTAssertEqual(second.audioRetentionPolicy, .afterOneWeek, "錄音保留不被文字的改動帶走")
    }

    /// repair-batch1：b8817d8 的「歷史筆數上限」欄位一直顯示、不用先選期限——只打過筆數（期限的 key 從沒寫過）
    /// 的人，當時生效的是「只留最新 N 筆」。升級後要照舊只留 N 筆，不能變成全部保留。
    func testExplicitHistoryLimitWithoutPolicyIsKeptAsLatestLimit() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(5, forKey: Keys.historyLimit)
        XCTAssertNil(context.userDefaults.object(forKey: Keys.autoDeletePolicy))
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.autoDeletePolicy, .latestLimit, "打過筆數＝明確設定過保留")
        XCTAssertEqual(preferences.historyLimit, 5)
        XCTAssertEqual(preferences.audioRetentionPolicy, .latestLimit)
        XCTAssertEqual(preferences.audioRetentionLimit, 5)
        try fill(preferences, count: 5)
        try fill(preferences, count: 3)
        XCTAssertEqual(preferences.historyRecords.count, 5, "b8817d8 只留 5 筆，升級後也一樣")
        XCTAssertEqual(recordingFiles(preferences), 5)
        let reopened = AppPreferences(isolation: context)
        XCTAssertEqual(reopened.autoDeletePolicy, .latestLimit, "重開還是一樣")
        XCTAssertEqual(reopened.historyRecords.count, 5)
        XCTAssertTrue(reopened.showsTextHistoryLimit, "設定頁顯示那一列，看得到自己設的 5")
        XCTAssertEqual(reopened.retentionSettings.textLimit, 5)
    }

    /// 兩個 key 都沒寫過的人才是「從沒動過」：文字全部保留（行為不變）。
    func testOnlyUsersWithNeitherKeyGetKeepAll() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        XCTAssertNil(context.userDefaults.object(forKey: Keys.historyLimit))
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.autoDeletePolicy, .keepAll)
        XCTAssertFalse(preferences.showsTextHistoryLimit, "全部保留時筆數沒有作用，不顯示")
    }

    // MARK: - 辨識失敗、還能重試的紀錄（repair-batch1）

    private func failedRecord(_ i: Int, in preferences: AppPreferences, mode: FormatterMode = .fast) throws -> HistoryRecord {
        var entry = try record(i, in: preferences, transcript: "")
        entry.mode = mode
        entry.note = "合成的失敗原因"
        entry.status = .failed
        return entry
    }

    /// 明確只留最新 3 筆：還沒重試、錄音還在的辨識失敗紀錄不能被文字的筆數上限整筆刪掉（錄音是那段話唯一的一份）。
    func testTextRetentionKeepsRetryableFailedRowAndItsAudio() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(AutoDeletePolicy.latestLimit.rawValue, forKey: Keys.autoDeletePolicy)
        context.userDefaults.set(3, forKey: Keys.historyLimit)
        let preferences = AppPreferences(isolation: context)
        let failed = try failedRecord(0, in: preferences)
        preferences.appendHistory(failed, countsTowardStats: false)
        for i in 1...3 { preferences.appendHistory(try record(i, in: preferences), countsTowardStats: false) }

        let records = preferences.historyRecords
        let kept = try XCTUnwrap(records.first { $0.id == failed.id }, "辨識失敗的那筆還在")
        XCTAssertEqual(kept.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(kept.audioPath)), "錄音還在才能重試")
        XCTAssertEqual(records.filter { $0.status == nil }.count, 3, "一般紀錄照樣只留最新 3 筆")
        XCTAssertEqual(AppPreferences(isolation: context).historyRecords.contains { $0.id == failed.id }, true, "重開還在")

        // 期限也一樣：一天前的失敗紀錄不因「1 天後刪除」被刪。
        let now = Date()
        var old = failed
        old.date = now.addingTimeInterval(-3 * 86_400)
        let plan = HistoryRetention.plan([old], text: .afterOneDay, textLimit: 1, audio: .afterOneDay, audioLimit: 1, now: now)
        XCTAssertEqual(plan.kept.map(\.id), [old.id])
        XCTAssertEqual(plan.kept.first?.audioPath, old.audioPath)
        XCTAssertTrue(plan.deletedAudioPaths.isEmpty)
    }

    /// repair round 2：辨識失敗、但錄音檔已經不在了（例如自己清掉 Recordings 資料夾）＝不能重試、按鈕是關的。
    /// 以前「文字保留不刪」的例外只看 audioPath 有沒有值：變成一筆不能重試、也永遠清不掉的紀錄。現在照一般文字規則。
    func testFailedRowWhoseRecordingIsGoneFollowsTextRetention() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(AutoDeletePolicy.latestLimit.rawValue, forKey: Keys.autoDeletePolicy)
        context.userDefaults.set(3, forKey: Keys.historyLimit)
        let preferences = AppPreferences(isolation: context)
        let gone = try failedRecord(0, in: preferences)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(gone.audioPath))
        XCTAssertFalse(gone.retryAvailable(audioExists: false), "錄音不在：重試按鈕是關的")
        preferences.appendHistory(gone, countsTowardStats: false)
        for i in 1...3 { preferences.appendHistory(try record(i, in: preferences), countsTowardStats: false) }
        XCTAssertFalse(preferences.historyRecords.contains { $0.id == gone.id }, "不能重試的失敗紀錄照筆數上限刪")
        XCTAssertEqual(preferences.historyRecords.count, 3)

        // 期限也一樣；錄音還在的那一筆照舊不刪（對照）。
        let now = Date()
        var oldGone = gone
        oldGone.date = now.addingTimeInterval(-3 * 86_400)
        var oldKept = try failedRecord(1, in: preferences)
        oldKept.date = now.addingTimeInterval(-3 * 86_400)
        let plan = HistoryRetention.plan([oldKept, oldGone], text: .afterOneDay, textLimit: 500, audio: .keepAll,
                                         audioLimit: 1, now: now)
        XCTAssertEqual(plan.kept.map(\.id), [oldKept.id], "錄音還在的照舊不刪；錄音不在的照期限刪")
        XCTAssertEqual(plan.removed.map(\.id), [oldGone.id])
    }

    /// 轉錄前就取消、只有錄音、可以重試的紀錄：錄音保留不刪它的錄音，但文字保留照規則刪（使用者自己取消的，
    /// 明確設了「只留最新幾筆」就照那個數字）。設定頁註腳只對「辨識失敗」承諾文字保留不刪（repair round 2）。
    func testCancelledAudioOnlyRowFollowsTextRetentionButKeepsAudioUnderAudioRetention() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        let now = Date()
        var cancelled = try record(0, in: preferences, transcript: "")
        cancelled.status = .cancelled
        cancelled.date = now.addingTimeInterval(-10)
        XCTAssertTrue(cancelled.retryAvailable(audioExists: true), "可以重試")
        XCTAssertFalse(cancelled.holdsRetryableAudio, "文字保留的例外只給辨識失敗")
        var newer = [try record(1, in: preferences), try record(2, in: preferences)]
        newer[0].date = now.addingTimeInterval(-5)
        newer[1].date = now
        let records = newer.reversed() + [cancelled]

        let audioOnly = HistoryRetention.plan(records, text: .keepAll, textLimit: 2, audio: .latestLimit, audioLimit: 1, now: now)
        XCTAssertEqual(audioOnly.kept.first { $0.id == cancelled.id }?.audioPath, cancelled.audioPath, "錄音保留不刪它的錄音")

        let textLimited = HistoryRetention.plan(records, text: .latestLimit, textLimit: 2, audio: .keepAll, audioLimit: 1, now: now)
        XCTAssertFalse(textLimited.kept.contains { $0.id == cancelled.id }, "明確只留 2 筆：照規則刪")

        let footnote = SettingsView.retentionFootnote(zh: true)
        XCTAssertFalse(footnote.contains("轉錄前取消"), "註腳不再把轉錄前取消的紀錄說成會保留：\(footnote)")
        XCTAssertTrue(footnote.contains("辨識失敗"), footnote)
        XCTAssertTrue(footnote.contains("錄音還在"), "例外只給錄音檔還在的那筆（錄音被刪掉的照規則刪）：\(footnote)")
        let english = SettingsView.retentionFootnote(zh: false)
        XCTAssertFalse(english.contains("failed ones are never deleted"), "英文也不再說失敗的一律不刪：\(english)")
        XCTAssertTrue(english.contains("still there"), english)
    }

    /// 不能重試的失敗紀錄（Edit Selection 要重新選取原文字）不享有「錄音不刪」的例外：照錄音保留規則刪錄音。
    func testUnretryableFailedRowIsNotExemptFromAudioRetention() throws {
        let now = Date()
        func entry(_ i: Int, mode: FormatterMode = .fast, transcript: String = "字", status: HistoryStatus? = nil) -> HistoryRecord {
            HistoryRecord(date: now.addingTimeInterval(TimeInterval(-i)), rawTranscript: transcript, output: transcript,
                          duration: 1, mode: mode, audioPath: "/r/\(i).caf", status: status)
        }
        let editFailed = entry(3, mode: .editSelection, transcript: "", status: .failed)
        let records = [entry(0), entry(1), entry(2), editFailed]
        let plan = HistoryRetention.plan(records, text: .keepAll, textLimit: 20, audio: .latestLimit, audioLimit: 1, now: now)
        XCTAssertEqual(plan.kept.count, 4, "文字留著")
        XCTAssertNil(plan.kept.first { $0.id == editFailed.id }?.audioPath, "不能重試的錄音照規則刪")
        XCTAssertTrue(plan.strippedAudioPaths.contains("/r/3.caf"))

        // 文字的筆數上限也不保護它（只保護還能重試的失敗紀錄）。
        let limited = HistoryRetention.plan(records, text: .latestLimit, textLimit: 3, audio: .keepAll, audioLimit: 1, now: now)
        XCTAssertFalse(limited.kept.contains { $0.id == editFailed.id })
    }

    /// 不能從歷史重試的失敗／取消紀錄（Edit Selection），「重試」按鈕關掉；正常紀錄的規則不變。
    func testRetryAvailabilityFollowsRetryPolicy() {
        func entry(mode: FormatterMode, transcript: String, status: HistoryStatus?, note: String? = nil) -> HistoryRecord {
            HistoryRecord(rawTranscript: transcript, output: status == nil ? transcript : "", duration: 1, mode: mode,
                          audioPath: "/r/x.caf", note: note, status: status)
        }
        let editFailed = entry(mode: .editSelection, transcript: "", status: .failed)
        XCTAssertFalse(editFailed.retryAvailable(audioExists: true), "按了也只會說要重新選取：按鈕關掉")
        XCTAssertFalse(editFailed.isRetryable(hasAudio: true))
        XCTAssertFalse(editFailed.holdsRetryableAudio)
        XCTAssertEqual(RetryPolicy.decide(mode: .editSelection, isRecording: false, isProcessing: false, isAskAnything: false,
                                          rawTranscript: "", hasAudio: true), .needsReselection, "跟重試的決策一致")
        XCTAssertFalse(entry(mode: .editSelection, transcript: "改正式一點", status: .cancelled).retryAvailable(audioExists: true))

        let fastFailed = entry(mode: .fast, transcript: "", status: .failed)
        XCTAssertTrue(fastFailed.retryAvailable(audioExists: true))
        XCTAssertFalse(fastFailed.retryAvailable(audioExists: false), "錄音被刪了就沒得重試")
        XCTAssertTrue(fastFailed.holdsRetryableAudio)
        XCTAssertTrue(entry(mode: .smart, transcript: "字", status: .cancelled).retryAvailable(audioExists: false), "有逐字稿就能重新整理")

        // 正常完成的紀錄：規則不變。
        XCTAssertTrue(entry(mode: .editSelection, transcript: "改正式一點", status: nil).retryAvailable(audioExists: true))
        XCTAssertFalse(entry(mode: .fast, transcript: "問題", status: nil, note: HistoryRecord.askAnythingNote).retryAvailable(audioExists: true))
        XCTAssertTrue(entry(mode: .fast, transcript: "字", status: nil).retryAvailable(audioExists: false))
    }

    func testExplicitKeepAllKeepsAllRecordingsToo() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(AutoDeletePolicy.keepAll.rawValue, forKey: Keys.autoDeletePolicy)
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.audioRetentionPolicy, .keepAll)
        try fill(preferences, count: 25)
        XCTAssertEqual(recordingFiles(preferences), 25)
    }

    // MARK: - 筆數夾值、改短先算

    /// 以前記憶體裡不夾值：欄位打 0 會用 0 去刪（沒加星號的全刪）。
    func testHistoryLimitIsClampedInMemory() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.autoDeletePolicy = .latestLimit
        try fill(preferences, count: 3)
        preferences.historyLimit = 0
        XCTAssertEqual(preferences.historyLimit, 1)
        XCTAssertEqual(preferences.historyRecords.count, 1, "最少留 1 筆，不是 0")
        preferences.historyLimit = 9_999
        XCTAssertEqual(preferences.historyLimit, 500)
    }

    func testRetentionImpactCountsWithoutDeletingAndApplyTrimsOnce() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        try fill(preferences, count: 25)
        var shorter = preferences.retentionSettings
        shorter.text = .latestLimit
        shorter.textLimit = 10
        let impact = preferences.retentionImpact(of: shorter)
        XCTAssertEqual(impact, AppPreferences.RetentionImpact(removedEntries: 15, removedRecordings: 15 - 5),
                       "第 11–25 筆刪掉；其中只有 5 個還有錄音（錄音只留最新 20）")
        XCTAssertEqual(preferences.historyRecords.count, 25, "只算、不刪")
        XCTAssertTrue(preferences.retentionImpact(of: preferences.retentionSettings).isEmpty)

        // 一次套用：先把筆數改小、再改成全部保留，中間狀態不能先刪掉紀錄。
        var looser = preferences.retentionSettings
        looser.textLimit = 5
        looser.text = .keepAll
        preferences.applyRetention(looser)
        XCTAssertEqual(preferences.historyRecords.count, 25)

        preferences.applyRetention(shorter)
        XCTAssertEqual(preferences.historyRecords.count, 10)
        XCTAssertEqual(AppPreferences(isolation: context).historyRecords.count, 10, "刪掉的寫回去了，重開不會回來")
    }

    // MARK: - 存放：UserDefaults → history.json（只搬一次）

    private let legacyJSON = """
    [{"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0001","date":782000300,"rawTranscript":"一","output":"一","duration":1,"mode":"fast","isStarred":false},\
    {"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0002","date":782000200,"rawTranscript":"二","output":"二","duration":1,"mode":"smart","isStarred":true,"note":"n"},\
    {"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0003","date":782000100,"rawTranscript":"三","output":"三","duration":1,"mode":"deep","isStarred":false}]
    """

    func testLegacyHistoryMovesToFileOnce() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(legacyJSON, forKey: Keys.historyJSON)
        let first = AppPreferences(isolation: context)
        XCTAssertEqual(first.historyRecords.map(\.output), ["一", "二", "三"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.historyFileURL.path))
        XCTAssertNil(context.userDefaults.string(forKey: Keys.historyJSON), "確認寫好才刪舊的那份")
        XCTAssertEqual(first.historyRecords[1].note, "n")
        XCTAssertTrue(first.historyRecords[1].isStarred)

        let second = AppPreferences(isolation: context)
        XCTAssertEqual(second.historyRecords.count, 3, "不重複搬")
        second.appendHistory(HistoryRecord(rawTranscript: "四", output: "四", duration: 1, mode: .fast))
        XCTAssertNil(context.userDefaults.string(forKey: Keys.historyJSON), "新的寫到檔案，不再寫 UserDefaults")
        XCTAssertEqual(AppPreferences(isolation: context).historyRecords.count, 4)
    }

    /// 降版再升版：舊版又寫了一份到 UserDefaults，併進來（同 id 以檔案為準），不丟。
    func testLeftoverLegacyHistoryIsMergedNotDropped() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.appendHistory(HistoryRecord(rawTranscript: "檔案", output: "檔案", duration: 1, mode: .fast))
        context.userDefaults.set(legacyJSON, forKey: Keys.historyJSON)
        let reopened = AppPreferences(isolation: context)
        XCTAssertEqual(reopened.historyRecords.count, 4)
        XCTAssertNil(context.userDefaults.string(forKey: Keys.historyJSON))
    }

    /// 檔案壞了：改名留著，不拿空陣列蓋掉；清空歷史時一起刪。
    func testUnreadableHistoryFileIsSetAsideNotOverwritten() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let file = context.applicationSupportDirectory.appendingPathComponent(AppPreferences.historyFileName)
        try Data("{not json".utf8).write(to: file)
        let preferences = AppPreferences(isolation: context)
        XCTAssertTrue(preferences.historyRecords.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: context.applicationSupportDirectory.path)
            .filter { $0.hasPrefix("history.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        let asideName = try XCTUnwrap(aside.first, "壞掉的檔案要改名留著")
        let kept = try Data(contentsOf: context.applicationSupportDirectory.appendingPathComponent(asideName))
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "{not json")
        preferences.appendHistory(HistoryRecord(rawTranscript: "新", output: "新", duration: 1, mode: .fast))
        XCTAssertEqual(AppPreferences(isolation: context).historyRecords.count, 1)
        preferences.clearHistory()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: context.applicationSupportDirectory.path)
            .filter { $0.hasPrefix("history.unreadable-") }.isEmpty, "清空歷史連壞掉的那份一起清")
    }
}
