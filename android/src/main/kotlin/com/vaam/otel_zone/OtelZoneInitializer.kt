package com.vaam.otel_zone

import android.app.ActivityManager
import android.content.Context
import androidx.startup.Initializer

/**
 * Installs the JVM crash handler and tags this run before the app's own code
 * runs.
 *
 * Registered through androidx.startup, so adoption is zero app-side lines:
 * the provider entry in the plugin manifest is the whole wiring, and
 * `create` runs before `Application.onCreate`, which is what makes a crash
 * during startup itself captureable.
 */
class OtelZoneInitializer : Initializer<Unit> {

    override fun create(context: Context) {
        installJvmCrashHandler(CrashStore(crashDirectory(context), sessionId = RunSession.id))

        // Tags this process so that its ApplicationExitInfo, read on a later
        // launch, says which session it ended. Below API 30 this is a no-op
        // and the JVM reports carry the session id themselves.
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        if (activityManager != null) {
            RunSession.tag { summary -> activityManager.setProcessStateSummary(summary) }
        }
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}
