package com.sanctum.vault

import java.io.File
import java.io.IOException
import java.util.UUID

class SharedImageCacheManager(
    cacheDir: File,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    val sharedDirectory = File(cacheDir, SharedImagePolicy.CACHE_DIRECTORY)

    fun createPartialFile(): File {
        repeat(8) {
            try {
                return createPartialFile(UUID.randomUUID().toString())
            } catch (_: IOException) {
                // Retry the vanishingly unlikely UUID collision.
            }
        }
        throw IOException("Unable to allocate shared-image cache file")
    }

    fun createPartialFile(cacheId: String): File {
        requireCacheId(cacheId)
        ensureDirectory()
        val candidate = File(sharedDirectory, "$cacheId.partial")
        if (!candidate.createNewFile()) {
            throw IOException("Unable to allocate shared-image cache file")
        }
        return candidate
    }

    fun commitPartial(partial: File): File {
        requireOwnedFile(partial, ".partial")
        val delivered = File(sharedDirectory, partial.name.removeSuffix(".partial") + ".img")
        if (delivered.exists() || !partial.renameTo(delivered)) {
            throw IOException("Unable to commit shared-image cache file")
        }
        return delivered
    }

    fun deletePartial(partial: File?): Boolean {
        if (partial == null || !isOwnedFile(partial, ".partial")) return false
        return !partial.exists() || partial.delete()
    }

    fun releaseDelivered(path: String?): Boolean {
        if (path.isNullOrBlank()) return false
        val file = File(path)
        if (!isOwnedFile(file, ".img")) return false
        return !file.exists() || file.delete()
    }

    fun deleteRequestArtifacts(cacheId: String): RequestCleanupResult {
        if (!CACHE_ID.matches(cacheId)) return RequestCleanupResult(0, 0)
        ensureDirectory()
        val partial = File(sharedDirectory, "$cacheId.partial")
        val delivered = File(sharedDirectory, "$cacheId.img")
        return RequestCleanupResult(
            partialDeleted = deleteOwnedIfPresent(partial, ".partial"),
            deliveredDeleted = deleteOwnedIfPresent(delivered, ".img"),
        )
    }

    fun cleanupOnStartup(): CleanupResult {
        ensureDirectory()
        val cutoff = nowMillis() - SharedImagePolicy.CACHE_EXPIRY_MS
        var partialDeleted = 0
        var expiredDeleted = 0

        sharedDirectory.listFiles()?.forEach { file ->
            when {
                isOwnedFile(file, ".partial") && file.delete() -> partialDeleted++
                isOwnedFile(file, ".img") && file.lastModified() < cutoff && file.delete() -> {
                    expiredDeleted++
                }
            }
        }
        return CleanupResult(partialDeleted, expiredDeleted)
    }

    fun countOwnedFiles(suffix: String): Int =
        sharedDirectory.listFiles()?.count { isOwnedFile(it, suffix) } ?: 0

    private fun ensureDirectory() {
        if (sharedDirectory.exists()) {
            if (!sharedDirectory.isDirectory) throw IOException("Shared-image cache is unavailable")
            return
        }
        if (!sharedDirectory.mkdirs() && !sharedDirectory.isDirectory) {
            throw IOException("Shared-image cache is unavailable")
        }
    }

    private fun requireOwnedFile(file: File, suffix: String) {
        if (!isOwnedFile(file, suffix)) throw IOException("Shared-image cache path rejected")
    }

    private fun requireCacheId(cacheId: String) {
        if (!CACHE_ID.matches(cacheId)) throw IOException("Shared-image cache ID rejected")
    }

    private fun deleteOwnedIfPresent(file: File, suffix: String): Int {
        if (!file.exists()) return 0
        return if (isOwnedFile(file, suffix) && file.delete()) 1 else 0
    }

    private fun isOwnedFile(file: File, suffix: String): Boolean {
        return try {
            if (!file.name.matches(OWNED_NAME) || !file.name.endsWith(suffix)) return false
            val absoluteRoot = sharedDirectory.absoluteFile
            val canonicalRoot = sharedDirectory.canonicalFile
            val absolute = file.absoluteFile
            val canonical = file.canonicalFile

            // The app data root itself can be an Android platform symlink
            // (/data/user/0 to /data/data). Validate both parent views so a
            // caller-supplied symlink or traversal segment is still rejected.
            absolute.parentFile == absoluteRoot &&
                canonical.parentFile == canonicalRoot &&
                absolute.name == canonical.name &&
                canonical.isFile
        } catch (_: IOException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    data class CleanupResult(
        val partialDeleted: Int,
        val expiredDeleted: Int,
    )

    data class RequestCleanupResult(
        val partialDeleted: Int,
        val deliveredDeleted: Int,
    )

    private companion object {
        val OWNED_NAME = Regex(
            "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(partial|img)$",
        )
        val CACHE_ID = Regex(
            "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        )
    }
}
