package com.sanctum.vault

import android.graphics.BitmapFactory
import java.io.EOFException
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.CRC32

fun interface SharedImageValidator {
    fun isValid(file: File): Boolean
}

class PlatformSharedImageValidator : SharedImageValidator {
    override fun isValid(file: File): Boolean {
        if (!file.isFile || file.length() == 0L) return false
        if (!ImageStructureValidator.isStructurallyValid(file)) return false

        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, options)
        val width = options.outWidth
        val height = options.outHeight
        if (width <= 0 || height <= 0) return false
        if (width > SharedImagePolicy.MAX_WIDTH || height > SharedImagePolicy.MAX_HEIGHT) {
            return false
        }
        return width.toLong() * height.toLong() <= SharedImagePolicy.MAX_PIXELS
    }
}

internal object ImageStructureValidator {
    private val pngSignature = byteArrayOf(
        0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    )

    fun isStructurallyValid(file: File): Boolean = try {
        RandomAccessFile(file, "r").use { input ->
            when {
                hasPrefix(input, pngSignature) -> validatePng(input)
                hasPrefix(input, byteArrayOf(0xff.toByte(), 0xd8.toByte())) -> validateJpeg(input)
                else -> true
            }
        }
    } catch (_: Exception) {
        false
    }

    private fun validatePng(input: RandomAccessFile): Boolean {
        input.seek(pngSignature.size.toLong())
        var firstChunk = true
        var hasImageData = false
        var hasEnd = false
        val buffer = ByteArray(SharedImagePolicy.COPY_BUFFER_BYTES)

        while (input.filePointer < input.length()) {
            val dataLength = input.readUnsignedInt()
            if (dataLength > Int.MAX_VALUE.toLong()) return false
            val type = ByteArray(4)
            input.readFully(type)
            val typeName = type.toString(Charsets.US_ASCII)
            if (firstChunk && (typeName != "IHDR" || dataLength != 13L)) return false
            if (typeName == "IHDR" && !firstChunk) return false
            if (typeName == "IEND" && dataLength != 0L) return false

            val crc = CRC32().apply { update(type) }
            var remaining = dataLength
            while (remaining > 0L) {
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read < 0) throw EOFException()
                crc.update(buffer, 0, read)
                remaining -= read
            }
            if (input.readUnsignedInt() != crc.value) return false

            when (typeName) {
                "IDAT" -> hasImageData = true
                "IEND" -> {
                    hasEnd = true
                    break
                }
            }
            firstChunk = false
        }
        return hasImageData && hasEnd && input.filePointer == input.length()
    }

    private fun validateJpeg(input: RandomAccessFile): Boolean {
        input.seek(2L)
        var hasDimensions = false
        var hasScan = false
        var insideScan = false
        while (input.filePointer < input.length()) {
            val marker = if (insideScan) readScanMarker(input) else readMarker(input)
            marker ?: return false
            when (marker) {
                0xd8 -> return false
                0xd9 -> {
                    return hasDimensions && hasScan && input.filePointer == input.length()
                }
                0xda -> {
                    skipSegment(input)
                    hasScan = true
                    insideScan = true
                }
                in 0xd0..0xd7, 0x01 -> Unit
                else -> {
                    insideScan = false
                    val segmentLength = input.readUnsignedShort()
                    if (segmentLength < 2) return false
                    if (isStartOfFrame(marker)) {
                        if (segmentLength < 8) return false
                        input.readUnsignedByte()
                        val height = input.readUnsignedShort()
                        val width = input.readUnsignedShort()
                        if (width == 0 || height == 0) return false
                        hasDimensions = true
                        skipFully(input, (segmentLength - 7).toLong())
                    } else {
                        skipFully(input, (segmentLength - 2).toLong())
                    }
                }
            }
        }
        return false
    }

    private fun readScanMarker(input: RandomAccessFile): Int? {
        while (input.filePointer < input.length()) {
            if (input.readUnsignedByte() != 0xff) continue
            var marker = input.readUnsignedByte()
            while (marker == 0xff) marker = input.readUnsignedByte()
            when (marker) {
                0x00, in 0xd0..0xd7, 0x01 -> Unit
                else -> return marker
            }
        }
        return null
    }

    private fun readMarker(input: RandomAccessFile): Int? {
        if (input.filePointer >= input.length() || input.readUnsignedByte() != 0xff) return null
        var marker = input.readUnsignedByte()
        while (marker == 0xff) marker = input.readUnsignedByte()
        return marker
    }

    private fun skipSegment(input: RandomAccessFile) {
        val length = input.readUnsignedShort()
        if (length < 2) throw EOFException()
        skipFully(input, (length - 2).toLong())
    }

    private fun skipFully(input: RandomAccessFile, count: Long) {
        if (count < 0 || input.filePointer + count > input.length()) throw EOFException()
        input.seek(input.filePointer + count)
    }

    private fun isStartOfFrame(marker: Int): Boolean = marker in setOf(
        0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
        0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
    )

    private fun hasPrefix(input: RandomAccessFile, prefix: ByteArray): Boolean {
        if (input.length() < prefix.size) return false
        input.seek(0L)
        return ByteArray(prefix.size).also(input::readFully).contentEquals(prefix)
    }

    private fun RandomAccessFile.readUnsignedInt(): Long = readInt().toLong() and 0xffffffffL
}
