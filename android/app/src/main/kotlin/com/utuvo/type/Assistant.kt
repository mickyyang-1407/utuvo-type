package com.utuvo.type

/**
 * 「說出要怎麼改」與「放開就翻譯」的文字引擎（對應 iOS `ios/Shared/OnDeviceAssistant.swift`）。
 *
 * Android 沒有 Apple Intelligence；裝置端只有 ML Kit 翻譯（只能翻、不能改寫）。
 * 所以改寫一定走雲端：用使用者在「智慧整理」存的 key（[AssistantRoutes.pick]），
 * 不是只有百鍊——iOS 用 `SmartCleanup.completionRoute` 的同一份選擇順序。
 *
 * 錯誤訊息照 iPhone 的短句：兩行內、含補救方法（鍵盤提示放不下長文）。
 * 這裡不碰 Android API，可以直接在 JVM 單元測試裡驗選擇順序與訊息長度。
 */
object Assistant {
    /** 鍵盤提示／設定頁顯示的引擎標示（iPhone badge：裝置端／雲端（你的 key）／不可用）。 */
    enum class Engine(val badge: String) {
        CLOUD("雲端（你的 key）"),
        UNAVAILABLE("不可用")
    }

    /** 目前有沒有可用的雲端引擎（`route != null`）。 */
    fun engine(hasRoute: Boolean): Engine = if (hasRoute) Engine.CLOUD else Engine.UNAVAILABLE

    // ── 提示詞（逐字對齊 iOS OnDeviceAssistant.editSelection／translate）──

    const val EDIT_SYSTEM = """
        你是文字編輯器。使用者會給你一段「原文」和一句「指示」。依指示修改原文，只輸出修改後的文字：不要解釋、不要引號、不要加標題、保留原文語言與大致長度。指示若是要新增內容，就在合適位置加進去；若是要改語氣，就整段改寫。
    """

    fun editUser(selection: String, instruction: String) = "原文：\n$selection\n\n指示：$instruction"

    fun translateSystem(targetZh: String, targetEn: String) =
        "你是翻譯引擎。把使用者的文字翻成$targetZh（$targetEn），只輸出翻譯本身，不要解釋、不要引號。"
}

/**
 * 選擇改寫／翻譯要用的雲端服務（對應 iOS `SmartCleanup.completionRoute`）。
 *
 * 順序：目前選的服務 → Groq → Gemini → 百鍊 → 自訂；一把有 key、端點與模型都齊的才算。
 * 抽成純函式（key／端點／模型由呼叫端給），電腦上的 JVM 測試才測得到，不碰 Android 偏好設定。
 */
object AssistantRoutes {
    /** 依序嘗試的服務（不含重複的選中服務）。 */
    fun order(selected: SmartCleanup.Provider): List<SmartCleanup.Provider> {
        val fallbacks = listOf(
            SmartCleanup.Provider.GROQ,
            SmartCleanup.Provider.GEMINI,
            SmartCleanup.Provider.DASHSCOPE,
            SmartCleanup.Provider.CUSTOM
        )
        return listOf(selected) + fallbacks.filter { it != selected }
    }

    /** 選中的服務有 key 就用它；否則找任何一把已存的 key。全部沒有 → null（這時不連雲端）。 */
    fun pick(selected: SmartCleanup.Provider, key: (SmartCleanup.Provider) -> String?,
             endpoint: (SmartCleanup.Provider) -> String,
             model: (SmartCleanup.Provider) -> String): Pair<SmartCleanup.Provider, String>? {
        for (p in order(selected)) {
            val k = key(p)?.takeIf { it.isNotBlank() } ?: continue
            if (endpoint(p).isNotBlank() && model(p).isNotBlank()) return p to k
        }
        return null
    }
}

/**
 * 錯誤翻成看得懂的一句話（對應 iOS `OnDeviceAssistant.describe`／`AssistantError`）。
 *
 * 規則（鍵盤提示約兩行）：短、講得出哪一段壞、給得出補救方法。
 * 沒有「無法完成作業」這種空泛系統訊息。
 */
object AssistantErrors {
    /** 沒有任何雲端 key：告訴他去哪裡加。 */
    const val NO_KEY = "沒有雲端 key：到設定→智慧整理加 Groq key"

    /** 改寫／翻譯用掉哪一家（設定頁與錯誤訊息都要看得出來）。 */
    fun providerNameRes(id: String): Int? = SmartLog.providerNameRes(id)

    fun forThrowable(error: Throwable, hasOnDeviceFallback: Boolean = false): String {
        val detail = detail(error)
        return if (hasOnDeviceFallback) "裝置端和雲端都失敗：$detail" else detail
    }

    /** 一句話的細節（不含前綴），長度受 hint 版面限制。 */
    fun detail(error: Throwable): String = when (error) {
        is CloudLlm.HttpError -> forHttpCode(error.code)
        is java.net.SocketTimeoutException -> "雲端逾時，稍後再試"
        is java.net.UnknownHostException, is java.net.ConnectException -> "連不上網：確認鍵盤有網路權限"
        else -> {
            val name = error.javaClass.simpleName
            when {
                name.contains("Timeout") -> "雲端逾時，稍後再試"
                name.contains("UnknownHost") || name.contains("Connect") || name.contains("Network") ->
                    "連不上網：確認鍵盤有網路權限"
                else -> "雲端回應看不懂"
            }
        }
    }

    fun forHttpCode(code: Int): String = when (code) {
        401, 403 -> "雲端 key 被拒：到設定→智慧整理重貼"
        429 -> "雲端免費額度用完了（429）"
        400 -> "雲端不接受這組參數（400）"
        in 500..599 -> "雲端服務忙（$code）"
        else -> "雲端回應錯誤 $code"
    }

    /** 模型回空字串。 */
    const val EMPTY = "模型沒有回傳內容"
}
