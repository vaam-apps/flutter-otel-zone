package com.vaam.otel_zone

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Registers the native crash-capture channel.
 *
 * The platform side is [AndroidNativeCrashApi]: the reports the JVM handler
 * left in `noBackupFilesDir`, and — on API 30+ — the OS's own record of how
 * previous runs died (`ApplicationExitInfo`), joined so a JVM crash is one
 * record rather than two. It also takes the screen the app shows
 * ([AndroidCrashContextApi]), which both of those records carry.
 */
class OtelZonePlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val reports = CrashReports(CrashStore(crashDirectory(context)), exitInfoSource(context))
        NativeCrashApi.setUp(binding.binaryMessenger, AndroidNativeCrashApi(reports))
        CrashContextApi.setUp(binding.binaryMessenger, AndroidCrashContextApi())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeCrashApi.setUp(binding.binaryMessenger, null)
        CrashContextApi.setUp(binding.binaryMessenger, null)
    }
}
