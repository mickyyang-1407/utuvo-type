import XCTest
@testable import UTUVOTypeiOS

/// R3-2（luna-review 2026-09-25）：把 R2 的 tuple 升級成 `RerecognitionGate`，
/// 獨立測 flush 對編輯意圖的回傳、begin 後 id 被覆蓋、finish 用舊 id 等情境。
final class RerecognitionGateTests: XCTestCase {
    func testBeginReturnsFreshIDAndFinishReturnsPending() {
        var gate = RerecognitionGate()
        let id = gate.begin(text: "raw", base: "base", isEdit: false)
        let finished = gate.finish(id: id)
        XCTAssertEqual(finished?.text, "raw")
        XCTAssertEqual(finished?.base, "base")
        XCTAssertEqual(finished?.isEdit, false)
        // finish 已經清乾淨，再 finish 同 id 應回 nil
        XCTAssertNil(gate.finish(id: id), "第二次 finish 同 id 回 nil")
    }

    func testFinishIgnoresStaleID() {
        var gate = RerecognitionGate()
        gate.begin(text: "v1", base: "b1", isEdit: false)
        let id2 = gate.begin(text: "v2", base: "b2", isEdit: false)
        let stale = UUID()
        XCTAssertNil(gate.finish(id: stale), "沒見過的 id → nil")
        XCTAssertEqual(gate.finish(id: id2)?.text, "v2", "新 id 仍可拿")
    }

    func testBeginTwiceOldIDFinishReturnsNil() {
        // R3 場景：開新一輪（begin 第二次）→ 舊的 Task 用舊 id 回來 finish → nil
        var gate = RerecognitionGate()
        let id1 = gate.begin(text: "v1", base: "b1", isEdit: false)
        _ = gate.begin(text: "v2", base: "b2", isEdit: false)
        XCTAssertNil(gate.finish(id: id1), "舊 id finish → nil（v2 已蓋掉）")
    }

    func testFlushAfterBeginTwiceFinishingOldIDReturnsNil() {
        // R3 場景：flush → 舊 id 再 finish → nil（gate 已清空）
        var gate = RerecognitionGate()
        let id1 = gate.begin(text: "v1", base: "b1", isEdit: false)
        _ = gate.begin(text: "v2", base: "b2", isEdit: false)
        XCTAssertNotNil(gate.flush())
        XCTAssertNil(gate.finish(id: id1))
    }

    func testFlushReturnsNonEditPending() {
        var gate = RerecognitionGate()
        _ = gate.begin(text: "v", base: "b", isEdit: false)
        XCTAssertNotNil(gate.flush())
    }

    func testFlushReturnsNilForEditIntent() {
        // 編輯意圖 flush 回 nil —— 使用者已經開新一輪，舊的口頭指令作廢，不改寫
        var gate = RerecognitionGate()
        _ = gate.begin(text: "v", base: "b", isEdit: true)
        XCTAssertNil(gate.flush(), "編輯意圖 flush 回 nil")
        // 再 flush 也是 nil（gate 已被清空）
        XCTAssertNil(gate.flush())
    }

    func testFlushOnEmptyGateReturnsNil() {
        var gate = RerecognitionGate()
        XCTAssertNil(gate.flush())
    }

    func testBeginOverwritesPending() {
        var gate = RerecognitionGate()
        _ = gate.begin(text: "v1", base: "b1", isEdit: false)
        let id2 = gate.begin(text: "v2", base: "b2", isEdit: false)
        let p = gate.finish(id: id2)
        XCTAssertEqual(p?.text, "v2")
        XCTAssertEqual(p?.base, "b2")
    }
}