@preconcurrency import AVFAudio

/// 錄音用的音訊工作階段設定（主 app 聽寫與鍵盤語音共用一份）。
///
/// 使用者在聽音樂時開始聽寫，音樂不能停、也不能被搶走輸出：
///   - `.mixWithOthers`：跟別的 app 的播放混在一起，不打斷、不壓低。
///   - `.allowBluetoothA2DP`：音樂繼續走藍牙耳機。少了它，`playAndRecord` 會把輸出拉到手機喇叭，
///     耳機裡就沒聲音（2026-09-18 真機回報：戴藍牙耳機聽音樂，一開 UTUVO Type 耳機就沒聲音）。
///   - 不開 `.allowBluetooth`（HFP）：那會把耳機降成電話音質來借用耳機麥克風，音樂變難聽。
///     A2DP 沒有麥克風，所以錄音用 iPhone 本身的麥克風。
///   - `.defaultToSpeaker`：沒戴耳機時聲音走喇叭（不是聽筒）。
enum VoiceAudioSession {
    static let category: AVAudioSession.Category = .playAndRecord
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]

    static func activate(_ session: AVAudioSession = .sharedInstance()) throws {
        try session.setCategory(category, mode: .default, options: options)
        // 錄音中 iOS 預設把震動與系統音靜音——鍵盤的開始／停止震動會整個消失（真機回報）。
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }
}
