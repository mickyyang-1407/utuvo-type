package com.utuvo.type

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 雲端翻譯 key（選配，對應 iOS IOSSecretStore）：只存 Android Keystore 加密過的密文，不回顯、不寫 log。
 * 加密金鑰在 Keystore 裡、不可匯出；app 移除時一起消失。
 */
object SecretStore {
    private const val ALIAS = "utuvo.type.cloudKey"
    private const val PREF = "secret"
    private const val FIELD = "dashscope"

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
        }.generateKey()
    }

    /** field：每個服務一把（預設 dashscope＝翻譯與智慧整理的百鍊共用同一把）。 */
    fun hasKey(c: Context, field: String = FIELD) = prefs(c).contains(field)

    fun save(c: Context, value: String, field: String = FIELD) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(value.trim().toByteArray())
        prefs(c).edit().putString(field, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    fun delete(c: Context, field: String = FIELD) { prefs(c).edit().remove(field).apply() }

    /** 解不開（例如還原備份到另一台手機、Keystore 金鑰不在了）就當作沒設定，並清掉壞掉的密文。 */
    fun apiKey(c: Context, field: String = FIELD): String? {
        val stored = prefs(c).getString(field, null) ?: return null
        return runCatching {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, 12))
            String(cipher.doFinal(sealed, 12, sealed.size - 12))
        }.getOrElse { delete(c, field); null }?.takeIf { it.isNotEmpty() }
    }
}
