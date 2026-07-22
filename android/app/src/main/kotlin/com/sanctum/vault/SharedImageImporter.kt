package com.sanctum.vault

import android.content.ComponentName
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.provider.OpenableColumns
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

sealed class SharedImageImportResult {
    data class Success(val path: String) : SharedImageImportResult()
    data class Failure(val code: String) : SharedImageImportResult()
}

interface SharedImageSource : Closeable {
    val scheme: String?
    val intentMimeType: String?
    fun resolveMimeType(): String?
    fun resolveMetadataSize(): Long?
    fun openStream(): InputStream
    fun cancel()
}

internal object BoundedInputCopier {
    fun copy(
        input: InputStream,
        output: OutputStream,
        maxBytes: Long,
        deadlineNanos: Long,
    ): Long {
        val buffer = ByteArray(SharedImagePolicy.COPY_BUFFER_BYTES)
        var total = 0L
        while (true) {
            if (Thread.currentThread().isInterrupted || System.nanoTime() >= deadlineNanos) {
                throw ImportTimedOutException()
            }
            val read = input.read(buffer)
            if (read < 0) return total
            if (read == 0) continue
            total += read
            if (total > maxBytes) throw ImageTooLargeException()
            output.write(buffer, 0, read)
        }
    }
}

class SharedImageImportEngine(
    private val cacheManager: SharedImageCacheManager,
    private val validator: SharedImageValidator,
    private val callbackExecutor: Executor = Executor(Runnable::run),
    private val scheduler: ScheduledExecutorService = newDaemonScheduler(),
    private val timeoutMillis: Long = SharedImagePolicy.IMPORT_TIMEOUT_MS,
) : Closeable {
    private val activeJob = AtomicReference<ImportJob?>()
    private val nextRequestGeneration = AtomicLong()
    private val workerLock = Any()
    private val workerExecutors = mutableListOf<ExecutorService>()
    private var nextWorkerGeneration = 0L
    private var currentWorker: WorkerGeneration? = newWorkerGeneration()
    private var closed = false

    fun start(source: SharedImageSource, callback: (SharedImageImportResult) -> Unit) {
        start(source, null, callback)
    }

    internal fun start(
        source: SharedImageSource,
        cacheId: String?,
        callback: (SharedImageImportResult) -> Unit,
    ) {
        if (source.scheme != ContentResolver.SCHEME_CONTENT) {
            source.closeQuietly()
            callbackExecutor.execute {
                callback(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_UNSUPPORTED_URI))
            }
            return
        }
        if (!source.intentMimeType.isImageMimeType()) {
            source.closeQuietly()
            callbackExecutor.execute {
                callback(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_INVALID_IMAGE))
            }
            return
        }

        val job = ImportJob(
            source = source,
            cacheId = cacheId,
            requestGeneration = nextRequestGeneration.incrementAndGet(),
            requestId = UUID.randomUUID().toString(),
            callback = callback,
        )
        if (!activeJob.compareAndSet(null, job)) {
            source.closeQuietly()
            callbackExecutor.execute {
                callback(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_BUSY))
            }
            return
        }

        val worker = synchronized(workerLock) {
            if (closed) null else currentWorker
        }
        if (worker == null) {
            finish(job, SharedImagePolicy.ERROR_UNAVAILABLE)
            return
        }
        job.workerGeneration = worker
        try {
            job.worker = worker.executor.submit { runImport(job) }
        } catch (_: RejectedExecutionException) {
            finish(job, SharedImagePolicy.ERROR_UNAVAILABLE)
            return
        }
        job.timeout = scheduler.schedule(
            { finish(job, SharedImagePolicy.ERROR_TIMEOUT, cancelWork = true) },
            timeoutMillis,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun runImport(job: ImportJob) {
        try {
            val resolvedMimeType = job.source.resolveMimeType()
            if (resolvedMimeType != null && !resolvedMimeType.isImageMimeType()) {
                finish(job, SharedImagePolicy.ERROR_INVALID_IMAGE)
                return
            }
            val reportedSize = job.source.resolveMetadataSize()
            if (reportedSize != null && reportedSize > SharedImagePolicy.MAX_STREAM_BYTES) {
                finish(job, SharedImagePolicy.ERROR_TOO_LARGE)
                return
            }

            val partial = cacheManager.createPartialFile(job.cacheId ?: job.requestId)
            synchronized(job.lock) {
                if (job.finished || !isActive(job)) {
                    cacheManager.deletePartial(partial)
                    return
                }
                job.partial = partial
            }
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
            job.source.openStream().use { input ->
                FileOutputStream(partial).use { output ->
                    job.output = output
                    BoundedInputCopier.copy(
                        input,
                        output,
                        SharedImagePolicy.MAX_STREAM_BYTES,
                        deadline,
                    )
                    output.fd.sync()
                }
                job.output = null
            }
            if (!validator.isValid(partial)) {
                finish(job, SharedImagePolicy.ERROR_INVALID_IMAGE)
                return
            }
            finishSuccess(job)
        } catch (_: ImageTooLargeException) {
            finish(job, SharedImagePolicy.ERROR_TOO_LARGE)
        } catch (_: ImportTimedOutException) {
            finish(job, SharedImagePolicy.ERROR_TIMEOUT, cancelWork = true)
        } catch (_: Exception) {
            finish(job, SharedImagePolicy.ERROR_UNAVAILABLE)
        } finally {
            job.output = null
            job.source.closeQuietly()
            if (job.finished) cacheManager.deletePartial(job.partial)
        }
    }

    private fun finishSuccess(job: ImportJob) {
        val result = synchronized(job.lock) {
            if (job.finished || !isActive(job)) {
                cacheManager.deletePartial(job.partial)
                return
            }
            try {
                val delivered = cacheManager.commitPartial(job.partial ?: return)
                job.delivered = delivered
                job.finished = true
                SharedImageImportResult.Success(delivered.absolutePath)
            } catch (_: Exception) {
                job.finished = true
                cacheManager.deletePartial(job.partial)
                SharedImageImportResult.Failure(SharedImagePolicy.ERROR_UNAVAILABLE)
            }
        }
        complete(job, result)
    }

    private fun finish(job: ImportJob, code: String, cancelWork: Boolean = false) {
        var invalidateWorker = false
        synchronized(job.lock) {
            if (job.finished) {
                cacheManager.deletePartial(job.partial)
                return
            }
            job.finished = true
            if (cancelWork) {
                job.output.closeQuietly()
                try {
                    job.source.cancel()
                } catch (_: Exception) {
                    job.source.closeQuietly()
                }
                job.worker?.cancel(true)
                invalidateWorker = true
            }
            cacheManager.deletePartial(job.partial)
            job.delivered?.let { cacheManager.releaseDelivered(it.absolutePath) }
        }
        if (invalidateWorker) invalidateWorker(job)
        complete(job, SharedImageImportResult.Failure(code))
    }

    private fun complete(job: ImportJob, result: SharedImageImportResult) {
        job.timeout?.cancel(false)
        if (!activeJob.compareAndSet(job, null)) return
        if (!job.callbackDelivered.compareAndSet(false, true)) return
        callbackExecutor.execute { job.callback(result) }
    }

    private fun isActive(job: ImportJob): Boolean {
        val active = activeJob.get()
        return active === job &&
            active.requestGeneration == job.requestGeneration &&
            active.requestId == job.requestId
    }

    private fun invalidateWorker(job: ImportJob) {
        val generation = job.workerGeneration ?: return
        synchronized(workerLock) {
            if (currentWorker !== generation) return
            generation.executor.shutdownNow()
            currentWorker = if (!closed && workerExecutors.size < MAX_WORKER_GENERATIONS) {
                newWorkerGeneration()
            } else {
                null
            }
        }
    }

    fun cancelActive() {
        activeJob.get()?.let {
            finish(it, SharedImagePolicy.ERROR_UNAVAILABLE, cancelWork = true)
        }
    }

    internal fun debugSnapshot(): EngineSnapshot = synchronized(workerLock) {
        EngineSnapshot(
            workerGenerationsCreated = workerExecutors.size,
            liveWorkerExecutors = workerExecutors.count { !it.isTerminated },
            acceptsNewWork = !closed && currentWorker != null,
        )
    }

    override fun close() {
        synchronized(workerLock) { closed = true }
        cancelActive()
        scheduler.shutdownNow()
        val executors = synchronized(workerLock) {
            currentWorker = null
            workerExecutors.toList()
        }
        executors.forEach(ExecutorService::shutdownNow)
    }

    internal data class EngineSnapshot(
        val workerGenerationsCreated: Int,
        val liveWorkerExecutors: Int,
        val acceptsNewWork: Boolean,
    )

    private data class WorkerGeneration(
        val generation: Long,
        val executor: ExecutorService,
    )

    private class ImportJob(
        val source: SharedImageSource,
        val cacheId: String?,
        val requestGeneration: Long,
        val requestId: String,
        val callback: (SharedImageImportResult) -> Unit,
    ) {
        val lock = Any()
        val callbackDelivered = AtomicBoolean(false)

        @Volatile
        var output: OutputStream? = null
        var partial: File? = null
        var delivered: File? = null
        var worker: Future<*>? = null
        var timeout: Future<*>? = null
        var workerGeneration: WorkerGeneration? = null
        var finished = false
    }

    private fun newWorkerGeneration(): WorkerGeneration {
        nextWorkerGeneration += 1
        val generation = nextWorkerGeneration
        val executor = newDaemonWorker(generation)
        workerExecutors += executor
        return WorkerGeneration(generation, executor)
    }

    private companion object {
        const val MAX_WORKER_GENERATIONS = 2

        fun newDaemonWorker(generation: Long): ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "sanctum-shared-image-import-$generation").apply {
                    isDaemon = true
                }
            }

        fun newDaemonScheduler(): ScheduledExecutorService =
            Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "sanctum-shared-image-timeout").apply { isDaemon = true }
            }
    }
}

