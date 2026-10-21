import Foundation
import CryptoKit
import SwiftUI
import UIKit
import LiteRTLM

/// 沒有 Apple Intelligence 的 iPhone：手機上的智慧整理（Gemma 4 E2B，LiteRT-LM，Apache 2.0）。2026-10-11 Micky 核准。
///
/// - 選配下載約 2.5 GB（像「高準確度辨識」），下載完驗 SHA-256；第一次在這支手機上「準備」（寫約 0.8 GB 權重快取）成功後才給整理用。
/// - 一律用 CPU：鍵盤聽寫時主 app 在背景，iOS 不准背景用 GPU（LocalQwenASR 09-24 實機 abort 過）。
/// - 有 Apple Intelligence 的機型不提供（用 Apple 的）；有雲端 key 時仍走雲端（SmartCleanup 的路由不變）。
/// - Android 版同一份設計與實測：`android/app/src/main/kotlin/com/utuvo/type/OnDeviceLlm.kt`。
@MainActor
final class GemmaCleanup: ObservableObject {
    static let shared = GemmaCleanup()

    nonisolated static let fileName = "gemma-4-E2B-it.litertlm"
    /// 釘在 Hugging Face 的固定版本：檔案換了 SHA-256 就對不上，不會默默載入別的模型。
    nonisolated static let url = URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm")!
    nonisolated static let sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    nonisolated static let bytes: Int64 = 2_588_147_712
    nonisolated static let downloadMB = Int(bytes / 1_048_576)
    /// 第一次載入另寫一份權重快取（Android 實測 CPU 788 MB）；寫到一半空間不夠，原生程式會直接 abort 整個 App。
    nonisolated static let cacheBytes: Int64 = 900 * 1_048_576
    nonisolated static var totalGB: String { String(format: "%.1f", Double(bytes + cacheBytes) / 1_000_000_000) }

    enum State: Equatable {
        case unsupported            // 有 Apple Intelligence（用 Apple 的）或記憶體不夠
        case notDownloaded
        case downloading(Double)
        case verifying
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded
    private var downloader: GemmaDownloader?
    private var preparing: Task<Void, Never>?
    private var downloadID: UUID?
    private var memoryObserver: NSObjectProtocol?

    private init() {
        state = Self.initialState()
        // 閒置常駐約 0.6–1.7 GB：系統喊記憶體不足就先放掉，下次講話時再載。
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in Task { await GemmaEngine.shared.unload() } }
    }

    /// 「是否提供」改變時（開發版開關）重算狀態；不動已下載的檔案。
    func refreshOffer() {
        guard downloader == nil, preparing == nil else { return }
        state = Self.initialState()
    }

    /// 主 app 啟動時呼叫：把 Gemma 接到 SmartCleanup（鍵盤聽寫的整理在主 app 做）。
    static func install() {
        _ = shared
        OnDeviceCleanup.fallback = OnDeviceFallback(
            isReady: { GemmaCleanup.isUsable },
            completion: { system, user in try await GemmaEngine.shared.complete(system: system, user: user) },
            prewarm: { Task { try? await GemmaEngine.shared.load() } }
        )
        // 驗證過但還沒準備好（上次準備到一半 App 被關掉）：開 App 就接著準備，不要一直停在「準備中」。
        if shared.state == .preparing { shared.prepare() }
    }

    // MARK: - 這台適不適合

    /// 6 GB 以上（系統回報約 5.5 GB）才提供：2 GB 模型＋App 本身，記憶體太少會被系統收掉。
    /// 門檻寫成常數：這是**實體記憶體（RAM）**，跟磁碟空間（`freeBytes(at:)`）是兩件事，
    /// 介面文案也照這個意思寫（工單 ios-D-repair1 第 3 點）。
    nonisolated static let minimumPhysicalMemory: UInt64 = 5_000_000_000

    nonisolated static var hasEnoughMemory: Bool { ProcessInfo.processInfo.physicalMemory >= minimumPhysicalMemory }

    nonisolated static var isOffered: Bool { !OnDeviceAssistant.onDeviceAvailable && hasEnoughMemory }

    private static func initialState() -> State {
        guard isOffered else { return .unsupported }
        if isPrepared && isVerified { return .ready }
        if isVerified { return .preparing }
        return .notDownloaded
    }

