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
    fun `tagging writes the encoded id on API 30 and up`() {
        var written: ByteArray? = null

        val tagged = RunSession.tag(sdkInt = 30, sessionId = "abc-123") { written = it }

        assertTrue(tagged)
        assertContentEquals("abc-123".toByteArray(), written)
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
