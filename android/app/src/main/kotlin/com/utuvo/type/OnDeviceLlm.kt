package com.utuvo.type

import android.app.ActivityManager
import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Build
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.LogSeverity
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import java.io.File
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 手機上的智慧整理模型（Gemma 4 E2B，LiteRT-LM；Apache 2.0）。
 *
 * 2026-10-11 Micky 核准：沒填雲端 key 時改在手機上整理，文字不離機；選配下載（約 2.5 GB），不放進安裝檔。
 * 下載交給系統 DownloadManager（離開 App 也會續傳、只走 Wi-Fi），完成後驗 SHA-256 才算可用。
 * 檔案放在 App 專屬的外部儲存（其他 App 讀不到、移除 App 會一起刪）。
 */
object OnDeviceModel {
    const val FILE = "gemma-4-E2B-it.litertlm"
    /** 釘在 Hugging Face 的固定版本：檔案換了 SHA-256 就對不上，不會默默載入別的模型。 */
    private const val REVISION = "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1"
    const val URL = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/$REVISION/$FILE"
    const val SHA256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    const val BYTES = 2_588_147_712L
    const val DOWNLOAD_MB = (BYTES / 1_048_576L).toInt()
    /**
     * 第一次載入時 LiteRT-LM 另寫一份權重快取（Pixel 7 實測 GPU 783 MB、CPU 788 MB）。
     * 寫到一半空間不夠，原生程式直接 abort 整個程序（2026-10-11 模擬器實測，鍵盤也會跟著掛）——所以載入前先檢查。
     */
    const val CACHE_BYTES = 900L * 1_048_576L
    /** 設定頁說明用：模型＋快取大約要多少空間（GB，一位小數）。 */
    val TOTAL_GB: String get() = "%.1f".format((BYTES + CACHE_BYTES) / 1_000_000_000.0)

    class NotEnoughSpace : Exception("notEnoughSpace")

    private const val PREF = "ondevice"
    private const val DOWNLOAD_ID = "downloadId"
    private const val VERIFIED = "verifiedLength"
    private const val FAILED = "failed"

    sealed class State {
        object Unsupported : State()
        object Absent : State()
        data class Downloading(val bytes: Long, val total: Long, val paused: Boolean) : State()
        object Verifying : State()
        object Ready : State()
        data class Failed(val reason: String) : State()
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    fun file(c: Context): File = File(c.getExternalFilesDir("models") ?: File(c.filesDir, "models"), FILE)

    /**
     * 64 位元 ARM／x86 才有 LiteRT-LM 的原生程式庫；記憶體少於 6 GB（系統回報約 5.5 GB）的手機
     * 同時開著鍵盤與其他 App 會被系統收掉，不提供。
     */
    fun supported(c: Context): Boolean {
        val abi = Build.SUPPORTED_64_BIT_ABIS.any { it == "arm64-v8a" || it == "x86_64" }
        val mem = ActivityManager.MemoryInfo().also {
            (c.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it)
        }.totalMem
        return abi && mem >= 5_000_000_000L
    }

    /** 鍵盤每次整理都會問：只看偏好與檔案長度，不碰 DownloadManager。 */
    fun isReady(c: Context): Boolean {
        val f = file(c)
        return prefs(c).getLong(VERIFIED, -1L) == BYTES && f.length() == BYTES
    }

    private val verifying = AtomicBoolean(false)

