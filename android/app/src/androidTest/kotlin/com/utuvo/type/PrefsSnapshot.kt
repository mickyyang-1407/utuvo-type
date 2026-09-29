package com.utuvo.type

import android.content.Context

/** 手機上是 Micky 真的在用的鍵盤：測試前整份存下、測試後原樣寫回（含同步時間），不留痕跡。 */
class PrefsSnapshot(private val c: Context, private val name: String) {
    private val saved: Map<String, *> = c.getSharedPreferences(name, Context.MODE_PRIVATE).all.toMap()

    @Suppress("UNCHECKED_CAST")
    fun restore() {
        val e = c.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear()
        for ((k, v) in saved) when (v) {
            is String -> e.putString(k, v)
            is Boolean -> e.putBoolean(k, v)
            is Int -> e.putInt(k, v)
            is Long -> e.putLong(k, v)
            is Float -> e.putFloat(k, v)
            is Set<*> -> e.putStringSet(k, v as Set<String>)
        }
        e.commit()
    }
}
