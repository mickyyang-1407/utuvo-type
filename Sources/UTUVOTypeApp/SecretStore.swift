import Foundation
import Security
import OSLog

enum SecretStore {
    private static let service = "com.utuvo.type.bailian"
    private static let account = "api-key"
    private static let logger = Logger(subsystem: "com.utuvo.type", category: "SecretStore")

    /// Reads a key without ever printing it. The environment names are
    /// intentionally compatible with DashScope/OpenAI-style setups.
    static func bailianAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment, keychainService: String = service) -> String? {
        for name in ["UTUVO_TYPE_BAILIAN_API_KEY", "DASHSCOPE_API_KEY"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        // Accessibility classes only apply to the data-protection Keychain on macOS.
        var query = identity(keychainService)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var legacy = identity(keychainService, dataProtection: false)
            legacy[kSecReturnData as String] = true
            legacy[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(legacy as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data, let value = String(data: data, encoding: .utf8),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  saveProtected(data, service: keychainService) == errSecSuccess else { return nil }
            _ = deleteLegacyItem(keychainService)
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if item[kSecAttrAccessible as String] as? String != kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String {
            guard SecItemUpdate(identity(keychainService) as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary) == errSecSuccess else { return nil }
        }
        // Also finish an interrupted migration after the protected copy was saved.
        _ = deleteLegacyItem(keychainService)
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
    static func hasKeychainKey(keychainService: String = service) -> Bool {
        guard supportsProtectedKeychain else { return false }
        let status = SecItemCopyMatching(identity(keychainService) as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemCopyMatching(identity(keychainService, dataProtection: false) as CFDictionary, nil) == errSecSuccess
    }

    /// 寫入 Keychain（存在就更新）。回傳 nil 表示成功，否則回傳給使用者看的錯誤訊息。
    /// 永遠不 log key 本身。
    @discardableResult
    static func saveBailianAPIKey(_ rawValue: String, keychainService: String = service) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "key 是空的，沒有寫入。" }
        guard let data = value.data(using: .utf8) else { return "key 編碼失敗（需為 UTF-8）。" }

        let status = saveProtected(data, service: keychainService)
        guard status == errSecSuccess else { return "Keychain 寫入失敗（OSStatus \(status)）。" }
        // Never remove the old copy until the protected write has succeeded.
        return deleteLegacyItem(keychainService)
    }

    /// 從 Keychain 刪除。找不到也算成功（結果狀態一致：沒有 key）。
    @discardableResult
    static func deleteBailianAPIKey(keychainService: String = service) -> String? {
        let status = SecItemDelete(identity(keychainService) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return "Keychain 刪除失敗（OSStatus \(status)）。"
        }
        return deleteLegacyItem(keychainService)
    }

    private static func saveProtected(_ data: Data, service: String) -> OSStatus {
        let base = identity(service)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary) }
        }
        return status
    }

    private static var supportsProtectedKeychain: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.application-identifier"] as? String != nil
    }

    private static func identity(_ service: String, dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        return query
    }

    private static func deleteLegacyItem(_ service: String) -> String? {
        let status = SecItemDelete(identity(service, dataProtection: false) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return nil }
        logger.error("Legacy Keychain cleanup failed: OSStatus \(status, privacy: .public)")
        return "舊 Keychain 項目清理失敗（OSStatus \(status)）。"
    }
}
