package com.vaam.otel_zone

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertSame
import kotlin.test.assertTrue

class JvmCrashHandlerTest {

    private val original = Thread.getDefaultUncaughtExceptionHandler()

    @AfterTest
    fun restoreDefaultHandler() {
        Thread.setDefaultUncaughtExceptionHandler(original)
    }

    private class Recorder(private val fails: Boolean = false) : JvmCrashRecorder {
        val recorded = mutableListOf<Pair<Thread, Throwable>>()

        override fun record(thread: Thread, throwable: Throwable) {
            recorded.add(thread to throwable)
            if (fails) throw IllegalStateException("no space left on device")
        }
    }

    private class Previous : Thread.UncaughtExceptionHandler {
        val handled = mutableListOf<Throwable>()

        override fun uncaughtException(thread: Thread, throwable: Throwable) {
            handled.add(throwable)
        }
    }

    @Test
    fun `the crash is recorded and the handler installed first still runs`() {
        val recorder = Recorder()
        val first = Previous()
        Thread.setDefaultUncaughtExceptionHandler(first)

        val handler = installJvmCrashHandler(recorder)
        assertSame(handler, Thread.getDefaultUncaughtExceptionHandler())

        val crash = RuntimeException("boom")
        handler.uncaughtException(Thread.currentThread(), crash)

        assertSame(crash, recorder.recorded.single().second)
        assertSame(crash, first.handled.single())
    }

    @Test
    fun `a store that fails still leaves the previous handler to run`() {
        val first = Previous()
        Thread.setDefaultUncaughtExceptionHandler(first)

        val handler = installJvmCrashHandler(Recorder(fails = true))
        val crash = RuntimeException("boom")
        handler.uncaughtException(Thread.currentThread(), crash)

        assertSame(crash, first.handled.single())
    }

    @Test
    fun `a failure with no previous handler installed is swallowed`() {
        Thread.setDefaultUncaughtExceptionHandler(null)
        val handler = installJvmCrashHandler(Recorder(fails = true))

        handler.uncaughtException(Thread.currentThread(), RuntimeException("boom"))

        assertTrue(Thread.getDefaultUncaughtExceptionHandler() is JvmCrashHandler)
    }
}