    // MARK: - 檔案（Application Support，不進 iCloud 備份）

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gemma", isDirectory: true)
    }
    nonisolated static var modelURL: URL { directory.appendingPathComponent(fileName) }
    nonisolated static var cacheDirectory: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    private nonisolated static var verifiedMarker: URL { directory.appendingPathComponent(".verified-\(sha256.prefix(12))") }
    nonisolated static var preparedMarker: URL { cacheDirectory.appendingPathComponent("cpu.\(sha256.prefix(12)).ok") }

    nonisolated static var isVerified: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? -1
        return size == bytes && FileManager.default.fileExists(atPath: verifiedMarker.path)
    }
    /// 準備好過（權重快取完整寫好）且快取檔還在。
    nonisolated static var isPrepared: Bool {
        guard FileManager.default.fileExists(atPath: preparedMarker.path) else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        return files.contains { $0.hasPrefix(fileName) && $0.hasSuffix(".xnnpack_cache") }
    }
    /// SmartCleanup 每次整理都會問：只看檔案，不碰網路或模型。
    nonisolated static var isUsable: Bool { isOffered && isVerified && isPrepared }

    nonisolated static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - 下載／驗證／準備／刪除

    func download() {
        guard Self.isOffered else { state = .unsupported; return }
        if case .downloading = state { return }
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = dir; try? excluded.setResourceValues(values)
        let reclaimable = Self.cacheSize()
        guard Self.freeBytes(at: dir) + reclaimable >= Self.bytes + Self.cacheBytes else {
            state = .failed(String(localized: "手機空間不夠：需要約 \(Self.totalGB) GB（模型＋快取）"))
            return
        }
        state = .downloading(0)
        let id = UUID()
        downloadID = id
        let downloader = GemmaDownloader(source: Self.url, destination: Self.modelURL, expectedBytes: Self.bytes) { progress in
            Task { @MainActor in
                guard GemmaCleanup.shared.downloadID == id else { return }
                if case .downloading = GemmaCleanup.shared.state { GemmaCleanup.shared.state = .downloading(progress) }
            }
        } completion: { result in
            // 已取消／被新的下載取代的那一份，回呼一律不理（luna-review iOS r1）。
            Task { @MainActor in
                guard GemmaCleanup.shared.downloadID == id else { return }
                GemmaCleanup.shared.finishDownload(result)
            }
        }
        self.downloader = downloader
        downloader.start()
    }

    func cancelDownload() {
        downloadID = nil
        downloader?.cancel()
        downloader = nil
        try? FileManager.default.removeItem(at: Self.modelURL)
        state = Self.initialState()
    }

    private func finishDownload(_ result: Result<Void, Error>) {
        downloader = nil
        downloadID = nil
        switch result {
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            state = .failed(String(localized: "下載沒有完成：\(error.localizedDescription)"))
        case .success:
            state = .verifying
            Task.detached(priority: .utility) {
                let ok = (try? Self.fileSHA256(Self.modelURL)) == Self.sha256
                await MainActor.run {
                    if ok {
                        try? Data().write(to: Self.verifiedMarker)
                        GemmaCleanup.shared.prepare()
                    } else {
                        try? FileManager.default.removeItem(at: Self.modelURL)
                        GemmaCleanup.shared.state = .failed(String(localized: "下載的檔案檢查不符，已刪除，可以再下載一次"))
                    }
                }
            }
        }
    }

    /// 第一次在這支手機上載入（寫權重快取＋空跑一次）。成功才算 ready，鍵盤聽寫才會用。
    func prepare() {
        guard Self.isVerified else { state = Self.initialState(); return }
        guard preparing == nil else { return }
        state = .preparing
        preparing = Task {
            defer { preparing = nil }
            do {
                try await GemmaEngine.shared.load()
                // 準備途中被刪掉：回到未下載，不要顯示失敗。
                guard Self.isVerified else { state = Self.initialState(); return }
                state = Self.isPrepared ? .ready : .failed(String(localized: "模型準備失敗"))
            } catch _ where !Self.isVerified {
                state = Self.initialState()
            } catch GemmaEngine.Failure.notEnoughSpace {
                state = .failed(String(localized: "第一次準備還需要約 \(Int((Self.cacheBytes + 300 * 1_048_576) / 1_048_576)) MB 空間，清出空間後再按一次"))
            } catch {
                state = .failed(String(localized: "模型準備失敗：\(error.localizedDescription)"))
            }
        }
    }

    /// 推論中按刪除：先叫正在跑的那一輪停、等它真的結束、放掉引擎，才刪檔（luna-review iOS r1）；刪 2.5 GB 不佔主執行緒。
    func delete() async {
        cancelDownload()
        preparing?.cancel()
        await GemmaEngine.shared.shutdown()
        let dir = Self.directory
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }.value
        state = Self.initialState()
    }

    /// 測試／開發用：檔案已經放好（模擬器 simctl 複製、實機 devicectl 推）時，用同一套 SHA-256 檢查後標成已驗證。
    nonisolated static func adoptExistingFile() -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? -1
        guard size == bytes, (try? fileSHA256(modelURL)) == sha256 else { return false }
        return FileManager.default.createFile(atPath: verifiedMarker.path, contents: Data())
    }

    nonisolated static func cacheSize() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    nonisolated static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 模型只在這個 actor 裡碰（Engine／Conversation 不是 Sendable）。一次只跑一輪：前一輪沒結束，下一輪排隊。
