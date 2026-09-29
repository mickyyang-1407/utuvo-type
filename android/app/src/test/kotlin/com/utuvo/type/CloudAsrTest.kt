package com.utuvo.type

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * 雲端語音辨識的純邏輯（WAV 編碼、請求建構、解析、退路）；逐條對應 `ios/iOSTests/CloudASRTests.swift`。
 * 全部用假 transport，不打真網路、不碰真 key。
 */
class CloudAsrTest {
    private val groq get() = SmartCleanup.Provider.GROQ
    private val gemini get() = SmartCleanup.Provider.GEMINI
    private val dashscope get() = SmartCleanup.Provider.DASHSCOPE

    // MARK: - WAV 編碼

    @Test
    fun wavHeaderAndPcm() {
        val data = CloudASR.wav(floatArrayOf(0f, 1.5f, -1f))
        assertEquals("44 bytes header + 3 samples × 2 bytes", 44 + 6, data.size)
        val ascii = { from: Int, until: Int -> String(data, from, until - from, Charsets.US_ASCII) }
        assertEquals("RIFF", ascii(0, 4))
        assertEquals(36 + 6, readUInt32(data, 4))
        assertEquals("WAVE", ascii(8, 12))
        assertEquals("fmt ", ascii(12, 16))
        assertEquals("fmt size = 16 (PCM)", 16, readUInt32(data, 16))
        assertEquals("PCM format", 1, readUInt16(data, 20))
        assertEquals("1 channel", 1, readUInt16(data, 22))
        assertEquals("sample rate", 16_000, readUInt32(data, 24))
        assertEquals("byte rate", 32_000, readUInt32(data, 28))
        assertEquals("block align", 2, readUInt16(data, 32))
        assertEquals("bits per sample", 16, readUInt16(data, 34))
        assertEquals("data", ascii(36, 40))
        assertEquals("data length = 2 × sample count", 6, readUInt32(data, 40))
        assertEquals(listOf(0, 32767, -32767), dataInt16(data.copyOfRange(44, data.size)))
    }

    @Test
    fun groqRealisesSmallFormPunctuation() {
        // Groq 實測輸出小寫全形逗號（U+FE50）：不轉成一般「，」，鍵盤的自我更正會把句子切壞。
        assertEquals("我們禮拜三，不對，禮拜四？", CloudASR.normalizePunctuation("我們禮拜三﹐不對﹐禮拜四﹖"))
        assertEquals("A、B。", CloudASR.normalizePunctuation("A﹑B﹒"))
    }

    // MARK: - Groq 請求

    @Test
    fun groqRequestShape() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(groq, "fake-groq-key", wav, "zh-TW", listOf("Atmos", "Pro Tools"))
        assertEquals("https://api.groq.com/openai/v1/audio/transcriptions", request.url)
        assertEquals("POST", request.method)
        assertEquals("Bearer fake-groq-key", request.headers["Authorization"])
        val contentType = request.headers["Content-Type"].orEmpty()
        assertTrue(contentType.startsWith("multipart/form-data; boundary="))
        val boundary = contentType.removePrefix("multipart/form-data; boundary=")
        assertTrue(boundary.isNotEmpty())

