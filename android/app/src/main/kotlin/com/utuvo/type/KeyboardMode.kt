package com.utuvo.type

/**
 * 鍵盤的純邏輯：模式判定與提示文案（對應 iOS `ios/Shared/KeyboardLogic.swift` 的 `KeyboardMode`）。
 *
 * 對齊 Typeless：選取文字＝「說出要怎麼改」；長按光球滑到語言＝「放開就翻譯」；其餘＝聽寫。
 * 不碰 Android API，JVM 單元測試直接餵選取文字與翻譯目標。
 */
sealed interface KeyboardMode {
    data object Dictate : KeyboardMode
    data class Edit(val selection: String) : KeyboardMode
    data class Translate(val target: Translation.Target) : KeyboardMode

    companion object {
        /** 決策順序：翻譯（剛剛長按選了語言）> 編輯（有選取）> 聽寫。 */
        fun decide(selectedText: String?, translateTarget: Translation.Target?): KeyboardMode {
            if (translateTarget != null) return Translate(translateTarget)
            val selection = selectedText?.trim().orEmpty()
            if (selection.isNotEmpty()) return Edit(selection)
            return Dictate
        }
    }

    /** 錄音前的提示（點一下說）。 */
    fun idleHint(targetName: String): String = when (this) {
        Dictate -> "點一下開始說"
        is Edit -> "說出要怎麼改"
        is Translate -> "說中文，貼上$targetName"
    }

    /** 錄音中的提示（再點一下完成）。 */
    fun recordingHint(targetName: String): String = when (this) {
        Dictate -> "再點一下完成"
        is Edit -> "說完再點一下，改寫會取代選取"
        is Translate -> "再點一下完成，翻成$targetName"
    }

    /** 「說出要怎麼改」時光球轉薰衣草，一眼看出現在講的是指示而不是新內容。 */
    val isEdit: Boolean get() = this is Edit
}
