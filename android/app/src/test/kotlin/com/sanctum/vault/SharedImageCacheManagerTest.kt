package com.sanctum.vault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.UUID

class SharedImageCacheManagerTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun commitUsesAtomicSameDirectoryRename() {
        val manager = manager()
        val partial = manager.createPartialFile().apply { writeText("image") }
        val delivered = manager.commitPartial(partial)

        assertFalse(partial.exists())
        assertTrue(delivered.isFile)
        assertEquals(manager.sharedDirectory.canonicalFile, delivered.parentFile.canonicalFile)
    }

    @Test
    fun releaseDeletesOnlyOwnedDeliveredFile() {
        val manager = manager()
        val delivered = manager.commitPartial(manager.createPartialFile().apply { writeText("image") })

        assertTrue(manager.releaseDelivered(delivered.absolutePath))
        assertFalse(delivered.exists())
    }

    @Test
    fun releaseRejectsTraversalPath() {
        val root = temporaryFolder.newFolder()
        val manager = SharedImageCacheManager(root)
        val outside = File(root, "${UUID.randomUUID()}.img").apply { writeText("outside") }
        val traversal = File(manager.sharedDirectory, "..${File.separator}${outside.name}")

        assertFalse(manager.releaseDelivered(traversal.path))
        assertTrue(outside.exists())
    }

    @Test
    fun releaseRejectsMalformedName() {
        val manager = manager()
        val malformed = File(manager.sharedDirectory, "shared_image.img").apply {
            parentFile.mkdirs()
            writeText("keep")
        }

        assertFalse(manager.releaseDelivered(malformed.absolutePath))
        assertTrue(malformed.exists())
    }

    @Test
    fun startupDeletesAllPartialFiles() {
        val manager = manager()
        manager.createPartialFile().writeText("one")
        manager.createPartialFile().writeText("two")

        val result = manager.cleanupOnStartup()

        assertEquals(2, result.partialDeleted)
        assertEquals(0, manager.countOwnedFiles(".partial"))
    }

    @Test
    fun startupDeletesDeliveredFilesOlderThanTwentyFourHours() {
        val now = 2 * SharedImagePolicy.CACHE_EXPIRY_MS
        val manager = manager(now)
        val delivered = manager.commitPartial(manager.createPartialFile().apply { writeText("old") })
        delivered.setLastModified(now - SharedImagePolicy.CACHE_EXPIRY_MS - 1)

        val result = manager.cleanupOnStartup()

        assertEquals(1, result.expiredDeleted)
        assertFalse(delivered.exists())
    }

    @Test
    fun exactlyTwentyFourHoursOldIsPreserved() {
        val now = 2 * SharedImagePolicy.CACHE_EXPIRY_MS
        val manager = manager(now)
        val delivered = manager.commitPartial(manager.createPartialFile().apply { writeText("edge") })
        delivered.setLastModified(now - SharedImagePolicy.CACHE_EXPIRY_MS)

        manager.cleanupOnStartup()

        assertTrue(delivered.exists())
    }

    @Test
    fun startupNeverDeletesOtherCacheFiles() {
        val root = temporaryFolder.newFolder()
        val manager = SharedImageCacheManager(root, nowMillis = { Long.MAX_VALUE / 2 })
        val otherCache = File(root, "other_feature.cache").apply { writeText("keep") }
        val malformedInside = File(manager.sharedDirectory, "not-owned.img").apply {
            parentFile.mkdirs()
            writeText("keep")
        }

        manager.cleanupOnStartup()

        assertTrue(otherCache.exists())
        assertTrue(malformedInside.exists())
    }

    private fun manager(now: Long = System.currentTimeMillis()): SharedImageCacheManager =
        SharedImageCacheManager(temporaryFolder.newFolder(), nowMillis = { now })
}
