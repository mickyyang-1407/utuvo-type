package com.utuvo.type.core

import java.io.File
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 讀音網格上的 K-best（0c 重排的候選來源）。標準答案＝`core/src/test/resources/zc/kbest.jsonl`，
 * 由 Python 參考實作 `zy.py` 的 `kbest()` / `_top()` 產生。第 1 名必須與 `conversion`（Viterbi）相同。
 */
class ZcKBestTest {
    private lateinit var lexicon: ZhuyinLexicon

    @BeforeTest
    fun setUp() {
        val resources = File(System.getProperty("utuvo.resources") ?: error("缺 utuvo.resources"))
        lexicon = ZhuyinLexicon.open(File(resources, "zhuyin.dat")) ?: error("zhuyin.dat 開不起來")
    }

    /** 把整句讀音逐鍵打進引擎（空白當一聲）。 */
    private fun engineWith(readings: List<String>): ZhuyinEngine {
        val e = ZhuyinEngine(lexicon)
        for (r in readings) {
            val tone = r.lastOrNull()?.takeIf { it in ZhuyinComposer.TONE_MARKS || it == ZhuyinComposer.FIRST_TONE_MARK }
            val body = if (tone != null) r.dropLast(1) else r
            for (ch in body) e.type(ch)
            if (tone != null && tone != ZhuyinComposer.FIRST_TONE_MARK) e.type(tone) else e.space()
        }
        return e
    }

    private fun fixtures(): List<Pair<List<String>, List<Pair<String, Double>>>> {
        val file = File(fixtureDir(), "kbest.jsonl")
        assertTrue(file.isFile, "標準答案不在 ${file.path}")
        return file.readLines().filter { it.isNotBlank() }.map { line ->
            val o = org.json.JSONObject(line)
            val reading = o.getJSONArray("reading").let { a -> List(a.length()) { a.getString(it) } }
            val arr = o.getJSONArray("kbest")
            val kbest = List(arr.length()) { i ->
                val pair = arr.getJSONArray(i)
                pair.getString(0) to pair.getDouble(1)
            }
            reading to kbest
        }
    }

    private fun fixtureDir(): File =
        File(System.getProperty("zc.fixtures") ?: error("缺 zc.fixtures（core/build.gradle.kts 應該有設）"))

    @Test
    fun matchesOracleKBest() {
        val cases = fixtures()
        assertEquals(120, cases.size, "標準答案應該有 120 例")
        var index = 0
        for ((reading, expected) in cases) {
            index++
            val e = engineWith(reading)
            assertEquals(reading, e.completeReadings(), "第 $index 例：引擎的讀音要跟標準答案一樣")
            val got = e.kBest(16)
            assertEquals(expected.size, got.size, "第 $index 例：候選數")
            for ((i, pair) in expected.withIndex()) {
                assertEquals(pair.first, got[i].first, "第 $index 例第 ${i + 1} 名的文字")
                assertTrue(
                    kotlin.math.abs(pair.second - got[i].second) < 1e-6,
                    "第 $index 例第 ${i + 1} 名的分數：期望 ${pair.second}，得到 ${got[i].second}",
                )
            }
        }
    }

    @Test
    fun firstCandidateEqualsViterbiConversion() {
        for ((index, pair) in fixtures().withIndex()) {
            val e = engineWith(pair.first)
            val top = e.kBest(16).firstOrNull()?.first
            assertNotNull(top, "第 ${index + 1} 例沒有候選")
            assertEquals(e.conversion, top, "第 ${index + 1} 例：K-best 第 1 名要等於 Viterbi 的 conversion")
        }
    }
}
