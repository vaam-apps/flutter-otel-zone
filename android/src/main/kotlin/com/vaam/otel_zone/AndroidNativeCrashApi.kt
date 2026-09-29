package com.vaam.otel_zone

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The [NativeCrashApi] the Dart drain talks to: the JVM reports on disk and
 * the OS's exit records, joined by [CrashReports].
 *
 * Reading and deleting run on [Dispatchers.IO] because the channel calls are
 * awaited on the platform thread, and `start()` must not pay for a directory
 * read or a binder call to the activity manager on the frame the app is
 * drawing.
 */
internal class AndroidNativeCrashApi(private val reports: CrashReports) : NativeCrashApi {

    override suspend fun pending(): List<NativeCrashReport> =
        withContext(Dispatchers.IO) { reports.pending() }

    override suspend fun acknowledge(ids: List<String>) {
        withContext(Dispatchers.IO) { reports.acknowledge(ids) }
    }
}
