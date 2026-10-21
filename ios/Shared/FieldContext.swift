import Foundation

/// 送整理時的「輸入欄位脈絡」組裝（純函式，可單元測試；不碰 UIKit）。
///
/// 從鍵盤拿到的只有 `textDocumentProxy`：**拿不到宿主 App 名稱**（iOS 的鍵盤 extension 沒有這項 API），
/// 所以這裡不填 appName，只填使用者輸入框裡的前後文與欄位語意。
///
/// 三個長度上限（照鐵律：新的上下文欄位要有字數上限）：
/// - 游標前文字 500 字（沿用既有 `appContextBlock` 的上限）
/// - 游標後文字 200 字（工單指定）
/// - 欄位提示 120 字
enum FieldContext {

    // MARK: - 上限（具名常數，測試與提示詞共用同一組數字）

    /// 游標前文字上限（沿用既有行為，不因為這張工單變動）。
    static let beforeLimit = 500
    /// 游標後文字上限（工單指定）。
    static let afterLimit = 200
    /// 欄位提示文字上限。
    static let hintLimit = 120

    // MARK: - 輸入

    /// 宿主欄位長什麼樣。鍵盤把 `textDocumentProxy` 的值轉成這個結構，
    /// 這裡就能在沒有 UIKit 的情況下測試（`UITextContentType` 的判定集中在一處）。
    struct Field: Equatable, Sendable {
        /// `keyboardType`（.emailAddress／.URL／.numberPad…）。
        var keyboardKind: String
        /// `returnKeyType`（.send／.search／.go…）。
        var returnKeyKind: String
        /// `textContentType` 的 rawValue（.emailAddress／.URL／.oneTimeCode…）；nil＝拿不到。
        var contentType: String?
        /// `isSecureTextEntry`。
        var isSecure: Bool

        init(keyboardKind: String = "default", returnKeyKind: String = "default",
             contentType: String? = nil, isSecure: Bool = false) {
            self.keyboardKind = keyboardKind
            self.returnKeyKind = returnKeyKind
            self.contentType = contentType
            self.isSecure = isSecure
        }
    }

    // MARK: - 密碼／一次性密碼：整份不送

    /// 這些 `textContentType` 是密碼或一次性驗證碼 → **前後文與欄位提示整份不送**。
    /// `isSecureTextEntry` 為真同樣不送（iOS 的密碼框就是這樣標的）。
    static let secretContentTypes: Set<String> = ["password", "newPassword", "oneTimeCode"]

    /// 信用卡欄位 → **整份不送**（工單 ios-C 第 3 點）。
    ///
    /// 為什麼信用卡也整份不送：信用卡號與安全碼是**個資 + 可用性極高的憑證**，使用者不會在信用卡欄位裡
    /// 打「要整理的句子」，前後文對整理毫無價值卻會外流一串卡號。UIKit 的信用卡 rawValue 全部以
    /// `cc-` 開頭（`cc-number`／`cc-csc`／`cc-exp`／`cc-exp-month`／`cc-exp-year`／`cc-name`／
    /// `cc-given-name`／`cc-family-name`／`cc-type`…），且各 OS 版會新增，所以用**前綴**收斂，
    /// `UIKitFieldMapping` 也把整個家族映射成同一個內部名稱。
    static let creditCardPrefix = "cc-"
    /// `UIKitFieldMapping` 把整個信用卡家族映射成的內部名稱（定義放在不碰 UIKit 的這裡，那邊引用）。
    static let creditCardKind = "creditCard"
    static let creditCardContentTypes: Set<String> = [creditCardKind]

    /// 數字／電話鍵盤 + 看起來像驗證碼的回車鍵 → 當成驗證碼欄位。
    ///
    /// 只看「數字鍵盤」不夠（金額、年份、電話、序號都會用到數字鍵盤），所以要再看一次回車鍵。
    /// 收斂得很緊：只有**「送出型」**的回車鍵（前往／下一個／搜尋／送出／加入／路線）才算，
    /// 「完成／換行／預設」不算——那是一般數字欄（金額、數量、電話）最常見的組合，
    /// 把它們當驗證碼會擋掉一大堆正當的脈絡。
    ///
    /// 真正明確的驗證碼欄位由 `textContentType == .oneTimeCode` 判定（上面 `allowsContext` 已擋），
    /// 這裡只是 `textContentType` 拿不到時的保守補充。
    static let otpReturnKeys: Set<String> = ["go", "next", "search", "send", "join", "route"]

