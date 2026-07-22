package com.sanctum.vault

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream

class ImageStructureValidatorTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun completePngIsAccepted() {
        assertTrue(ImageStructureValidator.isStructurallyValid(write("valid.png", pngBytes())))
    }

    @Test
    fun pngWithCorruptCrcIsRejected() {
        val bytes = pngBytes().apply { this[size - 5] = (this[size - 5].toInt() xor 1).toByte() }
        assertFalse(ImageStructureValidator.isStructurallyValid(write("corrupt.png", bytes)))
    }

    @Test
    fun truncatedPngIsRejected() {
        val bytes = pngBytes()
        assertFalse(
            ImageStructureValidator.isStructurallyValid(
                write("truncated.png", bytes.copyOf(bytes.size - 4)),
            ),
        )
    }

    @Test
    fun progressiveJpegWithMultipleScansIsAccepted() {
        assertTrue(
            ImageStructureValidator.isStructurallyValid(
                write("progressive.jpg", progressiveJpegBytes()),
            ),
        )
    }

    private fun write(name: String, bytes: ByteArray): File =
        temporaryFolder.newFile(name).apply { writeBytes(bytes) }

    private fun pngBytes(): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
        val header = ByteArrayOutputStream().also {
            DataOutputStream(it).use { data ->
                data.writeInt(1)
                data.writeInt(1)
                data.writeByte(8)
                data.writeByte(6)
                data.writeByte(0)
                data.writeByte(0)
                data.writeByte(0)
            }
        }.toByteArray()
        writeChunk(output, "IHDR", header)
        val compressed = ByteArrayOutputStream().also {
            DeflaterOutputStream(it).use { deflater ->
                deflater.write(byteArrayOf(0, 0, 0, 0, 0))
            }
        }.toByteArray()
        writeChunk(output, "IDAT", compressed)
        writeChunk(output, "IEND", byteArrayOf())
        return output.toByteArray()
    }

    private fun progressiveJpegBytes(): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0xff.toByte(), 0xd8.toByte()))
        writeJpegSegment(
            output,
            0xc2,
            byteArrayOf(8, 0, 1, 0, 1, 1, 1, 0x11, 0),
        )
        writeJpegSegment(output, 0xda, byteArrayOf(1, 1, 0, 0, 0, 0))
        output.write(byteArrayOf(0x01, 0xff.toByte(), 0x00, 0x02))
        writeJpegSegment(output, 0xc4, byteArrayOf(0, 0))
        writeJpegSegment(output, 0xda, byteArrayOf(1, 1, 0, 1, 0, 0))
        output.write(byteArrayOf(0x03, 0xff.toByte(), 0xd0.toByte(), 0x04))
        output.write(byteArrayOf(0xff.toByte(), 0xd9.toByte()))
        return output.toByteArray()
    }

    private fun writeJpegSegment(
        output: ByteArrayOutputStream,
        marker: Int,
        data: ByteArray,
    ) {
        output.write(0xff)
        output.write(marker)
        DataOutputStream(output).writeShort(data.size + 2)
        output.write(data)
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
