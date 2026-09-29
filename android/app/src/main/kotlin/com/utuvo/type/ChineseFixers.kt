package com.utuvo.type

import android.content.Context
import com.utuvo.type.core.TaiwanPlaces
import com.utuvo.type.core.TraditionalFixer

/**
 * 繁中逐字硬轉與站名救援（同 iOS TraditionalFixer＋TaiwanPlaces）。
 *
 * 系統語音的繁體是逐字硬轉的（回家→迴家、頭髮→頭發、颱風→臺風…），雲端辨識與雲端整理的回來文字也可能這樣；
 * 這裡在文字進到使用者的輸入框之前按詞轉回台灣繁體，再把讀音相同的錯字站名救回來。
 * 詞表與 iOS 共用同一份（OpenCC 在 assets、拼音詞庫在 pinyin-hant.dat），不在手機上重複一份。
 */
object ChineseFixers {
    private val lock = Any()
    @Volatile private var ready = false

    fun ready() = ready

    /** 第一次用到才載入詞表（讀一次幾百 KB，之後快取住）。 */
    fun configure(c: Context) {
        if (ready) return
        synchronized(lock) {
            if (ready) return
            val app = c.applicationContext
            TraditionalFixer.configure(TraditionalFixer.assetsSource { name ->
                runCatching { app.assets.open(name) }.getOrNull()
            })
            TaiwanPlaces.lexicon = Lexicons.pinyinHant(app)
            ready = true
        }
    }

    /** 站名救援包在繁體修正外層（同 iOS SpeechEngine：先轉繁體，再救站名）。詞表沒載到就原樣回傳。 */
    fun fix(text: String): String = TaiwanPlaces.fixStations(TraditionalFixer.fix(text))
}
