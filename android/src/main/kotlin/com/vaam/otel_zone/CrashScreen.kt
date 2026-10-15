package com.vaam.otel_zone

/**
 * The screen the app is showing, as this process keeps it, and the copy the OS
 * keeps of it for this process.
 *
 * The JVM handler writes [current] into its report at the throw. The OS's exit
 * record gets the same value from the process state summary, the 128-byte note
 * the OS keeps for this pid (see [RunSession]). That is the only copy that
 * survives a native crash, an ANR or a signal, so each change is written there
 * as well, and only when it differs from the one last written: one binder call to
 * the activity manager per change, never a file.
 *
 * [set] runs on the Pigeon background queue. The JVM handler reads [current]
 * without the lock, which is why it is `@Volatile`: a crash can land on any
 * thread at any moment, and the lock would make the handler wait for a binder
 * call it cannot afford.
 *
 * @param sdkInt the device's API level. Below 30 the summary is never written,
 *   because the OS does not keep one for the exit record to read.
 * @param tag writes [screen] into this process's summary and reports whether it
 *   did. It is [RunSession.tag] in the app and a fake in the tests.
 */
internal class CrashScreen(private val sdkInt: Int, private val tag: (String?) -> Boolean) {

    /** The screen [set] last kept, once cleaned, or `null` when it names none. */
    @Volatile
    var current: String? = null
        private set

    /** The screen last written into the summary, so an unchanged one is not written again. */
    private var lastTagged: String? = null

    /**
     * Keeps [screen] as the current screen and, on API 30 and up, writes it into
     * the process state summary when it differs from the one last written.
     *
     * [current] is set first, so the JVM handler sees the new screen even when
     * the write fails or is refused. A failure is swallowed and [lastTagged] is
     * left alone, so the next change tries again: tagging a run is a nicety and
     * must not be able to stop the app.
     */
    @Synchronized
    fun set(screen: String?) {
        val cleaned = clean(screen)
        current = cleaned
        // Build.VERSION_CODES.R, written out so that the JVM tests never load
        // android.os.Build.
        if (sdkInt < 30) return
        if (cleaned == lastTagged) return
        try {
            if (tag(cleaned)) lastTagged = cleaned
        } catch (_: Exception) {
            // A refused write is not a reason to stop the app, and the next
            // change tries again.
        }
    }

    companion object {
        /** The attribute a crash record carries the screen in. */
        const val ATTRIBUTE = "otel_zone.crashed.screen"

        /** The longest screen kept, in UTF-8 bytes. A route pattern is far shorter. */
        const val MAX_BYTES = 64

        /**
         * [screen] trimmed, or `null` when it is absent, blank, longer than
         * [MAX_BYTES] in UTF-8, or holds a control character. A screen is never cut
         * to fit: a cut route names the wrong screen.
         */
        fun clean(screen: String?): String? =
            screen?.trim()?.takeIf {
                it.isNotEmpty() &&
                    it.none(Char::isISOControl) &&
                    it.toByteArray(Charsets.UTF_8).size <= MAX_BYTES
            }

        /**
         * The process's screen. Replaced once by the initializer, which has the
         * activity manager and the build; until then it keeps the screen in memory
         * and writes no summary.
         */
        @Volatile
        var process: CrashScreen = CrashScreen(sdkInt = 0) { false }
    }
}
