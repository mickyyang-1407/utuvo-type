import Foundation
import Security
import XCTest
@testable import UTUVOTypeApp

final class SecretStoreMigrationTests: XCTestCase {
    override func setUpWithError() throws {
        let service = "com.utuvo.type.fixture." + UUID().uuidString
        var query = identity(service)
        query[kSecValueData as String] = Data("synthetic-entitlement-probe".utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("Unsigned SwiftPM runner has no data-protection entitlement; signed production fixture covers this gate.")
        }
        XCTAssertEqual(status, errSecSuccess)
        if status == errSecSuccess { SecItemDelete(identity(service) as CFDictionary) }
    }

    func testNewSaveAndExistingSaveUseDeviceOnly() throws {
        let service = "com.utuvo.type.fixture." + UUID().uuidString
        defer {
            _ = SecretStore.deleteBailianAPIKey(keychainService: service)
            var legacy = identity(service)
            legacy[kSecUseDataProtectionKeychain as String] = false
            SecItemDelete(legacy as CFDictionary)
        }
        XCTAssertNil(SecretStore.saveBailianAPIKey("synthetic-key", keychainService: service))
        XCTAssertEqual(try accessibility(service), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(SecItemUpdate(identity(service) as CFDictionary,
            [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked] as CFDictionary), errSecSuccess)
        XCTAssertNil(SecretStore.saveBailianAPIKey("synthetic-updated-key", keychainService: service))
        XCTAssertEqual(try accessibility(service), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(SecretStore.bailianAPIKey(environment: [:], keychainService: service), "synthetic-updated-key")
        print("B3 new+updated fixture items: kSecAttrAccessibleWhenUnlockedThisDeviceOnly; value preserved")
    }

    func testReadMigratesLegacyItemWithoutChangingValue() throws {
        let service = "com.utuvo.type.fixture." + UUID().uuidString
        defer {
            _ = SecretStore.deleteBailianAPIKey(keychainService: service)
            var legacy = identity(service)
            legacy[kSecUseDataProtectionKeychain as String] = false
            SecItemDelete(legacy as CFDictionary)
        }
        var item = identity(service)
        item[kSecUseDataProtectionKeychain as String] = false
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecValueData as String] = Data("synthetic-legacy-key".utf8)
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(SecretStore.bailianAPIKey(environment: [:], keychainService: service), "synthetic-legacy-key")
        XCTAssertEqual(try accessibility(service), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        print("B3 actual isolated Keychain read: legacy WhenUnlocked -> WhenUnlockedThisDeviceOnly; value preserved")
    }

    private func identity(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key", kSecUseDataProtectionKeychain as String: true]
    }
    private func accessibility(_ service: String) throws -> String {
        var query = identity(service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let item = try XCTUnwrap(result as? [String: Any])
        return try XCTUnwrap(item[kSecAttrAccessible as String] as? String)
    }
}
