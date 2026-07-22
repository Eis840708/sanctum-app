package com.sanctum.vault

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.system.Os
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream

@RunWith(AndroidJUnit4::class)
class SharedImageSecurityInstrumentedTest {
    private val targetContext = InstrumentationRegistry.getInstrumentation().targetContext
    private val providerAuthority =
        InstrumentationRegistry.getInstrumentation().context.packageName + ".hostile"
    private lateinit var importer: SharedImageImporter
    private lateinit var cacheManager: SharedImageCacheManager

    @Before
    fun setUp() {
        cacheManager = SharedImageCacheManager(targetContext.cacheDir)
        clearOwnedCache()
        importer = SharedImageImporter(targetContext)
    }

    @After
    fun tearDown() {
        importer.close()
        clearOwnedCache()
    }

    @Test
    fun coldStartShareRetainsImageUntilFlutterCanConsumeIt() {
        val uri = Uri.parse("content://$providerAuthority/valid-png")
        val intent = Intent(targetContext, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        ActivityScenario.launch<MainActivity>(intent).use {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (cacheManager.countOwnedFiles(".img") == 0 && System.nanoTime() < deadline) {
                Thread.sleep(50)
            }
            assertEquals(1, cacheManager.countOwnedFiles(".img"))
            assertEquals(0, cacheManager.countOwnedFiles(".partial"))
        }
    }

    @Test
    fun providerPngIsImportedAndReleased() {
        val success = assertSuccess(importFromProvider("valid-png"))
        assertTrue(File(success.path).isFile)
        assertTrue(release(success.path))
        assertEquals(0, cacheManager.countOwnedFiles(".img"))
    }

    @Test
    fun startupCleanupFinishesBeforeFirstImport() {
        val stalePartial = cacheManager.createPartialFile().apply { writeText("stale") }

        importer.cleanupOnStartup()
        val success = assertSuccess(importFromProvider("valid-png"))

        assertFalse(stalePartial.exists())
        assertEquals(0, cacheManager.countOwnedFiles(".partial"))
        assertTrue(release(success.path))
        assertNoOwnedCacheFiles()
    }

    @Test
    fun startupCleanupRemovesExpiredOwnedImageOnly() {
        val partial = cacheManager.createPartialFile().apply { writeText("expired") }
        val expired = cacheManager.commitPartial(partial)
        expired.setLastModified(
            System.currentTimeMillis() - SharedImagePolicy.CACHE_EXPIRY_MS - 1_000,
        )
        val unrelated = File(targetContext.cacheDir, "unrelated-cache-file").apply {
            writeText("keep")
        }

        importer.cleanupOnStartup()
        val success = assertSuccess(importFromProvider("valid-png"))

        assertFalse(expired.exists())
        assertTrue(unrelated.exists())
        assertTrue(release(success.path))
        unrelated.delete()
        assertNoOwnedCacheFiles()
    }

    @Test
    fun rawProviderContractSupportsValidationCommitAndRelease() {
        val uri = Uri.parse("content://$providerAuthority/valid-png")
        val partial = cacheManager.createPartialFile()
        val descriptor = requireNotNull(
            targetContext.contentResolver.openAssetFileDescriptor(
                uri,
                "r",
                android.os.CancellationSignal(),
            ),
        )
        descriptor.use {
            it.createInputStream().use { input ->
                partial.outputStream().use { output -> input.copyTo(output) }
            }
        }

        assertTrue(partial.length() > 0)
        assertTrue(PlatformSharedImageValidator().isValid(partial))
        val delivered = cacheManager.commitPartial(partial)
        assertTrue(cacheManager.releaseDelivered(delivered.absolutePath))
    }

    @Test
    fun providerJpegIsImported() {
        assertSuccess(importFromProvider("valid-jpeg"))
    }

    @Test
    fun exactByteCapProviderImageIsAccepted() {
        val success = assertSuccess(importFromProvider("exact-limit", waitSeconds = 20))

        assertEquals(SharedImagePolicy.MAX_STREAM_BYTES, File(success.path).length())
        assertTrue(release(success.path))
        assertNoOwnedCacheFiles()
    }

    @Test
    fun lyingProviderCannotBypassActualByteCap() {
        assertFailure(importFromProvider("lying-size"), SharedImagePolicy.ERROR_TOO_LARGE)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun unknownSizeProviderCannotBypassActualByteCap() {
        assertFailure(importFromProvider("unknown-size"), SharedImagePolicy.ERROR_TOO_LARGE)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun resolverMimeCamouflageIsRejected() {
        assertFailure(
            importFromProvider("mime-camouflage"),
            SharedImagePolicy.ERROR_INVALID_IMAGE,
        )
        assertNoOwnedCacheFiles()
    }

    @Test
    fun textPayloadClaimingImageMimeIsRejected() {
        assertFailure(importFromProvider("text"), SharedImagePolicy.ERROR_INVALID_IMAGE)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun truncatedImageIsRejectedAndPartialIsRemoved() {
        assertFailure(importFromProvider("truncated"), SharedImagePolicy.ERROR_INVALID_IMAGE)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun providerReadErrorIsStableAndPartialIsRemoved() {
        assertFailure(importFromProvider("read-error"), SharedImagePolicy.ERROR_UNAVAILABLE)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun hostileSlowProviderTimesOutAtProductionDeadline() {
        val started = System.nanoTime()
        assertFailure(importFromProvider("slow", waitSeconds = 20), SharedImagePolicy.ERROR_TIMEOUT)
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertTrue("timeout fired too early: $elapsedMillis ms", elapsedMillis >= 14_000)
        assertTrue("timeout fired too late: $elapsedMillis ms", elapsedMillis < 19_000)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun secondProviderShareIsBusyWhileFirstIsRunning() {
        val firstLatch = CountDownLatch(1)
        val secondLatch = CountDownLatch(1)
        var first: SharedImageImportResult? = null
        var second: SharedImageImportResult? = null

        importer.start(
            Uri.parse("content://$providerAuthority/slow"),
            "image/png",
        ) {
            first = it
            firstLatch.countDown()
        }
        importer.start(
            Uri.parse("content://$providerAuthority/valid-png"),
            "image/png",
        ) {
            second = it
            secondLatch.countDown()
        }

        assertTrue(secondLatch.await(5, TimeUnit.SECONDS))
        assertFailure(requireNotNull(second), SharedImagePolicy.ERROR_BUSY)
        assertTrue(firstLatch.await(20, TimeUnit.SECONDS))
        assertFailure(requireNotNull(first), SharedImagePolicy.ERROR_TIMEOUT)
        assertNoOwnedCacheFiles()
    }

    @Test
    fun twentySequentialSharesLeaveNoCacheFilesAfterRelease() {
        repeat(20) {
            val success = assertSuccess(importFromProvider("valid-png"))
            assertTrue(release(success.path))
        }
        assertNoOwnedCacheFiles()
    }

    @Test
    fun platformValidatorAcceptsRealPngAndJpeg() {
        assertTrue(PlatformSharedImageValidator().isValid(bitmapFile("valid.png", Bitmap.CompressFormat.PNG)))
        assertTrue(
            PlatformSharedImageValidator().isValid(bitmapFile("valid.jpg", Bitmap.CompressFormat.JPEG)),
        )
    }

    @Test
    fun platformValidatorRejectsZeroAndOversizedDimensions() {
        val validator = PlatformSharedImageValidator()
        assertFalse(validator.isValid(pngHeaderFile("zero.png", 0, 1)))
        assertFalse(
            validator.isValid(
                pngHeaderFile("wide.png", SharedImagePolicy.MAX_WIDTH + 1, 1),
            ),
        )
        assertFalse(
            validator.isValid(
                pngHeaderFile("tall.png", 1, SharedImagePolicy.MAX_HEIGHT + 1),
            ),
        )
        assertFalse(validator.isValid(pngHeaderFile("pixels.png", 8_000, 6_000)))
    }

    @Test
    fun releaseRejectsSymlinkEvenWithOwnedName() {
        cacheManager.sharedDirectory.mkdirs()
        val outside = File(targetContext.cacheDir, "outside-share-test").apply { writeText("keep") }
        val link = File(cacheManager.sharedDirectory, "${UUID.randomUUID()}.img")
        Os.symlink(outside.absolutePath, link.absolutePath)

        assertFalse(cacheManager.releaseDelivered(link.absolutePath))
        assertTrue(outside.exists())

        link.delete()
        outside.delete()
    }

    private fun importFromProvider(
        path: String,
        waitSeconds: Long = 10,
    ): SharedImageImportResult {
        val latch = CountDownLatch(1)
        var captured: SharedImageImportResult? = null
        importer.start(Uri.parse("content://$providerAuthority/$path"), "image/png") {
            captured = it
            latch.countDown()
        }
        assertTrue("provider import did not complete", latch.await(waitSeconds, TimeUnit.SECONDS))
        return requireNotNull(captured)
    }

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

    private fun bitmapFile(name: String, format: Bitmap.CompressFormat): File {
        val file = File(targetContext.cacheDir, name)
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        file.outputStream().use { bitmap.compress(format, 100, it) }
        bitmap.recycle()
        return file
    }

    private fun pngHeaderFile(name: String, width: Int, height: Int): File {
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
        val header = ByteArrayOutputStream().also {
            DataOutputStream(it).use { data ->
                data.writeInt(width)
                data.writeInt(height)
                data.writeByte(8)
                data.writeByte(6)
                data.writeByte(0)
                data.writeByte(0)
                data.writeByte(0)
            }
        }.toByteArray()
        writeChunk(output, "IHDR", header)
        val imageData = ByteArrayOutputStream().also {
            DeflaterOutputStream(it).use { deflater ->
                deflater.write(byteArrayOf(0, 0, 0, 0, 0))
            }
        }.toByteArray()
        writeChunk(output, "IDAT", imageData)
        writeChunk(output, "IEND", byteArrayOf())
        return File(targetContext.cacheDir, name).apply { writeBytes(output.toByteArray()) }
    }

    private fun writeChunk(output: ByteArrayOutputStream, type: String, data: ByteArray) {
        DataOutputStream(output).writeInt(data.size)
        val typeBytes = type.toByteArray(Charsets.US_ASCII)
        output.write(typeBytes)
        output.write(data)
        val crc = CRC32().apply {
            update(typeBytes)
            update(data)
        }
        DataOutputStream(output).writeInt(crc.value.toInt())
    }
}




