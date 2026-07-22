package com.sanctum.vault

import android.content.Context
import android.net.Uri

internal data class SharedImageDelivery(
    val id: Long,
    val result: SharedImageImportResult,
)

internal class SharedImageDeliveryStore {
    private var nextId = 0L
    private var pending: PendingDelivery? = null

    @Synchronized
    fun offer(result: SharedImageImportResult): SharedImageDelivery {
        check(pending == null) { "A shared image is already awaiting delivery" }
        val delivery = SharedImageDelivery(++nextId, result)
        pending = PendingDelivery(delivery)
        return delivery
    }

    @Synchronized
    fun claim(owner: String): SharedImageDelivery? {
        val current = pending ?: return null
        if (current.owner != null) return null
        current.owner = owner
        return current.delivery
    }

    @Synchronized
    fun consume(owner: String): SharedImageImportResult? {
        val current = pending ?: return null
        if (current.owner != null && current.owner != owner) return null
        pending = null
        return current.delivery.result
    }

    @Synchronized
    fun acknowledge(owner: String, deliveryId: Long): Boolean {
        val current = pending ?: return false
        if (current.owner != owner || current.delivery.id != deliveryId) return false
        pending = null
        return true
    }

    @Synchronized
    fun reject(owner: String, deliveryId: Long): Boolean {
        val current = pending ?: return false
        if (current.owner != owner || current.delivery.id != deliveryId) return false
        current.owner = null
        return true
    }

    @Synchronized
    fun detach(owner: String): SharedImageImportResult? {
        val current = pending ?: return null
        if (current.owner != owner) return null
        pending = null
        return current.delivery.result
    }

    @Synchronized
    fun hasPending(): Boolean = pending != null

    private data class PendingDelivery(
        val delivery: SharedImageDelivery,
        var owner: String? = null,
    )
}

internal object SharedImageRuntime {
    private val lock = Any()
    private val deliveries = SharedImageDeliveryStore()
    private var importer: SharedImageImporter? = null
    private var importing = false
    private var attachedOwner: String? = null
    private var ownerReady = false
    private var listener: ((SharedImageDelivery) -> Unit)? = null

    fun initialize(context: Context) {
        val created = synchronized(lock) {
            if (importer != null) return
            SharedImageImporter(context.applicationContext).also { importer = it }
        }
        created.cleanupOnStartup()
    }

    fun attach(
        owner: String,
        ready: Boolean,
        listener: (SharedImageDelivery) -> Unit,
    ) {
        var release: SharedImageImportResult? = null
        var dispatch: Pair<(SharedImageDelivery) -> Unit, SharedImageDelivery>? = null
        synchronized(lock) {
            attachedOwner?.takeIf { it != owner }?.let { release = deliveries.detach(it) }
            attachedOwner = owner
            ownerReady = ready
            this.listener = listener
            dispatch = claimForCurrentOwnerLocked()
        }
        releaseIfOwned(release)
        dispatch?.let { (callback, delivery) -> callback(delivery) }
    }

    fun setReady(owner: String) {
        val dispatch = synchronized(lock) {
            if (attachedOwner != owner) return
            ownerReady = true
            claimForCurrentOwnerLocked()
        }
        dispatch?.let { (callback, delivery) -> callback(delivery) }
    }

    fun detach(owner: String) {
        val release = synchronized(lock) {
            if (attachedOwner == owner) {
                attachedOwner = null
                ownerReady = false
                listener = null
            }
            deliveries.detach(owner)
        }
        releaseIfOwned(release)
    }

    fun start(uri: Uri, intentMimeType: String?): String? {
        val currentImporter: SharedImageImporter
        synchronized(lock) {
            if (importing || deliveries.hasPending()) return SharedImagePolicy.ERROR_BUSY
            importing = true
            currentImporter = checkNotNull(importer)
        }
        currentImporter.start(uri, intentMimeType, ::publish)
        return null
    }

    fun consume(owner: String): SharedImageImportResult? = synchronized(lock) {
        deliveries.consume(owner)
    }

    fun acknowledge(owner: String, deliveryId: Long) {
        synchronized(lock) { deliveries.acknowledge(owner, deliveryId) }
    }

    fun reject(owner: String, deliveryId: Long) {
        synchronized(lock) { deliveries.reject(owner, deliveryId) }
    }

    fun release(path: String?, callback: (Boolean) -> Unit) {
        synchronized(lock) { importer }?.release(path, callback) ?: callback(false)
    }

    fun isIdle(): Boolean = synchronized(lock) {
        !importing && !deliveries.hasPending()
    }

    private fun publish(result: SharedImageImportResult) {
        val dispatch = synchronized(lock) {
            importing = false
            deliveries.offer(result)
            claimForCurrentOwnerLocked()
        }
        dispatch?.let { (callback, delivery) -> callback(delivery) }
    }

    private fun claimForCurrentOwnerLocked(): Pair<(SharedImageDelivery) -> Unit, SharedImageDelivery>? {
        val owner = attachedOwner ?: return null
        if (!ownerReady) return null
        val callback = listener ?: return null
        val delivery = deliveries.claim(owner) ?: return null
        return callback to delivery
    }

    private fun releaseIfOwned(result: SharedImageImportResult?) {
        val path = (result as? SharedImageImportResult.Success)?.path ?: return
        synchronized(lock) { importer }?.release(path) { }
    }
}