actor GemmaEngine {
    static let shared = GemmaEngine()

    enum Failure: Error { case notReady, notEnoughSpace }

    /// 閒置多久放掉模型（鍵盤工作階段之間不一直佔記憶體）。
    static let idleUnload: Duration = .seconds(120)

    private var engine: Engine?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var unloadTask: Task<Void, Never>?
    /// 實際送進模型的整理次數（測試用）。
    private(set) var inferences = 0
    private(set) var lastLoadMs = 0

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            if unloadWhenFree { unloadWhenFree = false; engine = nil }
        } else { waiters.removeFirst().resume() }
    }

    func load() async throws {
        await acquire()
        defer { release() }
        _ = try await loadLocked()
    }

    /// 呼叫端已拿到 busy 閘門（acquire），所以中間的 await 不會讓別的整理插進來。
    private func loadLocked() async throws -> Engine {
        if let engine { scheduleUnload(); return engine }
        guard GemmaCleanup.isVerified else { throw Failure.notReady }
        let start = ContinuousClock.now
        let cache = GemmaCleanup.cacheDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // 記號在、快取檔卻不見了，或沒記號（上次可能寫到一半）：刪掉舊快取，先確認空間夠寫一份，再讓原生程式寫。
        if !GemmaCleanup.isPrepared {
            try? FileManager.default.removeItem(at: GemmaCleanup.preparedMarker)
            let stale = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            stale.filter { $0.lastPathComponent.hasPrefix(GemmaCleanup.fileName) }.forEach { try? FileManager.default.removeItem(at: $0) }
            // 檢查到寫入之間別的 App 也可能在寫：多留 300 MB 裕度（實際快取約 788 MB，門檻 900＋300）。
            guard GemmaCleanup.freeBytes(at: cache) >= GemmaCleanup.cacheBytes + 300 * 1_048_576 else { throw Failure.notEnoughSpace }
        }
        let config = try EngineConfig(modelPath: GemmaCleanup.modelURL.path, backend: .cpu(), cacheDir: cache.path)
        let engine = Engine(engineConfig: config)
        try await engine.initialize()
        // 載入後的第一次推論特別慢：先空跑一個字，真正的整理才不會吃到這段；也順便確認模型真的能跑。
        let warm = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message("只回一個字。", role: .system),
            thinkingConfig: ThinkingConfig(enableThinking: false)))
        _ = try await warm.sendMessage(Message("好"), maxOutputTokens: 1)
        FileManager.default.createFile(atPath: GemmaCleanup.preparedMarker.path, contents: Data())
        self.engine = engine
        lastLoadMs = Int(start.duration(to: .now) / .milliseconds(1))
        scheduleUnload()
        return engine
    }

    /// 一輪整理。呼叫端（SmartCleanup 的 CleanupBudget）逾時會取消 Task → 這裡叫模型停，下一句不用排在沒人要的結果後面。
    func complete(system: String, user: String) async throws -> String {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let engine = try await loadLocked()
        try Task.checkCancellation()
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(system, role: .system),
            // 整理要穩定：只取最可能的字，不要每次說法不同。
            samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
            thinkingConfig: ThinkingConfig(enableThinking: false)))
        try Task.checkCancellation()
        current = conversation
        defer { current = nil }
        inferences += 1
        // 輸出上限：原文 1.6 倍再加一點（把關本來就擋超過 1.55 倍的結果），擋住停不下來的情況。
        let limit = min(600, user.count * 8 / 5 + 48)
        defer { scheduleUnload() }
        return try await withTaskCancellationHandler {
            try await conversation.sendMessage(Message(user), maxOutputTokens: limit).toString
        } onCancel: {
            try? conversation.cancel()
        }
    }

    /// 正在推論時不放（原生 conversation 還掛在這個 engine 上）：等這一輪結束再放。
    func unload() {
        unloadTask?.cancel()
        if busy { unloadWhenFree = true; return }
        engine = nil
    }

    private var unloadWhenFree = false
    private var current: Conversation?

    /// 刪除模型前用：叫正在跑的那一輪停，等閘門空出來再放引擎——回來時保證沒有原生推論在用模型檔。
    func shutdown() async {
        unloadTask?.cancel()
        try? current?.cancel()
        await acquire()
        engine = nil
        unloadWhenFree = false
        release()
    }

    func inferenceCount() -> Int { inferences }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            do { try await Task.sleep(for: Self.idleUnload) } catch { return }
            await self.idleUnloadIfFree()
        }
    }

    private func idleUnloadIfFree() {
        guard !busy else { scheduleUnload(); return }
        engine = nil
    }
}

