import Foundation

/// 開源防呆（docs/OPEN-SOURCE-READINESS.md §二）：偵測本機引擎缺件，
/// 並從 General「安裝本機引擎」按鈕跑 scripts/bootstrap-runtime.sh、串流輸出進度。
/// 原則：不會在使用者不知情時下載任何東西——下載只發生在使用者按下按鈕之後。
enum RuntimeBootstrap {
    /// ASR 模型落點（相對 repo root），與 bootstrap-runtime.sh 一致。
    static let modelRelativePath = ".models/asr/Qwen3-ASR-0.6B-6bit"

    /// 找「引擎 root」＝放 scripts/bootstrap-runtime.sh 與 runtime/ 的目錄：
    /// UTUVO_TYPE_ROOT 最優先 → dist/ 內的 app 往上兩層（開發）→ cwd → app bundle 內建的
    /// Contents/Resources/engine（DMG／App 版，build-app.sh 會打包進去）。
    /// 找不到就回 nil（不顯示安裝卡）。
    static func locateRepoRoot() -> String? {
        var candidates: [String] = []
        if let root = ProcessInfo.processInfo.environment["UTUVO_TYPE_ROOT"], !root.isEmpty {
            candidates.append(root)
        }
        // dist/UTUVO Type.app → 上兩層是 repo root
        candidates.append(
            URL(fileURLWithPath: Bundle.main.bundlePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        )
        candidates.append(FileManager.default.currentDirectoryPath)
        if let bundled = bundledEngineRoot { candidates.append(bundled) }
        return candidates.first { hasScript($0) }
    }

    /// app bundle 內建的引擎腳本（Contents/Resources/engine）。
    static var bundledEngineRoot: String? {
        Bundle.main.resourceURL?.appendingPathComponent("engine", isDirectory: true).path
    }

    /// venv 與模型實際落地的目錄。從 repo 跑＝repo root；用 bundle 內建引擎時
    /// ＝~/Library/Application Support/UTUVO Type/engine（簽過名的 bundle 不能寫）。
    static func engineHome(for root: String) -> String {
        if let bundled = bundledEngineRoot, root == bundled {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            return base.appendingPathComponent(AppBrand.displayName, isDirectory: true)
                .appendingPathComponent("engine", isDirectory: true).path
        }
        return root
    }

    /// 給 runtime wrapper／bootstrap 的環境變數：告訴它們 venv 與模型在哪。
    static func engineEnvironment(root: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let root {
            environment["UTUVO_TYPE_ENGINE_HOME"] = engineHome(for: root)
        }
        return environment
    }

    static func hasScript(_ root: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: root).appendingPathComponent("scripts/bootstrap-runtime.sh").path
        )
    }

    /// 引擎已裝齊：venv python 可執行＋模型目錄非空。任一缺件＝需要安裝。
    static func isEngineInstalled(root: String) -> Bool {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: engineHome(for: root))
        guard fm.isExecutableFile(atPath: base.appendingPathComponent(".runtime/bin/python").path) else {
            return false
        }
        let modelDir = base.appendingPathComponent(modelRelativePath).path
        guard let contents = try? fm.contentsOfDirectory(atPath: modelDir) else { return false }
        return !contents.isEmpty
    }

    /// 目前執行中的安裝進程（app 結束時 terminate，避免孤兒下載）。
    private static let activeProcessLock = NSLock()
    private static nonisolated(unsafe) var _activeProcess: Process?
    @discardableResult
    static func terminateActive() -> Bool {
        activeProcessLock.lock()
        let process = _activeProcess
        activeProcessLock.unlock()
        guard let process, process.isRunning else { return false }
        process.terminate()
        return true
    }

    /// 跑 bootstrap 腳本，stdout/stderr 逐段回報。回傳 nil 代表根本沒啟動（completion 已帶 false）。
    /// completion 保證在「進程結束且輸出排空」後才呼叫（輸出遲遲不排空則最多再等 drainTimeout 秒）。
    @discardableResult
    static func run(
        root: String,
        onChunk: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    ) -> Process? {
        let script = URL(fileURLWithPath: root).appendingPathComponent("scripts/bootstrap-runtime.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            onChunk("[install] 找不到 scripts/bootstrap-runtime.sh；app bundle 內建引擎缺件，請重新下載 DMG 或從 repo 的 dist/ 啟動。\n")
            completion(false)
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        process.environment = engineEnvironment(root: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        activeProcessLock.lock()
        _activeProcess = process
        activeProcessLock.unlock()

        do {
            try process.run()
        } catch {
            onChunk("[install] 無法啟動安裝腳本：\(error.localizedDescription)\n")
            completion(false)
            return nil
        }

        // 讀取與結束的順序：terminationHandler 可能早於 pipe 排空（煙囪測試會 spawn 子進程，
        // 子進程若持有 stdout 會讓 EOF 延後），所以 completion 等「排空或 drainTimeout」兩者先到。
        let drained = DispatchSemaphore(value: 0)
        let drainTimeout: DispatchTime = .now() + 5
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForReading
            // 行緩衝：UTF-8 中文字可能被 chunk 邊界切開，累積到換行再吐，避免 log 亂碼。
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.subdata(in: pending.startIndex..<newline)
                    if let text = String(data: lineData, encoding: .utf8) {
                        onChunk(text + "\n")
                    }
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty, let text = String(data: pending, encoding: .utf8) {
                onChunk(text + "\n")
            }
            drained.signal()
        }
        process.terminationHandler = { [weak process] proc in
            _ = drained.wait(timeout: drainTimeout)
            activeProcessLock.lock()
            if _activeProcess === process { _activeProcess = nil }
            activeProcessLock.unlock()
            completion(proc.terminationStatus == 0)
        }
        return process
    }
}
