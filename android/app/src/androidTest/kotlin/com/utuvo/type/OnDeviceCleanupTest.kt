package com.utuvo.type

import android.os.Debug
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 手機上的智慧整理（Gemma 4 E2B）實機量測。
 *
 * 需要模型檔已在 App 的外部儲存（設定頁下載過，或開發時 `adb push` 到
 * `/sdcard/Android/data/com.utuvo.type/files/models/`）；沒有就跳過——公開 repo 與 CI 不帶 2.5 GB 的檔。
 * 結果寫到 `files/bench/ondevice-bench.json`（每句耗時、引擎載入時間、GPU／CPU、記憶體、整理前後）。
 */
@RunWith(AndroidJUnit4::class)
class OnDeviceCleanupTest {
    private val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

    private val samples = listOf(
        "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。",
        "那個就是說我覺得這個這個混音的低頻有點太多，然後人聲可以再往前一點，嗯，大概這樣。",
        "明天要做三件事，第一個是寄母帶給客戶，第二個是確認 Atmos 的交付規格，第三個是跟 Pro Tools 的 session 備份",
        "你可以幫我查一下明天台北的天氣嗎",
        "我、我想明天，不對，後天寄，然後記得帶硬碟跟耳機"
    )

    private fun requireModel() {
        val f = OnDeviceModel.file(app)
        assumeTrue("模型檔不在 ${f.absolutePath}", f.length() == OnDeviceModel.BYTES)
        if (!OnDeviceModel.isReady(app)) assertTrue("SHA-256 對不上", OnDeviceModel.adoptExistingFile(app))
    }

