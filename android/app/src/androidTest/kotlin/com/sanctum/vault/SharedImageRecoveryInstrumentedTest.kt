package com.sanctum.vault

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class SharedImageRecoveryInstrumentedTest {
    private val targetContext = InstrumentationRegistry.getInstrumentation().targetContext
    private val providerAuthority =
        InstrumentationRegistry.getInstrumentation().context.packageName + ".hostile"
    private lateinit var importer: SharedImageImporter
    private lateinit var cacheManager: SharedImageCacheManager

    @Before
    fun setUp() {
        cacheManager = SharedImageCacheManager(targetContext.cacheDir)
        clearOwnedCache()
        providerControl("reset")
        importer = SharedImageImporter(targetContext)
        importer.cleanupOnStartup()
    }

    @After
    fun tearDown() {
        providerControl("release-never")
        importer.close()
        clearOwnedCache()
    }

    @Test
    fun permanentProviderTimeoutIsReclaimedAndNextValidSourceSucceeds() {
        val firstResults = CopyOnWriteArrayList<SharedImageImportResult>()
        val secondResults = CopyOnWriteArrayList<SharedImageImportResult>()
        val firstCount = AtomicInteger()
        val secondCount = AtomicInteger()
        val firstLatch = CountDownLatch(1)
        val secondLatch = CountDownLatch(1)

        importer.start(
            Uri.parse("content://$providerAuthority/never"),
            "image/png",
        ) {
            firstResults += it
            firstCount.incrementAndGet()
            firstLatch.countDown()
        }
        assertTrue("permanent provider did not time out", firstLatch.await(20, TimeUnit.SECONDS))
        assertFailure(firstResults.single(), SharedImagePolicy.ERROR_TIMEOUT)

        importer.start(
            Uri.parse("content://$providerAuthority/valid-png"),
            "image/png",
        ) {
            secondResults += it
            secondCount.incrementAndGet()
            secondLatch.countDown()
        }
        assertTrue("recovery import did not complete", secondLatch.await(10, TimeUnit.SECONDS))
        val success = assertSuccess(secondResults.single())

        assertTrue(providerOpenCount("never") >= 1)
        assertTrue(providerOpenCount("valid-png") >= 1)
        assertEquals(1, firstCount.get())
        assertEquals(1, secondCount.get())
        assertTrue(release(success.path))
        val snapshot = importer.debugSnapshot()
        assertEquals(0, snapshot.activeWorkers)
        assertEquals(0, snapshot.recoveringWorkers)
        assertEquals(0, snapshot.queuedRequests)
        assertNoOwnedCacheFiles()

        providerControl("release-never")
        assertEquals(1, firstCount.get())
        assertEquals(1, secondCount.get())
        assertNoOwnedCacheFiles()
    }

    private fun providerControl(method: String) {
        val result = targetContext.contentResolver.call(
            Uri.parse("content://$providerAuthority/control"),
            method,
            null,
            null,
        )
        assertTrue(result?.getBoolean("ok") == true)
    }

    private fun providerOpenCount(path: String): Int =
        targetContext.contentResolver.call(
            Uri.parse("content://$providerAuthority/control"),
            "open-count",
            path,
            null,
        )?.getInt("count") ?: 0

    private fun release(path: String): Boolean {
        val latch = CountDownLatch(1)
        var released = false
        importer.release(path) {
            released = it
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        return released
    }

    private fun assertSuccess(result: SharedImageImportResult): SharedImageImportResult.Success {
        assertTrue("Expected success, got $result", result is SharedImageImportResult.Success)
        return result as SharedImageImportResult.Success
    }

    private fun assertFailure(result: SharedImageImportResult, code: String) {
        assertTrue(result is SharedImageImportResult.Failure)
        assertEquals(code, (result as SharedImageImportResult.Failure).code)
    }

    private fun assertNoOwnedCacheFiles() {
        assertEquals(0, cacheManager.countOwnedFiles(".partial"))
        assertEquals(0, cacheManager.countOwnedFiles(".img"))
    }

    private fun clearOwnedCache() {
        cacheManager.sharedDirectory.listFiles()?.forEach { file ->
            if (file.name.endsWith(".partial") || file.name.endsWith(".img")) file.delete()
        }
    }
}
