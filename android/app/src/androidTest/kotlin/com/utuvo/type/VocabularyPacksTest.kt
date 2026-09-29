package com.utuvo.type

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import android.content.Context

/**
 * 詞庫目錄 + 選詞器（CONTRACT-V2 schema 2）。
 * 純 JVM 測試：用合成 catalog + InMemoryPackTermsSource 直接注入，不讀 asset。
 */
@RunWith(AndroidJUnit4::class)
class VocabularyPacksTest {

    /** 測試 seam：合成 pack terms。 */
    private class InMemorySource(val map: Map<String, List<String>>) : PackTermsSource {
        override fun readTermsFile(packID: String): List<String>? = map[packID]
    }

    @After
    fun reset() {
        val c = InstrumentationRegistry.getInstrumentation().targetContext
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        VocabularyPacks.setTermsSourceForTest(InMemorySource(emptyMap()))
        // 清掉測試寫進 prefs 的 enabled／個人字典狀態，不留給下一個測試／下一次跑。
        c.getSharedPreferences("vocabularyPacks", Context.MODE_PRIVATE).edit().clear().commit()
        c.getSharedPreferences("dictionary", Context.MODE_PRIVATE).edit().clear().commit()
    }

    private fun makePacks(terms: Map<String, List<String>>): List<VocabularyCatalog.Pack> =
        VocabularyCatalog.Catalog.knownIDs.map { id ->
            VocabularyCatalog.Pack(
                id = id, name = id, summary = "",
                sourceName = "", sourceURL = "",
                licenseName = "", licenseURL = "",
                attribution = "", version = "2026-09-20",
                defaultOn = false,
                seedTerms = listOf("代表詞-$id"),
                termCount = terms[id]?.size ?: 0,
                termsSHA256 = "",
                terms = terms[id],
                termsFile = "$id.txt",
            )
        }

    // MARK: - schema 2

    @Test fun decodesSchema2() {
        val json = """
            {"schemaVersion":2,"packs":[
              {"id":"computing","name":"資訊與電腦","summary":"x","sourceName":"x","sourceURL":"x","licenseName":"x","licenseURL":"x","attribution":"x","version":"v","defaultOn":false,
               "seedTerms":["人工智慧"],"termsFile":"computing.txt","termCount":120000,"termsSHA256":"abc"}
            ]}
        """.trimIndent()
        val c = VocabularyCatalog.decode(json)
        assertEquals(2, c.schemaVersion)
        val p = c.packs.first()
        assertEquals("computing", p.id)
        assertEquals(120000, p.termCount)
        assertEquals("computing.txt", p.termsFile)
        assertNull(p.terms)
    }

    @Test fun rejectsSchema1() {
        val json = """{"schemaVersion":1,"packs":[{"id":"computing","name":"X","terms":["a"]}]}"""
        try {
            VocabularyCatalog.decode(json); assertTrue("應該丟例外", false)
        } catch (e: Exception) {
            assertTrue(e is VocabularyCatalog.LoadError)
        }
    }

    @Test fun allowlistOnlySixKnownIDs() {
        for (id in VocabularyCatalog.Catalog.knownIDs) {
            assertTrue(AssetPackTermsSource.isAllowedID(id))
        }
        assertFalse(AssetPackTermsSource.isAllowedID("../../../etc/passwd"))
        assertFalse(AssetPackTermsSource.isAllowedID("../escape"))
        assertFalse(AssetPackTermsSource.isAllowedID("custom"))
    }

    @Test fun cleanTermRejectsBadInput() {
        assertTrue(AssetPackTermsSource.isCleanTerm("人工智慧"))
        assertFalse(AssetPackTermsSource.isCleanTerm("7) 碼"))
        assertFalse(AssetPackTermsSource.isCleanTerm("人工(智慧"))
        assertFalse(AssetPackTermsSource.isCleanTerm("<b>詞"))
        assertFalse(AssetPackTermsSource.isCleanTerm("a"))
        assertFalse(AssetPackTermsSource.isCleanTerm("字".repeat(41)))
    }

    /** Kimi review round 1（低）：`&` 是合法詞（AT&T世界網／H&E染色法／程式&時鐘板），不得清洗丟棄。 */
    @Test fun cleanTermAcceptsLegitAmpersand() {
        assertTrue(AssetPackTermsSource.isCleanTerm("AT&T世界網"))
        assertTrue(AssetPackTermsSource.isCleanTerm("H&E染色法"))
        assertTrue(AssetPackTermsSource.isCleanTerm("程式&時鐘板"))
    }

