import XCTest
@testable import UTUVOTypeCore

/// delivery-learning-2（2026-10-22）：結果送不進輸入欄位時要看得到、拿得回來；
/// 同時不能誤擋（Chromium／Electron 的可編輯區常報奇怪的角色）。
final class DeliveryTargetTests: XCTestCase {

    // MARK: 該跳結果卡的

    func testNoFocusedElementIsUndeliverable() {
        XCTAssertEqual(DeliveryTarget.classify(.noFocusedElement), .undeliverable, "例如焦點在 Finder 桌面")
    }

    func testNonTextRolesAreUndeliverable() {
        for role in ["AXButton", "AXList", "AXOutline", "AXImage"] {
            XCTAssertEqual(DeliveryTarget.classify(.element(role: role, subrole: nil, valueSettable: false)),
                           .undeliverable, role)
        }
    }

    func testUndeliverableFocusStillPastesButShowsCard() {
        XCTAssertEqual(DeliveryTarget.plan(destinationChanged: false, focus: .undeliverable),
                       DeliveryTarget.Plan(paste: true, showCard: true))
    }

    func testDestinationChangedDoesNotPasteButShowsCard() {
        for verdict in [DeliveryTarget.Verdict.deliverable, .undeliverable, .unknown] {
            XCTAssertEqual(DeliveryTarget.plan(destinationChanged: true, focus: verdict),
                           DeliveryTarget.Plan(paste: false, showCard: true),
                           "前景 App 換了：不貼到別的 App，結果放卡片（\(verdict)）")
        }
    }

    // MARK: 不該擋、也不該多跳卡的（誤擋清單）

    func testTextFieldsAreDeliverable() {
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            XCTAssertEqual(DeliveryTarget.classify(.element(role: role, subrole: nil, valueSettable: true)),
                           .deliverable, role)
            XCTAssertEqual(DeliveryTarget.classify(.element(role: role, subrole: nil, valueSettable: nil)),
                           .deliverable, "\(role)：讀不到可不可寫不算不能貼")
        }
    }

    func testChromiumAndUnknownRolesAreNotBlocked() {
        let cases: [DeliveryTarget.Focus] = [
            .element(role: "AXWebArea", subrole: nil, valueSettable: false),
            .element(role: "AXGroup", subrole: nil, valueSettable: false),
            .element(role: "AXTable", subrole: nil, valueSettable: false),   // Numbers：⌘V 貼進儲存格
            .element(role: "AXTextArea", subrole: nil, valueSettable: false), // 唯讀判斷交給 Ask，不擋聽寫
            .element(role: nil, subrole: nil, valueSettable: nil),
            .element(role: "", subrole: nil, valueSettable: nil),
            .unreadable,
        ]
        for focus in cases {
            let verdict = DeliveryTarget.classify(focus)
            XCTAssertNotEqual(verdict, .undeliverable, "\(focus) 不能被當成送不進去")
            XCTAssertEqual(DeliveryTarget.plan(destinationChanged: false, focus: verdict),
                           DeliveryTarget.Plan(paste: true, showCard: false), "\(focus) 照現在的行為只貼")
        }
    }

    func testDeliverablePlanIsPlainPaste() {
        XCTAssertEqual(DeliveryTarget.plan(destinationChanged: false, focus: .deliverable),
                       DeliveryTarget.Plan(paste: true, showCard: false))
    }
}
