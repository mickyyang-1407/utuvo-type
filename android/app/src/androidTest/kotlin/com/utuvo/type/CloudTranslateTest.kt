package com.utuvo.type

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 雲端翻譯路徑（選配 key）。沒有真 key 可用，所以驗三件事：
 * key 加密存取來回一致；用假 key 打 DashScope 真的拿到 401（證明端點、驗證標頭都走到了）；
 * 雲端失敗時長按翻譯會退回手機上翻，使用者還是拿得到翻譯。
 */
@RunWith(AndroidJUnit4::class)
class CloudTranslateTest {
    private val app = InstrumentationRegistry.getInstrumentation().targetContext
    private val fakeKey = "sk-utuvo-test-not-a-real-key"

    @After fun cleanup() = SecretStore.delete(app)

    private fun <T> await(block: ((Result<T>) -> Unit) -> Unit): Result<T> {
        val done = CountDownLatch(1)
        var out: Result<T>? = null
        block { out = it; done.countDown() }
        assertTrue("3 分鐘沒回來", done.await(180, TimeUnit.SECONDS))
        return out!!
    }

    @Test
    fun secretRoundTrip() {
        SecretStore.delete(app)
        assertFalse(SecretStore.hasKey(app))
        SecretStore.save(app, "  $fakeKey  ")
        assertTrue(SecretStore.hasKey(app))
        assertEquals(fakeKey, SecretStore.apiKey(app))
        val raw = app.getSharedPreferences("secret", 0).all.values.joinToString()
        assertFalse("存的是密文，不能看得到 key：$raw", raw.contains(fakeKey))
        SecretStore.delete(app)
        assertEquals(null, SecretStore.apiKey(app))
    }

    @Test
    fun requestShapeAndParse() {
        val body = org.json.JSONObject(CloudLlm.body("SYS", "今天天氣很好"))
        assertEquals("qwen3.7-flash", body.getString("model"))
        assertEquals("SYS", body.getJSONArray("messages").getJSONObject(0).getString("content"))
        assertEquals("今天天氣很好", body.getJSONArray("messages").getJSONObject(1).getString("content"))
        assertEquals("Hello", CloudLlm.parse("""{"choices":[{"message":{"role":"assistant","content":" Hello\n"}}]}"""))
    }

    @Test
    fun fakeKeyReachesDashScopeAndIsRejected() {
        val r = await<String> { CloudLlm.complete(fakeKey, "x", "y", it) }
        val e = r.exceptionOrNull()
        assertTrue("假 key 應該被 DashScope 拒絕（401），實際：$r", e is CloudLlm.HttpError && e.code == 401)
    }

    @Test
    fun cloudFailureFallsBackToOnDevice() {
        SecretStore.save(app, fakeKey)
        val en = Translation.quickPick(app).first { it.code == "en" }
        val r = await<String> { Translation.translate(app, "今天天氣很好，我們去公園散步吧。", en, it) }
        val text = r.getOrThrow().lowercase()
        assertTrue("退回手機上翻應該還是英文：$text", text.contains("weather"))
    }
}
