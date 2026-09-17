import Foundation
import Security

/// iOS 端 API key 儲存（2026-09-11）。
///
/// v1 把 DashScope key 明文寫在 `UserDefaults`（會進未加密備份）。這裡改成
/// Keychain，語意與 macOS `SecretStore` 對齊：service/account 固定、值永不回顯、
/// 永不寫 log。`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` = 不跟著備份走、
/// 不同步到其他裝置。
///
/// 遷移：第一次讀取時若發現舊的 UserDefaults 值，搬進 Keychain 後刪掉舊值。
enum IOSSecretStore {
    private static let service = "com.utuvo.type.ios.bailian"
    private static let account = "api-key"
    /// v1 明文位置，只用於一次性遷移。
    private static let legacyDefaultsKey = "utuvo.type.bailian.key"

    static func apiKey(defaults: UserDefaults = .standard) -> String {
        migrateLegacyKeyIfNeeded(defaults: defaults)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasKey(defaults: UserDefaults = .standard) -> Bool {
        !apiKey(defaults: defaults).isEmpty
    }

    /// 寫入（存在就更新）。回傳 nil＝成功，否則是給使用者看的錯誤訊息。
    @discardableResult
    static func save(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "key 是空的，沒有寫入。" }
        guard let data = value.data(using: .utf8) else { return "key 編碼失敗（需為 UTF-8）。" }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return nil }
        if updateStatus == errSecItemNotFound {
            var addQuery = base
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess ? nil : "Keychain 寫入失敗（OSStatus \(addStatus)）。"
        }
        return "Keychain 更新失敗（OSStatus \(updateStatus)）。"
    }

    /// 刪除。找不到也算成功（結果一致：沒有 key）。
    @discardableResult
    static func delete() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return nil }
        return "Keychain 刪除失敗（OSStatus \(status)）。"
    }

    /// 把 v1 明文 key 搬進 Keychain 並清掉明文。搬完就不會再觸發。
    private static func migrateLegacyKeyIfNeeded(defaults: UserDefaults) {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else { return }
        if save(legacy) == nil {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
    }
}
