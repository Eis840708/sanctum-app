package com.sanctum.vault

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class SharedImageImportEngineTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private val engines = CopyOnWriteArrayList<SharedImageImportEngine>()

    @After
    fun tearDown() {
        engines.forEach(SharedImageImportEngine::close)
    }

    @Test
    fun emptyStreamIsRejected() {
        assertFailure(run(FakeSource(length = 0)), SharedImagePolicy.ERROR_INVALID_IMAGE)
    }

    @Test
    fun oneByteUsesActualStreamLength() {
        assertSuccess(run(FakeSource(length = 1)))
    }

    @Test
    fun normalStreamSucceeds() {
        assertSuccess(run(FakeSource(length = 32 * 1024)))
    }

    @Test
    fun streamIsOpenedOffTheCallingThread() {
        val callerThread = Thread.currentThread().name
        val source = FakeSource(length = 1)

        assertSuccess(run(source))

        assertNotNull(source.openedOnThread)
        assertNotEquals(callerThread, source.openedOnThread)
    }

    @Test
    fun exactByteCapSucceeds() {
        assertSuccess(run(FakeSource(length = SharedImagePolicy.MAX_STREAM_BYTES)))
    }

    @Test
    fun oneByteAboveCapFailsAndDeletesPartial() {
        val manager = manager()
        val result = run(
            FakeSource(length = SharedImagePolicy.MAX_STREAM_BYTES + 1),
            manager = manager,
        )
        assertFailure(result, SharedImagePolicy.ERROR_TOO_LARGE)
        assertEquals(0, manager.countOwnedFiles(".partial"))
        assertEquals(0, manager.countOwnedFiles(".img"))
    }

    @Test
    fun oversizedMetadataRejectsBeforeOpeningStream() {
        val source = FakeSource(
            length = 1,
            reportedSize = SharedImagePolicy.MAX_STREAM_BYTES + 1,
        )
        assertFailure(run(source), SharedImagePolicy.ERROR_TOO_LARGE)
        assertEquals(0, source.openCount.get())
    }

    @Test
    fun lyingSmallMetadataCannotBypassActualCap() {
        val source = FakeSource(
            length = SharedImagePolicy.MAX_STREAM_BYTES + 1,
            reportedSize = 1,
        )
        assertFailure(run(source), SharedImagePolicy.ERROR_TOO_LARGE)
    }

    @Test
    fun unknownMetadataStillUsesActualCount() {
        assertFailure(
            run(FakeSource(length = SharedImagePolicy.MAX_STREAM_BYTES + 1)),
            SharedImagePolicy.ERROR_TOO_LARGE,
        )
    }

    @Test
    fun readExceptionReturnsUnavailableAndDeletesPartial() {
        val manager = manager()
        val result = run(FakeSource(length = 100, failAfter = 20), manager = manager)
        assertFailure(result, SharedImagePolicy.ERROR_UNAVAILABLE)
        assertEquals(0, manager.countOwnedFiles(".partial"))
    }

    @Test
    fun timeoutCancelsSourceAndDeletesPartial() {
        val source = FakeSource(length = 100, readDelayMillis = 500)
        val manager = manager()
        val result = run(source, manager = manager, timeoutMillis = 50)
        assertFailure(result, SharedImagePolicy.ERROR_TIMEOUT)
        assertTrue(source.cancelled)
        assertTrue(source.closed)
        assertTrue(source.streamClosed)
        assertEquals(0, manager.countOwnedFiles(".partial"))
    }

    @Test
    fun timeoutBeforePartialRegistrationCannotLeakLateFile() {
        val source = FakeSource(length = 1, metadataDelayMillis = 250)
        val manager = manager()

        val result = run(source, manager = manager, timeoutMillis = 50)
        assertFailure(result, SharedImagePolicy.ERROR_TIMEOUT)
        Thread.sleep(350)

        assertEquals(0, manager.countOwnedFiles(".partial"))
        assertEquals(0, manager.countOwnedFiles(".img"))
    }

    @Test
    fun nonCooperativeTimeoutRotatesWorkerAndLaterImportSucceedsExactlyOnce() {
        val manager = manager()
        val engine = engine(manager, timeoutMillis = 100)
        val blocker = NonCooperativeSource()
        val firstResults = CopyOnWriteArrayList<SharedImageImportResult>()
        val secondResults = CopyOnWriteArrayList<SharedImageImportResult>()
        val firstCallback = CountDownLatch(1)
        val secondCallback = CountDownLatch(1)

        try {
            engine.start(blocker) {
                firstResults += it
                firstCallback.countDown()
            }
            assertTrue(firstCallback.await(5, TimeUnit.SECONDS))
            assertFailure(firstResults.single(), SharedImagePolicy.ERROR_TIMEOUT)

            val later = FakeSource(length = 1)
            engine.start(later) {
                secondResults += it
                secondCallback.countDown()
            }
            assertTrue(secondCallback.await(5, TimeUnit.SECONDS))
            assertSuccess(secondResults.single())
            assertEquals(1, later.openCount.get())

            blocker.release()
            assertTrue(blocker.closed.await(5, TimeUnit.SECONDS))
            assertEquals(1, firstResults.size)
            assertEquals(1, secondResults.size)
            assertEquals(0, manager.countOwnedFiles(".partial"))
            val delivered = (secondResults.single() as SharedImageImportResult.Success).path
            assertTrue(manager.releaseDelivered(delivered))
            assertEquals(0, manager.countOwnedFiles(".img"))

            val snapshot = engine.debugSnapshot()
            assertEquals(2, snapshot.workerGenerationsCreated)
            assertTrue(snapshot.liveWorkerExecutors <= 2)
            assertTrue(snapshot.acceptsNewWork)
            println(
                "engine_recovery first=ERROR_TIMEOUT " +
                    "firstCallbacks=${firstResults.size} second=Success " +
                    "secondCallbacks=${secondResults.size} secondOpenStream=${later.openCount.get()} " +
                    "generations=${snapshot.workerGenerationsCreated} " +
                    "liveExecutors=${snapshot.liveWorkerExecutors} partial=0 img=0",
            )
        } finally {
            blocker.release()
        }
    }

    @Test
    fun nonCooperativeTimeoutsStopAtFixedExecutorGenerationLimit() {
        val manager = manager()
        val engine = engine(manager, timeoutMillis = 50)
        val first = NonCooperativeSource()
        val second = NonCooperativeSource()

        try {
            assertFailure(await(engine, first), SharedImagePolicy.ERROR_TIMEOUT)
            assertFailure(await(engine, second), SharedImagePolicy.ERROR_TIMEOUT)

            val rejected = FakeSource(length = 1)
            assertFailure(await(engine, rejected), SharedImagePolicy.ERROR_UNAVAILABLE)
            assertEquals(0, rejected.openCount.get())

            val snapshot = engine.debugSnapshot()
            assertEquals(2, snapshot.workerGenerationsCreated)
            assertTrue(snapshot.liveWorkerExecutors <= 2)
            assertTrue(!snapshot.acceptsNewWork)
            assertEquals(0, manager.countOwnedFiles(".partial"))
            assertEquals(0, manager.countOwnedFiles(".img"))
            println(
                "engine_fail_closed generations=${snapshot.workerGenerationsCreated} " +
                    "liveExecutors=${snapshot.liveWorkerExecutors} " +
                    "acceptsNewWork=${snapshot.acceptsNewWork} thirdOpenStream=${rejected.openCount.get()} " +
                    "partial=0 img=0",
            )
        } finally {
            first.release()
            second.release()
            assertTrue(first.closed.await(5, TimeUnit.SECONDS))
            assertTrue(second.closed.await(5, TimeUnit.SECONDS))
        }
    }

    @Test
    fun secondImportReturnsBusyWhileFirstIsRunning() {
        val engine = engine(manager(), timeoutMillis = 100)
        val firstLatch = CountDownLatch(1)
        engine.start(FakeSource(length = 100, readDelayMillis = 500)) { firstLatch.countDown() }
        val second = await(engine, FakeSource(length = 1))
        assertFailure(second, SharedImagePolicy.ERROR_BUSY)
        assertTrue(firstLatch.await(2, TimeUnit.SECONDS))
    }

    @Test
    fun nonContentUriIsRejectedWithoutOpening() {
        val source = FakeSource(length = 1, scheme = "file")
        assertFailure(run(source), SharedImagePolicy.ERROR_UNSUPPORTED_URI)
        assertEquals(0, source.openCount.get())
    }

    @Test
    fun missingIntentImageMimeIsRejected() {
        val source = FakeSource(length = 1, intentMimeType = null)
        assertFailure(run(source), SharedImagePolicy.ERROR_INVALID_IMAGE)
    }

    @Test
    fun nonImageIntentMimeIsRejected() {
        val source = FakeSource(length = 1, intentMimeType = "text/plain")
        assertFailure(run(source), SharedImagePolicy.ERROR_INVALID_IMAGE)
    }

    @Test
    fun resolverMimeCamouflageIsRejected() {
        val source = FakeSource(length = 1, resolvedMimeType = "text/html")
        assertFailure(run(source), SharedImagePolicy.ERROR_INVALID_IMAGE)
        assertEquals(0, source.openCount.get())
    }

    @Test
    fun fixedProductionTimeoutIsFifteenSeconds() {
        assertEquals(15_000L, SharedImagePolicy.IMPORT_TIMEOUT_MS)
    }

    private fun run(
        source: FakeSource,
        manager: SharedImageCacheManager = manager(),
        timeoutMillis: Long = 2_000,
    ): SharedImageImportResult = await(engine(manager, timeoutMillis), source)

    private fun await(
        engine: SharedImageImportEngine,
        source: SharedImageSource,
    ): SharedImageImportResult {
        val latch = CountDownLatch(1)
        var captured: SharedImageImportResult? = null
        engine.start(source) {
            captured = it
            latch.countDown()
        }
        assertTrue("import callback timed out", latch.await(5, TimeUnit.SECONDS))
        assertNotNull(captured)
        return captured!!
    }

    private fun manager(): SharedImageCacheManager =
        SharedImageCacheManager(temporaryFolder.newFolder())

    private fun engine(
        manager: SharedImageCacheManager,
        timeoutMillis: Long,
    ): SharedImageImportEngine = SharedImageImportEngine(
        manager,
        SharedImageValidator { it.length() > 0 },
        timeoutMillis = timeoutMillis,
    ).also(engines::add)

    private fun assertSuccess(result: SharedImageImportResult) {
        assertTrue(result is SharedImageImportResult.Success)
        val file = java.io.File((result as SharedImageImportResult.Success).path)
        assertTrue(file.isFile)
        assertTrue(file.name.endsWith(".img"))
    }

    private fun assertFailure(result: SharedImageImportResult, expectedCode: String) {
        assertTrue(result is SharedImageImportResult.Failure)
        assertEquals(expectedCode, (result as SharedImageImportResult.Failure).code)
    }

    private class FakeSource(
        private val length: Long,
        private val reportedSize: Long? = null,
        private val failAfter: Long = -1,
        private val readDelayMillis: Long = 0,
        private val metadataDelayMillis: Long = 0,
        override val scheme: String? = "content",
        override val intentMimeType: String? = "image/png",
        private val resolvedMimeType: String? = "image/png",
    ) : SharedImageSource {
        val openCount = AtomicInteger()

        @Volatile
        var cancelled = false

        @Volatile
        var closed = false

        @Volatile
        var streamClosed = false

        @Volatile
        var openedOnThread: String? = null

        override fun resolveMimeType(): String? = resolvedMimeType

        override fun resolveMetadataSize(): Long? {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(metadataDelayMillis)
            while (System.nanoTime() < deadline) {
                try {
                    Thread.sleep(10)
                } catch (_: InterruptedException) {
                    // Models a provider call that does not honor interruption.
                }
            }
            return reportedSize
        }

        override fun openStream(): InputStream {
            openCount.incrementAndGet()
            openedOnThread = Thread.currentThread().name
            return GeneratedInputStream(
                length,
                failAfter,
                readDelayMillis,
                onClose = { streamClosed = true },
            )
        }

        override fun cancel() {
            cancelled = true
            close()
        }

        override fun close() {
            closed = true
        }
    }

    private class NonCooperativeSource : SharedImageSource {
        private val released = AtomicBoolean(false)
        val closed = CountDownLatch(1)

        override val scheme: String = "content"
        override val intentMimeType: String = "image/png"

        override fun resolveMimeType(): String = "image/png"

        override fun resolveMetadataSize(): Long {
            while (!released.get()) {
                try {
                    Thread.sleep(10)
                } catch (_: InterruptedException) {
                    // Models a provider that deliberately ignores interruption.
                }
            }
            return 1
        }

        override fun openStream(): InputStream = java.io.ByteArrayInputStream(byteArrayOf(1))

        override fun cancel() = Unit

        override fun close() {
            closed.countDown()
        }

        fun release() {
            released.set(true)
        }
    }

    private class GeneratedInputStream(
        private val length: Long,
        private val failAfter: Long,
        private val delayMillis: Long,
        private val onClose: () -> Unit,
    ) : InputStream() {
        private var position = 0L

        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(buffer: ByteArray, offset: Int, count: Int): Int {
            if (failAfter >= 0 && position >= failAfter) throw IOException("synthetic read failure")
            if (position >= length) return -1
            if (delayMillis > 0) Thread.sleep(delayMillis)
            val read = minOf(count.toLong(), length - position).toInt()
            for (index in 0 until read) buffer[offset + index] = (position + index).toByte()
            position += read
            return read
        }

        override fun close() {
            onClose()
            super.close()
        }
    }
}
