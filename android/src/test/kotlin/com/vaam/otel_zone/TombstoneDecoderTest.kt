package com.vaam.otel_zone

import java.io.ByteArrayOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Decodes `tombstone/native-crash.bin`, a binary fixture that was **not**
 * written by this module's own code.
 *
 * It is produced by `protoc` from `tombstone/native-crash.textproto`, using
 * `tombstone/tombstone-subset.proto` — the field numbers of AOSP's
 * `tombstone.proto` for the messages the decoder reads, plus a few fields it
 * must skip. Regenerate it from `android/src/test/resources/tombstone` with:
 *
 *     protoc --encode=Tombstone tombstone-subset.proto \
 *         < native-crash.textproto > native-crash.bin
 *
 * An encoder that shares the decoder's author's reading of the schema would
 * agree with it by construction; protoc does not. The hand-built messages
 * below cover what a well-formed tombstone never contains: truncation, lying
 * lengths, groups and stack-overflow depth.
 */
class TombstoneDecoderTest {

    private fun fixture(): ByteArray =
        checkNotNull(javaClass.getResourceAsStream("/tombstone/native-crash.bin")).use { it.readBytes() }

    @Test
    fun `the signal and the abort message are read from a protoc-built tombstone`() {
        val tombstone = assertNotNull(TombstoneDecoder.decode(fixture()))

        assertEquals(11, tombstone.signalNumber)
        assertEquals("SIGSEGV", tombstone.signalName)
        assertEquals(1, tombstone.signalCode)
        assertEquals("SEGV_MAPERR", tombstone.signalCodeName)
        assertEquals(0x10L, tombstone.faultAddress)
        assertEquals(
            "Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x10",
            tombstone.abortMessage,
        )
    }

    @Test
    fun `only the crashing thread's frames are returned, with pc, build id, function and file`() {
        val tombstone = assertNotNull(TombstoneDecoder.decode(fixture()))

        assertEquals(4350, tombstone.crashingThreadId)
        assertEquals("1.ui", tombstone.crashingThreadName)
        assertEquals(3, tombstone.frames.size)

        val top = tombstone.frames[0]
        assertEquals(0x7abc001234L, top.pc)
        assertEquals(0x1234L, top.relativePc)
        assertEquals("crash_now", top.functionName)
        assertEquals(24L, top.functionOffset)
        assertEquals("/data/app/~~x7Yk/com.example.app-abc==/lib/arm64/libapp.so", top.fileName)
        assertEquals("0123456789abcdef0123456789abcdef01234567", top.buildId)

        // A frame with nothing but an address is still a frame.
        val bare = tombstone.frames[2]
        assertNull(bare.functionName)
        assertNull(bare.fileName)
        assertNull(bare.buildId)
        assertEquals(0x7abc000009L, bare.pc)
    }

    @Test
    fun `the main thread's frames are not mixed into the crashing thread's`() {
        val tombstone = assertNotNull(TombstoneDecoder.decode(fixture()))

        assertTrue(tombstone.frames.none { it.functionName == "epoll_wait" })
    }

    @Test
    fun `frames format like a tombstone's own backtrace`() {
        val tombstone = assertNotNull(TombstoneDecoder.decode(fixture()))

        val lines = TombstoneDecoder.format(tombstone.frames).lines()

        assertEquals(
            "#00 pc 0x1234  /data/app/~~x7Yk/com.example.app-abc==/lib/arm64/libapp.so " +
                "(crash_now+24) (BuildId: 0123456789abcdef0123456789abcdef01234567)",
            lines[0],
        )
        assertEquals("#02 pc 0x9", lines[2])
    }

    @Test
    fun `a tombstone cut short still yields what came before the cut`() {
        val bytes = fixture()

        // Cut inside the last thread's frames; the signal came first.
        val tombstone = assertNotNull(TombstoneDecoder.decode(bytes.copyOf(bytes.size - 20)))

        assertEquals("SIGSEGV", tombstone.signalName)
        assertTrue(tombstone.abortMessage.orEmpty().startsWith("Fatal signal 11"))
    }

