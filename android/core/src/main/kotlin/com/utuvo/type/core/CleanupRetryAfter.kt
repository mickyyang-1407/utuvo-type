package com.utuvo.type.core

import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Parses both Retry-After forms used by HTTP: delay-seconds and an RFC 1123 date. */
object CleanupRetryAfter {
    fun milliseconds(header: String?, nowMillis: Long = System.currentTimeMillis()): Long? {
        val value = header?.trim()?.takeIf(String::isNotEmpty) ?: return null
        value.toLongOrNull()?.let { seconds ->
            val nonNegative = seconds.coerceAtLeast(0)
            return if (nonNegative > Long.MAX_VALUE / 1_000) Long.MAX_VALUE else nonNegative * 1_000
        }

        val parser = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
            isLenient = false
            timeZone = TimeZone.getTimeZone("GMT")
        }
        val retryAt = runCatching { parser.parse(value)?.time }.getOrNull() ?: return null
        return (retryAt - nowMillis).coerceAtLeast(0)
    }
}
