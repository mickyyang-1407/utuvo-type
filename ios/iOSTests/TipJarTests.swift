import StoreKitTest
import XCTest
@testable import UTUVOTypeiOS

/// 幫我加油（0.2.4）：用本機 StoreKit 設定（TypeTips.storekit）跑真的 StoreKit 2 購買流程。
@MainActor
final class TipJarTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "TypeTips")
        session.disableDialogs = true
        // StoreKitTest 的旗標是整台模擬器共用、跨 session 留著：每條都明確關掉，不然上一條的「交易失敗」會漏進來。
        session.failTransactionsEnabled = false
        session.askToBuyEnabled = false
        session.clearTransactions()
        UserDefaults.standard.removeObject(forKey: TipJar.pendingThanksKey)
    }

    func testOrderingIsByPriceThenDeclaredOrder() {
        struct P { let id: String; let price: Decimal }
        let items = [P(id: "com.utuvo.type.ios.tip.boost", price: 150), P(id: "com.utuvo.type.ios.tip.coffee", price: 30),
                     P(id: "com.utuvo.type.ios.tip.lunch", price: 90), P(id: "x.unknown", price: 30)]
        XCTAssertEqual(TipJar.ordered(items, id: \.id, price: \.price).map(\.id),
                       ["com.utuvo.type.ios.tip.coffee", "x.unknown", "com.utuvo.type.ios.tip.lunch", "com.utuvo.type.ios.tip.boost"])
    }

    func testLoadsThreeTipsCheapestFirst() async {
        let model = TipJarModel()
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.products.map(\.id), TipJar.productIDs)
        XCTAssertEqual(model.products.map(\.type), [.consumable, .consumable, .consumable], "小費不能是非消耗型（不解鎖功能）")
    }

    func testSuccessfulTipThanksAndFinishesTransaction() async throws {
        let model = TipJarModel()
        var finished: [String] = []
        model.finish = { transaction in
            finished.append(transaction.productID)
            await transaction.finish()
        }
        await model.load()
        let coffee = try XCTUnwrap(model.products.first)
        await model.buy(coffee)
        XCTAssertTrue(model.thanks)
        XCTAssertNil(model.message)
        XCTAssertNil(model.purchasing)
        XCTAssertEqual(finished, [coffee.id], "成功的消耗型交易一定要 finish 一次")
    }

    func testFailedPurchaseShowsMessageWithoutThanks() async throws {
        session.failTransactionsEnabled = true
        let model = TipJarModel()
        await model.load()
        await model.buy(try XCTUnwrap(model.products.last))
        XCTAssertFalse(model.thanks)
        XCTAssertNotNil(model.message)
    }

    func testAskToBuyIsPending() async throws {
        session.askToBuyEnabled = true
        let model = TipJarModel()
        await model.load()
        await model.buy(try XCTUnwrap(model.products.first))
        XCTAssertFalse(model.thanks)
        XCTAssertEqual(model.message, String(localized: "等待核准中（例如家長同意），完成後會自動入帳。"))
    }

    /// review 0.2.4 R1：家長核准後，交易從 Transaction.updates 回來（App init 起的監聽）→ 畫面要說謝謝、清掉「等待核准」。
    func testAskToBuyApprovalThanksAndClearsPending() async throws {
        session.askToBuyEnabled = true
        let model = TipJarModel()
        await model.load()
        await model.buy(try XCTUnwrap(model.products.first))
        XCTAssertEqual(model.awaitingApproval, [TipJar.productIDs[0]: 1])
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        for _ in 0..<50 where !model.thanks { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.thanks, "核准後應該說謝謝")
        XCTAssertNil(model.message, "核准後不該還寫等待核准")
        XCTAssertTrue(model.awaitingApproval.isEmpty)
    }

    /// review 0.2.4 R2-1：兩筆都在等核准，只核准一筆 → 說謝謝，但「等待核准」要留著；第二筆核准後才清掉。
    /// 核准那一刻由監聽器記旗標＋發通知（真實路徑見上一條）；這裡直接照監聽器的動作送，驗畫面邏輯。
    func testTwoPendingTipsKeepMessageUntilBothApproved() async throws {
        session.askToBuyEnabled = true
        let model = TipJarModel()
        await model.load()
        await model.buy(model.products[0])
        await model.buy(model.products[1])
        XCTAssertEqual(model.awaitingApproval, [TipJar.productIDs[0]: 1, TipJar.productIDs[1]: 1])
        func approved(_ id: String) {
            UserDefaults.standard.set(true, forKey: TipJar.pendingThanksKey)
            NotificationCenter.default.post(name: TipJar.completedNotification, object: nil, userInfo: ["productID": id])
        }
        approved(TipJar.productIDs[0])
        XCTAssertTrue(model.thanks)
        XCTAssertNotNil(model.message, "第二筆還在等，訊息要留著")
        model.thanks = false
        approved(TipJar.productIDs[1])
        XCTAssertTrue(model.thanks)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.awaitingApproval.isEmpty)
    }

    /// review 0.2.4 R3：同一品項買兩次都待核准，只核准一筆 → 訊息留著。
    func testSameTipTwicePendingCountsEachPurchase() async throws {
        session.askToBuyEnabled = true
        let model = TipJarModel()
        await model.load()
        await model.buy(model.products[0])
        await model.buy(model.products[0])
        XCTAssertEqual(model.awaitingApproval, [TipJar.productIDs[0]: 2])
        UserDefaults.standard.set(true, forKey: TipJar.pendingThanksKey)
        NotificationCenter.default.post(name: TipJar.completedNotification, object: nil, userInfo: ["productID": TipJar.productIDs[0]])
        XCTAssertTrue(model.thanks)
        XCTAssertNotNil(model.message, "還有一筆在等")
        XCTAssertEqual(model.awaitingApproval, [TipJar.productIDs[0]: 1])
    }

    /// review 0.2.4 R2-2：App 關著時被核准（監聽先處理、當下沒有畫面）→ 下次打開加油頁要說謝謝一次。
    func testThanksDeferredUntilScreenOpens() {
        UserDefaults.standard.set(true, forKey: TipJar.pendingThanksKey)
        let model = TipJarModel()
        XCTAssertTrue(model.thanks)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TipJar.pendingThanksKey), "只謝一次")
        XCTAssertFalse(TipJarModel().thanks)
    }
}
