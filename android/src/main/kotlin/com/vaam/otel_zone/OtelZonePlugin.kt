package com.vaam.otel_zone

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Registers the native crash-capture channel.
 *
 * The channel's platform side is [NativeCrashStub] until the Android capture
 * tickets land: it reports nothing and acknowledges nothing, which is exactly
 * the behaviour of the package before this plugin existed. Registering it now
 * is what lets the Dart drain ship and be tested ahead of the platform work.
 */
class OtelZonePlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeCrashApi.setUp(binding.binaryMessenger, NativeCrashStub())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeCrashApi.setUp(binding.binaryMessenger, null)
    }
}

/**
 * The no-op [NativeCrashApi] that the Android capture tickets replace.
 *
 * Reading `ApplicationExitInfo` and chaining the JVM uncaught-exception
 * handler both belong to those tickets, not this one.
 */
internal class NativeCrashStub : NativeCrashApi {
    override suspend fun pending(): List<NativeCrashReport> = emptyList()

    override suspend fun acknowledge(ids: List<String>) = Unit
}