        val start = indexOf(request.body, wav)
        assertTrue("WAV bytes 應在 body 裡", start >= 0)
        val text = String(request.body, 0, start, Charsets.UTF_8)
        assertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        // R1-4：要比對完整值（值後面緊接 \r\n），送出 "zh-TW" 時必須紅。
        assertTrue(text.contains("name=\"language\"\r\n\r\nzh\r\n"))
        assertTrue(text.contains("name=\"response_format\"\r\n\r\njson"))
        assertTrue(text.contains("name=\"temperature\"\r\n\r\n0"))
        assertTrue(text.contains("name=\"prompt\"\r\n\r\n以下是繁體中文（台灣）的語音。常用詞：Atmos、Pro Tools"))
        assertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        assertTrue(text.contains("Content-Type: audio/wav"))
        val closing = String(request.body, start + wav.size, request.body.size - start - wav.size, Charsets.UTF_8)
        assertTrue(closing.contains("--$boundary--"))
    }

    // R1-4：100 個熱詞時 prompt 必須截到 ≤200 字元，且含第一個、不含最後一個。
    @Test
    fun groqPromptTruncatesAt200CharsWith100Hotwords() {
        val hotwords = (1..100).map { "Term$it" }
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(groq, "k", wav, "zh-TW", hotwords)
        val start = indexOf(request.body, wav)
        assertTrue("WAV bytes 應在 body 裡", start >= 0)
        val text = String(request.body, 0, start, Charsets.UTF_8)
        val marker = "name=\"prompt\"\r\n\r\n"
        val valueStart = text.indexOf(marker)
        if (valueStart < 0) { fail("找不到 prompt 欄位"); return }
        val tail = text.substring(valueStart + marker.length)
        val lineEnd = tail.indexOf("\r\n")
        if (lineEnd < 0) { fail("prompt 值沒結束"); return }
        val value = tail.substring(0, lineEnd)
        assertTrue("prompt 必須 ≤ 200 字元（實際 ${value.length}）", value.length <= 200)
        assertTrue("含第一個詞", value.contains("Term1"))
        assertFalse("不含最後一個詞（已被截掉）", value.contains("Term100"))
    }

    // R1-2：簡中（zh-CN）Groq prompt 是簡體、不含「繁體」。
    @Test
    fun groqPromptSimplifiedForZhCN() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(groq, "k", wav, "zh-CN", listOf("Atmos"))
        val start = indexOf(request.body, wav)
        val text = String(request.body, 0, start, Charsets.UTF_8)
        assertTrue("含簡體指示", text.contains("简体"))
        assertFalse("不應含繁體", text.contains("繁體"))
    }

    // R1-2／R1-3：簡中 Gemini 指示是簡體；英文指示不含任何中文字。
    @Test
    fun geminiInstructionSimplifiedForZhCN() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(gemini, "k", wav, "zh-CN", listOf("Atmos"))
        val instruction = firstPartText(request.body)
        assertTrue("含簡體指示", instruction.contains("简体"))
        assertFalse("不應含繁體", instruction.contains("繁體"))
    }

    @Test
    fun geminiInstructionEnglishHasNoChineseChars() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(gemini, "k", wav, "en-US", listOf("Atmos", "Pro Tools"))
        val instruction = firstPartText(request.body)
        assertFalse("英文指示不應含中文字：$instruction", instruction.any { it.code in 0x3400..0x9FFF || it.code in 0xF900..0xFAFF })
    }

    // MARK: - Gemini 請求

    @Test
    fun geminiRequestShape() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(gemini, "fake-gemini-key", wav, "zh-TW", listOf("Atmos"))
        assertTrue(request.url.startsWith("https://generativelanguage.googleapis.com/v1beta/models/"))
        assertTrue(request.url.endsWith(":generateContent"))
        assertTrue(request.url.contains("models/${SmartCleanup.Provider.GEMINI.model}:generateContent"))
        assertEquals("POST", request.method)
        assertEquals("fake-gemini-key", request.headers["x-goog-api-key"])
        assertNull("Gemini 不用 Authorization", request.headers["Authorization"])
        assertEquals("application/json", request.headers["Content-Type"])

        val obj = JSONObject(String(request.body, Charsets.UTF_8))
        val parts = obj.getJSONArray("contents").getJSONObject(0).getJSONArray("parts")
        val inlineData = parts.getJSONObject(1).getJSONObject("inline_data")
        assertEquals("audio/wav", inlineData.getString("mime_type"))
        assertArrayEquals(wav, java.util.Base64.getDecoder().decode(inlineData.getString("data")))
        val instruction = parts.getJSONObject(0).getString("text")
        assertTrue(instruction.contains("繁體中文"))
        assertTrue(instruction.contains("Atmos"))
        val config = obj.getJSONObject("generationConfig")
        assertEquals(0, config.getInt("temperature"))
        assertNotNull(config.getJSONObject("thinkingConfig"))
    }

    // MARK: - 百鍊請求

    @Test
    fun dashscopeRequestShape() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(dashscope, "fake-dash-key", wav, "zh-TW", listOf("Atmos"))
        assertEquals(dashscope.endpoint, request.url)
        assertEquals("POST", request.method)
        assertEquals("Bearer fake-dash-key", request.headers["Authorization"])
        assertEquals("application/json", request.headers["Content-Type"])

        val obj = JSONObject(String(request.body, Charsets.UTF_8))
        assertEquals("qwen3-asr-flash", obj.getString("model"))
        assertFalse(obj.getBoolean("stream"))
        val messages = obj.getJSONArray("messages")
        assertEquals("system", messages.getJSONObject(0).getString("role"))
        assertEquals("Atmos", messages.getJSONObject(0).getString("content"))
        val audioPart = messages.getJSONObject(1).getJSONArray("content").getJSONObject(0)
        assertEquals("input_audio", audioPart.getString("type"))
        val dataURI = audioPart.getJSONObject("input_audio").getString("data")
        assertTrue(dataURI.startsWith("data:audio/wav;base64,"))
        assertArrayEquals(wav, java.util.Base64.getDecoder().decode(dataURI.removePrefix("data:audio/wav;base64,")))
        val asrOptions = obj.getJSONObject("asr_options")
        assertEquals("zh", asrOptions.getString("language"))
        assertFalse(asrOptions.getBoolean("enable_itn"))
    }

    @Test
    fun dashscopeOmitsSystemWhenNoHotwords() {
        val wav = CloudASR.wav(FloatArray(4_000))
        val request = CloudASR.makeRequest(dashscope, "k", wav, "en-US", emptyList())
        val obj = JSONObject(String(request.body, Charsets.UTF_8))
        val messages = obj.getJSONArray("messages")
        assertEquals("沒有 hotwords 就沒有 system message", 1, messages.length())
        assertEquals("user", messages.getJSONObject(0).getString("role"))
    }

    // MARK: - parse

    @Test
    fun parseGroqSuccess() {
        assertEquals("明天見", CloudASR.parse("""{"text":"明天見"}""".toByteArray(), groq))
    }

    @Test
    fun parseGeminiSuccess() {
        val json = """{"candidates":[{"content":{"parts":[{"text":"明天"},{"text":"見"}]}}]}"""
        assertEquals("明天見", CloudASR.parse(json.toByteArray(), gemini))
    }

    @Test
    fun parseDashscopeSuccessString() {
        val json = """{"choices":[{"message":{"content":"明天下午三點"}}]}"""
        assertEquals("明天下午三點", CloudASR.parse(json.toByteArray(), dashscope))
    }

    @Test
    fun parseDashscopeSuccessArray() {
        val json = """{"choices":[{"message":{"content":[{"text":"明天下午"},{"text":"三點"}]}}]}"""
        assertEquals("明天下午三點", CloudASR.parse(json.toByteArray(), dashscope))
    }

    @Test
    fun parseMalformedThrows() {
        assertThrowsMalformed("not json".toByteArray(), groq)
        assertThrowsMalformed("""{"choices":[]}""".toByteArray(), dashscope)
    }

    // MARK: - 失敗退路

    @Test
    fun transcribeReturnsNullOnHttp401_429_500() {
        for (status in listOf(401, 429, 500)) {
            val transport = CloudASR.Transport { _, _ -> CloudASR.Response(status, "{}".toByteArray()) }
            val result = CloudASR.transcribe(FloatArray(4_000), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG)
            assertNull("HTTP $status 應走系統結果", result)
        }
    }

    @Test
    fun transcribeReturnsNullOnTransportTimeout() {
        val transport = CloudASR.Transport { _, _ -> throw java.net.SocketTimeoutException("timed out") }
        assertNull(CloudASR.transcribe(FloatArray(4_000), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG))
    }

    @Test
    fun transcribeReturnsNullWhenTransportExceedsBudget() {
        // 30 秒錄音 → timeLimit(30) = min(6, 2.5 + 6) = 6 秒
        val transport = CloudASR.Transport { _, _ ->
            Thread.sleep(7_000)
            CloudASR.Response(200, """{"text":"晚了"}""".toByteArray())
        }
        val start = System.currentTimeMillis()
        val result = CloudASR.transcribe(FloatArray(16_000 * 30), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG)
        val elapsed = (System.currentTimeMillis() - start) / 1000.0
        assertNull(result)
        assertTrue("預算 6 秒，逾時回 null 應在 6.5 秒內（實際 $elapsed）", elapsed < 6.5)
    }

    @Test
    fun transcribeRejectsLoopingOutput() {
        val looping = "有 T O V O " + "T O ".repeat(40)
        val json = """{"text":"$looping"}"""
        val transport = CloudASR.Transport { _, _ -> CloudASR.Response(200, json.toByteArray()) }
        assertNull("迴圈文字應回 null", CloudASR.transcribe(FloatArray(4_000), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG))
    }

    @Test
    fun transcribeRejectsEmptyOutput() {
        val transport = CloudASR.Transport { _, _ -> CloudASR.Response(200, """{"text":"   "}""".toByteArray()) }
        assertNull(CloudASR.transcribe(FloatArray(4_000), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG))
    }

    @Test
    fun transcribeAcceptsGoodOutput() {
        val transport = CloudASR.Transport { _, _ -> CloudASR.Response(200, """{"text":"明天見"}""".toByteArray()) }
        assertEquals("明天見", CloudASR.transcribe(FloatArray(4_000), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG))
    }

    // MARK: - Gemini 400 retry

    @Test
    fun geminiRetriesWithoutThinkingConfigOn400() {
        val counter = AtomicInteger(0)
        val captured = mutableListOf<CloudASR.Request>()
        val transport = CloudASR.Transport { request, _ ->
            synchronized(captured) { captured.add(request) }
            if (counter.getAndIncrement() == 0) return@Transport CloudASR.Response(400, ByteArray(0))
            CloudASR.Response(200, """{"candidates":[{"content":{"parts":[{"text":"辨識結果"}]}}]}""".toByteArray())
        }
        val result = CloudASR.transcribe(FloatArray(4_000), "zh-TW", emptyList(), gemini, "k", transport, CloudASR.NO_LOG)
        assertEquals("辨識結果", result)
        assertEquals(2, captured.size)
        val config = JSONObject(String(captured[1].body, Charsets.UTF_8)).getJSONObject("generationConfig")
        assertFalse("第二次重送不應帶 thinkingConfig", config.has("thinkingConfig"))
        assertEquals(0, config.getInt("temperature"))
    }

    // MARK: - 長度門檻

    @Test
    fun transcribeSkipsTransportWhenTooShort() {
        val called = AtomicBoolean(false)
        val transport = CloudASR.Transport { _, _ -> called.set(true); CloudASR.Response(200, ByteArray(0)) }
        // 0.2 秒 < 0.25 秒
        assertNull(CloudASR.transcribe(FloatArray((0.2 * 16_000).toInt()), "zh-TW", emptyList(), groq, "k", transport, CloudASR.NO_LOG))
        assertFalse(called.get())
    }

    @Test
    fun transcribeSkipsTransportWhenDashscopeTooLong() {
        val called = AtomicBoolean(false)
        val transport = CloudASR.Transport { _, _ -> called.set(true); CloudASR.Response(200, ByteArray(0)) }
        // 211 秒 > 百鍊 210 秒上限
        assertNull(CloudASR.transcribe(FloatArray(16_000 * 211), "zh-TW", emptyList(), dashscope, "k", transport, CloudASR.NO_LOG))
        assertFalse(called.get())
    }

    // MARK: - 純函式與選擇器

    @Test
    fun supports() {
        assertTrue(CloudASR.supports(gemini))
        assertTrue(CloudASR.supports(groq))
        assertTrue(CloudASR.supports(dashscope))
        assertFalse(CloudASR.supports(SmartCleanup.Provider.CUSTOM))
    }

    @Test
    fun languageCode() {
        assertEquals("zh", CloudASR.languageCode("zh-TW"))
        assertEquals("zh", CloudASR.languageCode("zh-Hans"))
        assertEquals("en", CloudASR.languageCode("en-US"))
        assertNull(CloudASR.languageCode("ja-JP"))
        assertNull(CloudASR.languageCode(""))
    }

    @Test
    fun timeLimit() {
        assertEquals(2.5, CloudASR.timeLimit(0.0), 0.0001)
        assertEquals(4.5, CloudASR.timeLimit(10.0), 0.0001)
        assertEquals(6.0, CloudASR.timeLimit(60.0), 0.0001)
        assertEquals("上限 6 秒", 6.0, CloudASR.timeLimit(1_000.0), 0.0001)
    }

    @Test
    fun customProviderIsRefused() {
        try {
            CloudASR.makeRequest(SmartCleanup.Provider.CUSTOM, "k", CloudASR.wav(FloatArray(4_000)), "zh-TW", emptyList())
            fail("自訂服務不支援雲端辨識")
        } catch (e: CloudASR.Unsupported) {
            // 這就是預期
        }
    }

    @Test
    fun stripCodeFence() {
        assertEquals("辨識結果", CloudASR.stripCodeFence("```\n辨識結果\n```"))
        assertEquals("辨識結果", CloudASR.stripCodeFence("辨識結果"))
    }

    // MARK: - helpers

    private fun firstPartText(body: ByteArray): String {
        val parts = JSONObject(String(body, Charsets.UTF_8)).getJSONArray("contents").getJSONObject(0).getJSONArray("parts")
        return parts.getJSONObject(0).getString("text")
    }

    private fun assertThrowsMalformed(body: ByteArray, provider: SmartCleanup.Provider) {
        try {
            CloudASR.parse(body, provider)
            fail("malformed 應該丟出")
        } catch (e: CloudASR.Malformed) {
            // 這就是預期
        }
    }

    private fun assertArrayEquals(expected: ByteArray, actual: ByteArray) =
        assertTrue("base64 內容不一致", expected.contentEquals(actual))

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    private fun readUInt16(bytes: ByteArray, at: Int) =
        (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8)

    private fun readUInt32(bytes: ByteArray, at: Int) =
        (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8) or
            ((bytes[at + 2].toInt() and 0xFF) shl 16) or ((bytes[at + 3].toInt() and 0xFF) shl 24)

    private fun dataInt16(bytes: ByteArray): List<Int> = (0 until bytes.size / 2).map {
        ((bytes[it * 2].toInt() and 0xFF) or ((bytes[it * 2 + 1].toInt() and 0xFF) shl 8)).toShort().toInt()
    }
}
