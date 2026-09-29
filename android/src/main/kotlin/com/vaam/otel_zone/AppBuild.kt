package com.vaam.otel_zone

import android.content.Context
import android.content.pm.PackageInfo
import android.os.Build

/**
 * The attribute names a native crash record uses for the build that crashed.
 *
 * A record is exported by the *next* launch, under that launch's resource, so
 * after an app update `service.version` and `app.build_id` name the build that
 * reported the crash, not the one that died. These say which binary died, and
 * they are the same two names on every platform (iOS writes them too).
 */
internal object CrashedBuild {
    const val SERVICE_VERSION = "otel_zone.crashed.service.version"
    const val BUILD_ID = "otel_zone.crashed.app.build_id"
}

/**
 * The version and build of the app this process is running, read once.
 *
 * Read when the plugin starts and held in memory, because the two places that
 * need it run when the process is dying: the JVM crash handler cannot afford
 * a binder call to the package manager there, and the value that is worth
 * having is the one this process started with, which is the one that crashes.
 *
 * Either half is `null` when it is not known, and a `null` is never turned
 * into a made-up value: an absent attribute is honest, a wrong one sends
 * someone to fetch symbols for another binary.
 */
internal class AppBuild private constructor(
    /** `versionName`, e.g. `1.0.1`. */
    val versionName: String?,
    /** `longVersionCode`, as decimal text, e.g. `2`. */
    val buildId: String?,
) {

    /** The attributes to put on a record: only the halves that are known. */
    fun attributes(): Map<String, String> =
        buildMap {
            versionName?.let { put(CrashedBuild.SERVICE_VERSION, it) }
            buildId?.let { put(CrashedBuild.BUILD_ID, it) }
        }

    companion object {
        val UNKNOWN = AppBuild(null, null)

        /**
         * From the raw values the package manager gave. A blank or control-
         * character version, or a negative code, is unknown rather than
         * passed on.
         */
        fun of(versionName: String?, versionCode: Long?): AppBuild =
            AppBuild(
                versionName = versionName?.takeIf { it.isNotBlank() && it.none(Char::isISOControl) },
                buildId = versionCode?.takeIf { it >= 0 }?.toString(),
            )

        /**
         * The running app's own package, or [UNKNOWN] when the package manager
         * will not say. Never throws: this runs during start-up and a failure
         * to read the version must not stop the app.
         */
        fun read(context: Context, sdkInt: Int = Build.VERSION.SDK_INT): AppBuild =
            try {
                @Suppress("DEPRECATION")
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                from(info, sdkInt)
            } catch (_: Exception) {
                UNKNOWN
            }

        internal fun from(info: PackageInfo, sdkInt: Int): AppBuild =
            select(
                versionName = info.versionName,
                sdkInt = sdkInt,
                intCode = {
                    @Suppress("DEPRECATION")
                    info.versionCode.toLong()
                },
                longCode = { info.longVersionCode },
            )

        /**
         * `longVersionCode` from API 28, where `versionCode` (an `Int`) would
         * truncate a code that no longer fits one; `versionCode` below it.
         * The two are lambdas so that only the one this API level has is ever
         * called.
         */
        internal fun select(
            versionName: String?,
            sdkInt: Int,
            intCode: () -> Long,
            longCode: () -> Long,
        ): AppBuild =
            of(
                versionName = versionName,
                versionCode = if (sdkInt >= Build.VERSION_CODES.P) longCode() else intCode(),
            )
    }
}
