import Foundation
import UTUVOTypeCore

/// 台灣常見地名（Mac 端的精簡版）：只給 vocabulary cleanup 提示詞用，
/// 不重複 iOS 端的 `fixStations`／`looseSound` 邏輯（那是鍵盤端 pipeline 用的）。
///
/// 站名清單的 Swift 正本在 core `BuiltInVocabulary.taipeiMRT`（2026-10-22 asr-vocab-1，tw 內建包也用它）；
/// 與 iOS `ios/Shared/TaiwanPlaces.swift` 維持同樣內容，`contextualStrings` 提供同樣的「站名＋站」清單。
enum TaiwanPlaces {
    static var taipeiMRT: [String] { BuiltInVocabulary.taipeiMRT }

    static var contextualStrings: [String] { BuiltInVocabulary.stationNames }
}
