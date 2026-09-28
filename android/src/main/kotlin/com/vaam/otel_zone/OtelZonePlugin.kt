package com.vaam.otel_zone

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Registers the native crash-capture channel.
 *
 * The platform side is [AndroidNativeCrashApi], reading the reports the JVM
 * handler left in `noBackupFilesDir`. Reports of an OS-level death
 * (`ApplicationExitInfo`) belong to their own ticket and are not here yet;
 * until then `pending()` answers with JVM crashes only.
 */
class OtelZonePlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val store = CrashStore(crashDirectory(binding.applicationContext))
        NativeCrashApi.setUp(binding.binaryMessenger, AndroidNativeCrashApi(store))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeCrashApi.setUp(binding.binaryMessenger, null)
    }
}
