import XCTest
@testable import UTUVOTypeiOS
import UTUVOTypeCore

/// 兩台裝置（各自的 UserDefaults）共用一個假 iCloud：新增、修改、刪除都要帶到另一台，而且誰先同步都一樣。
@MainActor
final class DictionaryCloudTests: XCTestCase {
    final class FakeCloud: CloudKeyValues {
        var storage: [String: Any] = [:]
        func data(forKey key: String) -> Data? { storage[key] as? Data }
        func set(_ value: Any?, forKey key: String) { storage[key] = value }
    }

    private var suites: [String] = []

    private func device(_ name: String) -> DictionaryStore {
        let suite = "utuvo.test.dictcloud.\(name).\(UUID().uuidString)"
        suites.append(suite)
        return DictionaryStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    func testAddEditDeleteTravelBothWays() {
        let cloud = FakeCloud()
        let phone = device("phone"), mac = device("mac")
        phone.addTerm(source: "cloud code", output: "Claude Code")
        phone.addTerm(source: "jamin", output: "Gemini")
        DictionaryCloud.sync(store: cloud, local: phone)
        DictionaryCloud.sync(store: cloud, local: mac)
        XCTAssertEqual(mac.dictionary, ["cloud code": "Claude Code", "jamin": "Gemini"])

        mac.removeTerm(source: "jamin")
        mac.addTerm(source: "Atmos", output: "")
        DictionaryCloud.sync(store: cloud, local: mac)
        DictionaryCloud.sync(store: cloud, local: phone)
        XCTAssertEqual(phone.dictionary, ["cloud code": "Claude Code", "Atmos": "Atmos"])
        XCTAssertEqual(phone.dictionary, mac.dictionary)
    }

    func testLegacyDictionaryAndKeyboardWritesAreUploaded() {
        let cloud = FakeCloud()
        let phone = device("phone"), mac = device("mac")
        phone.set(["pik": "Pik"])          // 舊版／直接寫入的字典（沒有同步紀錄）
        DictionaryCloud.sync(store: cloud, local: phone)
        DictionaryCloud.sync(store: cloud, local: mac)
        XCTAssertEqual(mac.dictionary, ["pik": "Pik"])
    }

    func testImportCountsChanges() throws {
        let phone = device("phone")
        phone.addTerm(source: "a", output: "A")
        var other = DictionarySync()
        other.set("b", "B", at: Date().timeIntervalSince1970 + 10)
        other.set("a", "A2", at: Date().timeIntervalSince1970 + 10)
        XCTAssertEqual(phone.merge(try DictionarySync.decode(other.encoded())), 2)
        XCTAssertEqual(phone.dictionary, ["a": "A2", "b": "B"])
        XCTAssertEqual(phone.merge(other), 0, "同一份再匯入一次不會有變動")
    }
}
