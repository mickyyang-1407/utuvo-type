import Foundation
@preconcurrency import AVFAudio

/// 「小聲說話」模式（工單 ios-C 第 4 點）。
///
/// 開啟後做兩件事：
/// 1. **錄音前級增益提高**（`gain`）：把送進辨識器的 PCM 整體放大，輕聲講的音量才過得了辨識器的門檻。
///    套用在**每一條真的會用到麥克風的路徑**：主 app 聽寫（DictationModel）、鍵盤語音工作階段
///    （KeyboardVoiceHost，裝置端／Apple 雲端／Qwen 重辨識與雲端 ASR 都吃同一份放大後的 PCM）。
/// 2. **靜音判斷門檻放寬**（`silenceThresholdOffsetQuiet`／`muteHoldSecondsQuiet`）：輕聲講的人換氣比較長、
///    句中停頓比較久，門檻不動會把整句判成沒講話。
///
/// **不宣稱做不到的事**：`requestAudioBufferOptions` / `setInputGain` 是 macOS 的 API，
/// iOS 上拿不到硬體增益，所以這裡是**數位前級增益**（放大 buffer 的樣本），不是麥克風前級。
/// 寫錄 PCM 之前一定會過 `limited`（軟膝限幅），避免放大後削波失真（削波對辨識率的傷害比小聲更糟）。
enum QuietMode {
    static let settingKey = "utuvo.type.ios.quietMode"

    /// 一般模式的數位前級增益（原樣，1.0＝不改變）。
    public static let gainNormal: Float = 1.0

    /// 小聲模式的數位前級增益：2.5 倍 ≈ +8 dB。把「輕聲講」推到一般講話的音量區間。
    public static let gainQuiet: Float = 2.5

    /// 放大後的削波上限（漸近線）。1.0 = 剛好不溢位；留一點餘裕給後級處理。
    public static let limiterCeiling: Float = 0.98

    /// 軟膝限幅的**膝點**：|x| ≤ 0.7 完全原樣通過（安靜段落、正常音量不動一點）。
    ///
    /// 為什麼要軟膝而不是直接夾：直接夾 ±`limiterCeiling` 是**硬削波**——放大 2.5 倍後峰值
    /// 會被削成方波、產生諧波失真，而失真對辨識率是**扣分**（工單第 4 點：「避免削波失真」
    /// 這句話描述的是軟限幅的好處，硬夾根本不是）。軟膝在膝點以上用平滑曲線漸近到 ceiling，
    /// 單調、連續、波形連續，不會造出方波。
    public static let limiterKnee: Float = 0.7

    /// 一般模式判「整段全零（麥克風被別的 app 拿走）」要連續幾秒。
    public static let muteHoldSecondsNormal: TimeInterval = 1.5

    /// 小聲模式放寬到 3 秒：輕聲講時 iOS 麥克風增益調整會讓無聲段更容易湊出整批精確的 0。
    public static let muteHoldSecondsQuiet: TimeInterval = 3.0

    /// 靜音斷句：一般模式要求「比背景噪音高出這個幅度」才算在講話（dB）。
    static let silenceHeadroomNormal: Float = 12

    /// 小聲模式的降幅：只高出背景 6 dB 也算在講話。
    ///
    /// 為什麼動「headroom」而不是動門檻本身（這個方向是單元測試逼出來的）：
    /// 門檻是**自適應**的（背景＝同一批樣本的第 10 百分位），所以
    /// - 偏移門檻本身：會被自適應抵回去，等於沒改（實測安靜房與吵房都 0→0）。
    /// - 把夾住區間整個往下移：一般音量說話的停頓會跟著消失，關掉小聲模式效果一樣差（吵房 -20 dB：2→0）。
    /// - 降 headroom：只影響「音量本來就低」的情況，一般音量完全不受影響（實測兩者都是 2）。
    static let silenceHeadroomQuiet: Float = 6

    // MARK: - 開關（App Group，主 app 設定頁寫、錄音路徑讀）

    static var defaults: UserDefaults { KeyboardPresence.defaults }

    public static var isEnabled: Bool {
        get { defaults.bool(forKey: settingKey) }
        set { defaults.set(newValue, forKey: settingKey) }
    }

