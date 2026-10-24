import XCTest
@testable import UTUVOTypeCore

/// asr-vocab-2（2026-10-22）：智慧整理回來的文字只補套「英文專名＋個人字典」兩關，不重跑贅詞、分段、條列。
/// 套在已經寫對的文字上不能再改一次（冪等）。Kotlin 鏡像：android/core/.../VocabularyApplyTest.kt。
final class VocabularyApplyTests: XCTestCase {
    func testAppliesDictionaryAndLatinNamesWithoutTouchingLayout() {
        let out = Normalizer.applyVocabulary("1. 用優土佛 Type 匯出\n2. 更新 Protus",
                                             dictionary: ["優土佛": "UTUVO"], latinTerms: ["Pro Tools", "UTUVO"])
        XCTAssertEqual(out, "1. 用UTUVO Type 匯出\n2. 更新 Pro Tools")
    }

    func testFormattedParagraphWithoutHitsIsUnchanged() {
        let text = "老師你好，\n\n1. 明天下午 3 點開會。\n2. 帶 Atmos 母帶。\n\n謝謝！"
        XCTAssertEqual(Normalizer.applyVocabulary(text, dictionary: ["優土佛": "UTUVO"], latinTerms: ["Pro Tools", "UTUVO"]), text)
    }

    /// 反例一：字典值有 Uber Eats、Claude 輸出「更新 Protus」→ 不能冒出 Uber Eats。
    func testDoesNotInsertWrongBrandFromSkeleton() {
        let out = Normalizer.applyVocabulary("更新 Protus", dictionary: ["優吃": "Uber Eats"], latinTerms: ["Uber Eats"])
        XCTAssertFalse(out.contains("Uber Eats"), out)
        XCTAssertEqual(out, "更新 Protus")
    }

    /// 反例二：{"UTUVO":"UTUVO Type"}，已經寫成「UTUVO Type」→ 不能變「UTUVO Type Type」。
    func testIsIdempotentWhenValueContainsKey() {
        let dict = ["UTUVO": "UTUVO Type"]
        XCTAssertEqual(Normalizer.applyVocabulary("UTUVO Type", dictionary: dict, latinTerms: []), "UTUVO Type")
        XCTAssertEqual(Normalizer.applyVocabulary("我在用 UTUVO Type 打字", dictionary: dict, latinTerms: []), "我在用 UTUVO Type 打字")
        // 沒寫完整的照樣補上，而且再套一次不會變
        let once = Normalizer.applyVocabulary("UTUVO 很好用", dictionary: dict, latinTerms: [])
        XCTAssertEqual(once, "UTUVO Type 很好用")
        XCTAssertEqual(Normalizer.applyVocabulary(once, dictionary: dict, latinTerms: []), once)
    }

    func testValueWithKeyInTheMiddleIsAlsoIdempotent() {
        let dict = ["Atmos": "Dolby Atmos"]
        XCTAssertEqual(Normalizer.applyVocabulary("用 Dolby Atmos 混音", dictionary: dict, latinTerms: []), "用 Dolby Atmos 混音")
        XCTAssertEqual(Normalizer.applyVocabulary("用 Atmos 混音", dictionary: dict, latinTerms: []), "用 Dolby Atmos 混音")
    }

    func testInstanceMethodUsesOptions() {
        let n = Normalizer(options: NormalizerOptions(dictionary: ["優土佛": "UTUVO"], latinTerms: ["Pro Tools"]))
        XCTAssertEqual(n.applyVocabulary("更新 Protus，優土佛"), "更新 Pro Tools，UTUVO")
    }

    // MARK: - 智慧整理後補套的英文專名目標（asr-vocab-2 接線）

    /// 一個詞庫包的樣本：單字詞（Claude、iPhone、Typeless…）＋多字詞（Pro Tools、Uber Eats…）。
    private let packSample = ["Claude", "Gemini", "Typeless", "iPhone", "Zhipu", "SDK", "commit",
                              "Claude Code", "Pro Tools", "Uber Eats", "Spatial Audio"]
    private let personal = ["DAMI music", "UTUVO Type", "UTUVO"]

    func testCleanedTextTermsKeepPersonalAndOnlyMultiWordPackTerms() {
        let terms = Normalizer.latinTermsForCleanedText(personal: personal + ["", "DAMI music"], packTerms: packSample)
        XCTAssertEqual(terms, ["DAMI music", "UTUVO Type", "UTUVO", "Claude Code", "Pro Tools", "Uber Eats", "Spatial Audio"])
        XCTAssertEqual(Normalizer.latinTermsForCleanedText(personal: [], packTerms: []), [])
    }

    func testCleanedTextFixesNamesTheModelMisspelled() {
        let terms = Normalizer.latinTermsForCleanedText(personal: personal, packTerms: packSample)
        let out = Normalizer.applyVocabulary("我在 Darmy Music 用 Utuvo Type 寫歌詞，要做 Special Audio 版本。",
                                             dictionary: [:], latinTerms: terms)
        XCTAssertEqual(out, "我在 DAMI music 用 UTUVO Type 寫歌詞，要做 Spatial Audio 版本。")
        XCTAssertEqual(Normalizer.applyVocabulary(out, dictionary: [:], latinTerms: terms), out, "再套一次不變")
    }

    /// 模型寫對的英文一個字都不動：單字包內詞要是也進來，glad／cloud 會變 Claude、phone 會變 iPhone。
    func testCleanedTextLeavesCorrectEnglishAndCorrectNamesByteIdentical() {
        let terms = Normalizer.latinTermsForCleanedText(personal: personal, packTerms: packSample)
        for text in ["I'm glad the cloud sync works.", "My phone is in the shop, these types of stock commits are fine.",
                     "我在 DAMI music 用 UTUVO Type 打字，Claude 跟 Gemini 都試過。", "1. 匯出 AIFC\n2. 用 Pro Tools 混音"] {
            XCTAssertEqual(Normalizer.applyVocabulary(text, dictionary: ["優土佛": "UTUVO"], latinTerms: terms), text)
        }
    }

    /// 音訊包關著（Pro Tools 不在清單裡）：「Protus」不能被拉到同清單裡的 Uber Eats。
    func testCleanedTextDoesNotPullProtusToUberEats() {
        let terms = Normalizer.latinTermsForCleanedText(personal: personal, packTerms: packSample.filter { $0 != "Pro Tools" })
        XCTAssertEqual(Normalizer.applyVocabulary("更新 Protus", dictionary: [:], latinTerms: terms), "更新 Protus")
    }
}
