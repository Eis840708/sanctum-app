package com.sanctum.vault

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/**
 * Native side of the V-05 biometric auth-bound DEK wrap (DEV-P0-03 B2-5a-native
 * stage 1b). Contract: DEV-P0-03-B2-5a-native-dependency-assessment-v1.
 *
 * Owns a per-vault AES-256-GCM key in the AndroidKeyStore whose use requires a
 * fresh biometric authentication (BiometricPrompt.CryptoObject). The key is
 * hardware-backed (TEE, or StrongBox where available) and is invalidated when a
 * new biometric is enrolled. The plaintext DEK only ever lives in-process; the
 * key material never leaves secure hardware.
 *
 * Fail-closed: every failure path returns a MethodChannel error; a
 * software-only key is treated as unavailable (never a false hardware promise).
 * biometricOnly: only BIOMETRIC_STRONG is accepted (no device-credential
 * fallback), matching the director ruling.
 */
class KeyAuthChannel(private val activity: FragmentActivity) :
    MethodChannel.MethodCallHandler {

    private val keyStore: KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "capability" -> capability(result)
                "enroll" -> enroll(call, result)
                "unlock" -> unlock(call, result)
                "disable" -> disable(call, result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("keyauth-error", e.message, null)
        }
    }

    // --- capability -----------------------------------------------------------

    private fun capability(result: MethodChannel.Result) {
        val bm = BiometricManager.from(activity)
        val canAuth = bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) {
            result.success(
                capabilityMap(false, strongBox = false, secure = false, reason = "biometric:$canAuth")
            )
            return
        }
        // Probe a hardware key to learn StrongBox / secure-hardware status, then
        // delete it. Never reuses a real vault alias.
        val probe = "${KEY_ALIAS_PREFIX}__probe__"
        try {
            val strongBox = generateKey(probe, preferStrongBox = true)
            val secure = isInsideSecureHardware(probe)
            result.success(
                capabilityMap(
                    available = secure,
                    strongBox = strongBox,
                    secure = secure,
                    reason = if (secure) null else "not-secure-hardware"
                )
            )
        } finally {
            deleteKey(probe)
        }
    }

    // --- enroll ---------------------------------------------------------------

    private fun enroll(call: MethodCall, result: MethodChannel.Result) {
        val dek = call.argument<ByteArray>("dek")
            ?: return result.error("bad-args", "dek missing", null)
        val vaultId = call.argument<ByteArray>("vaultId")
            ?: return result.error("bad-args", "vaultId missing", null)
        val aad = call.argument<ByteArray>("aad")
            ?: return result.error("bad-args", "aad missing", null)
        val alias = aliasFor(vaultId)

        // Fresh key per enroll (replaces any previous wrap for this vault).
        deleteKey(alias)
        generateKey(alias, preferStrongBox = true)
        if (!isInsideSecureHardware(alias)) {
            deleteKey(alias)
            return result.error("not-secure-hardware", "key not hardware-backed", null)
        }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(alias))

        authenticate(
            cipher = cipher,
            onSuccess = { authed ->
                try {
                    authed.updateAAD(aad)
                    val ct = authed.doFinal(dek)
                    // blob = iv (12) ‖ ciphertext ‖ tag
                    result.success(authed.iv + ct)
                } catch (e: Exception) {
                    deleteKey(alias)
                    result.error("enroll-crypto", e.message, null)
                }
            },
            onError = { code, msg ->
                deleteKey(alias)
                result.error(code, msg, null)
            },
        )
    }

    // --- unlock ---------------------------------------------------------------

    private fun unlock(call: MethodCall, result: MethodChannel.Result) {
        val blob = call.argument<ByteArray>("blob")
            ?: return result.error("bad-args", "blob missing", null)
        val vaultId = call.argument<ByteArray>("vaultId")
            ?: return result.error("bad-args", "vaultId missing", null)
        val aad = call.argument<ByteArray>("aad")
            ?: return result.error("bad-args", "aad missing", null)
        val alias = aliasFor(vaultId)

        if (blob.size < GCM_IV_LENGTH + GCM_TAG_LENGTH_BYTES) {
            return result.error("bad-blob", "blob too short", null)
        }
        val key = try {
            secretKey(alias)
        } catch (e: Exception) {
            return result.error("no-key", "no biometric key for vault", null)
        }

        val iv = blob.copyOfRange(0, GCM_IV_LENGTH)
        val ct = blob.copyOfRange(GCM_IV_LENGTH, blob.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))

        authenticate(
            cipher = cipher,
            onSuccess = { authed ->
                try {
                    authed.updateAAD(aad)
                    result.success(authed.doFinal(ct))
                } catch (e: Exception) {
                    // Wrong AAD / tampered blob / invalidated key -> fail-closed.
                    result.error("unlock-crypto", e.message, null)
                }
            },
            onError = { code, msg -> result.error(code, msg, null) },
        )
    }

    // --- disable --------------------------------------------------------------

    private fun disable(call: MethodCall, result: MethodChannel.Result) {
        val vaultId = call.argument<ByteArray>("vaultId")
            ?: return result.error("bad-args", "vaultId missing", null)
        deleteKey(aliasFor(vaultId))
        result.success(true)
    }

    // --- biometric prompt -----------------------------------------------------

    private fun authenticate(
        cipher: Cipher,
        onSuccess: (Cipher) -> Unit,
        onError: (String, String?) -> Unit,
    ) {
        val executor = ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(
            activity,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    r: BiometricPrompt.AuthenticationResult
                ) {
                    val authed = r.cryptoObject?.cipher
                    if (authed == null) {
                        onError("no-crypto-object", "auth result had no cipher")
                    } else {
                        onSuccess(authed)
                    }
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    onError("auth-error-$code", msg.toString())
                }

                override fun onAuthenticationFailed() {
                    // Non-terminal (e.g. one bad fingerprint); the prompt stays
                    // up. No result emitted here.
                }
            },
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Sanctum")
            .setSubtitle("Authenticate to unlock your vault")
            .setNegativeButtonText("Use password")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    // --- keystore helpers -----------------------------------------------------

    /** Generates the per-vault key. Returns true if StrongBox-backed. */
    private fun generateKey(alias: String, preferStrongBox: Boolean): Boolean {
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(true)
                .setInvalidatedByBiometricEnrollment(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                b.setUserAuthenticationParameters(
                    0, // per-operation auth (CryptoObject)
                    KeyProperties.AUTH_BIOMETRIC_STRONG,
                )
            }
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                b.setIsStrongBoxBacked(true)
            }
            return b.build()
        }

        fun build(strongBox: Boolean) {
            val kg = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
            )
            kg.init(spec(strongBox))
            kg.generateKey()
        }

        val wantStrongBox = preferStrongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
        if (wantStrongBox) {
            try {
                build(strongBox = true)
                return true
            } catch (e: StrongBoxUnavailableException) {
                deleteKey(alias)
            }
        }
        build(strongBox = false)
        return false
    }

    private fun secretKey(alias: String): SecretKey =
        (keyStore.getKey(alias, null) as? SecretKey)
            ?: throw IllegalStateException("no key for $alias")

    private fun isInsideSecureHardware(alias: String): Boolean {
        val key = keyStore.getKey(alias, null) as? SecretKey ?: return false
        val factory = SecretKeyFactory.getInstance(key.algorithm, ANDROID_KEYSTORE)
        val info = factory.getKeySpec(key, KeyInfo::class.java) as KeyInfo
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            info.securityLevel != KeyProperties.SECURITY_LEVEL_SOFTWARE
        } else {
            @Suppress("DEPRECATION")
            info.isInsideSecureHardware
        }
    }

    private fun deleteKey(alias: String) {
        try {
            if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        } catch (_: Exception) {
            // best-effort
        }
    }

    private fun aliasFor(vaultId: ByteArray): String =
        KEY_ALIAS_PREFIX + vaultId.joinToString("") { "%02x".format(it) }

    private fun capabilityMap(
        available: Boolean,
        strongBox: Boolean,
        secure: Boolean,
        reason: String?,
    ): Map<String, Any?> = mapOf(
        "available" to available,
        "strongBox" to strongBox,
        "insideSecureHardware" to secure,
        "reason" to reason,
    )

    companion object {
        const val CHANNEL = "com.sanctum.vault/keyauth"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS_PREFIX = "sanctum.v3.hwbio."
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_LENGTH = 12
        private const val GCM_TAG_LENGTH_BITS = 128
        private const val GCM_TAG_LENGTH_BYTES = 16
    }
}