    /** 實際 loader（真實 assets .txt）：3 個含 & 的詞在、且每包實際載入數＝metadata termCount。 */
    @Test fun assetLoaderIncludesAmpersandTermsAndCountsMatchMetadata() {
        val c = ctx()
        VocabularyPacks.setTermsSourceForTest(AssetPackTermsSource(c.assets))
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        VocabularyPacks.ensureCatalogLoaded(c)
        val catalog = VocabularyPacks.catalog()
        assertEquals(6, catalog.packs.size)
        for (pack in catalog.packs) {
            val terms = VocabularyPacks.packWithTermsLoaded(c, pack.id)!!.terms!!
            assertEquals("${pack.id} 實際載入數應等於 metadata termCount", pack.termCount, terms.size)
        }
        assertTrue(AssetPackTermsSource(c.assets).readTermsFile("computing")!!.contains("AT&T世界網"))
        assertTrue(AssetPackTermsSource(c.assets).readTermsFile("medicine")!!.contains("H&E染色法"))
        assertTrue(AssetPackTermsSource(c.assets).readTermsFile("computing")!!.contains("程式&時鐘板"))
    }

    /**
     * Kimi review round 1（中）：biasing 個人詞——output 非空只送 output（不送 source 錯誤拼字）、
     * output 空（vocabulary-only）送 source 本身。真實入口 biasing(c)＋隔離 prefs。
     */
    @Test fun biasingPersonalEmptyOutputUsesSourceAndSkipsSourceWhenOutputExists() {
        val c = ctx()
        // 隔離 prefs：清掉個人字典與 enabled，讓 biasing 只看本測試的兩筆。
        c.getSharedPreferences("dictionary", Context.MODE_PRIVATE).edit().clear().commit()
        setEnabledIds(c, emptySet())   // stored 非空 → 內建包全關（無 defaultOn）
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        try {
            DictionaryStore.add(c, "jeman", "Gemini")   // 替換條目：output 非空
            DictionaryStore.add(c, "悠悠卡", "")         // vocabulary-only：output 空
            val biasing = VocabularyPacks.biasing(c)
            assertTrue("output 非空：送 output", biasing.contains("Gemini"))
            assertTrue("output 空：送 source 本身", biasing.contains("悠悠卡"))
            assertFalse("output 存在時不送 source 錯誤拼字", biasing.contains("jeman"))
            assertTrue(biasing.size <= 200)
        } finally {
            c.getSharedPreferences("dictionary", Context.MODE_PRIVATE).edit().clear().commit()
        }
    }

    // MARK: - cleanup 選詞

    @Test fun personalDictionaryWinsEvenWithEmptyOutput() {
        val dict = mapOf("jeman" to "Gemini", "cloudcoate" to "Claude Code", "悠悠卡" to "悠遊卡")
        val out = VocabularySelector.termsForCleanup("講到 jeman", emptyList(), dict, emptySet())
        assertTrue(out.contains("Gemini"))
        assertTrue(out.contains("Claude Code"))
        assertTrue(out.contains("悠遊卡"))
    }

    @Test fun relevantTermAppearsEvenWhenFarInBigPack() {
        val engineering = (1..800).map { "工程詞$it" } + listOf("人工智慧", "機器學習", "深度學習")
        val computing = listOf("資料結構")
        val packs = makePacks(mapOf("engineering" to engineering, "computing" to computing))
        val out = VocabularySelector.termsForCleanup("我在研究人工智慧", packs, emptyMap(), emptySet())
        assertTrue(out.contains("人工智慧"))
    }

    @Test fun fairMergePreventsBigPackFromSqueezingOthers() {
        val engineering = (1..1000).map { "工程詞$it" }
        val computing = listOf("資料結構", "演算法", "資料庫", "作業系統", "編譯器")
        val packs = makePacks(mapOf("engineering" to engineering, "computing" to computing))
        val out = VocabularySelector.termsForCleanup("資料結構 工程詞1 演算法 工程詞2", packs, emptyMap(), emptySet())
        assertTrue(out.contains("資料結構"))
        assertTrue(out.contains("演算法"))
        assertTrue(out.size <= 200)
    }

