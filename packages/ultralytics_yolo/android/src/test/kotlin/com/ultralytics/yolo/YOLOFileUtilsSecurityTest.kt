package com.ultralytics.yolo

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.io.IOException

class YOLOFileUtilsSecurityTest {
    @Test
    fun boundedReaderAcceptsExactLimit() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        assertArrayEquals(
            bytes,
            YOLOFileUtils.readBytesWithLimit(ByteArrayInputStream(bytes), bytes.size),
        )
    }

    @Test
    fun boundedReaderRejectsOneByteOverLimit() {
        val bytes = ByteArray(17)
        assertThrows(IOException::class.java) {
            YOLOFileUtils.readBytesWithLimit(ByteArrayInputStream(bytes), 16)
        }
    }

    @Test
    fun oversizedOnnxMetadataLengthIsSkippedBeforeAllocation() {
        val bytes = mutableListOf<Byte>()
        bytes += 0x72.toByte() // ModelProto field 14, length-delimited.
        bytes += encodeVarint(Int.MAX_VALUE.toLong() + 1)

        val props = YOLOFileUtils.readOnnxMetadataProps(
            ByteArrayInputStream(bytes.toByteArray()),
        )

        assertTrue(props.isEmpty())
    }

    private fun encodeVarint(value: Long): List<Byte> {
        var remaining = value
        val result = mutableListOf<Byte>()
        while (true) {
            if (remaining and 0x7f.inv().toLong() == 0L) {
                result += remaining.toByte()
                return result
            }
            result += ((remaining and 0x7f) or 0x80).toByte()
            remaining = remaining ushr 7
        }
    }
}