    static func isOTPField(_ field: Field) -> Bool {
        let numeric = field.keyboardKind == "numberPad" || field.keyboardKind == "phonePad" || field.keyboardKind == "asciiCapableNumberPad"
        guard numeric else { return false }
        return otpReturnKeys.contains(field.returnKeyKind)
    }

    /// 這張票的第一條鐵律：**密碼／一次性密碼欄位，前後文與欄位提示整份不送。**
    static func allowsContext(_ field: Field) -> Bool {
        if field.isSecure { return false }
        if let contentType = field.contentType {
            if secretContentTypes.contains(contentType) { return false }
            // 信用卡：映射後是 creditCardKind，直接照原始 rawValue 也擋（雙保險，兩條路徑都對）。
            if creditCardContentTypes.contains(contentType) { return false }
            if contentType.hasPrefix(creditCardPrefix) { return false }
        }
        if isOTPField(field) { return false }
        return true
    }

    // MARK: - 欄位語意提示

    /// 欄位類型 → 一句給整理服務看的提示（例：搜尋欄、網址、Email）。
    /// 純字串、不含使用者文字；沒有認得出來的類型回 nil（不要湊）。
    static func fieldHint(_ field: Field) -> String? {
        guard allowsContext(field) else { return nil }
        // textContentType 說得最準，優先用它。**鍵名是 `UITextContentType` 的 rawValue**，
        // 信用卡家族不在表內是故意的（那一類 `allowsContext` 已擋、根本走不到這裡）。
        switch field.contentType {
        case "URL": return String(localized: "輸入欄位是網址")
        case "emailAddress": return String(localized: "輸入欄位是 Email")
        case "telephoneNumber": return String(localized: "輸入欄位是電話")
        case "addressCity", "addressCountry", "addressCountryCode", "addressPostalCode",
             "addressState", "addressStateCode", "addressStreetAddressLine1",
             "addressStreetAddressLine2", "addressStreetSubaddress", "addressSublocality",
             "countryName", "postalCode", "sublocality", "streetAddressLine1",
             "streetAddressLine2", "streetAddressLine3", "administrativeArea",
             "streetAddress", "locality", "city", "administrativeAreaString":
            return String(localized: "輸入欄位是地址")
        case "familyName", "givenName", "middleName", "name", "namePrefix", "nameSuffix", "nickname":
            return String(localized: "輸入欄位是人名")
        case "organizationName": return String(localized: "輸入欄位是公司名稱")
        case "jobTitle": return String(localized: "輸入欄位是職稱")
        case "username": return String(localized: "輸入欄位是帳號")
        case "note": return String(localized: "輸入欄位是筆記")
        case "event": return String(localized: "輸入欄位是行程／事件")
        case "location", "locationName": return String(localized: "輸入欄位是地點")
        case "dateTime": return String(localized: "輸入欄位是日期時間")
        case "searchField": return String(localized: "輸入欄位是搜尋欄")
        default: break
        }
        // 沒有 textContentType（或它認不出來）就用 keyboardType 推。
        switch field.keyboardKind {
        case "emailAddress": return String(localized: "輸入欄位是 Email")
        case "URL", "webSearch": return String(localized: "輸入欄位是網址")
        case "phonePad", "telephoneNumber": return String(localized: "輸入欄位是電話")
        case "numberPad", "decimalPad", "asciiCapableNumberPad": return String(localized: "輸入欄位是數字")
        default: break
        }
        // 最後才用回車鍵（回車鍵代表「這個欄位按下會做什麼」，比鍵盤類型更像用途）。
        switch field.returnKeyKind {
        case "search", "yahoo", "google": return String(localized: "輸入欄位是搜尋欄")
        case "send": return String(localized: "輸入欄位是聊天／訊息（送出）")
        case "join": return String(localized: "輸入欄位是加入（群組或聯絡人）")
        case "route": return String(localized: "輸入欄位是路線")
        case "emergencyCall": return String(localized: "輸入欄位是電話")
        case "next": return String(localized: "輸入欄位是一串欄位中的其中一個")
        case "done", "go": return String(localized: "輸入欄位是單行輸入")
        default: return nil
        }
    }

