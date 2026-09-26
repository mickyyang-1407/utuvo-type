import XCTest
@testable import UTUVOTypeiOS

/// 讀音相同的錯字站名（2026-09-19 實機「元山站」）；不接「站」／「捷運」的一般詞不動。
final class TaiwanPlacesTests: XCTestCase {
    func testFixesHomophoneStationNames() {
        XCTAssertEqual(TaiwanPlaces.fixStations("搭到元山站以後換成紅線"), "搭到圓山站以後換成紅線")
        XCTAssertEqual(TaiwanPlaces.fixStations("然後搭到捷運公館"), "然後搭到捷運公館")
        XCTAssertEqual(TaiwanPlaces.fixStations("搭到中正記念堂站"), "搭到中正紀念堂站")
        XCTAssertEqual(TaiwanPlaces.fixStations("我在捷運忠孝復新"), "我在捷運忠孝復興")
    }

    func testLeavesOrdinaryWordsAlone() {
        XCTAssertEqual(TaiwanPlaces.fixStations("原山的風景很好"), "原山的風景很好", "沒有站／捷運不猜")
        XCTAssertEqual(TaiwanPlaces.fixStations("他在車站等我"), "他在車站等我")
        XCTAssertEqual(TaiwanPlaces.fixStations("台北車站見"), "台北車站見")
    }
}
