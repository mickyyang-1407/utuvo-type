import Foundation
import Security

enum SecretStore {
    private static let service = "com.utuvo.type.bailian"
    private static let account = "api-key"

    /// Reads a key without ever printing it. The environment names are
    /// intentionally compatible with DashScope/OpenAI-style setups.
    static func bailianAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for name in ["UTUVO_TYPE_BAILIAN_API_KEY", "DASHSCOPE_API_KEY"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

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
              let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var keychainInstructions: String {
        "Keychain service: \(service), account: \(account). 或設定 UTUVO_TYPE_BAILIAN_API_KEY / DASHSCOPE_API_KEY；App 不會把 key 寫入 repo 或 log。"
    }

    /// key 是否來自環境變數（環境變數優先於 Keychain，UI 需說明「改 Keychain 不會生效」）。
    static func keyComesFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        for name in ["UTUVO_TYPE_BAILIAN_API_KEY", "DASHSCOPE_API_KEY"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return true
            }
        }
        return false
    }

    /// Keychain 是否已存一把 key（不讀值、不看環境變數）。
    static func hasKeychainKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// 寫入 Keychain（存在就更新）。回傳 nil 表示成功，否則回傳給使用者看的錯誤訊息。
    /// 永遠不 log key 本身。
    @discardableResult
    static func saveBailianAPIKey(_ rawValue: String) -> String? {
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
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess ? nil : "Keychain 寫入失敗（OSStatus \(addStatus)）。"
        }
        return "Keychain 更新失敗（OSStatus \(updateStatus)）。"
    }

    /// 從 Keychain 刪除。找不到也算成功（結果狀態一致：沒有 key）。
    @discardableResult
    static func deleteBailianAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return nil }
        return "Keychain 刪除失敗（OSStatus \(status)）。"
    }
}