    @Test
    fun `bytes that are not a tombstone decode to null rather than throwing`() {
        assertNull(TombstoneDecoder.decode(ByteArray(0)))
        assertNull(TombstoneDecoder.decode("this is a text trace, not a proto".toByteArray()))
        assertNull(TombstoneDecoder.decode(ByteArray(64) { 0xff.toByte() }))
    }

    @Test
    fun `a length that lies about its size stops the scan instead of reading past it`() {
        // signal_info claiming 200 bytes with 2 present.
        val lying = byteArrayOf(0x52, 0xc8.toByte(), 0x01, 0x08, 0x0b)

        assertNull(TombstoneDecoder.decode(lying))
    }

    @Test
    fun `a stack-overflow depth is capped and the cap is stated`() {
        val frames = (0 until 500).map { Proto.message(4) { varint(1, it.toLong()) } }
        val thread = Proto.message { varint(1, 7); frames.forEach { raw(it) } }
        val tombstone = Proto.message {
            varint(6, 7)
            message(16) { varint(1, 7); bytes(2, thread) }
        }

        val decoded = assertNotNull(TombstoneDecoder.decode(tombstone))

        assertEquals(TombstoneDecoder.MAX_FRAMES, decoded.frames.size)
        assertEquals(500 - TombstoneDecoder.MAX_FRAMES, decoded.droppedFrames)
        assertTrue(TombstoneDecoder.format(decoded.frames, decoded.droppedFrames).contains("more frames"))
    }

    @Test
    fun `an abort message is bounded`() {
        val tombstone = Proto.message { text(14, "x".repeat(50_000)) }

        val decoded = assertNotNull(TombstoneDecoder.decode(tombstone))

        assertEquals(TombstoneDecoder.MAX_TEXT_CHARS, decoded.abortMessage?.length)
    }

    @Test
    fun `an unknown thread id yields the signal with no frames`() {
        val tombstone = Proto.message {
            varint(6, 99)
            message(10) { text(2, "SIGABRT") }
        }

        val decoded = assertNotNull(TombstoneDecoder.decode(tombstone))

        assertEquals("SIGABRT", decoded.signalName)
        assertTrue(decoded.frames.isEmpty())
    }

    @Test
    fun `a group wire type is rejected without throwing`() {
        // field 1, wire type 3 (start group)
        assertNull(TombstoneDecoder.decode(byteArrayOf(0x0b, 0x0c)))
    }

    /** A just-enough protobuf writer for the shapes protoc never emits. */
    private object Proto {
        fun message(field: Int? = null, build: Writer.() -> Unit): ByteArray {
            val writer = Writer().apply(build)
            val body = writer.toByteArray()
            if (field == null) return body
            return Writer().apply { bytes(field, body) }.toByteArray()
        }
    }

    private class Writer {
        private val out = ByteArrayOutputStream()

        fun toByteArray(): ByteArray = out.toByteArray()

        fun raw(bytes: ByteArray) = out.write(bytes)

        fun varint(field: Int, value: Long) {
            writeVarint(((field shl 3) or 0).toLong())
            writeVarint(value)
        }

        fun bytes(field: Int, value: ByteArray) {
            writeVarint(((field shl 3) or 2).toLong())
            writeVarint(value.size.toLong())
            out.write(value)
        }

        fun text(field: Int, value: String) = bytes(field, value.toByteArray())

        fun message(field: Int, build: Writer.() -> Unit) =
            bytes(field, Writer().apply(build).toByteArray())

        private fun writeVarint(value: Long) {
            var v = value
            while (v and 0x7fL.inv() != 0L) {
                out.write(((v and 0x7f) or 0x80).toInt())
                v = v ushr 7
            }
            out.write(v.toInt())
        }
    }
}