    fun state(c: Context): State {
        if (!supported(c)) return State.Unsupported
        if (isReady(c)) return State.Ready
        if (verifying.get()) return State.Verifying
        val p = prefs(c)
        val id = p.getLong(DOWNLOAD_ID, -1L)
        if (id < 0) return p.getString(FAILED, null)?.let { State.Failed(it) } ?: State.Absent
        val dm = c.getSystemService(DownloadManager::class.java)
        dm.query(DownloadManager.Query().setFilterById(id)).use { cur ->
            if (!cur.moveToFirst()) {
                p.edit().remove(DOWNLOAD_ID).apply()
                return State.Absent
            }
            val status = cur.getInt(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val bytes = cur.getLong(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            return when (status) {
                DownloadManager.STATUS_SUCCESSFUL -> { verifyAsync(c); State.Verifying }
                DownloadManager.STATUS_FAILED -> {
                    val reason = cur.getInt(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                    dm.remove(id)
                    p.edit().remove(DOWNLOAD_ID).putString(FAILED, "download($reason)").apply()
                    State.Failed("download($reason)")
                }
                DownloadManager.STATUS_PAUSED -> State.Downloading(bytes, BYTES, paused = true)
                else -> State.Downloading(bytes, BYTES, paused = false)
            }
        }
    }

    /** 回 false＝空間不夠，沒有開始（狀態變成 Failed("space")）。 */
    fun startDownload(c: Context): Boolean {
        val app = c.applicationContext
        delete(app)
        val dir = file(app).parentFile?.apply { mkdirs() }
        // 舊的權重快取已排定刪除（delete() 交給 worker，忙的時候會晚一點刪）：算成可用空間，不要誤判不夠（luna-review r4）。
        val reclaimable = OnDeviceLlm.cacheBytes(app)
        if ((dir?.usableSpace ?: 0L) + reclaimable < BYTES + CACHE_BYTES) {
            prefs(app).edit().putString(FAILED, "space").apply()
            return false
        }
        val request = DownloadManager.Request(Uri.parse(URL))
            .setTitle(app.getString(R.string.ondevice_download_title))
            .setDescription(app.getString(R.string.ondevice_download_desc, DOWNLOAD_MB))
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setAllowedOverMetered(false)   // 2.5 GB：只走 Wi-Fi，不吃行動數據
            .setAllowedOverRoaming(false)
            .setDestinationInExternalFilesDir(app, "models", FILE)
        val id = app.getSystemService(DownloadManager::class.java).enqueue(request)
        prefs(app).edit().putLong(DOWNLOAD_ID, id).remove(FAILED).apply()
        return true
    }

    /** 取消下載或刪除已下載的模型（同一顆按鈕）；也會釋放已載入的引擎。 */
    fun delete(c: Context) {
        val app = c.applicationContext
        val p = prefs(app)
        val id = p.getLong(DOWNLOAD_ID, -1L)
        if (id >= 0) runCatching { app.getSystemService(DownloadManager::class.java).remove(id) }
        OnDeviceLlm.release(dropCache = app)
        file(app).delete()
        p.edit().remove(DOWNLOAD_ID).remove(VERIFIED).remove(FAILED).apply()
    }

    /** 下載完成後驗 SHA-256（2.5 GB 大約十幾秒）；對不上就刪掉，不載入來路不明的檔。 */
    private fun verifyAsync(c: Context, done: () -> Unit = {}) {
        if (!verifying.compareAndSet(false, true)) { done(); return }
        val app = c.applicationContext
        Thread({
            try {
                val f = file(app)
                val ok = f.length() == BYTES && sha256(f) == SHA256
                val p = prefs(app)
                if (ok) {
                    p.edit().remove(DOWNLOAD_ID).putLong(VERIFIED, BYTES).remove(FAILED).apply()
                    // 趁使用者還在設定頁，先把 GPU 程式編譯好（第一次約 1–2 分鐘），第一次聽寫才不會等不到。
                    OnDeviceLlm.warm(app)
                } else {
                    f.delete()
                    p.edit().remove(DOWNLOAD_ID).remove(VERIFIED).putString(FAILED, "checksum").apply()
                }
            } finally {
                verifying.set(false)
                done()
            }
        }, "ondevice-verify").start()
    }

    /** 系統通知下載結束（使用者可能早就離開 App）：是我們的那一筆就驗證，鍵盤下次聽寫就能用。 */
    fun onDownloadComplete(c: Context, id: Long, done: () -> Unit) {
        val app = c.applicationContext
        if (id < 0 || id != prefs(app).getLong(DOWNLOAD_ID, -1L)) { done(); return }
        val ok = runCatching {
            app.getSystemService(DownloadManager::class.java).query(DownloadManager.Query().setFilterById(id)).use { cur ->
                cur.moveToFirst() && cur.getInt(cur.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) == DownloadManager.STATUS_SUCCESSFUL
            }
        }.getOrDefault(false)
        if (ok) verifyAsync(app, done) else { state(app); done() }
    }

    internal fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().buffered(1 shl 20).use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** 開發版測試用：檔案已經由 adb 放好時，直接驗證並標成可用（同一套 SHA-256 檢查）。 */
    internal fun adoptExistingFile(c: Context): Boolean {
        val f = file(c)
        if (f.length() != BYTES || sha256(f) != SHA256) return false
        prefs(c).edit().remove(DOWNLOAD_ID).putLong(VERIFIED, BYTES).remove(FAILED).apply()
        return true
    }
}

/** DownloadManager 下載完成時叫醒 App（manifest 註冊；系統是指名送給下載的那個 App）。 */
class OnDeviceDownloadReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(c: Context, intent: android.content.Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        // 不用 goAsync 撐住整段雜湊（2.5 GB 可能超過廣播時限＝ANR，luna-review r2）：驗證在自己的執行緒跑；
        // 程序若在驗完前被收掉，下次開設定頁或開始聽寫會再驗一次。
        OnDeviceModel.onDownloadComplete(c, intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)) {}
    }
}

/**
 * 載入與執行手機上的模型。整個 App（鍵盤與設定頁同一個程序）共用一個引擎、一條執行緒：
 * 開始聽寫時先載入（講話的幾秒內做完），閒置一段時間就釋放（模型吃 1–2 GB 記憶體，不能一直佔著鍵盤）。
 */
object OnDeviceLlm {
    /** 閒置多久釋放引擎。 */
    private const val IDLE_RELEASE_MS = 120_000L

    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "ondevice-llm").apply { isDaemon = true } }
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "ondevice-idle").apply { isDaemon = true } }

    // 只在 worker 執行緒上讀寫。
    private var engine: Engine? = null
    @Volatile var backend: String = ""
        private set
    @Volatile var lastLoadMs: Long = 0
        private set
    private var idle: ScheduledFuture<*>? = null

    /** 量測用（OnDeviceSpeedTest）：強制 "gpu"／"cpu"、開關 speculative decoding；正式流程不設。 */
    @Volatile internal var backendOverride: String? = null
    @Volatile internal var speculativeDecoding: Boolean? = null
    /** 實際送進模型的整理次數（測試用：逾時被放棄的那句不能偷偷跑）。 */
    internal val inferences = java.util.concurrent.atomic.AtomicInteger(0)

    /** 開始聽寫時呼叫：模型在就先載入，等講完時引擎已經好了。 */
    fun warm(c: Context) {
        val app = c.applicationContext
        if (!OnDeviceModel.isReady(app)) return
        if (!warming.compareAndSet(false, true)) return   // 設定頁每秒刷新也會叫：同時只排一次
        worker.execute {
            try {
                runCatching { ensureEngine(app) }
                    .onSuccess { lastPrepareError = null }
                    .onFailure { lastPrepareError = it }
            } finally { warming.set(false) }
        }
    }

    /** 最近一次背景準備失敗的原因（例：空間不夠）。設定頁拿來顯示、並停止自動重試（luna-review r3）。 */
    @Volatile var lastPrepareError: Throwable? = null

    private val warming = AtomicBoolean(false)

    /**
     * 這支手機上已經成功載入過一次（GPU 程式編譯好、權重快取寫好）。第一次要 1–2 分鐘，
     * 沒準備好之前鍵盤不走手機上整理——不然每一句都會在 8–20 秒期限內等不到（luna-review r2）。
     */
    fun prepared(c: Context): Boolean =
        cacheDir(c).listFiles()?.any { it.name.endsWith(".${OnDeviceModel.SHA256.take(12)}.ok") } == true

    /**
     * 一輪整理（同步，呼叫端在背景執行緒）。到 deadline 還沒好就中止推論並丟 SocketTimeoutException，
     * 跟雲端逾時走同一條路（SmartCleanup 的紀錄與把關不用分兩套）。
     */
    fun complete(c: Context, system: String, user: String, deadlineNanos: Long, maxOutputTokens: Int): String {
        val app = c.applicationContext
        // 推論在 worker 執行緒、逾時在呼叫端執行緒：用 AtomicReference 讓呼叫端看得到正在跑的那一輪。
        val conversation = java.util.concurrent.atomic.AtomicReference<com.google.ai.edge.litertlm.Conversation?>(null)
        val abandoned = AtomicBoolean(false)
        fun gaveUp() = abandoned.get() || System.nanoTime() >= deadlineNanos
        val task = worker.submit<String> {
            val e = ensureEngine(app)
            // 載入可能很久（第一次 GPU 編譯 60–90 秒）：呼叫端已經放棄就不要再跑推論，免得後面的整理排在它後面。
            if (gaveUp()) throw SocketTimeoutException("on-device cleanup deadline exceeded")
            val conv = e.createConversation(ConversationConfig(
                systemInstruction = Contents.of(system),
                // 整理要穩定：只取最可能的字（topK 1），不要每次說法不同。
                samplerConfig = SamplerConfig(1, 1.0, 0.0, 0),
                maxOutputToken = maxOutputTokens,
                thinkingConfig = ThinkingConfig(false),
                enableSpeculativeDecoding = speculativeDecoding
            ))
            conversation.set(conv)
            try {
                // 建 conversation 的這段時間也可能過了期限（luna-review r2）：送出前再看一次。
                if (gaveUp()) throw SocketTimeoutException("on-device cleanup deadline exceeded")
                inferences.incrementAndGet()
                val reply = conv.sendMessage(user)
                reply.contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text }
            } finally {
                conversation.set(null)
                conv.close()
                scheduleRelease()
            }
        }
        val remaining = deadlineNanos - System.nanoTime()
        try {
            if (remaining <= 0) throw TimeoutException()
            return task.get(remaining, TimeUnit.NANOSECONDS)
        } catch (_: TimeoutException) {
            // 推論還在跑：叫它停，下一句才不會排在一個已經沒用的結果後面。
            abandoned.set(true)
            conversation.get()?.let { runCatching { it.cancelProcess() } }
            task.cancel(false)
            throw SocketTimeoutException("on-device cleanup deadline exceeded")
        } catch (e: java.util.concurrent.ExecutionException) {
            throw e.cause ?: e
        }
    }

    /** 刪除模型時呼叫：等目前的推論結束後關掉引擎；給了 dropCache 就連 0.8 GB 的權重快取一起刪。 */
    fun release(dropCache: Context? = null) {
        worker.execute {
            closeEngine()
            dropCache?.let { cacheDir(it).deleteRecursively() }
        }
    }

    private fun cacheDir(c: Context) = File(c.noBackupFilesDir, "litertlm-cache")

    internal fun cacheBytes(c: Context): Long = cacheDir(c).listFiles()?.sumOf { it.length() } ?: 0L

    /** 這支手機的 GPU 用不了（試過失敗、已記住）或目前引擎跑在 CPU：整理會慢很多，等待上限要放寬。 */
    fun cpuOnly(c: Context) = backend == "cpu" || File(cacheDir(c), "gpu.failed").exists()

    private fun ensureEngine(c: Context): Engine {
        engine?.let { scheduleRelease(); return it }
        if (!OnDeviceModel.isReady(c)) throw SmartCleanup.NotConfigured()
        val start = System.nanoTime()
        Engine.setNativeMinLogSeverity(LogSeverity.ERROR)
        val path = OnDeviceModel.file(c).absolutePath
        // GPU 程式第一次要編譯（Pixel 7 實測 86 秒），結果存在這裡；放 files 而不是 cache，系統清快取時才不會重來一次。
        val cache = cacheDir(c).apply { mkdirs() }.absolutePath
        // 載入後的第一次推論特別慢（Pixel 7 GPU 約 10 秒）：先空跑一個字，真正的整理才不會吃到這段。
        // 這一輪也是後端檢查：模擬器的 GPU 能建引擎、推論時才丟「Can not find Op」，要在這裡就退回 CPU。
        fun load(backend: Backend): Engine {
            // 快取完整寫好過才留記號；沒記號的快取可能是上次寫到一半（空間不夠 abort）留下的，刪掉重寫。
            // 這個後端還沒有完整快取、空間又不夠寫一份：不要讓原生程式寫到一半 abort。
            val tag = if (backend is Backend.GPU) "gpu" else "cpu"
            val suffix = if (backend is Backend.GPU) "_mldrift_weight_cache.bin" else ".xnnpack_cache"
            val marker = File(cache, "$tag.${OnDeviceModel.SHA256.take(12)}.ok")
            // 記號在、快取檔卻不見了（被刪或清理過）也當作沒快取：記號只在兩者都在時才算數（luna-review r5）。
            val cacheFiles = { File(cache).listFiles()?.filter { it.name.startsWith(OnDeviceModel.FILE) && it.name.endsWith(suffix) }.orEmpty() }
            if (marker.exists() && cacheFiles().isEmpty()) marker.delete()
            if (!marker.exists()) {
                File(cache).listFiles()?.filter { it.name.startsWith(OnDeviceModel.FILE) && it.name.endsWith(suffix) }?.forEach { it.delete() }
                if (File(cache).usableSpace < OnDeviceModel.CACHE_BYTES) throw OnDeviceModel.NotEnoughSpace()
            }
            val engine = Engine(EngineConfig(modelPath = path, backend = backend, cacheDir = cache))
            try {
                engine.initialize()
                engine.createConversation(ConversationConfig(systemInstruction = Contents.of("只回一個字。"), maxOutputToken = 1,
                    thinkingConfig = ThinkingConfig(false))).use { it.sendMessage("好") }
                marker.createNewFile()
                return engine
            } catch (t: Throwable) {
                runCatching { engine.close() }
                // 用不了的後端（例：模擬器 GPU 建得起來、推論才失敗）留下的 0.8 GB 快取沒用，刪掉。
                File(cache).listFiles()?.filter { it.name.startsWith(OnDeviceModel.FILE) && it.name.contains(if (tag == "gpu") "_mldrift_" else ".xnnpack_") }
                    ?.forEach { it.delete() }
                marker.delete()
                throw t
            }
        }
        // GPU 快很多（Pixel 7 實測每句 3–7 秒 vs CPU 18–21 秒）；GPU 不能用的機型（含模擬器）退回 CPU，
        // 並記住，之後不再每次重試 GPU（每試一次要多寫 0.8 GB 快取再刪掉）。空間不夠就換 CPU 試（它可能已有快取）。
        val gpuFailed = File(cache, "gpu.failed")
        val (e, name) = if (backendOverride == "cpu" || (backendOverride == null && gpuFailed.exists())) {
            load(Backend.CPU()) to "cpu"
        } else try {
            load(Backend.GPU()) to "gpu"
        } catch (t: Throwable) {
            if (t is VirtualMachineError && t !is OutOfMemoryError) throw t
            if (backendOverride == "gpu") throw t
            if (t !is OnDeviceModel.NotEnoughSpace) gpuFailed.createNewFile()
            load(Backend.CPU()) to "cpu"
        }
        engine = e
        backend = name
        lastLoadMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
        scheduleRelease()
        return e
    }

    private fun scheduleRelease() {
        idle?.cancel(false)
        idle = timer.schedule({ worker.execute { closeEngine() } }, IDLE_RELEASE_MS, TimeUnit.MILLISECONDS)
    }

    private fun closeEngine() {
        idle?.cancel(false)
        idle = null
        engine?.let { runCatching { it.close() } }
        engine = null
    }
}
