package com.utuvo.type

import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * 雲端 chat completion（對應 iOS TranslationService.complete）：DashScope 相容模式、qwen3.7-flash。
 * 只有使用者在主 app 自己填了 key 才會走到這裡；沒 key＝完全不連雲端。
 */
object CloudLlm {
    const val ENDPOINT = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    const val MODEL = "qwen3.7-flash"

    class HttpError(val code: Int) : Exception("HTTP $code")

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val deadlineTimer = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "utuvo-cloud-deadline").apply { isDaemon = true }
    }

    fun body(system: String, user: String): String = JSONObject()
        .put("model", MODEL).put("temperature", 0).put("stream", false).put("enable_thinking", false)
        .put("messages", JSONArray()
            .put(JSONObject().put("role", "system").put("content", system))
            .put(JSONObject().put("role", "user").put("content", user)))
        .toString()

    fun parse(json: String): String =
        JSONObject(json).getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content").trim()

    fun complete(apiKey: String, system: String, user: String, done: (Result<String>) -> Unit) {
        io.execute {
            val r = runCatching { post(ENDPOINT, apiKey, body(system, user), connectMs = 8000, readMs = 20000) }
            main.post { done(r) }
        }
    }

    /** 同步送出（呼叫端自己放背景執行緒）；智慧整理也走這裡（不同端點、模型、逾時）。 */
    fun post(endpoint: String, apiKey: String, body: String, connectMs: Int, readMs: Int,
             deadlineNanos: Long? = null): String {
        val conn = URL(endpoint).openConnection() as HttpURLConnection
        var abort: ScheduledFuture<*>? = null
        try {
            val initialRemaining = deadlineNanos?.let(::remainingMillis)
            conn.connectTimeout = initialRemaining?.let { minOf(connectMs, it) } ?: connectMs
            conn.readTimeout = initialRemaining?.let { minOf(readMs, it) } ?: readMs
            if (deadlineNanos != null) {
                val remainingNanos = deadlineNanos - System.nanoTime()
                if (remainingNanos <= 0) throw SocketTimeoutException("cleanup deadline exceeded")
                abort = deadlineTimer.schedule({ conn.disconnect() }, remainingNanos, TimeUnit.NANOSECONDS)
            }
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Authorization", "Bearer $apiKey")
            conn.outputStream.use { it.write(body.toByteArray()) }
            deadlineNanos?.let { conn.readTimeout = minOf(readMs, remainingMillis(it)) }
            if (conn.responseCode != 200) {
                runCatching { conn.errorStream?.use { it.readBytes() } }   // 讀完才能放回連線池
                throw HttpError(conn.responseCode)
            }
            return parse(conn.inputStream.use { it.bufferedReader().readText() })
        } catch (e: java.io.IOException) {
            conn.disconnect()   // 連線壞了才丟掉；正常結束不 disconnect，連線留在池裡給下一次（省 TLS 握手）
            throw e
        } finally {
            abort?.cancel(false)
        }
    }

    private fun remainingMillis(deadlineNanos: Long): Int {
        val nanos = deadlineNanos - System.nanoTime()
        if (nanos <= 0) throw SocketTimeoutException("cleanup deadline exceeded")
        return TimeUnit.NANOSECONDS.toMillis(nanos).coerceAtLeast(1).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    /** 先連上（HEAD，回什麼都無所謂），讓之後的 post 直接重用這條連線。 */
    fun warm(endpoint: String) {
        val conn = URL(endpoint).openConnection() as HttpURLConnection
        conn.requestMethod = "HEAD"
        conn.connectTimeout = 5000; conn.readTimeout = 5000
        conn.responseCode
        runCatching { (conn.errorStream ?: conn.inputStream)?.use { it.readBytes() } }
    }
}
