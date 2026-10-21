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
class CloudRecorder {
    private companion object {
        const val TAG = "UTUVOCloudASR"
        const val SAMPLE_RATE = 16_000
        /** 超過這個長度就停止（雲端各家上限 210–300 秒；記憶體與逾時都不會先到）。 */
        const val MAX_SECONDS = 300
    }

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
        failed = false
        running = true
        record = created
        thread = Thread({ read(created) }, "cloud-asr-rec").apply { isDaemon = true; start() }
        return true
    }

    private fun read(rec: AudioRecord) {
        // 直接寫進會長大的 FloatArray：每個樣本都 boxed 進 ArrayList 的話，300 秒錄音會吃掉上百 MB。
        var out = FloatArray(SAMPLE_RATE * 4)
        var count = 0
        val limit = SAMPLE_RATE * MAX_SECONDS
        val buffer = ShortArray(2048)
        val gain = QuietMode.gain(quiet)
        try {
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) { failed = true; return }
            while (running && count < limit) {
                val read = rec.read(buffer, 0, buffer.size)
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
            }

        } catch (e: Exception) {
            Log.w(TAG, "recording failed", e)
            failed = true
        } finally {
            runCatching { rec.stop() }
            samples = if (failed) FloatArray(0) else out.copyOf(count)
            running = false
        }
    }

    @Volatile private var samples = FloatArray(0)

    /** 停止並取回整段（沒錄到就回空陣列；呼叫端看到空值就不送雲端）。 */
    fun stop(): FloatArray {
        val t = thread
        running = false
        if (t != null) runCatching { t.join(2000) }
        thread = null
        runCatching { record?.release() }
        record = null
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
