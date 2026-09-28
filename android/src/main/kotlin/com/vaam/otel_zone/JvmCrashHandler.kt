package com.vaam.otel_zone

/**
 * Records a fatal JVM exception, then hands it to the handler that was
 * installed before.
 *
 * The chain matters twice over. Another reporter installed first (or later,
 * around this one) must still see the crash, and Android's own "app has
 * stopped" handling sits behind the default handler — swallowing the
 * exception would turn a crash dialog into a silent exit.
 */
internal class JvmCrashHandler(
    private val recorder: JvmCrashRecorder,
    private val previous: Thread.UncaughtExceptionHandler?,
) : Thread.UncaughtExceptionHandler {

    override fun uncaughtException(thread: Thread, throwable: Throwable) {
        try {
            recorder.record(thread, throwable)
        } catch (_: Throwable) {
            // The process is already dying with one exception in flight.
            // Throwing a second from here would replace the real crash with
            // this one, so a store failure is dropped and the chain goes on.
        }
        previous?.uncaughtException(thread, throwable)
    }
}

/**
 * Puts a [JvmCrashHandler] in front of the current default handler.
 *
 * Returns it so the previous handler can be put back, which is how the tests
 * leave the JVM as they found it.
 */
internal fun installJvmCrashHandler(recorder: JvmCrashRecorder): JvmCrashHandler {
    val handler = JvmCrashHandler(recorder, Thread.getDefaultUncaughtExceptionHandler())
    Thread.setDefaultUncaughtExceptionHandler(handler)
    return handler
}
