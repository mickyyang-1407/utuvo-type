package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** 與 Swift LatinNameFixerTests 同一批語料（Micky 手機實機錯字）；行為以 Swift 為準。 */
class LatinNameFixerTest {
    private val terms = listOf(
        "Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Claude Code", "Anthropic", "Perplexity", "Copilot",
        "GitHub", "Cursor", "Codex", "Midjourney", "DeepSeek", "Qwen", "Llama", "Grok", "Kimi", "MiniMax", "GLM",
        "Typeless", "Chatterfly", "Notion", "Figma", "Slack", "Telegram", "LINE", "Threads", "Instagram",
        "NVIDIA", "TSMC", "Apple", "Tesla", "Android", "Pixel", "prompt", "session", "Tonmeister", "Dolby Atmos",
        "Dominik", "Tsubasa", "Schmalfuss",
    )

    private fun fix(s: String) = LatinNameFixer.fix(s, terms)

    @Test fun realMisrecognitions() {
        assertEquals("Apple NVIDIA", fix("AppleNVidia"))
        assertEquals("OpenAI ChatGPT", fix("OpenAIChatGPT"))
        assertEquals("Grok", fix("grook"))
        assertEquals("Claude Code", fix("clote coate"))
        assertEquals("MiniMax", fix("minimax"))
        assertEquals("Gemini", fix("Gimani"))
        assertEquals("Codex", fix("Coldex"))
        assertEquals("prompt", fix("promt"))
        assertEquals("session", fix("sesion"))
        assertEquals("Claude Code", fix("Cloud coat"))
        assertEquals("rprecity", fix("rprecity"))
    }

    @Test fun insideChineseSentence() {
        assertEquals("我在測試 Gemini 的智慧整理", fix("我在測試 Gimani 的智慧整理"))
        assertEquals("然後 chat 完以後打包成 prompt，在 coate 裡面開 session。",
            fix("然後 chat 完以後打包成 promt，在 coate 裡面開 sesion。"))
        assertEquals("這個 GLM Kimi 都要測", fix("這個 GLMKimi 都要測"))
    }

    @Test fun doesNotTouchOrdinaryEnglish() {
        for (s in listOf(
            "I put the apple pie on the bed",
            "open the file and check the code",
            "the line is too long, please fix it",
            "we need a new object for the stem",
            "Let's chat about the mixing session tomorrow",
            "他叫 Robert，不是 Roberta",
            "型號是 A13 Bionic",
            "https://github.com/mickyyang-1407/utuvo-type",
            "早上九點的 meeting 改到十點",
        )) assertEquals(s, fix(s), "不該動：$s")
    }

    @Test fun fullRealSentence() {
        val input = "一樣測試看看 AI的公司名稱。AppleNVidia，Tesla OpenAIChatGPT。，grook。clote coate，clotecoateGLMKimi。minimax"
        val expected = "一樣測試看看 AI的公司名稱。Apple NVIDIA，Tesla OpenAI ChatGPT。，Grok。Claude Code，Claude Code GLM Kimi。MiniMax"
        assertEquals(expected, LatinNameFixer.fix(input, terms + listOf("Google", "Microsoft", "Meta")))
    }

    @Test fun recasingOnly() {
        assertEquals("Claude Code 很好用", fix("Claude Code 很好用"))
        assertEquals("ChatGPT 跟 OpenAI", fix("chatgpt 跟 openai"))
        assertEquals("NVIDIA 的股價", fix("nvidia 的股價"))
        assertEquals("I ate an apple", fix("I ate an apple"))
        assertEquals("apple 的股價", fix("apple 的股價"))
        assertEquals("grook 跟 clote coate", LatinNameFixer.fix("grook 跟 clote coate", emptyList()))
    }

    @Test fun ambiguousIsLeftAlone() {
        assertEquals("kimee", LatinNameFixer.fix("kimee", listOf("Kimi", "Kimmy")))
    }

    @Test fun normalizerRunsTheStep() {
        val out = Normalizer(NormalizerOptions(latinTerms = terms)).normalize("我在測試 Gimani 的東西")
        assertEquals("我在測試 Gemini 的東西", out.cleaned)
        assertEquals(true, out.appliedSteps.contains("latin-names"), "步驟清單：${out.appliedSteps}")
    }

    /** TYPE-R03（2026-09-20）：超過 40 字元的拉丁 run 不再把後面的短 run 吃掉。
     *  長 run 本身保留原文不動，後續的獨立 run 仍各自進詞表比對。 */
    @Test fun longRunDoesNotEatFollowingShortRuns() {
        val onlyGemini = listOf("Gemini")
        val longSentence = "Please review the latest changes before tomorrow morning"
        assertEquals(true, longSentence.length > LatinNameFixer.MAX_RUN_LENGTH,
            "這個長句必須 > 40，否則這條測試沒在測超長路徑")

        // 1) 過長開頭 → 後面短名要照修（工單證據：中文逗號斷 run）。
        assertEquals("$longSentence，然後打開 Gemini",
            LatinNameFixer.fix("$longSentence，然後打開 jeman", onlyGemini))

        // 2) 中間過長 run（前後短名均可修；換行斷 run）。
        assertEquals("OpenAI\n$longSentence\nGemini",
            LatinNameFixer.fix("openai\n$longSentence\njeman", terms))

        // 3) 只有過長 run：完全不動。
        assertEquals(longSentence, LatinNameFixer.fix(longSentence, onlyGemini))

        // 4) 40/41 邊界：剛好 40 → 進詞表；剛好 41 → 超過上限原文保留。
        // 用「Ab」重複 20 次（40 字元）作 term，lowercased input 與 term 折完字面相同但大小寫不一樣——
        // 在 ≤40 路徑下會被 recase 回 term（驗證有走進詞表）；同樣 lowercased 但長度 +1（41）→
        // 跳過詞表、保留原文（驗證長度閘真的有擋）。
        val term40 = "Ab".repeat(20)   // 40 chars
        val term41 = term40 + "C"      // 41 chars
        assertEquals(term40, LatinNameFixer.fix(term40.lowercase(), listOf(term40)))
        assertEquals(term41.lowercase(), LatinNameFixer.fix(term41.lowercase(), listOf(term40)))

        // 5) 中文夾一長串英文＋短 jeman：中文不動、長串原文、短名照修。
        assertEquals("請看 $longSentence，然後 Gemini",
            LatinNameFixer.fix("請看 $longSentence，然後 jeman", onlyGemini))

        // 6) 工單舉例句逐字重現。
        assertEquals(
            "Please review the latest changes before tomorrow morning，然後打開 Gemini",
            LatinNameFixer.fix(
                "Please review the latest changes before tomorrow morning，然後打開 jeman",
                onlyGemini
            )
        )
    }
}
