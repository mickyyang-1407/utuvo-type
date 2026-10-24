package com.utuvo.type

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * 雲端語音辨識（選配，使用者自備 key；對應 iOS `ios/App/CloudASR.swift`，2026-09-29 移植）。
 *
 * 鍵盤錄完音後，如果使用者自己開了「雲端辨識」而且在「智慧整理」頁存了 key，
 * 就把整段錄音（16 kHz 單聲道）用同一把 key 送到那家服務重新辨識，拿回來的文字取代系統的結果；
 * 任何失敗、逾時、太長、太短都用原本系統 SpeechRecognizer 的結果。
 *
 * 設計重點跟 iOS 一樣：所有請求建構集中在 `makeRequest`／`parse`，純函式、不打真網路，方便 JVM 測試。
 * 整段（含 Gemini 400 重送）共用同一個單調預算，逾時不等輸入完成。
 * 注意：Android 這裡的 Provider 是 `SmartCleanup.Provider`；`custom` 端點各家請求／解析不同，不強行套。
 */
object CloudASR {
    /** SharedPreferences 開關的 key；沒設過＝關（預設 off，跟智慧整理預設關相同）。 */
    const val ENABLED_KEY = "cloudAsrEnabled"
    /** 最近 20 筆紀錄（不含逐字稿；格式比照 SmartLog）。 */
    const val LOG_KEY = "cloudAsrLog"

    private const val PREF = "smart"
    private const val SAMPLE_RATE = 16_000

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    // MARK: - 設定／可用性

    /** 使用者的開關。沒設過＝false（雲端辨識不預設開）。 */
    fun enabled(c: Context) = prefs(c).getBoolean(ENABLED_KEY, false)
    fun setEnabled(c: Context, on: Boolean) = prefs(c).edit().putBoolean(ENABLED_KEY, on).apply()

    /** 自訂 OpenAI 相容端點暫不支援雲端辨識。 */
    fun supports(p: SmartCleanup.Provider) = p != SmartCleanup.Provider.CUSTOM && p != SmartCleanup.Provider.CLAUDE

    /** 雲端辨識用哪一家：整理選的能辨識就用它；不能（Claude、自訂）就找任何一把已存、能辨識的 key（同 iOS CloudASR.route）。 */
    fun route(c: Context): Pair<SmartCleanup.Provider, String>? {
        val selected = SmartCleanup.provider(c)
        val order = listOf(selected) + listOf(SmartCleanup.Provider.GROQ, SmartCleanup.Provider.GEMINI,
            SmartCleanup.Provider.DASHSCOPE).filter { it != selected }
        for (p in order) {
            if (!supports(p)) continue
            val key = SmartCleanup.key(c, p)
            if (!key.isNullOrEmpty()) return p to key
        }
        return null
    }

    /** 兩段語音指示（zh 與 en）共用這個語言代碼；其他語言回 null＝不用雲端。 */
    fun languageCode(language: String): String? {
        if (language.startsWith("zh", true)) return "zh"
        if (language.startsWith("en", true)) return "en"
        return null
    }

    /** 開了、服務支援、語言支援、有 key。key 用 SmartCleanup.key（百鍊共用同一把）。 */
    fun isReady(c: Context, language: String): Boolean {
        if (!enabled(c)) return false
        if (languageCode(language) == null) return false
        return route(c) != null
    }

    /** 整段（含 Gemini 400 重送）的單調預算：2.5 秒起，每秒錄音加 0.2 秒，上限 6 秒。 */
    fun timeLimit(seconds: Double) = minOf(6.0, 2.5 + 0.2 * seconds)

    // MARK: - WAV（44 bytes 標頭＋16-bit PCM LE 單聲道）

