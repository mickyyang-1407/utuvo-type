import XCTest
import Security
@testable import UTUVOTypeiOS

/// key 要放 App Group 共用的 Keychain，鍵盤 extension 才讀得到（10-15 實機：鍵盤說沒 key、整理卻正常）。
final class SharedKeychainTests: XCTestCase {
    private let service = "com.utuvo.type.ios.test.sharedkeychain"
    private let account = "probe-\(UUID().uuidString)"

    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
        super.tearDown()
    }

    private func group(of account: String) -> [String] {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccessGroup as String] as? String }
    }

    func testNewKeyGoesToSharedGroup() {
        XCTAssertEqual(SharedKeychain.save(Data("gsk_test".utf8), service: service, account: account,
                                           accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly), errSecSuccess)
        XCTAssertEqual(group(of: account), [SharedKeychain.accessGroup])
        XCTAssertEqual(SharedKeychain.read(service: service, account: account), "gsk_test")
    }

    /// 舊版存在 app 自己的預設群組：讀一次就搬進共用群組、舊的刪掉，值不變。
    func testLegacyKeyMigratesOnRead() {
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data("gsk_old".utf8)]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        let before = group(of: account)
        XCTAssertEqual(before.count, 1)
        XCTAssertNotEqual(before.first, SharedKeychain.accessGroup, "前提：舊 key 不在共用群組")
        XCTAssertEqual(SharedKeychain.read(service: service, account: account), "gsk_old")
        XCTAssertEqual(group(of: account), [SharedKeychain.accessGroup], "搬完只剩共用群組那份")
    }

    /// 舊位置還有一份時存新 key：要落在共用群組（不然鍵盤還是讀不到）、舊那份要清掉（10-15 審查①）。
    func testSaveOverLegacyKeyLandsInSharedGroup() {
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: Data("gsk_old".utf8)]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        XCTAssertNotEqual(group(of: account), [SharedKeychain.accessGroup])
        XCTAssertEqual(SharedKeychain.save(Data("gsk_new".utf8), service: service, account: account,
                                           accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly), errSecSuccess)
        XCTAssertEqual(group(of: account), [SharedKeychain.accessGroup])
        XCTAssertEqual(SharedKeychain.read(service: service, account: account), "gsk_new")
    }
}
