package com.sanctum.vault

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class RecoverableImportCoordinatorTest {
    private val schedulers = CopyOnWriteArrayList<java.util.concurrent.ScheduledExecutorService>()
    private val coordinators = CopyOnWriteArrayList<RecoverableImportCoordinator>()

    @After
    fun tearDown() {
        coordinators.forEach(RecoverableImportCoordinator::close)
        schedulers.forEach { it.shutdownNow() }
    }

    @Test
    fun permanentWorkerTimesOutThenSecondSourceActuallyRunsAndSucceeds() {
        val first = ControlledWorker()
        val second = ControlledWorker(
            automaticResult = SharedImageImportResult.Success("second.img"),
        )
        val coordinator = coordinator(ArrayDeque(listOf(first, second)), timeoutMillis = 40)
        val firstResults = CopyOnWriteArrayList<SharedImageImportResult>()
        val secondResults = CopyOnWriteArrayList<SharedImageImportResult>()
        val firstCallback = CountDownLatch(1)
        val secondCallback = CountDownLatch(1)

        coordinator.submit("content://hostile/never", "image/png") {
            firstResults += it
            firstCallback.countDown()
        }
        assertTrue(first.started.await(1, TimeUnit.SECONDS))
        assertTrue(first.terminateRequested.await(1, TimeUnit.SECONDS))

        coordinator.submit("content://hostile/valid", "image/png") {
            secondResults += it
            secondCallback.countDown()
        }
        assertEquals(1, coordinator.snapshot().queuedRequests)
        assertEquals(0, second.openCount.get())

        first.confirmTerminated()
        assertTrue(firstCallback.await(1, TimeUnit.SECONDS))
        assertFailure(firstResults.single(), SharedImagePolicy.ERROR_TIMEOUT)
        assertTrue(second.started.await(1, TimeUnit.SECONDS))
        assertTrue(second.terminateRequested.await(1, TimeUnit.SECONDS))
        second.confirmTerminated()
        assertTrue(secondCallback.await(1, TimeUnit.SECONDS))
        assertTrue(secondResults.single() is SharedImageImportResult.Success)
        assertEquals(1, second.openCount.get())

        first.returnLate(SharedImageImportResult.Success("stale.img"))
        assertEquals(1, firstResults.size)
        assertEquals(1, secondResults.size)
    }

    @Test
    fun eachJobCallbacksExactlyOnceAcrossTimeoutAndLateResult() {
        val worker = ControlledWorker()
        val coordinator = coordinator(ArrayDeque(listOf(worker)), timeoutMillis = 30)
        val callbackCount = AtomicInteger()
        val callback = CountDownLatch(1)

        coordinator.submit("content://hostile/never", "image/png") {
            callbackCount.incrementAndGet()
            callback.countDown()
        }
        assertTrue(worker.terminateRequested.await(1, TimeUnit.SECONDS))
        worker.returnLate(SharedImageImportResult.Success("late.img"))
        worker.confirmTerminated()
        assertTrue(callback.await(1, TimeUnit.SECONDS))
        worker.returnLate(SharedImageImportResult.Failure(SharedImagePolicy.ERROR_UNAVAILABLE))

        assertEquals(1, callbackCount.get())
    }

    @Test
    fun closeAndTimeoutRaceCannotCommitOrReviveWorker() {
        val worker = ControlledWorker()
        val cleaned = CopyOnWriteArrayList<String>()
        val coordinator = coordinator(
            ArrayDeque(listOf(worker)),
            timeoutMillis = 200,
            cleanup = cleaned::add,
        )
        val results = CopyOnWriteArrayList<SharedImageImportResult>()
        val callback = CountDownLatch(1)

        coordinator.submit("content://hostile/never", "image/png") {
            results += it
            callback.countDown()
        }
        assertTrue(worker.started.await(1, TimeUnit.SECONDS))
        coordinator.close()
        assertTrue(worker.terminateRequested.await(1, TimeUnit.SECONDS))
        worker.returnLate(SharedImageImportResult.Success("late.img"))
        worker.confirmTerminated()
        assertTrue(callback.await(1, TimeUnit.SECONDS))

        assertEquals(1, results.size)
        assertFailure(results.single(), SharedImagePolicy.ERROR_UNAVAILABLE)
        assertEquals(1, cleaned.size)
        assertEquals(0, coordinator.snapshot().activeWorkers)
        assertEquals(0, coordinator.snapshot().recoveringWorkers)
    }

    @Test
    fun repeatedTimeoutRecoveryKeepsActiveWorkerAndQueueBounded() {
        val workers = List(6) { ControlledWorker() }
        val coordinator = coordinator(ArrayDeque(workers), timeoutMillis = 15)

        workers.forEachIndexed { index, worker ->
            val callback = CountDownLatch(1)
            coordinator.submit("content://hostile/never-$index", "image/png") {
                assertFailure(it, SharedImagePolicy.ERROR_TIMEOUT)
                callback.countDown()
            }
            assertTrue(worker.started.await(1, TimeUnit.SECONDS))
            assertTrue(worker.terminateRequested.await(1, TimeUnit.SECONDS))
            val duringRecovery = coordinator.snapshot()
            assertEquals(0, duringRecovery.activeWorkers)
            assertEquals(1, duringRecovery.recoveringWorkers)
            assertTrue(duringRecovery.queuedRequests <= 1)
            worker.confirmTerminated()
            assertTrue(callback.await(1, TimeUnit.SECONDS))
        }

        val snapshot = coordinator.snapshot()
        assertEquals(0, snapshot.activeWorkers)
        assertEquals(0, snapshot.recoveringWorkers)
        assertEquals(0, snapshot.queuedRequests)
        assertEquals(6, snapshot.workersStarted)
        assertEquals(6, snapshot.workersTerminated)
    }

    @Test
    fun onlyOneRequestCanQueueDuringWorkerReclamation() {
        val first = ControlledWorker()
        val second = ControlledWorker()
        val coordinator = coordinator(ArrayDeque(listOf(first, second)), timeoutMillis = 20)
        coordinator.submit("content://hostile/never", "image/png") { }
        assertTrue(first.terminateRequested.await(1, TimeUnit.SECONDS))

        val queued = CountDownLatch(1)
        coordinator.submit("content://hostile/valid-1", "image/png") { queued.countDown() }
        var third: SharedImageImportResult? = null
        val rejected = CountDownLatch(1)
        coordinator.submit("content://hostile/valid-2", "image/png") {
            third = it
            rejected.countDown()
        }

        assertTrue(rejected.await(1, TimeUnit.SECONDS))
        assertFailure(requireNotNull(third), SharedImagePolicy.ERROR_BUSY)
        assertFalse(queued.await(50, TimeUnit.MILLISECONDS))
        coordinator.close()
    }

    private fun coordinator(
        workers: ArrayDeque<ControlledWorker>,
        timeoutMillis: Long,
        cleanup: (String) -> Unit = {},
    ): RecoverableImportCoordinator {
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        schedulers += scheduler
        return RecoverableImportCoordinator(
            workerFactory = IsolatedImportWorkerFactory { workers.removeFirst() },
            cleanupArtifacts = cleanup,
            callbackExecutor = java.util.concurrent.Executor(Runnable::run),
            scheduler = scheduler,
            timeoutMillis = timeoutMillis,
        ).also(coordinators::add)
    }

    private fun assertFailure(result: SharedImageImportResult, code: String) {
        assertTrue(result is SharedImageImportResult.Failure)
        assertEquals(code, (result as SharedImageImportResult.Failure).code)
    }

    private class ControlledWorker(
        private val automaticResult: SharedImageImportResult? = null,
    ) : IsolatedImportWorker {
        val started = CountDownLatch(1)
        val terminateRequested = CountDownLatch(1)
        val openCount = AtomicInteger()
        private var listener: IsolatedImportWorker.Listener? = null

        override fun start(listener: IsolatedImportWorker.Listener) {
            this.listener = listener
            openCount.incrementAndGet()
            started.countDown()
            automaticResult?.let(listener::onResult)
        }

        override fun terminate() {
            terminateRequested.countDown()
        }

        override fun close() = Unit

        fun confirmTerminated() {
            listener?.onTerminated()
        }

        fun returnLate(result: SharedImageImportResult) {
            listener?.onResult(result)
        }
    }
}