    // MARK: - 組裝

    /// 組裝結果。`appName` 鍵盤永遠拿不到，這裡保留欄位只是讓主 app（未來若知道 App 名）能共用同一段程式。
    struct Context: Equatable, Sendable {
        var surroundingText: String = ""
        var textAfterCursor: String = ""
        var hint: String = ""

        var isEmpty: Bool { surroundingText.isEmpty && textAfterCursor.isEmpty && hint.isEmpty }
    }

    /// 切尾／截首的字數限制。中文與英文都算「字元」，跟既有 `appContextBlock` 的 `suffix(500)` 一致。
    static func clampBefore(_ text: String?) -> String {
        String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(beforeLimit))
    }

    static func clampAfter(_ text: String?) -> String {
        String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(afterLimit))
    }

    static func clampHint(_ text: String?) -> String {
        String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(hintLimit))
    }

    /// 最終組裝入口。
    /// - `enabled`：使用者的「整理時參考輸入欄位脈絡」開關（關掉就整份不送，與既有 includeAppContext 同一個開關）。
    /// - `before`／`after`：游標前後文。
    /// - `hintText`：宿主欄位的 placeholder／label 文字（拿不到就 nil；**不湊**）。
    static func assemble(enabled: Bool, field: Field, before: String?, after: String?,
                         hintText: String? = nil) -> Context {
        guard enabled, allowsContext(field) else { return Context() }
        return Context(surroundingText: clampBefore(before),
                       textAfterCursor: clampAfter(after),
                       hint: clampHint(hintText))
    }
}

// MARK: - UIKit 列舉 → 內部名稱

#if canImport(UIKit)
import UIKit

/// UIKit 列舉 → `FieldContext.Field` 的**單一轉換點**（`KeyboardViewController.currentField()` 只呼叫這裡）。
///
/// 為什麼要有這一層：`textDocumentProxy` 給的是 `UIKeyboardType` / `UIReturnKeyType` / `UITextContentType`，
/// 而 `String(describing:)` 印出來的是 `Optional(__C.UIKeyboardType)` 或 `UIKeyboardType(rawValue: 7)`
/// ——**永遠對不上** `FieldContext` 認的內部名稱，結果是 OTP 推論、鍵盤類型提示、回車鍵提示從不觸發。
/// 這裡用 `switch`／`==` 對 UIKit 常數比對，輸出穩定的內部名稱；判定邏輯仍全在 `FieldContext`（不碰 UIKit、可測）。
enum UIKitFieldMapping {

    // MARK: - 入口

    /// 從宿主欄位目前的 UIKit 狀態組出 `FieldContext.Field`。
    /// 三個列舉都吃 `?`：`textDocumentProxy` 的屬性是 `null_unspecified`（拿不到＝nil），
    /// 拿不到的一律映射成 `default`／nil，**不猜**。
    static func field(keyboardType: UIKeyboardType?,
                      returnKeyType: UIReturnKeyType?,
                      contentType: UITextContentType?,
                      isSecure: Bool?) -> FieldContext.Field {
        FieldContext.Field(keyboardKind: keyboardKind(keyboardType),
                           returnKeyKind: returnKeyKind(returnKeyType),
                           contentType: contentTypeKind(contentType),
                           isSecure: isSecure == true)
    }

    // MARK: - UIKeyboardType