/// 下載 2.5 GB：前景 URLSession＋進度回報；完成時把暫存檔搬到目的地（delegate 回呼內必須同步搬）。
final class GemmaDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var lastReported = -1

    init(source: URL, destination: URL, expectedBytes: Int64,
         progress: @escaping @Sendable (Double) -> Void,
         completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.source = source
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
        self.completion = completion
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false   // 2.5 GB：只走 Wi-Fi，不吃行動數據
        config.timeoutIntervalForResource = 60 * 60 * 3
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: source).resume()
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        let percent = Int(Double(totalBytesWritten) / Double(total) * 100)
        guard percent != lastReported else { return }
        lastReported = percent
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion(.failure(error)); session.finishTasksAndInvalidate() }
    }
}

/// 設定 → 智慧整理：沒有 Apple Intelligence 的 iPhone 才出現。下載／進度／準備／測試／刪除。
struct GemmaSection: View {
    @ObservedObject private var gemma = GemmaCleanup.shared
    @State private var message: String?
    @State private var messageIsError = false
    @State private var testing = false

    var body: some View {
        Section {
            switch gemma.state {
            case .unsupported:
                LabeledContent("手機上整理", value: String(localized: "這支手機記憶體不夠"))
            case .notDownloaded, .failed:
                Button {
                    TapPulse.shared.fire()
                    gemma.download()
                } label: {
                    Label(String(localized: "下載手機上整理模型（約 \(GemmaCleanup.downloadMB) MB）"), systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("gemmaDownload")
                if case .failed(let reason) = gemma.state {
                    Text(reason).font(.caption).foregroundStyle(.red)
                    if GemmaCleanup.isVerified {
                        Button(String(localized: "再準備一次")) { TapPulse.shared.fire(); gemma.prepare() }
                    }
                }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text(String(localized: "下載中… \(Int(progress * 100))%（請讓 App 留在前景）"))
                }
                Button(String(localized: "取消下載"), role: .destructive) { TapPulse.shared.fire(); gemma.cancelDownload() }
            case .verifying:
                LabeledContent("手機上整理", value: String(localized: "檢查檔案中…"))
            case .preparing:
                LabeledContent("手機上整理", value: String(localized: "第一次準備中（約 1–2 分鐘）…"))
            case .ready:
                LabeledContent("手機上整理", value: SmartCleanup.key(for: SmartCleanup.provider).isEmpty
                               ? String(localized: "已啟用・沒有 key 時使用") : String(localized: "已下載・目前有 key，先用雲端"))
                Button {
                    TapPulse.shared.fire()
                    Task { await test() }
                } label: {
                    Text(testing ? String(localized: "整理中…") : String(localized: "測試手機上整理"))
                }
                .disabled(testing)
                .accessibilityIdentifier("gemmaTest")
                if let message {
                    Text(message).font(.caption).foregroundStyle(messageIsError ? .red : .green)
                        .accessibilityIdentifier("gemmaMessage")
                }
                Button(String(localized: "刪除模型（釋放約 \(GemmaCleanup.totalGB) GB）"), role: .destructive) {
                    TapPulse.shared.fire()
                    Task { await gemma.delete() }
                }
            }
        } header: {
            Text("手機上整理（不用 key）")
        } footer: {
            Text("這支 iPhone 沒有 Apple Intelligence：可以下載 Google 的 Gemma 4 小模型（約 \(GemmaCleanup.downloadMB) MB，只在 Wi-Fi 下載；連同第一次準備的快取共需約 \(GemmaCleanup.totalGB) GB 空間），沒填雲端 key 時改在手機上整理改口和贅詞，文字不離開手機。鍵盤聽寫時 App 在背景、iOS 只給 CPU，每句大約要多等幾秒；專有名詞與錯字修得比雲端少。")
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let start = Date()
        guard let completion = OnDeviceCleanup.fallback?.completion,
              let out = await SmartCleanup.clean(SmartCleanupScreen.sample, language: "zh-TW", timeout: 120,
                                                 configuration: { .init(enabled: true, provider: .groq, endpoint: "", model: "", key: "") },
                                                 onDevice: completion, log: { _, _, _, _ in }) else {
            message = String(localized: "手機上整理這次沒有產生可用結果。")
            messageIsError = true
            return
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        message = String(localized: "可以用（\(ms) 毫秒，CPU）：\(out)")
        messageIsError = false
    }
}
