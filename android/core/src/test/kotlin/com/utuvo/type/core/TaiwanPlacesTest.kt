package com.utuvo.type.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 讀音相同的錯字站名（2026-09-19 實機「元山站」；iOS TaiwanPlacesTests 同一批案例）。
 * 讀音比對用繁體拼音詞庫 `pinyin-hant.dat`（與 iOS 共用同一份），詞庫位置＝`utuvo.resources`。
 */
class TaiwanPlacesTest {
    private fun fixStations(s: String): String {
        loadLexicon.value
        return TaiwanPlaces.fixStations(s)
    }

    @Test
    fun fixesHomophoneStationNames() {
        assertEquals("搭到圓山站以後換成紅線", fixStations("搭到元山站以後換成紅線"))
        assertEquals("然後搭到捷運公館", fixStations("然後搭到捷運公館"))
        assertEquals("搭到中正紀念堂站", fixStations("搭到中正記念堂站"))
        assertEquals("我在捷運忠孝復興", fixStations("我在捷運忠孝復新"))
    }

    @Test
    fun leavesOrdinaryWordsAlone() {
        assertEquals("原山的風景很好", fixStations("原山的風景很好"), "沒有站／捷運不猜")
        assertEquals("他在車站等我", fixStations("他在車站等我"))
        assertEquals("台北車站見", fixStations("台北車站見"))
    }

    @Test
    fun contextualStringsAreDistinctStationNames() {
        val all = TaiwanPlaces.contextualStrings
        assertEquals(all.distinct().size, all.size)
        assertEquals(all.size, TaiwanPlaces.taipeiMRT.distinct().size)
        assertEquals("圓山站", all.first { it == "圓山站" })
    }

    companion object {
        /** 詞庫載入慢，懶載入一次就好（kotlin-test 只掛 JUnit 5 的 @Test，不靠生命週期註解）。 */
        private val loadLexicon = lazy {
            val dir = System.getProperty("utuvo.resources")?.let(::File)
            check(dir != null && dir.isDirectory) { "utuvo.resources 沒設或不是資料夾（core/build.gradle.kts 應該有設）" }
            val lexicon = PinyinLexicon.open(File(dir, "pinyin-hant.dat"))
            checkNotNull(lexicon) { "pinyin-hant.dat 開不起來：$dir" }
            TaiwanPlaces.lexicon = lexicon
        }
    }
}
