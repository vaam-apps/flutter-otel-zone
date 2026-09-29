package com.example.otel_zone_example

import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger

/**
 * The refusing half of the crash harness.
 *
 * The real one lives in the `debug` source set and is not compiled into this
 * build type at all. This stand-in exists so `MainActivity` is the same file in
 * every build type, and it does exactly one thing: it never registers the
 * channel, and says so when an intent asks for a crash. A release build with
 * this object cannot be made to crash from outside, and the crash code and the
 * channel name are absent from its dex.
 */
object CrashHarness {
    fun register(messenger: BinaryMessenger) {
        // Deliberately nothing: no channel, so Dart sees MissingPluginException.
    }

    fun handle(intent: Intent?) {
        // Any `otel_*` extra is a harness request; none is honoured here.
        if (intent?.extras?.keySet()?.any { it.startsWith("otel_") } == true) {
            Log.w("OtelZoneCrashHarness", "refused: crash requests are debug-only")
        }
    }
}
