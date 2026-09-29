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
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    val isActive: Boolean get() = running

    @SuppressLint("MissingPermission")   // 呼叫端（UTUVOImeService.startListening）已檢查 RECORD_AUDIO
    fun start(): Boolean {
        if (running) return true
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
        try {
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) { failed = true; return }
            while (running && count < limit) {
                val read = rec.read(buffer, 0, buffer.size)
                if (read <= 0) { if (read < 0) failed = true; continue }
                if (count + read > out.size) {
                    val grown = FloatArray(minOf(limit, maxOf(out.size * 2, count + read)))
                    System.arraycopy(out, 0, grown, 0, count)
                    out = grown
                }
                for (i in 0 until read) out[count + i] = buffer[i] / 32768f
                count += read
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

    /** 使用者中途放棄（鍵盤收起、翻譯模式）→ 直接丟掉，不要把剛剛的音送出去。 */
    fun cancel() {
        failed = true
        stop()
    }
}