    @Test fun seedRotationWhenNoRelevantMatch() {
        val engineering = (1..100).map { "工程詞$it" }
        val packs = makePacks(mapOf("engineering" to engineering))
        val out = VocabularySelector.termsForCleanup("完全不相關的句子", packs, emptyMap(), emptySet())
        assertTrue(out.contains("代表詞-engineering"))
    }

    @Test fun stationTermsOnlyWhenTalkingAboutStations() {
        val stations = setOf("圓山站", "台北車站")
        val tw = VocabularyCatalog.Pack(
            id = "tw", name = "tw", summary = "",
            sourceName = "", sourceURL = "",
            licenseName = "", licenseURL = "",
            attribution = "", version = "",
            defaultOn = true,
            seedTerms = listOf("圓山站"), termCount = 0,
            termsSHA256 = "",
            terms = listOf("圓山站", "台北車站", "西門站", "高鐵"),
            termsFile = ""
        )
        val plain = VocabularySelector.termsForCleanup("我搭高鐵", listOf(tw), emptyMap(), stations)
        assertFalse(plain.contains("圓山站"))
        assertFalse(plain.contains("台北車站"))
        assertTrue(plain.contains("高鐵"))
        val stationText = VocabularySelector.termsForCleanup("我搭到元山站", listOf(tw), emptyMap(), stations)
        assertTrue(stationText.contains("圓山站"))
    }

    @Test fun capAt200() {
        val dict = (1..500).associate { "k$it" to "v$it" }
        val packs = makePacks(emptyMap())
        val out = VocabularySelector.termsForCleanup(null, packs, dict, emptySet())
        assertTrue(out.size <= 200)
        assertEquals(out.size, out.distinct().size)
    }

    @Test fun missingOrCorruptCatalogFallsBackToEmpty() {
        val out = VocabularySelector.termsForCleanup(null, emptyList(), emptyMap(), emptySet())
        assertEquals(0, out.size)
    }

    @Test fun unicodeAndDedup() {
        val dict = mapOf("Jeman" to "Gemini", "jeman" to "Gemini", "JEMAN" to "Gemini")
        val out = VocabularySelector.termsForCleanup("Jeman", emptyList(), dict, emptySet())
        assertEquals(1, out.count { it == "Gemini" })
    }

    // MARK: - search

    @Test fun searchCapsAt100AndPrefersSeed() {
        val terms = (1..500).map { "詞$it" }
        val pack = VocabularyCatalog.Pack(
            id = "law", name = "法律", summary = "",
            sourceName = "", sourceURL = "",
            licenseName = "", licenseURL = "",
            attribution = "", version = "",
            defaultOn = false,
            seedTerms = listOf("詞100"), termCount = terms.size,
            termsSHA256 = "",
            terms = terms,
            termsFile = ""
        )
        val matches = VocabularySelector.search("詞", pack, limit = 100)
        assertEquals(100, matches.size)
    }

    // MARK: - latin seed（避免巨量詞灌 LatinNameFixer）

    @Test fun latinSeedTermsOnlyReturnsSeedLatinWords() {
        val engineering = VocabularyCatalog.Pack(
            id = "engineering", name = "", summary = "",
            sourceName = "", sourceURL = "",
            licenseName = "", licenseURL = "",
            attribution = "", version = "",
            defaultOn = false,
            seedTerms = listOf("Bridge", "Tunnel", "鋼筋"),
            termCount = 0, termsSHA256 = "",
            terms = listOf("Bridge", "Tunnel", "鋼筋混凝土", "水泥", "灌注樁"),
            termsFile = ""
        )
        val seeds = VocabularySelector.latinSeedTerms(listOf(engineering))
        assertEquals(listOf("Bridge", "Tunnel"), seeds)
    }

    // MARK: - 6-pack enabled 載入：確保 selector 用的 terms 是 loaded 的那批

