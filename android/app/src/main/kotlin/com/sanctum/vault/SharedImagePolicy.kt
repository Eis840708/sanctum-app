package com.sanctum.vault

object SharedImagePolicy {
    const val MAX_STREAM_BYTES = 10L * 1024L * 1024L
    const val IMPORT_TIMEOUT_MS = 15_000L
    const val MAX_WIDTH = 12_000
    const val MAX_HEIGHT = 12_000
    const val MAX_PIXELS = 40_000_000L
    const val CACHE_DIRECTORY = "sanctum_shared"
    const val CACHE_EXPIRY_MS = 24L * 60L * 60L * 1000L
    const val COPY_BUFFER_BYTES = 8 * 1024

    const val ERROR_TOO_LARGE = "too_large"
    const val ERROR_TIMEOUT = "timeout"
    const val ERROR_INVALID_IMAGE = "invalid_image"
    const val ERROR_UNSUPPORTED_URI = "unsupported_uri"
    const val ERROR_BUSY = "busy"
    const val ERROR_UNAVAILABLE = "unavailable"
}
