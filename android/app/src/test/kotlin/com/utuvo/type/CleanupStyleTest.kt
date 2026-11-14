package com.utuvo.type

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** 整理風格（2026-11-14，同 iOS TypelessW3Tests 的那幾條）：精簡＝新提示詞＋雲端一律寬鬆把關；忠實＝原本做法。 */
class CleanupStyleTest {
    private fun accepted(text: String, reply: String, relaxed: Boolean): Boolean = try {
        SmartCleanup.finishCleaned(reply, text, relaxed); true
    } catch (_: SmartCleanup.Rejected) { false }

    @Test
    fun conciseUsesRelaxedGateForEveryCloudProviderFaithfulKeepsOldRule() {
        for (p in SmartCleanup.Provider.entries) {
            assertTrue(SmartCleanup.relaxedFor(SmartCleanup.Style.CONCISE, p))
            assertEquals(p == SmartCleanup.Provider.CLAUDE, SmartCleanup.relaxedFor(SmartCleanup.Style.FAITHFUL, p))
        }
    }

    @Test
    fun faithfulPromptIsUnchangedAndConcisePromptHasListAndNoAnswerRules() {
        assertEquals(SmartCleanup.instructions.replace(SmartCleanup.PARAGRAPH_KEEP_RULE, SmartCleanup.PARAGRAPH_LIST_RULE),
            SmartCleanup.baseInstructions(SmartCleanup.Style.FAITHFUL, autoList = true))
        val concise = SmartCleanup.baseInstructions(SmartCleanup.Style.CONCISE, autoList = true)
        assertTrue(concise.contains(SmartCleanup.CONCISE_LIST_RULE))
        assertTrue(concise.contains("絕對不要回答"))
        assertFalse(SmartCleanup.baseInstructions(SmartCleanup.Style.CONCISE, autoList = false).contains(SmartCleanup.CONCISE_LIST_RULE))
        assertTrue(SmartCleanup.system(emptyList(), style = SmartCleanup.Style.CONCISE).startsWith(concise))
    }

    /** 真人錄音 lp01：清單＋「人生→人聲」「付→附」。寬鬆放行、嚴格（OpenAI 等在忠實模式）照擋。 */
    @Test
    fun relaxedAcceptsListAndHomophoneFixes() {
        val raw = "這次案子分成三個部分,第一個部分是前期的素材整理,主要把客戶給的Multi-Track收進來,然後檢查每一軌的完整性。另外第二個部分是實際的混音,這部分大概會花三天,重點在於人生的空間感。總之交付的時候記得付一份Mixing Note"
        val reply = "這次案子分成三個部分：\n1. 前期素材整理，主要把客戶給的 Multi-Track 收進來，並檢查每一軌的完整性\n2. 實際混音，大概會花三天，重點在於人聲的空間感\n交付時記得附一份 Mixing Note。"
        assertTrue(accepted(raw, reply, relaxed = true))
        assertFalse(accepted(raw, reply, relaxed = false))
    }

    @Test
    fun relaxedStillBlocksAnswersNumbersAndPerson() {
        assertFalse(accepted("你能不能幫我確認一下檔案是不是最新版?", "我沒辦法確認你的檔案是不是最新版，我看不到你的電腦。", relaxed = true))
        assertFalse(accepted("總共是1250塊先付三成當定金", "總共是1,520塊，先付三成當定金。", relaxed = true))
        assertFalse(accepted("我這邊沒有收到你的檔案", "你那邊沒有收到我的檔案。", relaxed = true))
        assertTrue(accepted("預算是30萬,第二期先付10萬5", "預算是30萬，第二期先付10萬5。", relaxed = true))
    }

    /**
     * 真 API 對打（沒有 key 就跳過）：`LIVE_CLAUDE_KEY`、`LIVE_BENCH_IN`（{id: 逐字稿} JSON）、`LIVE_BENCH_OUT`。
     * 走跟 App 同一份提示詞、請求內容與把關（finishCleaned）；不含需要 Context 的繁體修正與個人字典。
     */
    @Test
    fun liveConciseVersusFaithfulWithClaude() {
        val key = System.getenv("LIVE_CLAUDE_KEY").orEmpty()
        val input = System.getenv("LIVE_BENCH_IN").orEmpty()
        val output = System.getenv("LIVE_BENCH_OUT").orEmpty()
        assumeTrue(key.isNotEmpty() && input.isNotEmpty() && output.isNotEmpty())
        val cases = JSONObject(File(input).readText())
        val provider = SmartCleanup.Provider.CLAUDE
        val rows = org.json.JSONArray()
        for (style in SmartCleanup.Style.entries) {
            var ok = 0
            val ids = cases.keys().asSequence().sorted().toList()
            val results = java.util.concurrent.Executors.newFixedThreadPool(4).let { pool ->
                val futures = ids.map { id ->
                    pool.submit<JSONObject> {
                        val text = cases.getString(id)
                        val start = System.nanoTime()
                        val system = SmartCleanup.system(emptyList(), autoList = true, style = style)
                        val content = try {
                            CloudLlm.post(provider.endpoint, key, SmartCleanup.body(provider.model, system, text, provider.extra()),
                                connectMs = 5000, readMs = 20000, log = {})
                        } catch (e: Exception) { "" }
                        var out = ""; var accepted = false
                        try { out = SmartCleanup.finishCleaned(content.trim(), text, SmartCleanup.relaxedFor(style, provider)); accepted = true }
                        catch (_: SmartCleanup.Rejected) {}
                        JSONObject().put("id", id).put("style", style.id).put("accepted", accepted).put("out", out)
                            .put("raw", if (accepted) "" else content).put("ms", (System.nanoTime() - start) / 1_000_000)
                    }
                }
                val r = futures.map { it.get() }; pool.shutdown(); r
            }
            results.forEach { if (it.getBoolean("accepted")) ok++; rows.put(it) }
            println("LIVEBENCH|android|${style.id}|accepted=$ok/${results.size}")
        }
        File(output).writeText(rows.toString(1))
        if (rows.length() == 0) fail("no rows")
    }
}