class SharedImageImporter(context: Context) : Closeable {
    private val appContext = context.applicationContext
    private val cacheManager = SharedImageCacheManager(appContext.cacheDir)
    private val callbackExecutor = Executor { command ->
        Handler(Looper.getMainLooper()).post(command)
    }
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "sanctum-share-supervisor").apply { isDaemon = true }
    }
    private val coordinator = RecoverableImportCoordinator(
        workerFactory = IsolatedImportWorkerFactory { request ->
            AndroidIsolatedImportWorker(appContext, request)
        },
        cleanupArtifacts = { cacheId -> cacheManager.deleteRequestArtifacts(cacheId) },
        callbackExecutor = callbackExecutor,
        scheduler = scheduler,
    )
    private val maintenanceExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "sanctum-shared-image-maintenance").apply { isDaemon = true }
    }

    fun start(uri: Uri, intentMimeType: String?, callback: (SharedImageImportResult) -> Unit) {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            callbackExecutor.execute {
                callback(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_UNSUPPORTED_URI))
            }
            return
        }
        if (!intentMimeType.isImageMimeType()) {
            callbackExecutor.execute {
                callback(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_INVALID_IMAGE))
            }
            return
        }
        maintenanceExecutor.execute {
            coordinator.submit(uri.toString(), intentMimeType, callback)
        }
    }

    fun cleanupOnStartup() {
        maintenanceExecutor.execute {
            try {
                cacheManager.cleanupOnStartup()
            } catch (_: Exception) {
                // Cache maintenance is best effort and never blocks app startup.
            }
        }
    }

    fun release(path: String?, callback: (Boolean) -> Unit) {
        maintenanceExecutor.execute {
            val released = try {
                cacheManager.releaseDelivered(path)
            } catch (_: Exception) {
                false
            }
            callbackExecutor.execute { callback(released) }
        }
    }

    internal fun debugSnapshot(): RecoverableImportCoordinator.Snapshot = coordinator.snapshot()

    override fun close() {
        coordinator.close()
        scheduler.shutdownNow()
        maintenanceExecutor.shutdown()
    }
}

