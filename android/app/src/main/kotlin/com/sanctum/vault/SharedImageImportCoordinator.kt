package com.sanctum.vault

import java.io.Closeable
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Future
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

internal data class IsolatedImportRequest(
    val generation: Long,
    val requestId: String,
    val cacheId: String,
    val uri: String,
    val intentMimeType: String?,
)

internal interface IsolatedImportWorker : Closeable {
    fun start(listener: Listener)
    fun terminate()

    interface Listener {
        fun onResult(result: SharedImageImportResult)
        fun onTerminated()
    }
}

internal fun interface IsolatedImportWorkerFactory {
    fun create(request: IsolatedImportRequest): IsolatedImportWorker
}

internal class RecoverableImportCoordinator(
    private val workerFactory: IsolatedImportWorkerFactory,
    private val cleanupArtifacts: (String) -> Unit,
    private val callbackExecutor: Executor,
    private val scheduler: ScheduledExecutorService,
    private val timeoutMillis: Long = SharedImagePolicy.IMPORT_TIMEOUT_MS,
) : Closeable {
    private val lock = Any()
    private var generation = 0L
    private var active: Job? = null
    private var recovering: Job? = null
    private var queued: PendingRequest? = null
    private var closed = false
    private var workersStarted = 0L
    private var workersTerminated = 0L

    fun submit(
        uri: String,
        intentMimeType: String?,
        callback: (SharedImageImportResult) -> Unit,
    ) {
        val pending = PendingRequest(uri, intentMimeType, callback)
        var startNow: PendingRequest? = null
        var immediate: SharedImageImportResult? = null
        synchronized(lock) {
            when {
                closed -> immediate = failure(SharedImagePolicy.ERROR_UNAVAILABLE)
                active != null -> immediate = failure(SharedImagePolicy.ERROR_BUSY)
                recovering != null && queued == null -> queued = pending
                recovering != null -> immediate = failure(SharedImagePolicy.ERROR_BUSY)
                else -> startNow = pending
            }
        }
        immediate?.let { deliver(callback, it) }
        startNow?.let(::startJob)
    }

    fun snapshot(): Snapshot = synchronized(lock) {
        Snapshot(
            generation = generation,
            activeWorkers = if (active == null) 0 else 1,
            recoveringWorkers = if (recovering == null) 0 else 1,
            queuedRequests = if (queued == null) 0 else 1,
            workersStarted = workersStarted,
            workersTerminated = workersTerminated,
        )
    }

    private fun startJob(pending: PendingRequest) {
        val job: Job
        try {
            synchronized(lock) {
                if (closed) {
                    deliver(pending.callback, failure(SharedImagePolicy.ERROR_UNAVAILABLE))
                    return
                }
                generation += 1
                val request = IsolatedImportRequest(
                    generation = generation,
                    requestId = UUID.randomUUID().toString(),
                    cacheId = UUID.randomUUID().toString(),
                    uri = pending.uri,
                    intentMimeType = pending.intentMimeType,
                )
                job = Job(request, pending.callback, workerFactory.create(request))
                active = job
                workersStarted += 1
            }
        } catch (_: Exception) {
            deliver(pending.callback, failure(SharedImagePolicy.ERROR_UNAVAILABLE))
            return
        }

        job.timeout = scheduler.schedule(
            { finish(job, failure(SharedImagePolicy.ERROR_TIMEOUT)) },
            timeoutMillis,
            TimeUnit.MILLISECONDS,
        )
        try {
            job.worker.start(
                object : IsolatedImportWorker.Listener {
                    override fun onResult(result: SharedImageImportResult) = finish(job, result)
                    override fun onTerminated() = workerTerminated(job)
                },
            )
        } catch (_: Exception) {
            finish(job, failure(SharedImagePolicy.ERROR_UNAVAILABLE))
        }
    }

    private fun finish(job: Job, result: SharedImageImportResult) {
        var terminate = false
        synchronized(lock) {
            if (active !== job || job.completed) return
            job.completed = true
            job.timeout?.cancel(false)
            job.result = result
            job.cleanupOnTermination = result !is SharedImageImportResult.Success
            active = null
            recovering = job
            terminate = true
        }
        if (terminate) job.worker.terminate()
    }

    private fun workerTerminated(job: Job) {
        var result: SharedImageImportResult? = null
        var callback: ((SharedImageImportResult) -> Unit)? = null
        var next: PendingRequest? = null
        var cleanup = false
        synchronized(lock) {
            when {
                recovering === job -> {
                    recovering = null
                    workersTerminated += 1
                    cleanup = job.cleanupOnTermination
                    if (!job.callbackDelivered) {
                        job.callbackDelivered = true
                        result = job.result ?: failure(SharedImagePolicy.ERROR_UNAVAILABLE)
                        callback = job.callback
                    }
                    if (!closed) {
                        next = queued
                        queued = null
                    }
                }
                active === job -> {
                    job.timeout?.cancel(false)
                    active = null
                    workersTerminated += 1
                    cleanup = true
                    if (!job.callbackDelivered) {
                        job.callbackDelivered = true
                        result = failure(SharedImagePolicy.ERROR_UNAVAILABLE)
                        callback = job.callback
                    }
                }
                else -> return
            }
        }
        if (cleanup) cleanupArtifacts(job.request.cacheId)
        if (callback != null && result != null) deliver(checkNotNull(callback), checkNotNull(result))
        next?.let(::startJob)
    }

    override fun close() {
        var activeToTerminate: Job? = null
        var recoveringToTerminate: Job? = null
        var queuedToFail: PendingRequest? = null
        synchronized(lock) {
            if (closed) return
            closed = true
            queuedToFail = queued
            queued = null
            active?.let { job ->
                job.timeout?.cancel(false)
                job.completed = true
                job.result = failure(SharedImagePolicy.ERROR_UNAVAILABLE)
                job.cleanupOnTermination = true
                activeToTerminate = job
                recovering = job
                active = null
            }
            recoveringToTerminate = recovering
        }
        queuedToFail?.let { deliver(it.callback, failure(SharedImagePolicy.ERROR_UNAVAILABLE)) }
        activeToTerminate?.worker?.terminate()
        if (recoveringToTerminate !== activeToTerminate) recoveringToTerminate?.worker?.terminate()
    }

    private fun deliver(
        callback: (SharedImageImportResult) -> Unit,
        result: SharedImageImportResult,
    ) {
        callbackExecutor.execute { callback(result) }
    }

    data class Snapshot(
        val generation: Long,
        val activeWorkers: Int,
        val recoveringWorkers: Int,
        val queuedRequests: Int,
        val workersStarted: Long,
        val workersTerminated: Long,
    )

    private data class PendingRequest(
        val uri: String,
        val intentMimeType: String?,
        val callback: (SharedImageImportResult) -> Unit,
    )

    private class Job(
        val request: IsolatedImportRequest,
        val callback: (SharedImageImportResult) -> Unit,
        val worker: IsolatedImportWorker,
    ) {
        var timeout: Future<*>? = null
        var result: SharedImageImportResult? = null
        var completed = false
        var callbackDelivered = false
        var cleanupOnTermination = false
    }

    private companion object {
        fun failure(code: String) = SharedImageImportResult.Failure(code)
    }
}