    @Test
    fun enabledCatalogPacksLoadedReturnsLoadedTerms() {
        val computingTerms = listOf("人工智慧", "機器學習", "深度學習")
        val packList = listOf(
            VocabularyCatalog.Pack(
                id = "computing", name = "資訊", summary = "",
                sourceName = "", sourceURL = "",
                licenseName = "", licenseURL = "",
                attribution = "", version = "v",
                defaultOn = true,
                seedTerms = listOf("人工智慧"),
                termCount = computingTerms.size,
                termsSHA256 = "",
                terms = null,
                termsFile = "computing.txt",
            )
        )
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog(2, packList))
        val src = InMemorySource(mapOf("computing" to computingTerms))
        VocabularyPacks.setTermsSourceForTest(src)
        val loaded = packList.map {
            if (it.terms == null) it.terms = src.readTermsFile(it.id)
            it
        }
        assertNotNull(loaded.first().terms)
        assertTrue(loaded.first().terms!!.contains("人工智慧"))
    }

    // MARK: - 入口冷啟動與 disabled 排除（RUNTIME-INTEGRATION-FINDINGS #1/#2）

    private fun ctx(): Context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun setEnabledIds(c: Context, ids: Set<String>) {
        c.getSharedPreferences("vocabularyPacks", Context.MODE_PRIVATE)
            .edit().putStringSet("enabled", ids).commit()
    }

    /** 冷啟動：不經過 buildPacks（設定頁），biasing／termsForCleanup 入口要自己把 catalog 載起來。 */
    @Test fun entryPointColdStartLoadsCatalogFromAssets() {
        val c = ctx()
        setEnabledIds(c, setOf("ai", "medicine"))   // medicine = catalog 包
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)   // 模擬 IME 冷啟動
        val biasing = VocabularyPacks.biasing(c)
        assertEquals(2, VocabularyPacks.catalog().schemaVersion)
        assertEquals(6, VocabularyPacks.catalog().packs.size)
        assertTrue("medicine 開啟＋冷啟動，seed 必須進 biasing（實際前 30：${biasing.take(30)}）",
            biasing.contains("心肌梗塞"))
    }

    /** disabled 的內建包（audio 預設關）與 catalog 包不得進 biasing／cleanup。 */
    @Test fun disabledPacksExcludedFromBiasingAndCleanup() {
        val c = ctx()
        setEnabledIds(c, setOf("ai"))
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        val biasing = VocabularyPacks.biasing(c)
        assertFalse("audio 關閉不得進 biasing", biasing.contains("Dolby Atmos"))
        assertFalse("catalog 包預設全關不得進 biasing", biasing.contains("心肌梗塞"))
        val cleanup = VocabularyPacks.termsForCleanup(c, null)
        assertFalse(cleanup.contains("Dolby Atmos"))
        assertFalse(cleanup.contains("心肌梗塞"))
    }

    /** 明細搜尋：不管開／關都要能載入這一包完整詞表，且不得隱式啟用。 */
    @Test fun packWithTermsLoadsRegardlessOfEnabledState() {
        val c = ctx()
        // 前一個測試的 @After 會把 seam 換成空 InMemorySource；這裡換回真實 assets 才讀得到 .txt。
        VocabularyPacks.setTermsSourceForTest(AssetPackTermsSource(c.assets))
        setEnabledIds(c, setOf("ai"))   // computing 關閉
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        val pack = VocabularyPacks.packWithTermsLoaded(c, "computing")
        assertNotNull(pack)
        assertNotNull(pack!!.terms)
        assertTrue("關閉狀態也要載得到非 seed 詞", pack.terms!!.contains("雲端運算"))
        assertTrue("瀏覽明細不得隱式啟用",
            VocabularyPacks.enabledCatalogPacks(c).none { it.id == "computing" })
    }

    /** 開關持久化：開 medicine → 重讀 prefs 仍是開；關掉後立即排除。 */
    @Test fun togglePersistsAndImmediatelyExcludes() {
        val c = ctx()
        setEnabledIds(c, setOf("ai"))
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        VocabularyPacks.ensureCatalogLoaded(c)   // catalog() 是純讀快取；先觸發載入
        val medicine = VocabularyPacks.catalog().packs.first { it.id == "medicine" }
        VocabularyPacks.setCatalogEnabled(c, medicine, true)
        assertTrue(VocabularyPacks.enabledCatalogPacks(c).any { it.id == "medicine" })
        // 模擬程序重啟：catalog 重新讀，prefs 不變 → 仍是開
        VocabularyPacks.setCatalogForTest(VocabularyCatalog.Catalog.empty)
        assertTrue(VocabularyPacks.enabledCatalogPacks(c).any { it.id == "medicine" })
        VocabularyPacks.setCatalogEnabled(c, medicine, false)
        assertFalse(VocabularyPacks.enabledCatalogPacks(c).any { it.id == "medicine" })
    }
}