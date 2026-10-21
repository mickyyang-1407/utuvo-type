import Foundation
import Security

/// 主 app 與鍵盤 extension 共用的 Keychain 位置（App Group 當 access group）。
///
/// 10-15 實機：key 原本存在主 app 預設的 access group（team.bundleID），鍵盤是另一個 bundle ID，
/// `SecItemCopyMatching` 找不到 → 「幫我寫／改寫／問任何事」一律回「請加 Groq key」，
/// 而整理（在主 app 跑）正常——使用者明明有 key。
/// 新寫入一律放共用群組；舊位置的 key 由主 app 讀取時搬過來（鍵盤看不到舊位置，搬不了）。
enum SharedKeychain {
    static let accessGroup = "group.com.utuvo.type"

    /// 讀：不指定 access group＝搜這個 process 有權限的所有群組（主 app：自己的＋共用；鍵盤：共用）。
    /// 讀到舊位置的值就順手搬進共用群組。
    static func read(service: String, account: String) -> String {
        guard let value = copy(service: service, account: account, group: nil) else { return "" }
        if copy(service: service, account: account, group: accessGroup) == nil {
            migrate(service: service, account: account, value: value)
        }
        return value
    }

    /// 寫：存在就更新（不論在哪個群組），不存在就新增到共用群組。
    static func save(_ data: Data, service: String, account: String, accessible: CFString) -> OSStatus {
        // 舊位置還有一份時，下面不指定群組的 SecItemUpdate 會就地更新舊那份、共用群組永遠沒有
        // （ccm3f 審查 10-15 ①）：先讀一次讓它搬進共用群組，再更新。
        _ = read(service: service, account: account)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return update }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        add[kSecAttrAccessGroup as String] = accessGroup
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func migrate(service: String, account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account,
                                  kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecAttrAccessGroup as String: accessGroup]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return }
        // 共用群組那份寫成功才刪舊的；刪的時候指定舊值所在、不是共用群組的那份。
        add.removeValue(forKey: kSecValueData as String)
        add.removeValue(forKey: kSecAttrAccessible as String)
        add.removeValue(forKey: kSecAttrAccessGroup as String)
        var query = add
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let group = item[kSecAttrAccessGroup as String] as? String, group != accessGroup else { continue }
            var delete = add
            delete[kSecAttrAccessGroup as String] = group
            SecItemDelete(delete as CFDictionary)
        }
    }

    private static func copy(service: String, account: String, group: String?) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
