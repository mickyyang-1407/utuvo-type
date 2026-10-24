import XCTest
@testable import UTUVOTypeCore

/// Groq Whisper 會輸出小型標點「﹐」「﹑」（2026-10-22 ls03／sc04／sc05 真人錄音）；要在改口／清單規則之前換成一般全形。
final class SmallFormPunctuationTests: XCTestCase {
    func testSmallFormsAreFolded() {
        XCTAssertEqual(Normalizer.foldSmallFormPunctuation("好\u{FE54}你呢\u{FE56}對\u{FE57}時間\u{FE55}三點"), "好；你呢？對！時間：三點")
        XCTAssertEqual(Normalizer.foldSmallFormPunctuation("小柏\u{FE51}不是"), "小柏、不是")
        XCTAssertEqual(Normalizer.foldSmallFormPunctuation("沒有小型標點"), "沒有小型標點")
    }

    func testNormalizerSeesOrdinaryCommas() {
        // 「﹐」換成「，」之後，數量＋頓號列舉的清單規則才認得（2026-10-22 W2-6 ls03 → 編號清單）。
        let out = Normalizer().normalize("幫我準備四樣東西\u{FE50}播放器、耳機、線材、還有轉接頭\u{FE50}").cleaned
        XCTAssertEqual(out, "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭")
        XCTAssertEqual(SentenceMood.finish(out), out)
        // 沒有數量的列舉不成清單：照舊看到一般逗號、句尾吊著的逗號由 finish 拿掉。
        let plain = Normalizer().normalize("我準備了東西\u{FE50}播放器、耳機、線材\u{FE50}").cleaned
        XCTAssertEqual(plain, "我準備了東西，播放器、耳機、線材，")
        XCTAssertEqual(SentenceMood.finish(plain), "我準備了東西，播放器、耳機、線材")
    }

    func testStepListIsUnchanged() {
        XCTAssertEqual(Normalizer().normalize("好\u{FE50}走吧").appliedSteps.first, "trim")
    }
}
