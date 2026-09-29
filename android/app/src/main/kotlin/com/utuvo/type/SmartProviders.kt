package com.utuvo.type

/**
 * 沒選過服務時用哪一家（同 iOS `SmartCleanup.resolvedDefaultProvider`）。
 *
 * 推薦服務＝Groq（2026-09-26 Micky：Gemini 免費版實測每天只有 20 次）。
 * 0.2.2 以前預設是 Gemini、而且不會寫入 provider，所以「沒存過 provider 但有 Gemini key」＝舊使用者正在用 Gemini，要維持。
 * 例外：鑰匙圈在刪 App 重裝後還在、偏好不在；兩把 key 都有時選推薦的 Groq（不猜成舊的 Gemini）。
 *
 * 放成獨立物件（不碰 Android 設定、不碰 Handler），電腦上的 JVM 測試才測得到。
 */
object SmartProviders {
    val recommended: SmartCleanup.Provider = SmartCleanup.Provider.GROQ

    fun resolve(stored: String?, hasGeminiKey: Boolean, hasGroqKey: Boolean = false): SmartCleanup.Provider {
        SmartCleanup.Provider.entries.firstOrNull { it.id == stored }?.let { return it }
        if (hasGroqKey) return SmartCleanup.Provider.GROQ
        return if (hasGeminiKey) SmartCleanup.Provider.GEMINI else recommended
    }
}