    // MARK: - 純邏輯（可單元測試）

    /// 依開關回傳該用的數位前級增益。
    public static func gain(enabled: Bool) -> Float { enabled ? gainQuiet : gainNormal }

    /// 依開關回傳「全零持續多久算麥克風被拿走」。
    public static func muteHoldSeconds(enabled: Bool) -> TimeInterval {
        enabled ? muteHoldSecondsQuiet : muteHoldSecondsNormal
    }

    /// 靜音斷句門檻（dBFS）。`floor` 是 `SilenceDetector` 從這段錄音量出來的背景（第 10 百分位）。
    public static func silenceThreshold(floor: Float, enabled: Bool) -> Float {
        let headroom = enabled ? silenceHeadroomQuiet : silenceHeadroomNormal
        return min(silenceWindowCeiling, max(silenceWindowFloor, floor + headroom))
    }

    /// 自適應門檻的夾住區間（兩種模式共用——見 `silenceHeadroomQuiet` 的說明，
    /// 這個區間動了會連一般音量說話的停頓一起弄掉）。
    public static let silenceWindowFloor: Float = -60
    public static let silenceWindowCeiling: Float = -30

    /// 單一樣本的**軟膝限幅**。
    ///
    /// - |x| ≤ `limiterKnee`：**原樣**回傳（不動訊號，量化的位元也不浪費）。
    /// - |x| > `limiterKnee`：以膝點為原點做一條平滑的漸近曲線，逐漸逼近 ±`limiterCeiling`。
    ///
    /// 曲線用 `knee + (ceiling − knee) · tanh((|x| − knee) / (ceiling − knee))`：
    /// - x = knee 時 tanh(0)=0 → 值剛好 = knee，**與線性段連續**（沒有階梯）。
    /// - x → ∞ 時 tanh → 1 → 漸近 `ceiling`，**永遠小於** ceiling（±10 也只是 0.9996…，不會溢位）。
    /// - tanh 嚴格遞增 → 整條曲線**單調**（不會有輸入大輸出小的反折）。
    ///
    /// 對稱套用到負半軸，所以正負增益行為完全一致。
    public static func limited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let span = limiterCeiling - limiterKnee
        let asymptotic = limiterKnee + span * tanh((magnitude - limiterKnee) / span)
        // `tanh` 的引數只要超過大約 ±9 就會在 **Float** 底下四捨五入成精確的 1.0
        // （±10 的樣本就是這樣），算出來會剛好等於 `limiterCeiling`——那就變回硬削波了。
        // 夾在 ceiling 的**下一個可表示值**以內：仍然單調、仍然連續，但保證永遠嚴格小於 ceiling。
        let shaped = min(limiterCeiling.nextDown, asymptotic)
        return sample < 0 ? -shaped : shaped
    }

    /// 整段 PCM 套用增益 + 限幅。**回傳新 buffer**（不改原 buffer：同一份 PCM 還要餵給別的消費者）。
    public static func applyingGain(to samples: [Float], enabled: Bool) -> [Float] {
        guard enabled else { return samples }
        let g = gainQuiet
        return samples.map { limited($0 * g) }
    }

    /// 在麥克風 tap 上套用小聲模式的增益 + 限幅。
    ///
    /// 這是**所有錄音路徑的單一入口**：`RequestBox.feed`（鍵盤語音工作階段：Apple 裝置端／Apple 雲端／
    /// Qwen 重辨識／雲端 ASR 全都吃這一份）與 `DictationModel` 的 tap（App 內聽寫）都呼叫它，
    /// 所以「小聲模式對哪條路徑有效」不會講一套做一套。開關關閉時**原 buffer 直通**，不多複製一份。
    ///
    /// 回傳的是新 buffer（不改動系統给的 buffer——它會被重用，而且同一份還要餵給 levels 統計）。
    public static func processed(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard isEnabled,
              let source = buffer.floatChannelData?[0], buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = out.floatChannelData?[0] else { return buffer }
        let g = gainQuiet
        let n = Int(buffer.frameLength)
        for i in 0..<n { destination[i] = limited(source[i] * g) }
        out.frameLength = buffer.frameLength
        return out
    }
}
