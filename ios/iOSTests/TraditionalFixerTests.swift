import XCTest
@testable import UTUVOTypeiOS

/// 新引擎繁中逐字硬轉的修正（字典在 app bundle 裡）。
final class TraditionalFixerTests: XCTestCase {
    func testFixesCharacterByCharacterConversion() {
        let f = TraditionalFixer.shared
        XCTAssertEqual(f.fix("我等一下就迴家了，你先迴去吧"), "我等一下就回家了，你先回去吧")
        XCTAssertEqual(f.fix("我剛剛發現頭發太長了"), "我剛剛發現頭髮太長了")
        XCTAssertEqual(f.fix("臺風要來了，臺灣這幾天會下大雨"), "颱風要來了，台灣這幾天會下大雨")
        XCTAssertEqual(f.fix("這跟係統沒有關係"), "這跟系統沒有關係")
        XCTAssertEqual(f.fix("後麵還有很多人，皇後很美"), "後面還有很多人，皇后很美")
    }

    func testCorrectTextStaysAndEnglishUntouched() {
        let s = "這首歌的混音我想請你幫我再調整幾個地方，room mic 太多了，傳一個 WAV 給我。"
        XCTAssertEqual(TraditionalFixer.shared.fix(s), s)
    }

    func testTokensKeepTimingAndGetContext() {
        let tokens = ["迴", "家", "了"].enumerated().map { TimedToken(text: $1, start: Double($0), duration: 0.2) }
        let fixed = TraditionalFixer.shared.fix(tokens: tokens)
        XCTAssertEqual(fixed.map(\.text), ["回", "家", "了"])
        XCTAssertEqual(fixed.map(\.start), [0, 1, 2])
    }
}
