package com.utuvo.type

import android.content.Context

/**
 * 小聲說話模式（對齊工單 android-C）。
 *
 * 設定開關「小聲說話」：
 * 1. 錄音前級增益提高（[GAIN_QUIET]，約 +8 dB），放大低音量語音。
 * 2. 靜音判斷門檻降低／等待時間放寬（[SILENCE_COMPLETE_QUIET_MS]、[MIN_SPEECH_QUIET_MS]），
 *    讓輕聲說話者的氣音或斷續停頓不被提早截斷。
 * 預設關閉。
 */
object QuietMode {
    private const val PREFS = DictationLanguage.PREFS
    private const val KEY = "quiet_mode"

    /** 一般模式前級增益（原訊號大小）。 */
    const val GAIN_NORMAL = 1.0f

    /** 小聲模式前級增益（提升 2.5 倍，相當於約 +8 dB 的數位前級增益）。 */
    const val GAIN_QUIET = 2.5f

    /** 一般模式下判定為完整靜音的等待長度（毫秒）。 */
    const val SILENCE_COMPLETE_NORMAL_MS = 1500L

    /** 小聲模式下放寬完整靜音等待時間（毫秒），避免輕聲說話時較長的換氣停頓被過早截斷。 */
    const val SILENCE_COMPLETE_QUIET_MS = 3000L

    /** 一般模式下判定可能為靜音的長度（毫秒）。 */
    const val SILENCE_POSSIBLY_COMPLETE_NORMAL_MS = 1000L

    /** 小聲模式下判定可能為靜音的長度（毫秒）。 */
    const val SILENCE_POSSIBLY_COMPLETE_QUIET_MS = 2000L

    /** 一般模式下判定有語音活動的最小長度（毫秒）。 */
    const val MIN_SPEECH_NORMAL_MS = 1000L

    /** 小聲模式降低最小語音活動長度（毫秒），使微弱聲音更容易被辨識器捕捉。 */
    const val MIN_SPEECH_QUIET_MS = 500L

    fun isEnabled(c: Context): Boolean =
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)

    fun setEnabled(c: Context, on: Boolean) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
    }

    /** 根據開關狀態回傳對應的數位前級增益倍數。 */
    fun gain(enabled: Boolean): Float = if (enabled) GAIN_QUIET else GAIN_NORMAL

    /** 軟膝限幅的膝點：絕對值在這以下原樣通過（一般說話的樣本都在這裡，不被染色）。 */
    const val LIMITER_KNEE = 0.7f

    /** 軟膝限幅的上限：放大後的峰值平滑地逼近它、永遠不會碰到，不會變成硬削波的方波。 */
    const val LIMITER_CEILING = 0.98f

    /**
     * 單一樣本的軟膝限幅（同 iOS QuietMode.limited）。
     * 2.5 倍增益下大聲的字會超過 ±1；直接夾住＝硬削波，失真對辨識的傷害比小聲更大。
     * 膝點以上用 tanh 漸近 [LIMITER_CEILING]，連續且單調；Float 的 tanh 在大引數會進位成 1.0，
     * 所以再夾在 ceiling 的前一個可表示值，保證嚴格小於 ceiling。
     */
    fun limited(sample: Float): Float {
        val magnitude = kotlin.math.abs(sample)
        if (magnitude <= LIMITER_KNEE) return sample
        val span = LIMITER_CEILING - LIMITER_KNEE
        val asymptotic = LIMITER_KNEE + span * kotlin.math.tanh((magnitude - LIMITER_KNEE) / span)
        val shaped = minOf(Math.nextDown(LIMITER_CEILING), asymptotic)
        return if (sample < 0f) -shaped else shaped
    }
}
