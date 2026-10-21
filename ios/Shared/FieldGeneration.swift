import Foundation

/// 輸入欄位識別：背景非同步結果回來時，先確認宿主還停在同一個欄位再貼。
///
/// 2026-10-14（Q3-repair2，review-agy ⑤）：前一版用「鍵盤自己插入次數預算」去猜 `textDidChange`
/// 是不是換欄位，會在正常情況誤判而**丟掉聽寫結果**——整理中連按光球、背景整理替換第 1 句時第 2 句還在錄、
/// 同欄位移動游標、宿主自動格式化（電話／搜尋建議），預算從不扣減就作廢了這一整段。
/// 改用系統自己提供的欄位識別：`textDocumentProxy.documentIdentifier`
/// （UUID，每個文字輸入工作階段一個，iOS 11+）。
///
/// 用法：開始一段非同步工作時取快照（`FieldGeneration(documentIdentifier:)`），回來時用
/// `isSameField(currentIdentifier:)` 比對。中間發生幾次 `textDidChange`／`selectionDidChange` 都不影響判定。
/// 這裡刻意不放 actor／UIKit，好讓純邏輯測試不用起鍵盤。
struct FieldGeneration: Equatable, Sendable {
    /// `nil` = 系統還沒給識別碼（extension 剛 attach 的一瞬間就是這樣）。
    /// 拿不到時一律當同一個欄位——不能因為識別碼缺席就不貼，那比誤貼更糟。
    let documentIdentifier: UUID?

    init(documentIdentifier: UUID?) {
        self.documentIdentifier = documentIdentifier
    }

    /// 快照與目前是不是同一個欄位。兩邊都有識別碼才比對；任一邊是 nil 就當沒換欄位。
    func isSameField(currentIdentifier: UUID?) -> Bool {
        guard let documentIdentifier, let currentIdentifier else { return true }
        return documentIdentifier == currentIdentifier
    }
}
