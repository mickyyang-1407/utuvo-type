package com.utuvo.type.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 逐字硬轉的繁中修正（iOS TraditionalFixerTests 同一批案例）；字典與 iOS 共用同一份 OpenCC 檔案。
 * 位置由 `utuvo.opencc` 系統屬性指定（core/build.gradle.kts 設成 ios/Shared/Resources/OpenCC）。
 */
class TraditionalFixerTest {
    private fun fix(s: String): String {
        loadDictionaries.value
        return TraditionalFixer.fix(s)
    }

    @Test
    fun fixesCharacterByCharacterConversion() {
        assertEquals("我等一下就回家了，你先回去吧", fix("我等一下就迴家了，你先迴去吧"))
        assertEquals("我剛剛發現頭髮太長了", fix("我剛剛發現頭發太長了"))
        assertEquals("颱風要來了，台灣這幾天會下大雨", fix("臺風要來了，臺灣這幾天會下大雨"))
        assertEquals("這跟系統沒有關係", fix("這跟係統沒有關係"))
        assertEquals("後面還有很多人，皇后很美", fix("後麵還有很多人，皇後很美"))
    }

    @Test
    fun correctTextStaysAndEnglishUntouched() {
        val s = "這首歌的混音我想請你幫我再調整幾個地方，room mic 太多了，傳一個 WAV 給我。"
        assertEquals(s, fix(s))
    }

    @Test
    fun tokensKeepContextAndSplitBack() {
        loadDictionaries.value
        assertEquals(listOf("回", "家", "了"), TraditionalFixer.fixTokens(listOf("迴", "家", "了")))
    }

    companion object {
        /** 詞表載入慢，懶載入一次就好（kotlin-test 只掛 JUnit 5 的 @Test，不靠生命週期註解）。 */
        private val loadDictionaries = lazy {
            val dir = System.getProperty("utuvo.opencc")?.let(::File)
            check(dir != null && dir.isDirectory) { "utuvo.opencc 沒設或不是資料夾（core/build.gradle.kts 應該有設）" }
            TraditionalFixer.configure(TraditionalFixer.directorySource(dir))
        }
    }
}
