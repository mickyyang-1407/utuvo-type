import Foundation

/// 忘記關麥的保護（capture-latency-v3，2026-10-22；repair-batch1 修正同日）。
///
/// Mac 以前唯一的自動停止是「安靜時自動結束」（安靜 3 秒就停，對長段口述太短，所以預設關），沒有錄音長度上限：
/// 切換模式忘了按停就一直錄，按停後整段環境音被轉錄、貼進目前的欄位（開了自動送出還會直接送出）。
///
/// - 長度上限：Typeless 桌面版 `MAX_DURATION_MS` 9 分鐘，最後 1 分鐘倒數（`COUNTDOWN_BUFFER_MS`），
///   到了照常停止並送出（`RECORD.TIMEOUT` → stopping → finishing）。只有 Groq 雲端一條辨識路（沒裝本機引擎）時
///   上限是 Groq 一次收的 `MacCloudASR.maxSeconds`（300 秒）**再扣 5 秒餘裕**：每秒才檢查一次、停止要一點時間，
///   而且長度按**實際錄到的音訊**算（引擎比這個計時器先開始，那一段也會送去 Groq）——上限剛好 300 秒的話，
///   被截斷的錄音一定超過 300 秒，Groq 直接拒收，重試也救不回來。
///   repair round 2：上限另外在 tap 端**按樣本數**硬截（`AudioCaptureSession.captureLimitSeconds`）：到了上限之後的
///   音訊不寫檔、不送 PCM，主執行緒卡住也不會讓送給 Groq 的錄音超過上限；這裡（每秒一次）負責倒數與停止。
/// - 長時間安靜：連續 60 秒沒有聲音就開始倒數 30 秒，倒數中講話就取消；倒數完才照常停止。
///   「有聲音」的門檻比「安靜時自動結束」低很多（`AudioCaptureSession.longSilenceActivityRMS`），小聲講話不算安靜。
///   這樣停下來的那一次不自動送出（`AppModel.effectiveAutoSubmit`）：文字照樣貼上、留在歷史。
///   一律開啟，跟「安靜時自動結束」那個 3 秒選項無關（那個預設仍是關）。
///
/// 純邏輯、時間由呼叫端傳入：測試不用真的錄音。每次錄音一個值，`stop` 只會回一次。
struct RecordingLimits: Sendable {
    static let maxSeconds: TimeInterval = 9 * 60
    /// 只有 Groq 時，上限比 Groq 收的長度短這麼多（秒）。
    static let cloudSafetyMarginSeconds: TimeInterval = 5
    static let cloudOnlyMaxSeconds: TimeInterval = MacCloudASR.maxSeconds - cloudSafetyMarginSeconds
    static let warningSeconds: TimeInterval = 60
    /// 連續這麼久沒聲音才開始倒數。
    static let longSilenceSeconds: TimeInterval = 60
    /// 安靜停止前的倒數（倒數中有聲音就取消）。
    static let longSilenceWarningSeconds: TimeInterval = 30

    enum StopReason: Equatable, Sendable {
        case maxDuration
        case longSilence
    }

    enum Action: Equatable, Sendable {
        case none
        /// 快到長度上限：還剩幾秒（無條件進位）。
        case countdown(secondsLeft: Int)
        /// 很久沒聲音：再安靜幾秒就停（無條件進位）；講話就取消。
        case silenceCountdown(secondsLeft: Int)
        /// 現在照常停止。
        case stop(StopReason)
    }

    let startedAt: Date
    let maxDuration: TimeInterval
    let warningLead: TimeInterval
    let longSilence: TimeInterval
    let silenceWarning: TimeInterval
    private(set) var stopped = false
    /// 這一輪安靜倒數從什麼時候開始（第一次回 `.silenceCountdown` 的那一刻）；有聲音就清掉。
    private var silenceWarnedAt: Date?

    init(startedAt: Date, maxDuration: TimeInterval = maxSeconds, warningLead: TimeInterval = warningSeconds,
         longSilence: TimeInterval = longSilenceSeconds, silenceWarning: TimeInterval = longSilenceWarningSeconds) {
        self.startedAt = startedAt
        self.maxDuration = maxDuration
        self.warningLead = warningLead
        self.longSilence = longSilence
        self.silenceWarning = silenceWarning
    }

    static func maxDuration(cloudOnly: Bool) -> TimeInterval {
        cloudOnly ? cloudOnlyMaxSeconds : maxSeconds
    }

    /// 只看牆上時鐘（測試與沒有錄音長度可讀時）。
    mutating func check(now: Date, lastVoiceAt: Date?) -> Action {
        check(now: now, capturedSeconds: nil, lastVoiceAt: lastVoiceAt)
    }

    /// - Parameters:
    ///   - capturedSeconds: 到目前為止實際錄到的音訊長度（`AudioCaptureSession.capturedSeconds`）。
    ///     長度上限取它跟牆上時鐘比較長的那個：引擎比計時早開始，送給辨識的是錄到的全部。
    ///   - lastVoiceAt: 最後一次聽到聲音的時間；nil 或早於開始＝從開始到現在都沒聲音。
    mutating func check(now: Date, capturedSeconds: TimeInterval?, lastVoiceAt: Date?) -> Action {
        guard !stopped else { return .none }
        let elapsed = max(now.timeIntervalSince(startedAt), capturedSeconds ?? 0)
        if elapsed >= maxDuration {
            stopped = true
            return .stop(.maxDuration)
        }
        let quietSince = max(lastVoiceAt ?? startedAt, startedAt)
        var silenceLeft: TimeInterval?
        if now.timeIntervalSince(quietSince) >= longSilence {
            // 倒數一定先出現、而且出現滿 `silenceWarning` 秒才停：中間漏了幾次檢查（App 卡住）也不會直接停。
            let warnedAt = silenceWarnedAt ?? now
            silenceWarnedAt = warnedAt
            let left = silenceWarning - now.timeIntervalSince(warnedAt)
            if left <= 0 {
                stopped = true
                return .stop(.longSilence)
            }
            silenceLeft = left
        } else {
            silenceWarnedAt = nil
        }
        let maxLeft = maxDuration - elapsed
        let inMaxWarning = elapsed >= maxDuration - warningLead
        if let silenceLeft, !inMaxWarning || silenceLeft < maxLeft {
            return .silenceCountdown(secondsLeft: Int(silenceLeft.rounded(.up)))
        }
        if inMaxWarning {
            return .countdown(secondsLeft: Int(maxLeft.rounded(.up)))
        }
        return .none
    }
}
