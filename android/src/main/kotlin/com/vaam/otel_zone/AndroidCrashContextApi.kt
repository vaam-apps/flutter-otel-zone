package com.vaam.otel_zone

/**
 * The [CrashContextApi] the Dart side talks to: it hands the screen to
 * [CrashScreen.process].
 *
 * Pigeon calls it on a serial background queue, so the write to the OS happens
 * there and never on the platform thread.
 */
internal class AndroidCrashContextApi : CrashContextApi {

    override fun setCrashScreen(screen: String?) {
        CrashScreen.process.set(screen)
    }
}