private class AndroidIsolatedImportWorker(
    private val context: Context,
    private val request: IsolatedImportRequest,
) : IsolatedImportWorker {
    private val lock = Any()
    private var listener: IsolatedImportWorker.Listener? = null
    private var binder: IBinder? = null
    private var remote: ISharedImageWorker? = null
    private var workerPid = 0
    private var bound = false
    private var closed = false
    private var terminating = false
    private var terminationSignalled = false

    private val callback = object : ISharedImageWorkerCallback.Stub() {
        override fun onResult(
            generation: Long,
            requestId: String?,
            success: Boolean,
            value: String?,
        ) {
            if (generation != request.generation || requestId != request.requestId) return
            val result = if (success && value != null) {
                SharedImageImportResult.Success(value)
            } else {
                SharedImageImportResult.Failure(value ?: SharedImagePolicy.ERROR_UNAVAILABLE)
            }
            synchronized(lock) { listener }?.onResult(result)
        }
    }

    private val deathRecipient = IBinder.DeathRecipient { signalTerminated() }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            if (service == null) {
                signalTerminated()
                return
            }
            val serviceInterface = ISharedImageWorker.Stub.asInterface(service)
            try {
                service.linkToDeath(deathRecipient, 0)
                val pid = serviceInterface.pid
                synchronized(lock) {
                    binder = service
                    remote = serviceInterface
                    workerPid = pid
                }
                if (synchronized(lock) { terminating || closed }) {
                    terminate()
                    return
                }
                serviceInterface.importImage(
                    request.generation,
                    request.requestId,
                    request.cacheId,
                    request.uri,
                    request.intentMimeType,
                    callback,
                )
            } catch (_: Exception) {
                if (synchronized(lock) { terminating }) {
                    signalTerminated()
                } else {
                    synchronized(lock) { listener }?.onResult(
                        SharedImageImportResult.Failure(SharedImagePolicy.ERROR_UNAVAILABLE),
                    )
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) = signalTerminated()
        override fun onBindingDied(name: ComponentName?) = signalTerminated()
        override fun onNullBinding(name: ComponentName?) = signalTerminated()
    }

    override fun start(listener: IsolatedImportWorker.Listener) {
        synchronized(lock) {
            check(this.listener == null) { "Worker session already started" }
            this.listener = listener
        }
        val intent = Intent(context, SharedImageWorkerService::class.java)
        val didBind = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        synchronized(lock) { bound = didBind }
        if (!didBind) {
            listener.onResult(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_UNAVAILABLE))
        }
    }

    override fun terminate() {
        val pid: Int
        val connected: Boolean
        synchronized(lock) {
            if (terminationSignalled) return
            terminating = true
            pid = workerPid
            connected = binder != null
        }
        if (pid > 0 && pid != Process.myPid()) {
            Process.killProcess(pid)
        } else if (!connected) {
            context.stopService(Intent(context, SharedImageWorkerService::class.java))
            signalTerminated()
        } else if (binder?.isBinderAlive == false) {
            signalTerminated()
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
        }
        binder?.unlinkToDeath(deathRecipient, 0)
        unbindOnce()
    }

    private fun signalTerminated() {
        val callback: IsolatedImportWorker.Listener?
        synchronized(lock) {
            if (terminationSignalled || closed && !terminating) return
            terminationSignalled = true
            callback = listener
        }
        unbindOnce()
        callback?.onTerminated()
    }

    private fun unbindOnce() {
        val shouldUnbind = synchronized(lock) {
            if (!bound) false else {
                bound = false
                true
            }
        }
        if (shouldUnbind) {
            try {
                context.unbindService(connection)
            } catch (_: IllegalArgumentException) {
                // Binding may already have died with the worker process.
            }
        }
    }
}

