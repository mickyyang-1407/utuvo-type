package com.utuvo.type.core

/**
 * Android 鍵盤：系統辨識器最後交回**空的**結果時，這次聽寫要怎麼收尾（純函式，JVM 測得到）。
 *
 * 同樣是「系統沒聽到」，系統可能用 onError(NO_MATCH) 回報，也可能用 onResults 回一個空結果。
 * onError 那條路手上有雲端錄音就先送雲端救；onResults 回空的這條路以前直接丟掉錄音、提示回到待機，
 * 使用者講的話整段不見、也沒有任何回饋（2026-10-22 mobile-keyboard-v2）。
 *
 * - [Action.RESCUE]：使用者自己按了停、手上有雲端錄音、而且不是翻譯 → 跟 onError 一樣送雲端救，
 *   救不回來才提示「沒有聽到聲音」。
 * - [Action.DROP]：60 秒沒講話自動收尾（不能把一分鐘的靜音送上雲端）、沒有雲端錄音、或翻譯中
 *   （翻譯要的是翻好的文字，不錄雲端）→ 丟掉錄音，但要提示「沒有聽到聲音」，不能靜默回到待機。
 */
object EmptyStopPlan {
    enum class Action { RESCUE, DROP }

    @JvmStatic
    fun decide(stopRequested: Boolean, hasCloudSamples: Boolean, translating: Boolean): Action =
        if (stopRequested && hasCloudSamples && !translating) Action.RESCUE else Action.DROP
}
