package com.sanctum.vault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.UUID

class SharedImageRequestCacheTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun requestCleanupRemovesOnlyItsPartialAndDeliveredArtifacts() {
        val manager = SharedImageCacheManager(temporaryFolder.newFolder())
        val oldId = UUID.randomUUID().toString()
        val newId = UUID.randomUUID().toString()
        val oldPartial = manager.createPartialFile(oldId).apply { writeText("old") }
        val oldDelivered = manager.commitPartial(oldPartial)
        val newPartial = manager.createPartialFile(newId).apply { writeText("new") }

        val result = manager.deleteRequestArtifacts(oldId)

        assertEquals(0, result.partialDeleted)
        assertEquals(1, result.deliveredDeleted)
        assertFalse(oldDelivered.exists())
        assertTrue(newPartial.exists())
    }

    @Test
    fun malformedRequestIdCannotAddressCache() {
        val manager = SharedImageCacheManager(temporaryFolder.newFolder())
        val partial = manager.createPartialFile().apply { writeText("keep") }

        val result = manager.deleteRequestArtifacts("../${UUID.randomUUID()}")

        assertEquals(0, result.partialDeleted)
        assertEquals(0, result.deliveredDeleted)
        assertTrue(partial.exists())
    }
}
