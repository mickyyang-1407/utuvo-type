import XCTest
@testable import UTUVOTypeiOS

/// 輸入欄位識別（Q3-repair2 review-agy ⑤）。
///
/// 背景非同步（雲端辨識、智慧整理）回來時，先確認宿主還停在同一個欄位再貼。
/// 判斷只看系統的 `textDocumentProxy.documentIdentifier`（UUID，每個文字輸入工作階段一個），
/// 不再看 delegate 回呼幾次——前一版的回呼預算會在整理中連按光球、同欄位移動游標時誤判而丟掉結果。
final class FieldGenerationTests: XCTestCase {
    /// 同一個欄位 → 可以照常貼，不管中間發生幾次 textDidChange／selectionDidChange。
    func testSameIdentifierStillInserts() {
        let id = UUID()
        let snapshot = FieldGeneration(documentIdentifier: id)
        XCTAssertTrue(snapshot.isSameField(currentIdentifier: id))
    }

    /// 換欄位（系統給新的 documentIdentifier）→ 背景結果要丟掉，不能貼進新欄位。
    func testDifferentIdentifierBlocksInsert() {
        let snapshot = FieldGeneration(documentIdentifier: UUID())
        XCTAssertFalse(snapshot.isSameField(currentIdentifier: UUID()), "換欄位之後不能貼進新欄位")
    }

    /// 拿不到識別碼不能成為不貼的理由：快照端 nil、現在端 nil。
    func testBothNilInserts() {
        let snapshot = FieldGeneration(documentIdentifier: nil)
        XCTAssertTrue(snapshot.isSameField(currentIdentifier: nil), "兩邊都沒有識別碼＝沒有換欄位的證據，照舊貼")
    }

    /// 只有一邊是 nil 也照舊貼（系統可能在中途才給識別碼）。
    func testOneSideNilInserts() {
        let snapshot = FieldGeneration(documentIdentifier: UUID())
        XCTAssertTrue(snapshot.isSameField(currentIdentifier: nil))
        XCTAssertTrue(FieldGeneration(documentIdentifier: nil).isSameField(currentIdentifier: UUID()))
    }

    /// 判斷是純函式：同一組輸入呼叫多次結果一致，不會像計數器那樣把快照本身用掉。
    func testRepeatableComparison() {
        let id = UUID()
        let snapshot = FieldGeneration(documentIdentifier: id)
        for _ in 0..<10 {
            XCTAssertTrue(snapshot.isSameField(currentIdentifier: id))
        }
        XCTAssertFalse(snapshot.isSameField(currentIdentifier: UUID()))
        XCTAssertTrue(snapshot.isSameField(currentIdentifier: id), "快照是值型別，比較過不會被消耗或改變")
    }
}
