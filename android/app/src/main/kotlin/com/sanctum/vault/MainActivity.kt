package com.sanctum.vault

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterFragmentActivity() {
    private val ownerId = UUID.randomUUID().toString()
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        SharedImageRuntime.initialize(applicationContext)
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        SharedImageRuntime.attach(ownerId, shareChannel != null, ::notifyFlutter)
        if (SharedImageIntentHistory.shouldHandle(intent, savedInstanceState != null)) {
            handleShareIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (SharedImageIntentHistory.shouldHandle(intent, recreated = false)) {
            handleShareIntent(intent)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSharedImage" -> consumePendingResult(result)
                    "releaseSharedImage" -> {
                        SharedImageRuntime.release(call.arguments as? String) { released ->
                            result.success(released)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        SharedImageRuntime.setReady(ownerId)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        if (intent.type?.startsWith("image/", ignoreCase = true) != true) {
            notifyTransientError(SharedImagePolicy.ERROR_INVALID_IMAGE)
            return
        }

        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (uri == null) {
            notifyTransientError(SharedImagePolicy.ERROR_UNAVAILABLE)
            return
        }
        SharedImageRuntime.start(uri, intent.type)?.let(::notifyTransientError)
    }

    private fun notifyFlutter(delivery: SharedImageDelivery) {
        val channel = shareChannel
        if (channel == null) {
            SharedImageRuntime.reject(ownerId, delivery.id)
            return
        }
        val method: String
        val argument: String
        when (val importResult = delivery.result) {
            is SharedImageImportResult.Success -> {
                method = "newSharedImage"
                argument = importResult.path
            }
            is SharedImageImportResult.Failure -> {
                method = "sharedImageError"
                argument = importResult.code
            }
        }
        channel.invokeMethod(method, argument, object : MethodChannel.Result {
            override fun success(result: Any?) {
                SharedImageRuntime.acknowledge(ownerId, delivery.id)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                SharedImageRuntime.reject(ownerId, delivery.id)
            }

            override fun notImplemented() {
                SharedImageRuntime.reject(ownerId, delivery.id)
            }
        })
    }

    private fun notifyTransientError(code: String) {
        shareChannel?.invokeMethod("sharedImageError", code)
    }

    private fun consumePendingResult(result: MethodChannel.Result) {
        when (val pending = SharedImageRuntime.consume(ownerId)) {
            is SharedImageImportResult.Success -> result.success(pending.path)
            is SharedImageImportResult.Failure -> result.error(pending.code, null, null)
            null -> result.success(null)
        }
    }

    override fun onDestroy() {
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        SharedImageRuntime.detach(ownerId)
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "com.sanctum.vault/share"
    }
}
