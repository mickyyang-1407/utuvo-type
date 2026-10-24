package com.utuvo.type

import java.util.concurrent.atomic.AtomicBoolean

/**
 * 語音翻譯要翻的是哪一份文字（modes-2）。純邏輯，JVM 測得到。
 *
 * 以前翻的是確定性整理（Dictation.clean）的結果：「三點，不對，四點」這類改口、口頭禪原封不動被翻出去。
 * 現在有開智慧整理、而且有雲端 key 時，先跑**同一套**智慧整理（同樣的提示詞、同樣的把關、同樣的時限），
 * 翻整理好的那一份；整理失敗、逾時、沒通過把關就翻原本那一份——翻譯永遠不會因為整理卡住。
 *
 * 只有手機上的模型（沒有雲端 key）時不先整理：那條路一句要 8–60 秒，翻譯會被拖住。
 */
internal object TranslateSource {
    /** 先整理再翻譯的條件：智慧整理開著（[SmartCleanup.isEnabled]），而且不是只有手機上的模型。 */
    fun cleansFirst(cleanupEnabled: Boolean, onDeviceOnly: Boolean): Boolean = cleanupEnabled && !onDeviceOnly

    /**
     * 跑一次翻譯：[cleanFirst] 時先 [clean]（回 null＝不用整理結果），再把選好的文字交給 [translate]。
     * [translate] 只會被叫一次（整理的回呼就算被叫兩次也一樣）。
     */
    fun run(
        cleanFirst: Boolean,
        deterministic: String,
        clean: (done: (String?) -> Unit) -> Unit,
        translate: (String) -> Unit,
    ) {
        if (!cleanFirst) { translate(deterministic); return }
        val once = AtomicBoolean(false)
        clean { cleaned ->
            if (once.compareAndSet(false, true)) translate(pick(deterministic, cleaned))
        }
    }

    /** 整理好的那份有字就用它，否則用原本那份。 */
    fun pick(deterministic: String, cleaned: String?): String =
        cleaned?.trim()?.takeIf { it.isNotEmpty() } ?: deterministic
}
