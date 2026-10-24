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
    /// 游標前文字上限（字元）。跟 iOS／Android 一樣 500（context-awareness-1，2026-10-22）。
    public static let beforeCursorLimit = 500
    /// 游標後文字上限（字元）。跟 iOS／Android 一樣 200。
    public static let afterCursorLimit = 200
    /// 游標周圍上下文的請求半徑（字元）＝游標前那一段。舊名保留給既有呼叫端。
    public static let surroundingRadius = beforeCursorLimit
    /// 游標周圍上下文的回傳上限（字元）＝游標前＋游標後。
    public static let surroundingLimit = beforeCursorLimit + afterCursorLimit

    /// 要向 Accessibility 讀的兩段範圍（UTF-16 位置，跟 AX 的 CFRange 一樣）。
    public struct CursorWindows: Equatable, Sendable {
        /// 游標前：一定合法（start ≥ 0、end ＝ 游標），不需要知道欄位總長度。
        public var before: NSRange
        /// 選取之後：要知道欄位總長度才能保證不超出；拿不到總長度＝nil（不讀，不是整段放棄）。
        public var after: NSRange?

        public init(before: NSRange, after: NSRange?) {
            self.before = before
            self.after = after
        }
    }

    /// 游標前後要讀的範圍（純函式）。
    ///
    /// 2026-10-22 實測：舊算法一律請求 `[loc-1000, sel+2000]`，超出欄位長度時 AppKit 的
    /// `AXStringForRange` 直接回 nil（kAXErrorIllegalArgument）——9 個字的聊天欄位、游標在文件結尾，
    /// 最常見的兩種情況都讀不到前文。現在游標前只讀 `[max(0,loc-500), loc)`，一定合法；
    /// 游標後才需要欄位總長度 `count`，拿不到就不送游標後。
    public static func cursorWindows(location: Int, selectionLength: Int, count: Int?) -> CursorWindows {
        var cursor = max(0, location)
        if let count { cursor = min(cursor, max(0, count)) }
        let start = max(0, cursor - beforeCursorLimit)
        let before = NSRange(location: start, length: cursor - start)
        guard let count else { return CursorWindows(before: before, after: nil) }
        let afterStart = cursor + max(0, selectionLength)
        guard afterStart <= count else { return CursorWindows(before: before, after: nil) }
        return CursorWindows(before: before,
                             after: NSRange(location: afterStart, length: min(afterCursorLimit, count - afterStart)))
    }

    /// 游標前文字：留最靠近游標的那一端（suffix），跟 iOS `FieldContext.clampBefore` 同規則。
    public static func clampBeforeCursor(_ text: String?) -> String {
        String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(beforeCursorLimit))
    }

    /// 游標後文字：留緊接游標的那一端（prefix），跟 iOS `FieldContext.clampAfter` 同規則。
    public static func clampAfterCursor(_ text: String?) -> String {
        String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(afterCursorLimit))
    }

    /// 超過上限就截斷；沒超過原樣返回。以 Character 計（一個中文字＝1）。
    public static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    public static func boundedSelectedText(_ text: String) -> String {
        bounded(text, limit: selectedTextLimit)
    }

    /// 選取文字會不會被 [boundedSelectedText] 截斷（以 Character 計，跟截斷同一把尺）。
    public static func selectionExceedsLimit(_ text: String) -> Bool {
        text.count > selectedTextLimit
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
        blockReason(lookup, isBrowser: isBrowser, blockedSites: blockedSites) != nil
    }

    /// 為什麼擋（context-awareness-v2，2026-10-22）：使用者看到的訊息要分清楚是哪一種。
    public enum BlockReason: String, Codable, Equatable, Sendable {
        /// 網址讀得到，而且在「不讀脈絡的網站」清單裡。
        case listed
        /// 網址讀不到（或不知道是不是網頁），為了安全先擋；不代表這個網站在清單裡。
        case unverifiable
    }

    /// 跟 [shouldBlock] 同一套規則，另外說出原因；不擋回 nil。
    public static func blockReason(_ lookup: PageLookup, isBrowser: Bool, blockedSites: [String]) -> BlockReason? {
        let active = blockedSites.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard active else { return nil }
        switch lookup {
        case .notWeb:
            return nil
        case .unknown:
            return .unverifiable
        case .webArea(let url):
            guard let page = url.flatMap(pageLocation(from:)) else { return isBrowser ? .unverifiable : nil }
            return isBlocked(pageLocation: page, blockedSites: blockedSites) ? .listed : nil
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
