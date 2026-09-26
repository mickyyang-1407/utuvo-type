import XCTest
@testable import UTUVOTypeCore

/// 2026-09-24 實機回報（苑涵，Mac 0.1.5 Fast 模式）：講數字不會轉成阿拉伯數字。
/// 規則在 Normalizer（Fast／Smart／iOS 共用），不靠模型。同時驗「該轉」與「不該轉」兩張清單。
final class NumberNormalizationTests: XCTestCase {
    private let n = Normalizer(options: NormalizerOptions(dictionary: [:], fillerSet: NormalizerOptions.defaultFillers,
                                                          localeIdentifier: "zh_TW", latinTerms: []))

    func testConverts() {
        let cases: [(String, String)] = [
            ("我明天下午三點要付兩千五百元", "我明天下午3點要付2,500元"),
            ("一二三四五六七八九十", "12345678910"),
            ("一二三四五", "12345"),
            ("電話是零九一二三四五六七八", "電話是0912345678"),
            ("十分鐘後見", "10分鐘後見"),
            ("我等你十五分鐘", "我等你15分鐘"),
            ("今天是九月二十四號", "今天是9 月 24 號"),
            ("預算大概三萬五", "預算大概35,000"),
            ("三萬五元", "35,000元"),
            ("兩千五", "2,500"),
            ("百分之二十", "20%"),
            ("百分之三點五", "3.5%"),
            ("三點五公斤", "3.5公斤"),
            ("三點見", "3點見"),
            ("一千零五元", "1,005元"),
            ("等一下十點半見", "等一下10:30見"),
        ]
        for (input, expected) in cases { XCTAssertEqual(n.normalize(input).cleaned, expected, input) }
    }

    func testLeavesWordsAndApproximationsAlone() {
        for input in ["我們一起去一下", "這個十分好", "我有三個問題", "他一個人去", "第一次", "一定要", "一模一樣", "七上八下",
                      "有兩點要說", "快一點", "我有一點累", "一五一十", "九九八十一", "三四五個人", "千萬不要", "幾十個人",
                      "好幾百次", "二十幾歲", "三三兩兩", "十多個", "第十次"] {
            XCTAssertEqual(n.normalize(input).cleaned, input, input)
        }
    }
}
