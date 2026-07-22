package com.sanctum.vault

import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import android.os.Process
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

class SharedImageWorkerService : Service() {
    private val started = AtomicBoolean(false)
    private lateinit var engine: SharedImageImportEngine

    private val binder = object : ISharedImageWorker.Stub() {
        override fun getPid(): Int = Process.myPid()

        override fun importImage(
            generation: Long,
            requestId: String?,
            cacheId: String?,
            uri: String?,
            intentMimeType: String?,
            callback: ISharedImageWorkerCallback?,
        ) {
            if (!started.compareAndSet(false, true) ||
                requestId == null || cacheId == null || uri == null || callback == null
            ) {
                callback?.sendFailure(generation, requestId.orEmpty())
                return
            }
            val source = AndroidSharedImageSource(contentResolver, Uri.parse(uri), intentMimeType)
            engine.start(source, cacheId) { result ->
                try {
                    when (result) {
                        is SharedImageImportResult.Success -> callback.onResult(
                            generation,
                            requestId,
                            true,
                            result.path,
                        )
                        is SharedImageImportResult.Failure -> callback.onResult(
                            generation,
                            requestId,
                            false,
                            result.code,
                        )
                    }
                } catch (_: Exception) {
                    // The main process may already have invalidated this generation.
                } finally {
                    stopSelf()
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        engine = SharedImageImportEngine(
            SharedImageCacheManager(cacheDir),
            PlatformSharedImageValidator(),
            callbackExecutor = Executor(Runnable::run),
        )
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        engine.close()
        super.onDestroy()
    }

    private fun ISharedImageWorkerCallback.sendFailure(generation: Long, requestId: String) {
        try {
            onResult(
                generation,
                requestId,
                false,
                SharedImagePolicy.ERROR_UNAVAILABLE,
            )
        } catch (_: Exception) {
            // The caller may have already torn down the binder.
        }
    }
}
