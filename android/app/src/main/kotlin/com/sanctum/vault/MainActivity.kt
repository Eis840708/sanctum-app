package com.sanctum.vault

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterFragmentActivity() {
    private val channel = "com.sanctum.vault/share"
    private var pendingImagePath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
        // Notify Flutter that a new image arrived
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, channel).invokeMethod("newSharedImage", pendingImagePath)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSharedImage" -> {
                        result.success(pendingImagePath)
                        pendingImagePath = null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND &&
            intent.type?.startsWith("image/") == true) {
            @Suppress("DEPRECATION")
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                pendingImagePath = copyUriToTemp(uri)
            }
        }
    }

    private fun copyUriToTemp(uri: Uri): String? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val tmp = File(cacheDir, "shared_${System.currentTimeMillis()}.jpg")
            FileOutputStream(tmp).use { out -> inputStream.copyTo(out) }
            inputStream.close()
            tmp.absolutePath
        } catch (_: Exception) {
            null
        }
    }
}
