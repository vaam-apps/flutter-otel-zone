package com.example.otel_zone_example

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Induces each way an Android process can die, so the crash-capture path can
 * be exercised on purpose.
 *
 * **This is the debug half.** Only the `debug` source set compiles it; the
 * `release` and `profile` source sets carry a same-named object whose every
 * member refuses, so the release APK contains neither the channel name nor any
 * of the code below, and `MainActivity` is identical across build types.
 *
 * Two doors lead here, and both end in [crash]:
 *
 *  - the `otel_zone_example/crash` method channel, for the debug UI and for
 *    in-app tests; and
 *  - an intent extra, `otel_crash`, for a host script that has to trigger a
 *    death from outside a process that is about to stop answering:
 *    `adb shell am start -n <pkg>/.MainActivity --es otel_crash jvm`.
 *
 * Every crash is *posted*, never run inline. A method-channel handler that
 * throws is caught by Flutter and turned into an error result, so an inline
 * `throw` would not be a crash at all — and an inline block would hold up the
 * channel reply.
 */
object CrashHarness {
    const val CHANNEL = "otel_zone_example/crash"
    const val EXTRA = "otel_crash"
    private const val TAG = "OtelZoneCrashHarness"

    /** How long the main thread is held for `anr`. See [anr]. */
    private const val ANR_BLOCK_MILLIS = 60_000L

    /** Gives the channel reply (or the `am start`) time to complete first. */
    private const val LEAD_MILLIS = 300L

    val kinds: Set<String> = setOf("jvm", "native", "anr")

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "crash" -> {
                    val kind = call.arguments as? String
                    if (kind != null && crash(kind)) {
                        result.success(null)
                    } else {
                        result.error("unknown-kind", "Unknown crash kind: $kind", kinds.toList())
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Handles `--es otel_crash <kind>` on a new intent. */
    fun handle(intent: Intent?) {
        val kind = intent?.getStringExtra(EXTRA) ?: return
        if (!crash(kind)) Log.w(TAG, "unknown crash kind '$kind'")
    }

    /** Schedules the death and returns whether [kind] was recognised. */
    fun crash(kind: String): Boolean {
        val main = Handler(Looper.getMainLooper())
        val action: () -> Unit = when (kind) {
            "jvm" -> ::jvm
            "native" -> ::native
            "anr" -> ::anr
            else -> return false
        }
        Log.w(TAG, "crashing on purpose: $kind")
        main.postDelayed({ action() }, LEAD_MILLIS)
        return true
    }

    /** An uncaught exception on the main thread: the ordinary Android crash. */
    private fun jvm() {
        throw IllegalStateException("otel_zone harness: induced JVM crash")
    }

    /**
     * A real SIGSEGV, with no JNI: the process signals itself. `debuggerd`'s
     * handler sees an ordinary fatal signal, so the OS files it as
     * `REASON_CRASH_NATIVE` and, on API 31+, writes a tombstone. `si_code` is
     * `SI_USER` rather than `SEGV_MAPERR`, which the report says and which is
     * the honest difference from a real bad dereference.
     */
    private fun native() {
        Process.sendSignal(Process.myPid(), 11)
    }

    /**
     * Holds the main thread. Blocking it does **not** by itself make an ANR:
     * the OS declares one only when something is waiting on the thread — an
     * input event unanswered for 5 s (or a broadcast/service timeout). A
     * blocked thread with nobody asking is just an idle-looking app, so the
     * host script sends a tap while this holds, and the ANR lands about 5 s
     * after it. The block is long enough (60 s) to outlast that with margin
     * and finite so a forgotten device recovers.
     */
    private fun anr() {
        val until = System.currentTimeMillis() + ANR_BLOCK_MILLIS
        while (System.currentTimeMillis() < until) {
            try {
                Thread.sleep(100)
            } catch (_: InterruptedException) {
                // Still blocked: the point is that the looper does not spin.
            }
        }
    }
}
