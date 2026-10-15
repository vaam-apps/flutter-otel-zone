package com.vaam.otel_zone

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CrashScreenTest {

    @Test
    fun `set keeps the cleaned screen for the crash handler`() {
        val screen = CrashScreen(sdkInt = 30) { false }

        screen.set("  /orders/:id \n")

        assertEquals("/orders/:id", screen.current)
    }

    @Test
    fun `below API 30 the summary is never written`() {
        var calls = 0
        val screen = CrashScreen(sdkInt = 29) {
            calls++
            true
        }

        screen.set("/a")

        assertEquals("/a", screen.current)
        assertEquals(0, calls)
    }

    @Test
    fun `on API 30 a change re-tags the run once and an unchanged screen does not`() {
        val written = mutableListOf<String?>()
        val screen = CrashScreen(sdkInt = 30) {
            written.add(it)
            true
        }

        screen.set("/a")
        screen.set("/a")
        screen.set("/b")
        screen.set("/b")

        assertEquals(listOf<String?>("/a", "/b"), written)
    }

    @Test
    fun `a tagger that throws keeps the screen in memory and the next change tries again`() {
        var fail = true
        val attempts = mutableListOf<String?>()
        val screen = CrashScreen(sdkInt = 30) {
            attempts.add(it)
            if (fail) throw SecurityException("denied")
            true
        }

        screen.set("/a")

        assertEquals("/a", screen.current)
        fail = false
        screen.set("/a")
        assertEquals(listOf<String?>("/a", "/a"), attempts)
    }

    @Test
    fun `null, blank, overlong and control-character screens clear it`() {
        val screen = CrashScreen(sdkInt = 29) { true }

        screen.set("/a")
        screen.set(null)
        assertNull(screen.current)

        screen.set("/a")
        screen.set("  ")
        assertNull(screen.current)

        screen.set("/a")
        screen.set("x".repeat(65))
        assertNull(screen.current)

        screen.set("/a")
        screen.set("/a\u0007")
        assertNull(screen.current)
    }
}
