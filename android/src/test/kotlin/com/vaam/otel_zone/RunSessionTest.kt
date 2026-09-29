package com.vaam.otel_zone

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RunSessionTest {

    @Test
    fun `a session id survives the round trip through the summary`() {
        assertEquals(RunSession.id, RunSession.decode(RunSession.encode(RunSession.id)))
    }

    @Test
    fun `the id is stable within a process and fits the summary limit`() {
        assertEquals(RunSession.id, RunSession.id)
        assertTrue(RunSession.encode(RunSession.id).size <= 128)
    }

    @Test
    fun `a summary that is not a session id is treated as absent`() {
        assertNull(RunSession.decode(null))
        assertNull(RunSession.decode(ByteArray(0)))
        assertNull(RunSession.decode("../etc/passwd".toByteArray()))
        assertNull(RunSession.decode("has space".toByteArray()))
        assertNull(RunSession.decode(ByteArray(129) { 'a'.code.toByte() }))
        assertNull(RunSession.decode(byteArrayOf(0xff.toByte(), 0xfe.toByte())))
    }

    @Test
    fun `tagging writes the encoded id and build on API 30 and up`() {
        var written: ByteArray? = null
        val build = AppBuild.of("1.0.1", 2)

        val tagged = RunSession.tag(sdkInt = 30, sessionId = "abc-123", build = build) { written = it }

        assertTrue(tagged)
        assertContentEquals(RunSession.encode("abc-123", build), written)
        val tag = RunSession.decodeTag(written)
        assertEquals("abc-123", tag?.sessionId)
        assertEquals("1.0.1", tag?.versionName)
        assertEquals("2", tag?.buildId)
    }

    @Test
    fun `the version and build survive the round trip next to the session id`() {
        val tag = RunSession.decodeTag(RunSession.encode(RunSession.id, AppBuild.of("1.0.1", 2)))

        assertEquals(RunSession.id, tag?.sessionId)
        assertEquals("1.0.1", tag?.versionName)
        assertEquals("2", tag?.buildId)
    }

    @Test
    fun `a summary with no build known decodes to a session with no version and no build`() {
        val tag = RunSession.decodeTag(RunSession.encode(RunSession.id))

        assertEquals(RunSession.id, tag?.sessionId)
        assertNull(tag?.versionName)
        assertNull(tag?.buildId)
    }

    @Test
    fun `one half of the build can be known without the other`() {
        val onlyCode = RunSession.decodeTag(RunSession.encode("s", AppBuild.of(null, 7)))
        val onlyName = RunSession.decodeTag(RunSession.encode("s", AppBuild.of("2.0", null)))

        assertNull(onlyCode?.versionName)
        assertEquals("7", onlyCode?.buildId)
        assertEquals("2.0", onlyName?.versionName)
        assertNull(onlyName?.buildId)
    }

    @Test
    fun `a summary from before the build was recorded has a session and no build, never a guess`() {
        // Exactly what the previous release wrote: the bare session id.
        val legacy = "6f1c2a3e-1111-4222-8333-444455556666".toByteArray()

        val tag = RunSession.decodeTag(legacy)

        assertEquals("6f1c2a3e-1111-4222-8333-444455556666", tag?.sessionId)
        assertNull(tag?.versionName)
        assertNull(tag?.buildId)
        assertEquals("6f1c2a3e-1111-4222-8333-444455556666", RunSession.decode(legacy))
    }

    @Test
    fun `the summary with the longest fields we allow still fits the OS limit`() {
        val session = "s".repeat(36)
        val build = AppBuild.of("v".repeat(64), Long.MAX_VALUE)

        val bytes = RunSession.encode(session, build)

        assertTrue(bytes.size <= 128, "was ${bytes.size} bytes")
        val tag = RunSession.decodeTag(bytes)
        assertEquals("v".repeat(64), tag?.versionName)
        assertEquals(Long.MAX_VALUE.toString(), tag?.buildId)
    }

    @Test
    fun `a summary that would pass 128 bytes drops the version, then the build, and never cuts either`() {
        val longSession = "s".repeat(64)
        // 1 + (1+64) + (1+64) + (1+19) = 151: too big, so the version goes.
        val dropsVersion = RunSession.encode(longSession, AppBuild.of("v".repeat(64), Long.MAX_VALUE))
        // Too long for the version cap on its own: dropped, not truncated.
        val overlongVersion = RunSession.encode("s", AppBuild.of("v".repeat(65), 3))

        assertTrue(dropsVersion.size <= 128)
        assertNull(RunSession.decodeTag(dropsVersion)?.versionName)
        assertEquals(Long.MAX_VALUE.toString(), RunSession.decodeTag(dropsVersion)?.buildId)
        assertNull(RunSession.decodeTag(overlongVersion)?.versionName)
        assertEquals("3", RunSession.decodeTag(overlongVersion)?.buildId)
        assertEquals(longSession, RunSession.decodeTag(dropsVersion)?.sessionId)
    }

    @Test
    fun `the limit holds however long the fields are`() {
        for (versionLength in listOf(1, 20, 64, 65, 200)) {
            for (sessionLength in listOf(1, 36, 64)) {
                val bytes = RunSession.encode(
                    "s".repeat(sessionLength),
                    AppBuild.of("é".repeat(versionLength), Long.MAX_VALUE),
                )
                assertTrue(bytes.size <= 128, "session $sessionLength, version $versionLength: ${bytes.size}")
                assertEquals("s".repeat(sessionLength), RunSession.decodeTag(bytes)?.sessionId)
            }
        }
    }

    @Test
    fun `a version with multibyte characters is measured in bytes`() {
        // 40 characters, 80 bytes: over the 64-byte field cap.
        val tag = RunSession.decodeTag(RunSession.encode("s", AppBuild.of("é".repeat(40), 1)))

        assertNull(tag?.versionName)
        assertEquals("1", tag?.buildId)
    }

    @Test
    fun `a malformed current-format summary is treated as absent, not partly believed`() {
        val good = RunSession.encode("abc-123", AppBuild.of("1.0", 5))

        // Truncated anywhere: the lengths no longer add up.
        for (cut in 1 until good.size) {
            assertNull(RunSession.decodeTag(good.copyOf(cut)), "cut at $cut")
        }
        // Trailing bytes.
        assertNull(RunSession.decodeTag(good + byteArrayOf(0)))
        // A format this build does not know.
        assertNull(RunSession.decodeTag(byteArrayOf(2) + good.copyOfRange(1, good.size)))
        // A session id that is not one of ours.
        assertNull(RunSession.decodeTag(byteArrayOf(1, 3, 'a'.code.toByte(), ' '.code.toByte(), 'b'.code.toByte(), 0, 0)))
        // Over the OS limit.
        assertNull(RunSession.decodeTag(ByteArray(129) { 1 }))
    }

    @Test
    fun `a field that is not what it should be is absent while the rest is kept`() {
        fun summary(version: ByteArray, build: ByteArray) =
            byteArrayOf(1, 1, 's'.code.toByte(), version.size.toByte()) + version +
                byteArrayOf(build.size.toByte()) + build

        val badVersion = RunSession.decodeTag(summary("1.0\n".toByteArray(), "5".toByteArray()))
        val badBuild = RunSession.decodeTag(summary("1.0".toByteArray(), "12a".toByteArray()))
        val notUtf8 = RunSession.decodeTag(summary(byteArrayOf(0xff.toByte(), 0xfe.toByte()), "5".toByteArray()))

        assertNull(badVersion?.versionName)
        assertEquals("5", badVersion?.buildId)
        assertEquals("1.0", badBuild?.versionName)
        assertNull(badBuild?.buildId)
        assertNull(notUtf8?.versionName)
        assertEquals("s", notUtf8?.sessionId)
    }

    @Test
    fun `tagging is skipped below API 30 without calling the OS`() {
        var called = false

        val tagged = RunSession.tag(sdkInt = 29, sessionId = "abc-123") { called = true }

        assertFalse(tagged)
        assertFalse(called)
    }

    @Test
    fun `a failing OS call is swallowed`() {
        val tagged = RunSession.tag(sdkInt = 34, sessionId = "abc-123") {
            throw SecurityException("denied")
        }

        assertFalse(tagged)
    }
}