    /** Float 樣本（[-1, 1]）→ 16 kHz 單聲道 WAV。標頭欄位與 iOS `CloudASR.wav` 逐位元組相同。 */
    fun wav(samples: FloatArray, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val dataSize = samples.size * 2
        val out = ByteArrayOutputStream(44 + dataSize)
        fun le32(value: Int) {
            out.write(value and 0xFF); out.write(value shr 8 and 0xFF)
            out.write(value shr 16 and 0xFF); out.write(value shr 24 and 0xFF)
        }
        fun le16(value: Int) { out.write(value and 0xFF); out.write(value shr 8 and 0xFF) }
        fun ascii(tag: String) = out.write(tag.toByteArray(Charsets.US_ASCII))
        ascii("RIFF")
        le32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        le32(16)                      // fmt sub-chunk size = 16 (PCM)
        le16(1)                       // PCM
        le16(1)                       // mono
        le32(sampleRate)
        le32(sampleRate * 2)          // byte rate
        le16(2)                       // block align
        le16(16)                      // bits per sample
        ascii("data")
        le32(dataSize)
        // PCM：先夾到 [-1, 1]，再 ×32767 取整數。
        val pcm = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) {
            val clamped = maxOf(-1f, minOf(1f, sample))
            pcm.putShort((clamped * 32767f).toInt().toShort())
        }
        out.write(pcm.array())
        return out.toByteArray()
    }

    // MARK: - 請求建構（純函式，沒有副作用）

    class Unsupported : Exception("custom provider does not support cloud ASR")
    class Malformed : Exception("malformed response")

    /**
     * `context`＝前一段的辨識結果（Q3 邊錄邊傳）。Whisper 的 prompt／Gemini 的指示都會帶它，
     * 避免斷句處用字不一致；null＝整段一次送（舊行為）。
     */
    @JvmOverloads
    fun makeRequest(provider: SmartCleanup.Provider, key: String, wav: ByteArray,
                    language: String, hotwords: List<String>, boundary: String = defaultBoundary(),
                    context: String? = null): Request {
        return when (provider) {
            SmartCleanup.Provider.GROQ -> groqRequest(key, wav, language, hotwords, boundary, context)
            SmartCleanup.Provider.GEMINI -> geminiRequest(key, wav, language, hotwords, true, provider, context)
            SmartCleanup.Provider.DASHSCOPE -> dashscopeRequest(key, wav, language, hotwords, provider, context)
            SmartCleanup.Provider.CLAUDE, SmartCleanup.Provider.CUSTOM -> throw Unsupported()
        }
    }

    private fun defaultBoundary() = "----UTUVOCloudASR${UUID.randomUUID()}"

    private fun groqRequest(key: String, wav: ByteArray, language: String, hotwords: List<String>,
                            boundary: String, context: String? = null): Request {
        val body = ByteArrayOutputStream()
        fun field(name: String, value: String) {
            body.write("--$boundary\r\n".toByteArray(Charsets.UTF_8))
            body.write("Content-Disposition: form-data; name=\"$name\"\r\n\r\n".toByteArray(Charsets.UTF_8))
            body.write("$value\r\n".toByteArray(Charsets.UTF_8))
        }
        val langCode = languageCode(language) ?: "zh"
        val prompt = groqPrompt(language, hotwords, context)
        field("model", "whisper-large-v3")
        field("language", langCode)
        field("response_format", "json")
        field("temperature", "0")
        field("prompt", prompt)
        // file part（filename 固定 audio.wav，Content-Type audio/wav）
        body.write("--$boundary\r\n".toByteArray(Charsets.UTF_8))
        body.write("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".toByteArray(Charsets.UTF_8))
        body.write("Content-Type: audio/wav\r\n\r\n".toByteArray(Charsets.UTF_8))
        body.write(wav)
        body.write("\r\n".toByteArray(Charsets.UTF_8))
        body.write("--$boundary--\r\n".toByteArray(Charsets.UTF_8))
        return Request("https://api.groq.com/openai/v1/audio/transcriptions", "POST", mapOf(
            "Authorization" to "Bearer $key",
            "Content-Type" to "multipart/form-data; boundary=$boundary"
        ), body.toByteArray())
    }

    /** R1-2：簡中使用者要簡體版的指示。zh-TW／zh-Hant／zh-HK＝繁體；其他 zh（zh-CN、zh-Hans）＝簡體。 */
    internal fun groqPrompt(originalLanguage: String, hotwords: List<String>, context: String? = null): String {
        val prefix: String
        val separator: String
        if (isSimplifiedChinese(originalLanguage)) {
            prefix = "以下是简体中文的语音。常用词："
            separator = "、"
        } else if (originalLanguage.startsWith("zh", true)) {
            prefix = "以下是繁體中文（台灣）的語音。常用詞："
            separator = "、"
        } else {
            prefix = "Vocabulary: "
            separator = ", "
        }
        val maxTotal = 200
        val words = ArrayList<String>()
        var current = prefix.length
        for (word in hotwords) {
            val add = (if (words.isEmpty()) 0 else separator.length) + word.length
            if (current + add > maxTotal) break
            words.add(word)
            current += add
        }
        var prompt = prefix + words.joinToString(separator)
        // Q3 邊錄邊傳：前一段的辨識結果當上下文（Whisper prompt），避免斷句處用字不一致。
        if (!context.isNullOrEmpty()) prompt += "\n" + context
        return prompt
    }

    /** zh-Hant／zh-HK／zh-TW 是繁體；其餘 zh（zh-Hans／zh-CN 等）走簡體。 */
    internal fun isSimplifiedChinese(language: String): Boolean {
        val lower = language.lowercase()
        if (!lower.startsWith("zh")) return false
        if (lower.contains("hant") || lower.contains("tw") || lower.contains("hk")) return false
        return true
    }

    private fun geminiRequest(key: String, wav: ByteArray, language: String, hotwords: List<String>,
                               includeThinkingConfig: Boolean, provider: SmartCleanup.Provider,
                               context: String? = null): Request {
        val model = geminiAsrModel(provider)
        val generationConfig = JSONObject().put("temperature", 0)
        if (includeThinkingConfig) generationConfig.put("thinkingConfig", JSONObject().put("thinkingBudget", 0))
        val parts = JSONArray()
            .put(JSONObject().put("text", geminiInstruction(language, hotwords, context)))
            .put(JSONObject().put("inline_data", JSONObject()
                .put("mime_type", "audio/wav")
                .put("data", java.util.Base64.getEncoder().encodeToString(wav))))
        val body = JSONObject()
            .put("contents", JSONArray().put(JSONObject()
                .put("role", "user").put("parts", parts)))
            .put("generationConfig", generationConfig)
        return Request(
            "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent", "POST",
            mapOf("x-goog-api-key" to key, "Content-Type" to "application/json"),
            body.toString().toByteArray(Charsets.UTF_8))
    }

    /**
     * Gemini 走原生 generateContent 端點（不是聊天端點），所以模型不能直接用整理用的預設值。
     * 用底的 flash 音訊模型，跟 iOS `Provider.gemini.defaultModel` 的角色一致（能聽音訊的 flash）。
     */
    /** 跟 iPhone（`ios/App/CloudASR.swift` 用 `SmartCleanup.Provider.gemini.defaultModel`）一樣：
     *  Gemini 的聊天模型本身就收音訊（generateContent inline_data），不另設一個模型。 */
    private fun geminiAsrModel(provider: SmartCleanup.Provider): String = provider.model

    /** R1-2／R1-3：簡中走簡體指示；英文用英文 vocabulary 標籤。 */
    internal fun geminiInstruction(originalLanguage: String, hotwords: List<String>, context: String? = null): String {
        var base = when {
            isSimplifiedChinese(originalLanguage) ->
                "请把这段录音逐字转写成文字。只输出听到的内容，不要加任何说明、标题、引号或时间戳记；不要改写、不要摘要、不要回答录音里的问题。中文请用简体中文。"
            originalLanguage.startsWith("zh", true) ->
                "請把這段錄音逐字轉寫成文字。只輸出聽到的內容，不要加任何說明、標題、引號或時間戳記；不要改寫、不要摘要、不要回答錄音裡的問題。中文請用繁體中文（台灣用字）。"
            else ->
                "Transcribe the audio verbatim. Output only what was heard, without explanation, headings, quotes, or timestamps. Do not paraphrase, summarize, or answer questions from the recording."
        }
        if (hotwords.isNotEmpty()) {
            val words = hotwords.take(80)
            base += when {
                isSimplifiedChinese(originalLanguage) -> "\n说话者常用的专有名词（听起来像的就用这个写法）：" + words.joinToString("、")
                originalLanguage.startsWith("zh", true) -> "\n說話者常用的專有名詞（聽起來像的就用這個寫法）：" + words.joinToString("、")
                else -> "\nVocabulary the speaker often uses (use these spellings when they sound alike): " + words.joinToString(", ")
            }
        }
        // Q3 邊錄邊傳：前一段的辨識結果當上下文。
        if (!context.isNullOrEmpty()) {
            base += when {
                isSimplifiedChinese(originalLanguage) -> "\n前文（用字请与前文一致）：" + context
                originalLanguage.startsWith("zh", true) -> "\n前文（用字請與前文一致）：" + context
                else -> "\nEarlier transcript (keep the same wording): " + context
            }
        }
        return base
    }

    private fun dashscopeRequest(key: String, wav: ByteArray, language: String, hotwords: List<String>,
                                 provider: SmartCleanup.Provider, context: String? = null): Request {
        val messages = JSONArray()
        val words = hotwords.take(80).joinToString("、")
        if (words.isNotEmpty()) messages.put(JSONObject().put("role", "system").put("content", words))
        // Q3 邊錄邊傳：前一段的辨識結果當上下文。
        if (!context.isNullOrEmpty()) messages.put(JSONObject().put("role", "user").put("content", context))
        messages.put(JSONObject().put("role", "user").put("content", JSONArray().put(JSONObject()
            .put("type", "input_audio")
            .put("input_audio", JSONObject().put("data", "data:audio/wav;base64," + java.util.Base64.getEncoder().encodeToString(wav))))))
        val body = JSONObject()
            .put("model", DASHSCOPE_ASR_MODEL)
            .put("stream", false)
            .put("messages", messages)
            .put("asr_options", JSONObject()
                .put("language", languageCode(language) ?: "zh")
                .put("enable_itn", false))
        return Request(provider.endpoint, "POST", mapOf(
            "Authorization" to "Bearer $key", "Content-Type" to "application/json"),
            body.toString().toByteArray(Charsets.UTF_8))
    }

    /** 百鍊的語音辨識模型（跟整理用的 qwen3.7-flash 不同）。 */
    const val DASHSCOPE_ASR_MODEL = "qwen3-asr-flash"

    // MARK: - 解析（純函式）

    fun parse(body: ByteArray, provider: SmartCleanup.Provider): String {
        val obj = try { JSONObject(String(body, Charsets.UTF_8)) } catch (e: Exception) { throw Malformed() }
        return when (provider) {
            SmartCleanup.Provider.GROQ -> if (obj.has("text")) obj.optString("text") else throw Malformed()
            SmartCleanup.Provider.GEMINI -> {
                val parts = obj.optJSONArray("candidates")?.optJSONObject(0)
                    ?.optJSONObject("content")?.optJSONArray("parts")
                    ?: throw Malformed()
                joinText(parts)
            }
            SmartCleanup.Provider.DASHSCOPE -> {
                val message = obj.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")
                    ?: throw Malformed()
                when (val content = message.opt("content")) {
                    is String -> content
                    is JSONArray -> joinText(content)
                    else -> throw Malformed()
                }
            }
            SmartCleanup.Provider.CLAUDE, SmartCleanup.Provider.CUSTOM -> throw Unsupported()
        }
    }

    private fun joinText(parts: JSONArray): String {
        val sb = StringBuilder()
        for (i in 0 until parts.length()) sb.append(parts.optJSONObject(i)?.optString("text").orEmpty())
        val text = sb.toString()
        if (text.isEmpty()) throw Malformed()
        return text
    }

    /** Gemini 偶爾會用 ``` 圍起回應；逐字稿就不該帶這個。 */
    fun stripCodeFence(text: String): String {
        var t = text.trim()
        if (!t.startsWith("```")) return t
        val nl = t.indexOf('\n')
        t = if (nl >= 0) t.substring(nl + 1) else ""
        t = t.trim()
        return if (t.endsWith("```")) t.dropLast(3).trim() else t
    }

    // MARK: - 傳輸（可注入；正式環境走 HttpURLConnection，測試用假網路）

    data class Request(val url: String, val method: String, val headers: Map<String, String>, val body: ByteArray)
    data class Response(val code: Int, val body: ByteArray)

    fun interface Transport {
        /** 逾時請丟 SocketTimeoutException；其他連線問題丟 IOException。 */
        @Throws(Exception::class)
        fun send(request: Request, remainingMs: Long): Response
    }

    /** 正式傳輸：HttpURLConnection，connect/read timeout 都被整段預算綁住。 */
    object HttpTransport : Transport {
        override fun send(request: Request, remainingMs: Long): Response {
            val connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
                requestMethod = request.method
                connectTimeout = minOf(3000L, remainingMs).toInt().coerceAtLeast(1)
                readTimeout = remainingMs.toInt().coerceAtLeast(1)
                doOutput = true
                useCaches = false
                setRequestProperty("Accept", "application/json")
                request.headers.forEach { (k, v) -> setRequestProperty(k, v) }
            }
            return try {
                connection.outputStream.use { it.write(request.body) }
                val code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                val body = stream?.use { input -> input.readBytes() } ?: ByteArray(0)
                Response(code, body)
            } finally {
                connection.disconnect()
            }
        }
    }

    // MARK: - 整段錄音 → 文字

    /** 預算內每次嘗試的結果分類（給 log 與測試用）。 */
    sealed class Outcome {
        object Transport : Outcome()
        data class Http(val code: Int) : Outcome()
        object Malformed : Outcome()
        object Error : Outcome()
    }

    /** log：(開始時間、經過毫秒、服務、結果、錄音秒數、輸出字數)。 */
    fun interface Log {
        fun record(start: Long, elapsedMs: Long, provider: String, outcome: String, audioSeconds: Double, outputChars: Int)
    }

    /** 守護：把服務回來的文字整理成可以直接貼的逐字稿；空字串或迴圈文字回 null。 */
    fun interface Guard {
        /** 回 null＝拒絕（空或迴圈）。 */
        fun accept(text: String, language: String, seconds: Double): String?
    }

    private val budgetExecutor = Executors.newCachedThreadPool { r ->
        Thread(r, "cloud-asr").apply { isDaemon = true }
    }

    /**
     * 錄音 → 文字。任何失敗都回 null，呼叫端退回系統 SpeechRecognizer 的結果。
     * 整段（含 Gemini 400 重送）共用同一個預算：逾時不等輸入完成。
     * [maxBudgetMs]＝最多能用多久（從按停起算的總時限剩下的時間，capture-latency-v1）；
     * null＝只受 [timeLimit] 限制（舊行為）；≤ 0＝時間已經用完，不打網路、記一筆 timeout。
     */
    @JvmOverloads
    fun transcribe(samples: FloatArray, language: String, hotwords: List<String>,
                   provider: SmartCleanup.Provider, key: String,
                   transport: Transport = HttpTransport,
                   log: Log = NO_LOG,
                   guard: Guard = Guard(::trimGuard),
                   maxBudgetMs: Long? = null): String? {
        val seconds = samples.size / 16_000.0
        // 太短（< 0.25 秒）不打網路。
        if (seconds < 0.25) return null
        // 百鍊 base64 後上限 10 MB，其他家 5 分鐘；逾時一律不打。
        val maxSeconds = if (provider == SmartCleanup.Provider.DASHSCOPE) 210.0 else 300.0
        if (seconds > maxSeconds) return null
        if (key.isEmpty()) return null

        val start = System.currentTimeMillis()
        if (maxBudgetMs != null && maxBudgetMs <= 0) {
            log.record(start, 0, provider.id, "timeout", seconds, 0)
            return null
        }
        val budgetMs = minOf((timeLimit(seconds) * 1000).toLong(), maxBudgetMs ?: Long.MAX_VALUE).coerceAtLeast(1)
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(budgetMs)
        val audio = wav(trimSilence(samples))
        val providerId = provider.id

        // 回傳型別：String＝成功文字；Outcome＝失敗分類；null＝被取消（預算用完）。
        val future = budgetExecutor.submit<Any?> {
            var response: Response
            try {
                response = transport.send(makeRequest(provider, key, audio, language, hotwords), remainingMs(deadlineNanos))
            } catch (e: Exception) {
                return@submit if (e is InterruptedException) null else Outcome.Transport
            }
            // Gemini 思考預算不被接受時拿掉重送一次（同一預算）。
            if (response.code == 400 && provider == SmartCleanup.Provider.GEMINI) {
                val retry = runCatching { geminiRequest(key, audio, language, hotwords, false, provider) }
                    .getOrNull() ?: return@submit Outcome.Http(400)
                try {
                    response = transport.send(retry, remainingMs(deadlineNanos))
                } catch (e: Exception) {
                    return@submit if (e is InterruptedException) null else Outcome.Transport
                }
                if (response.code != 200) return@submit Outcome.Http(response.code)
            } else if (response.code != 200) {
                return@submit Outcome.Http(response.code)
            }
            return@submit try { parse(response.body, provider) } catch (e: Exception) {
                if (e is Unsupported) Outcome.Error else Outcome.Malformed
            }
        }

        val outcome = try {
            future.get(budgetMs, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            future.cancel(true)
            log.record(start, System.currentTimeMillis() - start, providerId, "timeout", seconds, 0)
            return null
        } catch (e: Exception) {
            log.record(start, System.currentTimeMillis() - start, providerId, "error", seconds, 0)
            return null
        }
        val elapsedMs = System.currentTimeMillis() - start

        if (outcome == null) {           // 被取消 → budget 用完
            log.record(start, elapsedMs, providerId, "timeout", seconds, 0)
            return null
        }
        if (outcome !is String) {
            val label = when (outcome) {
                is Outcome.Http -> "http:${outcome.code}"
                Outcome.Transport -> "transport"
                Outcome.Malformed -> "malformed"
                else -> "error"
            }
            log.record(start, elapsedMs, providerId, label, seconds, 0)
            return null
        }
        val cleaned = if (provider == SmartCleanup.Provider.GEMINI) stripCodeFence(outcome) else outcome
        val accepted = runCatching { guard.accept(cleaned, language, seconds) }.getOrNull()
        if (accepted.isNullOrEmpty()) {
            log.record(start, elapsedMs, providerId, "empty", seconds, 0)
            return null
        }
        if (looksLooping(accepted, seconds)) {
            log.record(start, elapsedMs, providerId, "loop", seconds, accepted.length)
            return null
        }
        log.record(start, elapsedMs, providerId, "ok", seconds, accepted.length)
        return accepted
    }


    private fun remainingMs(deadlineNanos: Long) =
        TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime()).coerceAtLeast(1)

    /**
     * 解碼迴圈（熱詞偶爾讓模型卡在「T O T O …」）：同一個 1–8 字單位連續 8 次以上，
     * 或字數遠超過人能講的量（每秒 12 字）。規則與 iOS `TranscriptGuard.looksLooping` 相同。
     */
    private val loopingPattern = Regex("(.{1,8}?)(?:\\s*\\1){7,}")

    fun looksLooping(text: String, seconds: Double): Boolean {
        if (text.length > maxOf(80, (seconds * 12).toInt())) return true
        return loopingPattern.containsMatchIn(text)
    }

    /**
     * Unicode Small Form Variants（U+FE50–FE57）→ 一般全形標點。
     * Groq Whisper 的中文常輸出「小寫」標點（2026-09-25 實測 128 段裡 13 段有）；
     * 後面的自我更正（「不對」）與贅字規則只認一般全形標點，不轉會把句子切壞。
     */
    private val smallFormPunctuation = mapOf(
        '﹐' to '，', '﹑' to '、', '﹒' to '。', '﹔' to '；',
        '﹕' to '：', '﹖' to '？', '﹗' to '！'
    )

    fun normalizePunctuation(text: String) = text.map { smallFormPunctuation[it] ?: it }.joinToString("")

    /**
     * 頭尾安靜段剪掉、各留 0.3 秒：講完到按停止之間的底噪，是 Whisper 補「謝謝大家收看」的主要來源（同 iOS trimSilence）。
     * 20 ms 一格、峰值 < [ChunkedASR.SILENCE_THRESHOLD]；整段都沒聲音就原樣回傳。
     */
    fun trimSilence(samples: FloatArray, sampleRate: Int = SAMPLE_RATE, keepSeconds: Double = 0.3): FloatArray {
        val frame = sampleRate / 50
        if (samples.size <= frame * 2) return samples
        fun loud(i: Int): Boolean {
            var peak = 0f
            for (j in i until minOf(samples.size, i + frame)) peak = maxOf(peak, kotlin.math.abs(samples[j]))
            return peak >= ChunkedASR.SILENCE_THRESHOLD
        }
        var first = 0
        while (first < samples.size && !loud(first)) first += frame
        if (first >= samples.size) return samples
        var last = ((samples.size - 1) / frame) * frame
        while (last > first && !loud(last)) last -= frame
        val keep = (keepSeconds * sampleRate).toInt()
        val lo = maxOf(0, first - keep); val hi = minOf(samples.size, last + frame + keep)
        return if (lo == 0 && hi == samples.size) samples else samples.copyOfRange(lo, hi)
    }

    /** Whisper 在安靜的尾巴補的字幕結尾句（同 iOS TranscriptGuard.outroPhrases；比對前去掉空白標點、英文小寫）。 */
    val outroPhrases = listOf(
        "謝謝大家收看", "谢谢大家收看", "謝謝收看", "谢谢收看", "感謝收看", "感谢收看", "感謝您的收看", "感谢您的收看",
        "謝謝觀看", "谢谢观看", "謝謝大家觀看", "谢谢大家观看", "感謝觀看", "感谢观看", "感謝您的觀看", "感谢您的观看",
        "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目", "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "字幕由amaraorg社群提供", "字幕由amaraorg社区提供", "字幕by索兰娅", "字幕by索蘭婭",
        "優優獨播劇場yoyotelevisionseriesexclusive", "优优独播剧场yoyotelevisionseriesexclusive",
        "請訂閱我的頻道", "请订阅我的频道", "歡迎訂閱我的頻道", "欢迎订阅我的频道", "記得訂閱", "记得订阅",
        "thanksforwatching", "thankyouforwatching", "thankyouverymuchforwatching", "pleasesubscribe",
        "subtitlesbytheamaraorgcommunity",
    )

    private fun isFiller(c: Char) = c.isWhitespace() || !c.isLetterOrDigit()

    /** 去掉尾端（可連續好幾句）的字幕結尾句幻覺；`reference`（裝置端逐字稿）也有這句＝使用者真的講了，不動。同 iOS。 */
    fun dropOutroHallucination(text: String, reference: String? = null): String {
        fun key(s: String) = s.filter { !isFiller(it) }.lowercase()
        val heard = reference?.let(::key).orEmpty()
        var out = text
        while (true) {
            val tail = key(out)
            val phrase = outroPhrases.firstOrNull { tail.endsWith(it) && !heard.contains(it) } ?: break
            var need = phrase.length
            var cut = out.length
            while (need > 0 && cut > 0) { cut--; if (!isFiller(out[cut])) need-- }
            out = out.substring(0, cut)
        }
        return if (out == text) text else out.trim()
    }

    /** 純文字守護（不碰 Android API，所以 JVM 測試也能跑）：去頭尾空白、轉小形標點、擋空字串。 */
    fun trimGuard(text: String, language: String, seconds: Double): String? {
        val cleaned = normalizePunctuation(text.trim())
        return if (cleaned.isBlank()) null else cleaned
    }

    // MARK: - log

    /** 測試用的無聲 log（不寫本機 pref）。 */
    val NO_LOG = Log { _, _, _, _, _, _ -> }

    /**
     * 記下這一次雲端重辨識最後一筆結果（"ok"／"timeout"／"transport"／"http:500"…），其餘照原本的 log 寫。
     * 鍵盤用它決定退回裝置端文字時要提示哪一種原因（[CloudFallback]）。
     */
    class OutcomeTap(private val inner: Log = NO_LOG) : Log {
        @Volatile var last: String? = null
            private set

        override fun record(start: Long, elapsedMs: Long, provider: String, outcome: String,
                            audioSeconds: Double, outputChars: Int) {
            last = outcome
            inner.record(start, elapsedMs, provider, outcome, audioSeconds, outputChars)
        }
    }

    /** 從按停起算的總時限還剩多少毫秒（可能 ≤ 0）。總時限＝[timeLimit]（整段秒數，最多 6 秒）。 */
    fun remainingBudgetMs(stoppedAtNanos: Long, seconds: Double, now: Long = System.nanoTime()): Long =
        (timeLimit(seconds) * 1000).toLong() - TimeUnit.NANOSECONDS.toMillis(now - stoppedAtNanos)

    /** 預設 log：寫進本機 pref，最近 20 筆。 */
    fun defaultLog(c: Context) = Log { start, elapsedMs, provider, outcome, audioSeconds, outputChars ->
        CloudAsrLog.record(c, start, elapsedMs, provider, outcome, audioSeconds, outputChars)
    }
}

