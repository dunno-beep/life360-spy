package com.you.life360monitor

import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object Crypto {
    private val key: SecretKeySpec by lazy {
        SecretKeySpec(
            MessageDigest.getInstance("SHA-256").digest(BuildConfig.TOKEN.toByteArray()),
            "AES"
        )
    }

    fun seal(s: String): String? = try {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
        Base64.encodeToString(nonce + c.doFinal(s.toByteArray()), Base64.NO_WRAP)
    } catch (e: Exception) { null }

    fun open(b: String): String? = try {
        val all = Base64.decode(b, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, all.copyOfRange(0, 12)))
        String(c.doFinal(all.copyOfRange(12, all.size)))
    } catch (e: Exception) { null }
}
