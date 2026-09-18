import XCTest
@preconcurrency import AVFAudio
@testable import UTUVOTypeiOS

/// 使用者戴藍牙耳機聽音樂時開始聽寫：音樂不能停、不能被拉到喇叭、不能降成電話音質。
final class VoiceAudioSessionTests: XCTestCase {
    func testKeepsMusicPlayingOnBluetooth() throws {
        let session = AVAudioSession.sharedInstance()
        try VoiceAudioSession.activate(session)
        defer { try? session.setActive(false) }
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers), "要跟音樂混在一起，不打斷")
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP), "音樂要繼續走藍牙耳機")
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetooth), "不能借耳機麥克風把音樂降成電話音質")
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "不壓低音樂")
    }
}
