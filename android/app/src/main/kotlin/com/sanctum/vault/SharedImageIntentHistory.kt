package com.sanctum.vault

import android.content.Intent
import android.net.Uri

internal object SharedImageIntentHistory {
    private var lastFingerprint: String? = null

    @Synchronized
    fun shouldHandle(intent: Intent?, recreated: Boolean): Boolean {
        if (intent?.action != Intent.ACTION_SEND) return false
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        val fingerprint = "${uri}|${intent.type.orEmpty()}"
        if (recreated && fingerprint == lastFingerprint) return false
        lastFingerprint = fingerprint
        return true
    }
}