    @Test
    fun cleansSamplesOnDevice() {
        requireModel()
        val results = JSONArray()
        val warmStart = System.nanoTime()
        // 第一次：載入引擎（量載入時間）；給很長的上限，量的是實際耗時。
        val first = runCatching { SmartCleanup.runOnDevice(app, samples[0], 120_000L) }
        val firstMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - warmStart)
        val pssAfterLoad = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss
        results.put(entry(samples[0], first, firstMs, cold = true))
        for (text in samples) {
            val start = System.nanoTime()
            val r = runCatching { SmartCleanup.runOnDevice(app, text, 60_000L) }
            results.put(entry(text, r, TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start), cold = false))
        }
        val report = JSONObject()
            .put("device", android.os.Build.MODEL)
            .put("backend", OnDeviceLlm.backend)
            .put("engineLoadMs", OnDeviceLlm.lastLoadMs)
            .put("processPssKb", pssAfterLoad)
            .put("results", results)
        val out = File(app.filesDir, "bench/ondevice-bench.json").apply { parentFile?.mkdirs() }
        out.writeText(report.toString(2))
        Log.i("OnDeviceBench", report.toString())
        // 量測本身：五句都要有回應（通過把關與否另看報告；不代答那句應該原樣）。
        for (i in 1 until results.length()) {
            val o = results.getJSONObject(i)
            assertTrue("第 $i 句沒有回應：${o.optString("error")}", o.optString("error").isEmpty() || o.optString("error") == "Rejected")
        }
    }

    /** 逾時要真的中止：給 1 毫秒，必須丟 SocketTimeoutException，而且下一句不會卡在上一句後面。 */
    @Test
    fun deadlineAbortsAndNextRequestStillWorks() {
        requireModel()
        val r = runCatching { SmartCleanup.runOnDevice(app, samples[1], 1L) }
        assertTrue("應該逾時：$r", r.exceptionOrNull() is java.net.SocketTimeoutException)
        val start = System.nanoTime()
        val ok = runCatching { SmartCleanup.runOnDevice(app, samples[4], 120_000L) }
        assertTrue("逾時之後下一句失敗：${ok.exceptionOrNull()}", ok.isSuccess || ok.exceptionOrNull() is SmartCleanup.Rejected)
        Log.i("OnDeviceBench", "after-timeout ms=${TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)} out=${ok.getOrNull()}")
    }

    /**
     * 鍵盤用的同一個入口（UTUVOImeService.refine → SmartCleanup.clean）：沒 key＋模型在＝走手機上整理，
     * 結果從 done 回主執行緒，紀錄記成 ondevice。手機上若已存雲端 key（會走雲端），跳過不動它。
     */
    @Test
    fun keyboardEntryRoutesToOnDeviceWithoutKey() {
        requireModel()
        val snap = PrefsSnapshot(app, "smart")
        try {
            SmartCleanup.setEnabled(app, true)
            assumeTrue("這支手機有雲端 key，整理會走雲端", SmartCleanup.usesOnDevice(app))
            assertTrue(SmartCleanup.isEnabled(app))
            // 鍵盤開始聽寫時 warmUp；講話的那幾秒讓引擎載好。
            SmartCleanup.warmUp(app)
            runCatching { SmartCleanup.runOnDevice(app, "好", 300_000L) }
            val latch = java.util.concurrent.CountDownLatch(1)
            var out: String? = "unset"
            var onMain = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                SmartCleanup.clean(app, samples[4], { r ->
                    out = r; onMain = android.os.Looper.myLooper() == android.os.Looper.getMainLooper(); latch.countDown()
                })
            }
            assertTrue("clean 沒回來", latch.await(60, TimeUnit.SECONDS))
            assertTrue("done 要在主執行緒", onMain)
            // 紀錄在 done 之後才寫（不讓診斷擋住替換），等它一下。
            val before = System.nanoTime()
            while (SmartLog.load(app).isEmpty() && System.nanoTime() - before < TimeUnit.SECONDS.toNanos(5)) Thread.sleep(50)
            val last = SmartLog.load(app).last()
            Log.i("OnDeviceBench", "keyboard-entry out=$out log=$last")
            assertEquals(SmartCleanup.ON_DEVICE_ID, last.provider)
            assertEquals("ok", last.outcome)
            assertEquals("我想後天寄，然後記得帶硬碟跟耳機", out?.trimEnd('。'))
        } finally {
            snap.restore()
        }
    }

    /** luna-review r1：冷載入時逾時，載入完不能再跑那句；下一句不必排在一個沒人要的推論後面。 */
    @Test
    fun coldLoadTimeoutDoesNotRunAbandonedInference() {
        requireModel()
        OnDeviceLlm.release()
        val before = OnDeviceLlm.inferences.get()
        val r = runCatching { SmartCleanup.runOnDevice(app, samples[2], 200L) }   // 載入一定超過 200 ms
        assertTrue("應該逾時：$r", r.exceptionOrNull() is java.net.SocketTimeoutException)
        // 載入完、被放棄的那句不跑：下一句的耗時≈剩下的載入＋一句，不會再多一整句。
        val start = System.nanoTime()
        val ok = runCatching { SmartCleanup.runOnDevice(app, samples[4], 300_000L) }
        val ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
        Log.i("OnDeviceBench", "cold-timeout next ms=$ms loadMs=${OnDeviceLlm.lastLoadMs} out=${ok.getOrNull()}")
        assertTrue(ok.isSuccess || ok.exceptionOrNull() is SmartCleanup.Rejected)
        assertEquals("被放棄的那句不應該送進模型", 1, OnDeviceLlm.inferences.get() - before)
    }

    /**
     * luna-review r2：推論做到一半逾時 → cancelProcess → conversation.close()。上游有「取消後 session 卡住」的回報；
     * 這裡確認取消之後下一句照常完成（worker 沒被卡死），而且之後還能連續用。
     */
    @Test
    fun cancelMidGenerationThenNextWorks() {
        requireModel()
        runCatching { SmartCleanup.runOnDevice(app, samples[4], 300_000L) }   // 先載好、暖機
        val long = samples.joinToString("，")                                  // 長逐字稿：生成一定超過 1.5 秒
        repeat(3) { round ->
            val r = runCatching { SmartCleanup.runOnDevice(app, long, 1500L) }
            assertTrue("第 $round 輪應該逾時：$r", r.exceptionOrNull() is java.net.SocketTimeoutException)
            val start = System.nanoTime()
            val ok = runCatching { SmartCleanup.runOnDevice(app, samples[4], 60_000L) }
            val ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
            Log.i("OnDeviceBench", "cancel-mid round=$round next ms=$ms out=${ok.getOrNull()} err=${ok.exceptionOrNull()}")
            assertTrue("取消後下一句失敗：${ok.exceptionOrNull()}", ok.isSuccess || ok.exceptionOrNull() is SmartCleanup.Rejected)
        }
    }

    /** luna-review r2：剛下載完、第一次準備（GPU 編譯 1–2 分鐘）還沒好時，鍵盤不走手機上整理；開始聽寫的 warmUp 會把它準備好。 */
    @Test
    fun keyboardWaitsUntilFirstPreparationDone() {
        requireModel()
        val snap = PrefsSnapshot(app, "smart")
        try {
            SmartCleanup.setEnabled(app, true)
            // 先判斷要不要跳過，再動快取記號：有 key 的手機（Micky 的 Pixel）不能白白重編 GPU 快取。
            assumeTrue("這支手機有雲端 key，整理會走雲端", !SecretStore.hasKey(app, SmartCleanup.provider(app).secretField))
            OnDeviceLlm.release()
            runCatching { SmartCleanup.runOnDevice(app, "好", 1L) }   // 等 release 在 worker 上做完
            File(app.noBackupFilesDir, "litertlm-cache").listFiles()?.filter { it.name.endsWith(".ok") }?.forEach { it.delete() }
            assertTrue(!OnDeviceLlm.prepared(app))
            assertTrue("還沒準備好就不該開手機上整理", !SmartCleanup.isEnabled(app))
            SmartCleanup.warmUp(app)
            val start = System.nanoTime()
            while (!OnDeviceLlm.prepared(app) && System.nanoTime() - start < TimeUnit.MINUTES.toNanos(4)) Thread.sleep(500)
            assertTrue("warmUp 沒把模型準備好", OnDeviceLlm.prepared(app))
            assertTrue(SmartCleanup.isEnabled(app) && SmartCleanup.usesOnDevice(app))
        } finally {
            snap.restore()
        }
    }

    @Test
    fun checksumRejectsWrongFile() {
        val f = File(app.cacheDir, "not-a-model.bin").apply { writeText("x") }
        assertEquals("2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881", OnDeviceModel.sha256(f))
        f.delete()
    }

    private fun entry(text: String, r: Result<String>, ms: Long, cold: Boolean) = JSONObject()
        .put("input", text).put("ms", ms).put("cold", cold)
        .put("output", r.getOrNull() ?: JSONObject.NULL)
        .put("rejectedOutput", (r.exceptionOrNull() as? SmartCleanup.Rejected)?.output ?: JSONObject.NULL)
        .put("error", r.exceptionOrNull()?.javaClass?.simpleName ?: "")
}
