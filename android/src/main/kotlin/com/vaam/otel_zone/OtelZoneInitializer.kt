package com.vaam.otel_zone

import android.content.Context
import androidx.startup.Initializer

/**
 * Installs the JVM crash handler before the app's own code runs.
 *
 * Registered through androidx.startup, so adoption is zero app-side lines:
 * the provider entry in the plugin manifest is the whole wiring, and
 * `create` runs before `Application.onCreate`, which is what makes a crash
 * during startup itself captureable.
 */
class OtelZoneInitializer : Initializer<Unit> {

    override fun create(context: Context) {
        installJvmCrashHandler(CrashStore(crashDirectory(context)))
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}
