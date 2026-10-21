import Foundation

/// 讀取使用者畫面內容的硬上限（2026-09-11 抽出）。
///
/// 產品的隱私宣稱是「只讀 focused 欄位的選取文字與它周圍一小段，不截圖、不讀整份文件」。
/// 在此之前這兩個數字是散在 `AccessibilitySupport` 裡的 magic number，**沒有任何測試**——
/// 有人把 12_000 改成 120_000 不會有東西變紅，而綠燈跟「沒在檢查」長得一模一樣。
/// 常數與截斷邏輯移到這裡，`ContextBoundsTests` 釘住。
public enum ContextBounds: Sendable {
    /// 選取文字上限（字元）。
    public static let selectedTextLimit = 12_000
    /// 游標周圍上下文的請求半徑（字元）。
    public static let surroundingRadius = 1_000
    /// 游標周圍上下文的回傳上限（字元）。
    public static let surroundingLimit = 2_000

    /// 超過上限就截斷；沒超過原樣返回。以 Character 計（一個中文字＝1）。
    public static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    public static func boundedSelectedText(_ text: String) -> String {
        bounded(text, limit: selectedTextLimit)
    }

    public static func boundedSurroundingText(_ text: String) -> String {
        bounded(text, limit: surroundingLimit)
    }

    /// 視窗標題、欄位提示文字上限（字元）。
    public static let titleLimit = 120
    /// 網頁位置上限（字元）。
    public static let pageLocationLimit = 200

    /// 網址只留「網域＋路徑」：拿掉帳號密碼、查詢參數（常帶 token／搜尋字）與 # 片段。非 http(s) 不收。
    public static func pageLocation(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let path = components.path == "/" ? "" : components.path
        return bounded(host + path, limit: pageLocationLimit)
    }

    /// 敏感網站（使用者清單）：網域相同或是它的子網域就擋；擋到的話整份脈絡都不送，只留 App 名稱。
    public static func isBlocked(pageLocation: String?, blockedSites: [String]) -> Bool {
        guard let page = pageLocation?.lowercased(), !page.isEmpty else { return false }
        let host = page.split(separator: "/", maxSplits: 1).first.map(String.init) ?? page
        return blockedSites.contains { raw in
            // 清單項目只看網域：使用者貼整個網址（含路徑）也擋整個網域，寧可多擋（luna-review r4）。
            let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            let site = stripped.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard !site.isEmpty else { return false }
            return host == site || host.hasSuffix("." + site)
        }
    }

    /// 往上找網頁區塊的結果。
    public enum PageLookup: Equatable, Sendable {
        /// 爬到 App 頂層都沒有網頁區塊＝不是網頁內容。
        case notWeb
        /// 在網頁區塊裡；網址可能讀不到（nil）或不是 http(s)。
        case webArea(url: String?)
        /// 層數／時間用完或 AX 讀不到父節點＝不知道。
        case unknown
    }

    /// 要不要擋（擋＝連選取文字都不讀）。有封鎖清單時，不確定的一律偏向擋（luna-review r3／r4）：
    /// - 不知道是不是網頁 → 擋；
    /// - 瀏覽器裡的網頁但網址讀不到或不是 http(s)（擴充功能頁、密碼管理器彈窗）→ 擋；
    /// - 非瀏覽器 App 裡的網頁區塊（Electron 的 app:// 或 file://）沒有網站可比 → 不擋，否則 Slack／Notion 全部失效。
    public static func shouldBlock(_ lookup: PageLookup, isBrowser: Bool, blockedSites: [String]) -> Bool {
        let active = blockedSites.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard active else { return false }
        switch lookup {
        case .notWeb:
            return false
        case .unknown:
            return true
        case .webArea(let url):
            guard let page = url.flatMap(pageLocation(from:)) else { return isBrowser }
            return isBlocked(pageLocation: page, blockedSites: blockedSites)
        }
    }

    /// 已知瀏覽器（bundle id 前綴比對）。
    public static let browserBundlePrefixes = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.", "com.brave.Browser",
        "com.microsoft.edgemac", "org.mozilla.", "com.operasoftware.", "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS", "org.chromium.Chromium", "ai.perplexity.comet",
    ]

    public static func isBrowser(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier else { return false }
        return browserBundlePrefixes.contains { id.hasPrefix($0) }
    }

    /// 預設擋掉的網站：密碼管理器、登入頁、付款。使用者可在設定改。
    public static let defaultBlockedSites = [
        "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com",
        "1password.com", "bitwarden.com", "lastpass.com", "paypal.com", "stripe.com"
    ]
}
