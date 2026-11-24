package app.spotless.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import uniffi.encore_ffi.CoreException
import uniffi.encore_ffi.SecretStore

/**
 * SecretStore for the shared Rust core. Values are AES-GCM encrypted before they enter private
 * app storage; the AES key itself is non-exportable and held by Android Keystore. This store never
 * logs values. The Rust account API sees the cookie only while authenticating and keeps only the
 * opaque account/display fields on the UI bridge.
 */
class AndroidKeystoreSecretStore(context: Context) : SecretStore {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    init {
        // Fail before enabling account import if Android Keystore cannot create/read its key.
        key()
    }

    @Synchronized
    override fun get(name: String): String? = guarded {
        val encoded = prefs.getString(prefName(name), null) ?: return@guarded null
        val parts = encoded.split(':', limit = 3)
        if (parts.size != 3 || parts[0] != VERSION) {
            throw IllegalStateException("Encrypted credential record is invalid")
        }
        val iv = Base64.decode(parts[1], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[2], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(name.toByteArray(StandardCharsets.UTF_8))
        String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    @Synchronized
    override fun set(name: String, value: String) = guarded {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(name.toByteArray(StandardCharsets.UTF_8))
        val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val encoded = listOf(
            VERSION,
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(ciphertext, Base64.NO_WRAP),
        ).joinToString(":")
        check(prefs.edit().putString(prefName(name), encoded).commit()) {
            "Android could not persist the encrypted credential"
        }
    }

    @Synchronized
    override fun delete(name: String) = guarded {
        check(prefs.edit().remove(prefName(name)).commit()) {
            "Android could not remove the encrypted credential"
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun prefName(name: String): String =
        Base64.encodeToString(name.toByteArray(StandardCharsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private inline fun <T> guarded(block: () -> T): T = try {
        block()
    } catch (error: CoreException) {
        throw error
    } catch (_: Exception) {
        // Keep exception text generic: provider errors must never accidentally expose credential data.
        throw CoreException.Failed("Android secure credential storage failed")
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "ztunes.session-secrets.v1"
        const val PREFS = "ztunes_encrypted_sessions_v1"
        const val VERSION = "v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}
