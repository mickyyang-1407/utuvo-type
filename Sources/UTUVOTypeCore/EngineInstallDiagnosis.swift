import Foundation

/// 本機引擎安裝失敗的診斷：把 bootstrap／pip／curl 的 log 翻成「哪裡壞了、怎麼修、一鍵指令」。
/// 純函式、無 UI、可測。原則：使用者不必讀 25 行 pip 輸出，也不必懂 Python。
public struct EngineInstallDiagnosis: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case xcodeLicense        // Xcode 授權未同意，clang 拒跑
        case missingCompiler     // 沒有 Command Line Tools／clang（舊版 bootstrap 才會需要）
        case noPrebuiltWheel     // 某套件沒有預編 wheel（新版 bootstrap --only-binary 直接紅）
        case network             // 下載失敗／逾時／DNS
        case diskFull
        case permissionDenied
        case notAppleSilicon
        case cancelled
        case unknown
    }

    public let kind: Kind
    /// 一句話講哪裡壞（zh／en）。
    public let summaryZh: String
    public let summaryEn: String
    /// 使用者要做什麼（zh／en）。
    public let fixZh: String
    public let fixEn: String
    /// 能在終端機直接執行的修復指令（沒有就 nil）。
    public let command: String?
    /// 修完再按重試有沒有意義（false＝這台跑不了／要回報）。
    public let retryable: Bool
    /// 需要把 log 回報給開發者（沒 wheel、未知）。
    public let needsReport: Bool

    /// 依序比對；第一個命中的規則就是答案（排序＝越具體越前面）。
    public static func diagnose(log: String, cancelled: Bool = false) -> EngineInstallDiagnosis {
        if cancelled {
            return .init(kind: .cancelled,
                         summaryZh: "安裝已取消。", summaryEn: "Install was cancelled.",
                         fixZh: "隨時可以再按「安裝本機引擎」，會從斷點接著跑。",
                         fixEn: "Press “Install local engine” again any time; it resumes where it stopped.",
                         command: nil, retryable: true, needsReport: false)
        }
        let text = log
        func has(_ needles: String...) -> Bool {
            needles.contains { text.range(of: $0, options: .caseInsensitive) != nil }
        }

        if has("not agreed to the Xcode license", "xcodebuild -license") {
            return .init(kind: .xcodeLicense,
                         summaryZh: "這台 Mac 的 Xcode 授權還沒同意，系統不讓編譯器執行。",
                         summaryEn: "Xcode’s license hasn’t been accepted on this Mac, so the compiler refuses to run.",
                         fixZh: "在「終端機」執行下面這行（會要求你的登入密碼），完成後回來按「重試安裝」。",
                         fixEn: "Run the command below in Terminal (it asks for your login password), then come back and press “Retry install”.",
                         command: "sudo xcodebuild -license accept", retryable: true, needsReport: false)
        }
        if has("No developer tools were found", "invalid active developer path", "clang: command not found",
               "xcrun: error", "xcode-select --install") {
            return .init(kind: .missingCompiler,
                         summaryZh: "安裝過程需要 Apple 的 Command Line Tools，這台還沒有。",
                         summaryEn: "The install needs Apple’s Command Line Tools, which aren’t on this Mac.",
                         fixZh: "在「終端機」執行下面這行，跟著系統視窗裝完（約 1 GB），再按「重試安裝」。",
                         fixEn: "Run the command below in Terminal, follow the system prompt (about 1 GB), then press “Retry install”.",
                         command: "xcode-select --install", retryable: true, needsReport: false)
        }
        if has("No matching distribution found", "Building wheel for", "Failed building wheel",
               "Failed to build installable wheels") {
            return .init(kind: .noPrebuiltWheel,
                         summaryZh: "有一個 Python 套件在這台找不到預編版本，安裝停在那裡。",
                         summaryEn: "One Python package has no prebuilt build for this Mac, so the install stopped there.",
                         fixZh: "這不是你的問題，是我們要修的。請按「回報問題」把紀錄送給我們；安裝前可先用雲端模式。",
                         fixEn: "This is on us, not you. Please use “Report issue” to send us the log; cloud mode works in the meantime.",
                         command: nil, retryable: false, needsReport: true)
        }
        if has("No space left on device", "Disk quota exceeded") {
            return .init(kind: .diskFull,
                         summaryZh: "磁碟空間不夠（模型約 1.2 GB，加上執行環境約 2 GB）。",
                         summaryEn: "Not enough disk space (the model is about 1.2 GB; with the runtime about 2 GB).",
                         fixZh: "清出至少 3 GB 後按「重試安裝」。",
                         fixEn: "Free at least 3 GB and press “Retry install”.",
                         command: nil, retryable: true, needsReport: false)
        }
        if has("Permission denied", "Operation not permitted", "Read-only file system") {
            return .init(kind: .permissionDenied,
                         summaryZh: "沒辦法寫入安裝資料夾（Application Support）。",
                         summaryEn: "Couldn’t write to the install folder (Application Support).",
                         fixZh: "確認 UTUVO Type 沒有被「檔案與資料夾」權限擋住，或把 app 搬到「應用程式」再開一次。",
                         fixEn: "Check that UTUVO Type isn’t blocked under Files and Folders privacy, or move the app to Applications and relaunch.",
                         command: nil, retryable: true, needsReport: false)
        }
        if has("需要 Apple Silicon", "requires Apple Silicon") {
            return .init(kind: .notAppleSilicon,
                         summaryZh: "這台不是 Apple Silicon，跑不了本機引擎。",
                         summaryEn: "This Mac isn’t Apple silicon, so the local engine can’t run here.",
                         fixZh: "到 設定 → 雲端 加入 API key，改走雲端聽寫。",
                         fixEn: "Add an API key under Settings → Cloud and dictate through the cloud instead.",
                         command: nil, retryable: false, needsReport: false)
        }
        if has("Could not fetch URL", "Read timed out", "ReadTimeoutError", "Temporary failure in name resolution",
               "nodename nor servname provided", "Failed to establish a new connection", "Connection refused",
               "curl: (6)", "curl: (7)", "curl: (28)", "curl: (35)", "curl: (56)",
               "下載獨立版 Python 失敗", "模型下載失敗", "查不到獨立版 Python", "ConnectionResetError", "SSLError") {
            return .init(kind: .network,
                         summaryZh: "下載中斷：連不上 Python／模型的下載來源。",
                         summaryEn: "Download interrupted: couldn’t reach the Python or model download source.",
                         fixZh: "確認網路（公司／學校網路可能擋 GitHub 或 Hugging Face），再按「重試安裝」，會從斷點續傳。",
                         fixEn: "Check your connection (some office/school networks block GitHub or Hugging Face), then press “Retry install”; downloads resume.",
                         command: nil, retryable: true, needsReport: false)
        }
        return .init(kind: .unknown,
                     summaryZh: "安裝失敗，原因我們還沒看過。",
                     summaryEn: "The install failed for a reason we haven’t seen before.",
                     fixZh: "按「回報問題」把紀錄送給我們，我們會回信；安裝前可先用雲端模式。",
                     fixEn: "Use “Report issue” to send us the log and we’ll get back to you; cloud mode works in the meantime.",
                     command: nil, retryable: true, needsReport: true)
    }

    /// 回報用的 log 摘要：留最後 N 行、去掉家目錄路徑（不把使用者名稱送出去）。
    public static func reportExcerpt(log: String, maxLines: Int = 60) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines)
        let home = NSHomeDirectory()
        return lines.map { line -> String in
            var s = String(line)
            if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
            // /Users/<name>/ 形式也遮（log 裡可能是別的使用者路徑或 /private/var 展開）
            if let re = try? NSRegularExpression(pattern: "/Users/[^/\\s]+") {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "~")
            }
            return s
        }.joined(separator: "\n")
    }
}