/**
 * 雲端重辨識沒成功、改貼裝置端（系統辨識器）文字時，要不要提示使用者、提示哪一種（delivery-learning-v3、capture-latency-v1）。
 * 以前完全靜默：使用者不知道這次是比較弱的那一份結果。純函式，JVM 測得到。
 */
object CloudFallback {
    enum class Notice {
        /** 不用提示：雲端成功、沒有裝置端文字可貼、或根本沒送出請求（太短、沒有 key）。 */
        NONE,
        /** 網路慢或連不上（逾時、傳輸錯誤）。 */
        SLOW_NETWORK,
        /** 服務回錯誤、被限流、或回來的文字不能用。 */
        FAILED,
    }

    /**
     * @param outcome 這次最後一筆雲端結果（[CloudASR.OutcomeTap.last]）；null＝沒有送出任何請求。
     * @param cloudText 雲端回來的文字；非 null＝雲端成功（就算整段只是被濾掉的結尾句，也不是失敗）。
     * @param deviceText 系統辨識器的文字（就是要改貼的那一份）。
     */
    @JvmStatic
    fun notice(outcome: String?, cloudText: String?, deviceText: String): Notice = when {
        cloudText != null -> Notice.NONE
        deviceText.isEmpty() -> Notice.NONE
        outcome == null || outcome == "ok" -> Notice.NONE
        outcome == "timeout" || outcome == "transport" -> Notice.SLOW_NETWORK
        else -> Notice.FAILED
    }
}

