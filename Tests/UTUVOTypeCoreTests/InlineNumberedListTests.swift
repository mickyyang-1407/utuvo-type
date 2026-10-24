import Foundation
import Testing
@testable import UTUVOTypeCore

struct InlineNumberedListTests {
    static let raw = "好，我來測試看看明天的錄音要帶 1.麥克風 2.輔駕 3.腳架 4.個人監聽器 5.耳機還有最重要的 6.耳朵"
    static let expected = "好，我來測試看看明天的錄音要帶：\n1. 麥克風\n2. 輔駕\n3. 腳架\n4. 個人監聽器\n5. 耳機\n6. 還有最重要的耳朵"

    @Test func explicitListKeepsEveryWordAndEmphasis() {
        let result = OutputShape.expandingInlineNumberedList(Self.raw)
        #expect(result == Self.expected)
        #expect(OutputShape.expandingInlineNumberedList(result) == result)
        #expect(DictationPolish.accepts(original: Self.raw, cleaned: result))
        #expect(Normalizer().normalize(result).cleaned.filter { $0 == "\n" }.count == 6)
    }

    @Test(arguments: ["版本1.2與2.3", "費用1.5元，另付2.5元", "1. 麥克風", "1. 麥克風 3. 耳機",
                       "1. 麥克風 1. 耳機", "1. 2. 耳機", "`1. 麥克風 2. 耳機`", "1. 麥克風\n2. 耳機"])
    func ambiguousOrAlreadyStructuredInputStaysUntouched(_ raw: String) {
        #expect(OutputShape.expandingInlineNumberedList(raw) == raw)
    }

    @Test(arguments: ["耳機", "最重要的", "個人監聽器"])
    func formattingDoesNotAuthorizeLostContent(_ lost: String) {
        #expect(!DictationPolish.accepts(original: Self.raw, cleaned: Self.expected.replacingOccurrences(of: lost, with: "")))
    }

    @Test func valuesNegationAndOutputOrdinalsStayProtected() {
        let raw = "交付 1. 48K 2. -14 LUFS 3. 不要耳機"
        let formatted = OutputShape.expandingInlineNumberedList(raw)
        #expect(DictationPolish.accepts(original: raw, cleaned: formatted))
        for (from, to) in [("48K", "96K"), ("-14", "14"), ("不要", "要"), ("2. ", "9. ")] {
            #expect(!DictationPolish.accepts(original: raw, cleaned: formatted.replacingOccurrences(of: from, with: to)))
        }
    }
}
