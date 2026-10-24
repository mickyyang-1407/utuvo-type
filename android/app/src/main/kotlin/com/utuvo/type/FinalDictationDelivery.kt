package com.utuvo.type

/** Production one-shot coordinator, called on the IME main thread. Each request
 * implementation owns its bounded deadline. Events contain metadata only. */
internal class FinalDictationDelivery {
    private var generation = 0L
    private var pending: (() -> Unit)? = null
    private var active = false
    /** Used before the mic start entry mutates any turn, recorder, selection or undo state. */
    fun mayStartRecording(): Boolean = !active
    fun cancel() { generation++; active = false; pending?.invoke(); pending = null }
    fun start(deterministic: String,
              primary: ((String?) -> Unit) -> (() -> Unit),
              localFallback: (((String?) -> Unit) -> (() -> Unit))?,
              valid: () -> Boolean, deliver: (String) -> Boolean,
              retain: (String) -> Unit, event: (String) -> Unit) {
        // Duplicate ASR/cloud callbacks must not destroy the utterance already polishing.
        if (active) { event("ignored-while-polishing"); return }
        cancel()
        active = true
        val token = generation
        var completed = false
        fun current() = token == generation && !completed
        fun finish(candidate: String?) {
            if (!current()) return
            completed = true; active = false; pending = null
            val output = candidate ?: deterministic
            if (!valid()) { event("skipped-target-changed"); retain(output); return }
            if (deliver(output)) event("insertion-api-accepted")
            else { event("insertion-rejected"); retain(output) }
        }
        var primaryResolved = false
        var localResolved = false
        val request = primary { candidate ->
            if (!current() || primaryResolved) return@primary
            primaryResolved = true
            event(if (candidate == null) "candidate-unavailable" else "candidate-ready")
            if (candidate != null || localFallback == null) finish(candidate)
            else {
                event("local-fallback")
                val localRequest = localFallback { fallback ->
                    if (current() && !localResolved) { localResolved = true; finish(fallback) }
                }
                if (current() && !localResolved) pending = localRequest
            }
        }
        if (current() && !primaryResolved) pending = request
    }
}