/** 雲端辨識的最近 20 筆紀錄（只存在這支手機；查問題用：花多久、有沒有換、為什麼沒換）。 */
object CloudAsrLog {
    private const val PREF = "smart"
    private const val FIELD = "logCloudAsr"

    data class Entry(val at: String, val ms: Long, val provider: String, val outcome: String,
                     val audioSeconds: Double, val outputChars: Int)

    private fun store(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    fun load(c: Context): List<Entry> = runCatching {
        val a = JSONArray(store(c).getString(FIELD, "[]"))
        (0 until a.length()).map { a.getJSONObject(it).let { o ->
            Entry(o.getString("at"), o.getLong("ms"), o.getString("provider"), o.getString("outcome"),
                o.optDouble("audioSeconds", 0.0), o.optInt("outputChars", 0))
        } }
    }.getOrDefault(emptyList())

    /** 追加一筆紀錄；只在這支手機上（跟 SmartLog 一樣）。 */
    fun record(context: Context, start: Long, elapsedMs: Long, provider: String,
               outcome: String, audioSeconds: Double, outputChars: Int) {
        synchronized(this) {
            val all = load(context) + Entry(Instant.ofEpochMilli(start).toString(), elapsedMs, provider,
                outcome, audioSeconds, outputChars)
            val a = JSONArray()
            all.takeLast(20).forEach {
                a.put(JSONObject().put("at", it.at).put("ms", it.ms).put("provider", it.provider)
                    .put("outcome", it.outcome).put("audioSeconds", it.audioSeconds)
                    .put("outputChars", it.outputChars))
            }
            store(context).edit().putString(FIELD, a.toString()).apply()
        }
    }
}

