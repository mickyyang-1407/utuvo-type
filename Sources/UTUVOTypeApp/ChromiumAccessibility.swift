import AppKit
import ApplicationServices
import Foundation

/// modes-3（2026-10-22）：Electron／Chromium 系的 App（Claude、Notion、Obsidian、VS Code、Slack、LINE 桌面版……）
/// 預設不建立完整的輔助使用樹，Ask anything／Edit Selection／白話解釋讀不到選取文字。
///
/// 做法：對它們的 **App 元素**設 `AXManualAccessibility = true`（Electron 官方支援的開關），每個行程只設一次。
/// 絕不設 `AXEnhancedUserInterface`——那是給 VoiceOver 的，會讓視窗動畫與定位壞掉。
/// 只在使用者按下讀選取的快捷鍵時才設，平常聽寫不碰（聽寫不需要選取文字）。
///
/// 判斷是不是 Chromium 系看 App bundle 的 `Contents/Frameworks`（唯讀）：
/// - 名字就是 `Electron Framework`／`Chromium Embedded Framework`／`nwjs Framework`；
/// - 或是改過名的「<產品> Framework.framework」（Chrome、Edge、Comet、Lark、Codex……）而且裡面有 Chromium 的
///   `chrome_100_percent.pak`。2026-10-22 本機 /Applications 唯讀掃描：Electron 30 個、CEF 2 個、nwjs 2 個、
///   改名 5 個（Google Chrome／Microsoft Edge／Comet／Lark／Codex），都有這個 pak；Microsoft Office 的
///   `OutlookRightsFramework.framework` 沒有空格也沒有 pak，不算。
@MainActor
final class ChromiumAccessibility {
    static let shared = ChromiumAccessibility()

    /// 要設的屬性。測試釘住：不准換成 AXEnhancedUserInterface。
    static let attributeName = "AXManualAccessibility"

    /// 一定是 Chromium 系的 framework 名稱。
    static let knownFrameworks: Set<String> = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
        "nwjs Framework.framework",
    ]
    /// 改名 framework 裡的 Chromium 資源檔。
    static let chromiumMarker = "chrome_100_percent.pak"

    /// 純函式：framework 名稱清單＋「這個 framework 裡有沒有 Chromium 資源檔」→ 是不是 Chromium 系。
    static func isChromiumBased(frameworkNames: [String], hasChromiumMarker: (String) -> Bool) -> Bool {
        if frameworkNames.contains(where: knownFrameworks.contains) { return true }
        return frameworkNames.contains { $0.hasSuffix(" Framework.framework") && hasChromiumMarker($0) }
    }

    /// (pid) → 是不是 Chromium 系。測試注入；正式讀 App bundle（唯讀）。
    var detector: (Int32) -> Bool = { pid in ChromiumAccessibility.bundleIsChromium(pid: pid) }
    /// (pid) → 設定成功沒。測試注入假的；正式才真的對那個 App 設屬性。
    var setter: (Int32) -> Bool = { pid in ChromiumAccessibility.setManualAccessibility(pid: pid) }

    /// 處理過的行程（pid＋啟動時間，避免 pid 被重複使用時誤判）。
    private var handled: [String: Bool] = [:]

    /// 需要的話打開；回傳 true＝**這次剛打開**（Chromium 要一點時間建樹，呼叫端可稍等再讀選取）。
    /// 同一個行程第二次起一律回 false，不會重設。
    @discardableResult
    func enableIfNeeded(pid: Int32, launchKey: String = "") -> Bool {
        let key = "\(pid)|\(launchKey)"
        if handled[key] != nil { return false }
        guard detector(pid) else { handled[key] = false; return false }
        let ok = setter(pid)
        handled[key] = ok
        return ok
    }

    /// 前景 App：讀選取前呼叫。
    @discardableResult
    func enableForFrontmostApp() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let launched = app.launchDate.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return enableIfNeeded(pid: app.processIdentifier, launchKey: launched)
    }

    private static func bundleIsChromium(pid: Int32) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return isChromiumBased(frameworkNames: names) { name in
            let resources = frameworks.appendingPathComponent(name).appendingPathComponent("Resources")
            return FileManager.default.fileExists(atPath: resources.appendingPathComponent(chromiumMarker).path)
        }
    }

    private static func setManualAccessibility(pid: Int32) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return AXUIElementSetAttributeValue(app, attributeName as CFString, kCFBooleanTrue) == .success
    }
}
