package com.utuvo.type

import android.content.Intent
import android.os.Build
import android.speech.RecognizerIntent

/**
 * 鍵盤送給辨識器的請求（測試也用這一份，驗到的就是鍵盤真正送出的設定）。
 *
 * 標點：Android 13+ 要開 EXTRA_ENABLE_FORMATTING，辨識器才會加標點（停頓逗號、問句問號、轉折逗號）。
 * 沒開＝整段零標點（09-19 Pixel 7 實測，Micky 回報「完全沒有標點符號」）。
 */
object SpeechRequest {
    /** biasing：個人字典的詞（Android 13+ EXTRA_BIASING_STRINGS），讓人名、術語比較容易聽對。 */
    fun build(language: String, biasing: List<String> = emptyList()): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        if (Build.VERSION.SDK_INT >= 33) {
            putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
            if (biasing.isNotEmpty()) putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(biasing))
        }
    }
}
