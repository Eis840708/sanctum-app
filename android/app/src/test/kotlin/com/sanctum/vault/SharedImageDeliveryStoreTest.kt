package com.sanctum.vault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedImageDeliveryStoreTest {
    @Test
    fun recreatedActivityTakesUnclaimedCommittedFileExactlyOnce() {
        val store = SharedImageDeliveryStore()
        val success = SharedImageImportResult.Success("committed.img")
        store.offer(success)

        assertNull(store.detach("old-owner"))
        val claimed = requireNotNull(store.claim("new-owner"))
        assertEquals(success, claimed.result)
        assertTrue(store.acknowledge("new-owner", claimed.id))
        assertNull(store.claim("third-owner"))
        assertFalse(store.hasPending())
    }

    @Test
    fun recreationAfterHandoffReleasesOldOwnershipInsteadOfRedelivering() {
        val store = SharedImageDeliveryStore()
        val success = SharedImageImportResult.Success("committed.img")
        val delivery = store.offer(success)
        assertEquals(delivery, store.claim("old-owner"))

        assertEquals(success, store.detach("old-owner"))
        assertNull(store.claim("new-owner"))
        assertFalse(store.hasPending())
    }

    @Test
    fun staleOwnerCannotAcknowledgeNewDelivery() {
        val store = SharedImageDeliveryStore()
        val first = store.offer(SharedImageImportResult.Failure("first"))
        store.claim("old-owner")
        assertTrue(store.acknowledge("old-owner", first.id))
        val second = store.offer(SharedImageImportResult.Success("second.img"))
        store.claim("new-owner")

        assertFalse(store.acknowledge("old-owner", first.id))
        assertTrue(store.hasPending())
        assertTrue(store.acknowledge("new-owner", second.id))
    }

    @Test
    fun twentyDeliveriesDoNotAccumulateOwnership() {
        val store = SharedImageDeliveryStore()
        repeat(20) { index ->
            val delivery = store.offer(SharedImageImportResult.Success("$index.img"))
            assertEquals(delivery, store.claim("owner-$index"))
            assertTrue(store.acknowledge("owner-$index", delivery.id))
        }
        assertFalse(store.hasPending())
    }
}