    /// 內部名稱（`FieldContext` 只認這些）。
    static func keyboardKind(_ type: UIKeyboardType?) -> String {
        guard let type else { return "default" }
        switch type {
        case .default: return "default"
        case .asciiCapable: return "asciiCapable"
        case .numbersAndPunctuation: return "numbersAndPunctuation"
        case .URL: return "URL"
        case .numberPad: return "numberPad"
        case .phonePad: return "phonePad"
        case .namePhonePad: return "namePhonePad"
        case .emailAddress: return "emailAddress"
        case .decimalPad: return "decimalPad"
        case .twitter: return "twitter"
        case .webSearch: return "webSearch"
        case .asciiCapableNumberPad: return "asciiCapableNumberPad"
        @unknown default: return "default"
        }
    }

    // MARK: - UIReturnKeyType

    static func returnKeyKind(_ type: UIReturnKeyType?) -> String {
        guard let type else { return "default" }
        switch type {
        case .default: return "default"
        case .go: return "go"
        case .google: return "google"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .search: return "search"
        case .send: return "send"
        case .yahoo: return "yahoo"
        case .done: return "done"
        case .emergencyCall: return "emergencyCall"
        case .continue: return "continue"
        @unknown default: return "default"
        }
    }

    // MARK: - UITextContentType

    /// 信用卡家族共用的內部名稱。`UITextContentType` 的信用卡 rawValue 全部以 `cc-` 開頭
    /// （`cc-number`／`cc-csc`／`cc-exp`／`cc-exp-month`／`cc-exp-year`／`cc-given-name`／`cc-family-name`…），
    /// 而且各 OS 版都可能多一個新 rawValue。全部 switch 出來等於每次 OS 更新都要改程式，
    /// 所以信用卡家族用 **rawValue 前綴**收斂（`FieldContext.creditCardPrefix`），新的自動落同一類。
    static let creditCardKind = FieldContext.creditCardKind

    /// `UITextContentType` → 內部名稱。**用 `==` 對 UIKit 常數比對**（不是比字串）。
    ///
    /// 為什麼不直接回傳 `rawValue`：實測（10-14 真機／模擬器 UIKit 值）rawValue 是 kebab-case
    /// ——`new-password`、`one-time-code`、`cc-number`、`street-address`、`given-name`——
    /// 和 Swift 的成員名（`newPassword`、`oneTimeCode`、`streetAddressLine1`…）**對不上**。
    /// 這裡統一映射成 Swift 風格的內部名稱，讓 `FieldContext` 的比對表只需要認一套名字。
    static func contentTypeKind(_ type: UITextContentType?) -> String? {
        guard let type else { return nil }
        if type.rawValue.hasPrefix(FieldContext.creditCardPrefix) { return creditCardKind }
        switch type {
        case .URL: return "URL"
        case .addressCity: return "addressCity"
        case .addressState: return "addressState"
        case .countryName: return "countryName"
        case .creditCardNumber, .creditCardSecurityCode, .creditCardExpiration,
             .creditCardExpirationMonth, .creditCardExpirationYear,
             .creditCardGivenName, .creditCardFamilyName:
            return creditCardKind
        case .dateTime: return "dateTime"
        case .emailAddress: return "emailAddress"
        case .familyName: return "familyName"
        case .givenName: return "givenName"
        case .jobTitle: return "jobTitle"
        case .location: return "location"
        case .middleName: return "middleName"
        case .name: return "name"
        case .namePrefix: return "namePrefix"
        case .nameSuffix: return "nameSuffix"
        case .nickname: return "nickname"
        case .newPassword: return "newPassword"
        case .organizationName: return "organizationName"
        case .oneTimeCode: return "oneTimeCode"
        case .password: return "password"
        case .postalCode: return "postalCode"
        case .streetAddressLine1: return "streetAddressLine1"
        case .streetAddressLine2: return "streetAddressLine2"
        case .sublocality: return "sublocality"
        case .telephoneNumber: return "telephoneNumber"
        case .username: return "username"
        // 認不出來（例如 `note`、`event` 這種 SDK 已無成員、但宿主仍可能用 rawValue 送出來的）
        // → 回傳 rawValue 讓 `FieldContext` 的比對表自己決定要不要湊；不認就不給提示。
        default: return type.rawValue
        }
    }
}
#endif
