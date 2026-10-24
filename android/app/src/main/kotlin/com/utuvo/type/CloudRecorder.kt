package com.utuvo.type

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log

/**
 * 雲端辨識用的錄音（16 kHz 單聲道 PCM），對應 iOS 端「把整段錄音送去重辨識」的那段音訊。
 *
 * 跟系統 SpeechRecognizer 同時開：辨識器照跑（現場字＋失敗時的退路），這邊另外存一份給雲端。
 * 麥克風被占用、沒有錄音權限、或開不起來都回 false——呼叫端就只留系統辨識器，不影響打字。
 */
class CloudRecorder @JvmOverloads constructor(
    /** 單次錄音上限（秒）。正式版用 [MAX_SECONDS]；測試縮短才跑得完。 */
    maxSeconds: Int = MAX_SECONDS,
    /** 上限前多久提醒（秒）。 */
    warningSeconds: Int = WARNING_SECONDS,
) {
    companion object {
        private const val TAG = "UTUVOCloudASR"
        private const val SAMPLE_RATE = 16_000
        /** 超過這個長度就停止（雲端各家上限 210–300 秒；記憶體與逾時都不會先到）。 */
        const val MAX_SECONDS = 300
        /** 上限前多久提醒使用者（Typeless 是 9 分鐘上限、8 分鐘先提醒）。 */
        const val WARNING_SECONDS = 60
    }

    private val limit = SAMPLE_RATE * maxSeconds
    /** 錄到這個樣本數就提醒一次；-1＝不提醒（上限太短）。 */
    private val warnAt = if (warningSeconds in 1 until maxSeconds) SAMPLE_RATE * (maxSeconds - warningSeconds) else -1

    /**
     * 錄到上限前 [WARNING_SECONDS] 秒時呼叫一次（capture-latency-3）。
     * 在錄音執行緒上呼叫：只准 post 到主執行緒，不能在這裡碰 UI。
     */
    @Volatile var onLimitWarning: (() -> Unit)? = null

    /**
     * 錄滿上限、錄音執行緒自己結束時呼叫一次（麥克風已放掉、樣本已備好，等 [stop] 取走）。
     * 以前到上限只是安靜地跳出迴圈：鍵盤還顯示聆聽中、系統辨識器收不到聲音，使用者按停時整段雲端錄音被丟掉。
     * 同 [onLimitWarning]，在錄音執行緒上呼叫，只准 post。
     */
    @Volatile var onLimitReached: (() -> Unit)? = null

    /** 這次錄音是不是錄滿上限才結束的。 */
    @Volatile var limitReached = false
        private set

    /** 錄音執行緒自己結束（錄滿上限）、樣本還沒被 [stop] 取走。 */
    @Volatile private var unclaimed = false

    /**
     * 有沒有樣本可以取：還在錄，或錄滿上限自己停了但還沒取走。取走一次（[stop]／[cancel]）就變 false——
     * 呼叫端用這個當「要不要收錄音」的唯一條件，第二次收尾才不會把已經取好的樣本清掉。
     */
    val hasSamplesToClaim: Boolean get() = running || unclaimed

    @Volatile private var running = false
    @Volatile private var failed = false
    @Volatile private var quiet = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    val isActive: Boolean get() = running

    /**
     * Q3 邊錄邊傳：錄音中偵測到停頓，就把那一段交給 sink（背景送去辨識）。
     * sink 在錄音執行緒上被呼叫，只准做最輕的事（丟進執行緒）。
     */
    @Volatile private var chunkSink: ((FloatArray) -> Unit)? = null

    /**
     * 原始 16-bit 樣本的旁路（錄音執行緒上呼叫，只准丟進佇列）：鍵盤把它經 pipe 餵給系統辨識器，
     * 讓麥克風只有我們一個在開（2026-10-20 Pixel 7：兩邊同時開，先開的那個會被系統填 0）。
     */
    @Volatile var pcmTap: ((ShortArray, Int) -> Unit)? = null
    private var stream: ChunkedASR.Stream? = null

    fun setChunkSink(sink: ((FloatArray) -> Unit)?) {
        chunkSink = sink
        stream = if (sink == null) null else ChunkedASR.Stream()
    }

    @SuppressLint("MissingPermission")   // 呼叫端（UTUVOImeService.startListening）已檢查 RECORD_AUDIO
    fun start(quietMode: Boolean = false): Boolean {
        if (running) return true
        quiet = quietMode
        val min = try {
            AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        } catch (e: Exception) {
            Log.w(TAG, "getMinBufferSize failed", e); return false
        }
        if (min <= 0) { Log.w(TAG, "16 kHz mono not supported (min=$min)"); return false }
        val created = runCatching {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 4)
        }.getOrNull() ?: runCatching {
            AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 4)
        }.getOrNull()
        if (created == null || created.state != AudioRecord.STATE_INITIALIZED) {
            Log.w(TAG, "AudioRecord init failed"); created?.release(); return false
        }
        resetForStart()
        record = created
        thread = Thread({ read(created) }, "cloud-asr-rec").apply { isDaemon = true; start() }
        return true
    }

    /** 測試用：不開麥克風，用假來源在自己的執行緒上跑同一個錄音迴圈（同正式版的 [read]）。 */
    internal fun startWithSource(source: (ShortArray, Int) -> Int, quietMode: Boolean = false): Boolean {
        if (running) return true
        quiet = quietMode
        resetForStart()
        thread = Thread({ pump(source) }, "cloud-asr-rec-test").apply { isDaemon = true; start() }
        return true
    }

    private fun resetForStart() {
        failed = false
        limitReached = false
        unclaimed = false
        samples = FloatArray(0)
        running = true
    }

    private fun read(rec: AudioRecord) {
        pump(
            source = { buffer, size -> rec.read(buffer, 0, size) },
            prepare = {
                rec.startRecording()
                rec.recordingState == AudioRecord.RECORDSTATE_RECORDING
            },
            release = {
                runCatching { rec.stop() }
                // 錄滿上限自己結束時麥克風要馬上放掉（以前只有 stop() 才 release，到上限之後一直占著）。
                runCatching { rec.release() }
            })
    }

    /**
     * 錄音迴圈：讀到 [stop] 或錄滿上限。`source(buffer, size)` 最多讀 size 個樣本，回傳讀到幾個（負數＝出錯）。
     */
    private fun pump(source: (ShortArray, Int) -> Int, prepare: () -> Boolean = { true }, release: () -> Unit = {}) {
        // 直接寫進會長大的 FloatArray：每個樣本都 boxed 進 ArrayList 的話，300 秒錄音會吃掉上百 MB。
        var out = FloatArray(minOf(limit, SAMPLE_RATE * 4))
        var count = 0
        val buffer = ShortArray(2048)
        val gain = QuietMode.gain(quiet)
        var warned = false
        try {
            if (!prepare()) { failed = true; return }
            while (running && count < limit) {
                // 最後一批只讀到上限為止：以前整批讀進來，寫超過陣列尾端丟例外，整段錄音被當成失敗清空。
                val read = source(buffer, minOf(buffer.size, limit - count))
                if (read <= 0) { if (read < 0) failed = true; continue }
                pcmTap?.invoke(buffer, read)
                if (count + read > out.size) {
                    val grown = FloatArray(minOf(limit, maxOf(out.size * 2, count + read)))
                    System.arraycopy(out, 0, grown, 0, count)
                    out = grown
                }
                // 這一批在 out 裡的起點：邊錄邊傳的切段器要知道聲音是從哪裡開始的。
                val from = count
                for (i in 0 until read) {
                    // 軟膝限幅（不是 coerceIn 硬削波）：放大後的峰值平滑收住、不失真。
                    out[count + i] = QuietMode.limited((buffer[i] / 32768f) * gain)
                }
                count += read
                // 邊錄邊傳：這一段讓切段器決定有沒有講完一段；有就交給 sink。
                stream?.push(out, from, count)?.let { cuts ->
                    val sink = chunkSink
                    if (sink != null && cuts.isNotEmpty()) {
                        for (cut in cuts) sink(out.copyOfRange(cut.start, cut.end))
                    }
                }
                if (!warned && warnAt in 1..count) {
                    warned = true
                    onLimitWarning?.invoke()
                }
            }
            if (count >= limit) limitReached = true
        } catch (e: Exception) {
            runCatching { Log.w(TAG, "recording failed", e) }
            failed = true
        } finally {
            release()
            samples = if (failed) FloatArray(0) else out.copyOf(count)
            val reachedLimit = limitReached && !failed
            unclaimed = reachedLimit
            running = false
            if (reachedLimit) onLimitReached?.invoke()
        }
    }

    @Volatile private var samples = FloatArray(0)

    /** 停止並取回整段（沒錄到就回空陣列；呼叫端看到空值就不送雲端）。 */
    fun stop(): FloatArray {
        val t = thread
        running = false
        if (t != null) runCatching { t.join(2000) }
        thread = null
        // 錄音執行緒結束時自己會放掉麥克風；卡住沒結束（read 不回來）才在這裡補放。
        if (t?.isAlive == true) runCatching { record?.release() }
        record = null
        unclaimed = false
        return if (failed) FloatArray(0) else samples
    }

    /**
     * 講完（[stop] 之後）：把還沒切掉的尾巴取出來當最後一段（Q3）。
     * 回 null＝沒有尾巴，或太短不值得打網路。
     */
    fun takeFinalChunk(): FloatArray? {
        val s = stream ?: return null
        stream = null
        chunkSink = null
        if (failed) return null
        val cut = s.finish() ?: return null
        val all = samples
        val lower = maxOf(0, minOf(cut.start, all.size))
        val upper = maxOf(lower, minOf(cut.end, all.size))
        return all.copyOfRange(lower, upper)
    }

    /** 使用者中途放棄（鍵盤收起、翻譯模式）→ 直接丟掉，不要把剛剛的音送出去。 */
    fun cancel() {
        failed = true
        stop()
    }
}
