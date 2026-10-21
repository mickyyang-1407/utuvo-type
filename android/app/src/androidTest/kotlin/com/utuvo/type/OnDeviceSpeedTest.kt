package com.utuvo.type

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.benchmark
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 手機上整理的速度矩陣（GPU／CPU × speculative decoding），只在手動帶
 * `-Pandroid.testInstrumentationRunnerArguments.ondeviceBench=1` 時跑（一輪好幾分鐘，不進一般測試）。
 * 結果寫到 `files/bench/ondevice-speed.json`。
 */
@RunWith(AndroidJUnit4::class)
class OnDeviceSpeedTest {
    private val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    private val samples = listOf(
        "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。",
        "那個就是說我覺得這個這個混音的低頻有點太多，然後人聲可以再往前一點，嗯，大概這樣。",
        "明天要做三件事，第一個是寄母帶給客戶，第二個是確認 Atmos 的交付規格，第三個是跟 Pro Tools 的 session 備份",
        "你可以幫我查一下明天台北的天氣嗎",
        "我、我想明天，不對，後天寄，然後記得帶硬碟跟耳機"
    )

    @OptIn(com.google.ai.edge.litertlm.ExperimentalApi::class)
    @Test
    fun speedMatrix() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("ondeviceBench") == "1")
        assumeTrue(OnDeviceModel.isReady(app) || OnDeviceModel.adoptExistingFile(app))
        val report = JSONObject().put("device", android.os.Build.MODEL)
        val raw = JSONObject()
        for ((name, backend) in if (InstrumentationRegistry.getArguments().getString("ondeviceRaw") == "1") listOf("gpu" to Backend.GPU(), "cpu" to Backend.CPU()) else emptyList()) {
            val b = runCatching { benchmark(OnDeviceModel.file(app).absolutePath, backend, 700, 64, app.cacheDir.absolutePath) }
            raw.put(name, b.getOrNull()?.toString() ?: ("error: " + b.exceptionOrNull()))
            Log.i("OnDeviceBench", "raw $name ${raw.get(name)}")
        }
        report.put("raw", raw)
        val runs = JSONArray()
        for ((backend, spec) in listOf("gpu" to null)) {
            OnDeviceLlm.release()
            OnDeviceLlm.backendOverride = backend
            OnDeviceLlm.speculativeDecoding = spec
            val ms = JSONArray()
            val outs = JSONArray()
            // 跟鍵盤一樣：開始聽寫時 warm（載入＋暖機），講完才送第一句。
            OnDeviceLlm.warm(app)
            val loadStart = System.nanoTime()
            runCatching { SmartCleanup.runOnDevice(app, samples[4], 300_000L) }
            val firstMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - loadStart)
            // 暖機做完之後的第一句（引擎與 GPU 都熱了）：量的是使用者講完後實際等多久。
            val afterWarm = System.nanoTime()
            runCatching { SmartCleanup.runOnDevice(app, samples[1], 120_000L) }
            val afterWarmMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - afterWarm)
            for (t in samples) {
                val s = System.nanoTime()
                val r = runCatching { SmartCleanup.runOnDevice(app, t, 120_000L) }
                ms.put(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - s))
                outs.put(r.getOrNull() ?: (r.exceptionOrNull() as? SmartCleanup.Rejected)?.output?.let { "✗ $it" } ?: r.exceptionOrNull().toString())
            }
            val run = JSONObject().put("backend", OnDeviceLlm.backend).put("speculative", spec ?: JSONObject.NULL)
                .put("loadMs", OnDeviceLlm.lastLoadMs).put("firstMs", firstMs).put("afterWarmMs", afterWarmMs).put("ms", ms).put("outputs", outs)
            Log.i("OnDeviceBench", run.toString())
            runs.put(run)
        }
        OnDeviceLlm.backendOverride = null
        OnDeviceLlm.speculativeDecoding = null
        OnDeviceLlm.release()
        report.put("runs", runs)
        File(app.filesDir, "bench/ondevice-speed.json").apply { parentFile?.mkdirs() }.writeText(report.toString(2))
    }
}