internal class AndroidSharedImageSource(
    private val resolver: ContentResolver,
    private val uri: Uri,
    override val intentMimeType: String?,
) : SharedImageSource {
    private val cancellationSignal = CancellationSignal()
    private val descriptor = AtomicReference<AssetFileDescriptor?>()
    private val stream = AtomicReference<InputStream?>()

    override val scheme: String? = uri.scheme

    override fun resolveMimeType(): String? = resolver.getType(uri)

    override fun resolveMetadataSize(): Long? {
        resolver.query(
            uri,
            arrayOf(OpenableColumns.SIZE),
            null,
            null,
            null,
            cancellationSignal,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                return cursor.getLong(index).takeIf { it >= 0L }
            }
        }
        return null
    }

    override fun openStream(): InputStream {
        val openedDescriptor = resolver.openAssetFileDescriptor(uri, "r", cancellationSignal)
            ?: throw IOException("Shared image is unavailable")
        descriptor.set(openedDescriptor)
        return openedDescriptor.createInputStream().also(stream::set)
    }

    override fun cancel() {
        cancellationSignal.cancel()
        close()
    }

    override fun close() {
        stream.getAndSet(null).closeQuietly()
        descriptor.getAndSet(null).closeQuietly()
    }
}

private class ImageTooLargeException : IOException()
private class ImportTimedOutException : IOException()

private fun String?.isImageMimeType(): Boolean =
    this?.lowercase()?.startsWith("image/") == true

private fun Closeable?.closeQuietly() {
    try {
        this?.close()
    } catch (_: Exception) {
        // Cleanup must not replace the stable result code.
    }
}
