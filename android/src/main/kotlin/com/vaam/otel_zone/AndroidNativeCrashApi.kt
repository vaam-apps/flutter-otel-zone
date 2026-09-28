package com.vaam.otel_zone

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The [NativeCrashApi] the Dart drain talks to: the reports already on disk.
 *
 * Reading and deleting run on [Dispatchers.IO] because the channel calls are
 * awaited on the platform thread, and `start()` must not pay for a directory
 * read on the frame the app is drawing.
 */
internal class AndroidNativeCrashApi(private val store: CrashStore) : NativeCrashApi {

    override suspend fun pending(): List<NativeCrashReport> =
        withContext(Dispatchers.IO) { store.pending() }

    override suspend fun acknowledge(ids: List<String>) {
        withContext(Dispatchers.IO) { store.acknowledge(ids) }
    }
}
