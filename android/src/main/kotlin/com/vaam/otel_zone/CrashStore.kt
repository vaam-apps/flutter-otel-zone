package com.vaam.otel_zone

import android.content.Context
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/**
 * Writes one fatal JVM exception, before the process dies.
 *
 * A function interface so the handler can be tested against a recorder that
 * fails, without a directory or a device.
 */
internal fun interface JvmCrashRecorder {
    /**
     * Records [throwable]. May throw: a dying process has nowhere to report
     * a failure, so [JvmCrashHandler] decides what to do with one.
     */
    fun record(thread: Thread, throwable: Throwable)
}

/**
 * The app-private directory the crash reports live in.
 *
 * `noBackupFilesDir`, not `filesDir`: a crash report is a fact about one run
 * of one install, and restoring it into a fresh install on a new device
 * would file someone else's crash under this one.
 */
internal fun crashDirectory(context: Context): File =
    File(context.noBackupFilesDir, "otel_zone/crashes")

/**
 * The Android side of [NativeCrashApi]: one JSON file per report.
 *
 * Files rather than a database, because the write happens inside an
 * uncaught-exception handler. The process is already dying, so the write has
 * to be one small synchronous write with no transaction left to roll back —
 * and it has to survive being killed halfway, which is what the temp file
 * and rename are for.
 */
internal class CrashStore(
    private val directory: File,
    private val maxReports: Int = DEFAULT_MAX_REPORTS,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val staleTempMillis: Long = DEFAULT_STALE_TEMP_MILLIS,
) : JvmCrashRecorder {

    private val sequence = AtomicLong(0)

    override fun record(thread: Thread, throwable: Throwable) {
        directory.mkdirs()
        sweepTemps()
        val id = nextId()

        val report = JSONObject()
            .put("id", id)
            .put("kind", JVM_KIND)
            .put("timestampMicros", nowMillis() * 1000L)
            .put("type", throwable.javaClass.name)
            .put("message", throwable.message)
            .put("stacktrace", throwable.stackTraceToString())
            .put("attributes", JSONObject().put("thread.name", thread.name))

        val target = File(directory, "$id$SUFFIX")
        // Built from the directory, not from target.path: File(parent, child)
        // makes an absolute child relative to the parent, so passing the
        // target's own path here would nest the whole path under the
        // directory instead of writing beside it.
        val temp = File(directory, "$id$SUFFIX$TEMP_SUFFIX")
        temp.writeText(report.toString())
        if (!temp.renameTo(target)) {
            temp.delete()
            throw IOException("could not rename ${temp.path} to ${target.path}")
        }
        trim()
    }

    /**
     * Every unacknowledged report, oldest first.
     */
    fun pending(): List<NativeCrashReport> {
        sweepTemps()
        return reportFiles().mapNotNull(::read)
    }

    /**
     * Deletes the reports named by [ids]. Unknown ids are ignored.
     */
    fun acknowledge(ids: List<String>) {
        ids.forEach { id ->
            // The ids come from across the channel, so they are checked
            // before they are turned into a path: a name is only ever
            // accepted if it is one this store could have written.
            if (!SAFE_ID.matches(id)) return@forEach
            File(directory, "$id$SUFFIX").delete()
        }
    }

    /**
     * An id that sorts by age and cannot collide across launches.
     */
    private fun nextId(): String {
        while (true) {
            val id = "$JVM_KIND-%016d-%04d".format(nowMillis(), sequence.getAndIncrement())
            if (!File(directory, "$id$SUFFIX").exists()) return id
        }
    }

    /**
     * Keeps the newest [maxReports] reports.
     */
    private fun trim() {
        val files = reportFiles()
        if (files.size <= maxReports) return
        files.take(files.size - maxReports).forEach { it.delete() }
    }

    /**
     * Report files, oldest first. The name leads with the timestamp, so
     * lexical order is age order.
     */
    private fun reportFiles(): List<File> =
        directory
            .listFiles { file -> file.isFile && file.name.endsWith(SUFFIX) }
            ?.sortedBy { it.name }
            .orEmpty()

    /**
     * Deletes temp files that no live write can still own.
     *
     * A temp file only survives its writer when the process died between the
     * write and the rename, and nothing else looks for a `*.tmp`, so without
     * this they accumulate for the life of the install.
     *
     * The age check is what keeps a sweep from destroying a crash: [pending]
     * runs on `Dispatchers.IO` while a crash can land on any thread at the
     * same moment, and a write that is in flight is milliseconds old. Only a
     * file nobody could still be writing is treated as a corpse.
     */
    private fun sweepTemps() {
        val cutoff = nowMillis() - staleTempMillis
        // lastModified() answers 0 when the filesystem will not say, and an
        // unknown age is not evidence of a live write.
        directory
            .listFiles { file -> file.isFile && file.name.endsWith(TEMP_SUFFIX) }
            ?.filter { it.lastModified() < cutoff }
            ?.forEach { it.delete() }
    }

    /**
     * One report, or `null` if this build cannot read it.
     */
    private fun read(file: File): NativeCrashReport? =
        try {
            val json = JSONObject(file.readText())
            NativeCrashReport(
                id = json.getString("id"),
                kind = json.optString("kind", JVM_KIND),
                timestampMicros = json.optLong("timestampMicros"),
                type = json.optionalString("type"),
                message = json.optionalString("message"),
                stacktrace = json.optionalString("stacktrace"),
                threads = json.optJSONArray("threads")?.let { array ->
                    (0 until array.length()).map(array::getString)
                },
                sessionId = json.optionalString("sessionId"),
                attributes = json.optJSONObject("attributes")?.toMap(),
            )
        } catch (_: Exception) {
            null
        }

    /**
     * `optString` answers `"null"` for a JSON null, which is not the same
     * thing as an absent field.
     */
    private fun JSONObject.optionalString(key: String): String? =
        if (isNull(key)) null else optString(key)

    private fun JSONObject.toMap(): Map<String, String> =
        keys().asSequence().associateWith { key -> optString(key) }

    private companion object {
        const val JVM_KIND = "jvm"
        const val SUFFIX = ".json"
        const val TEMP_SUFFIX = ".tmp"
        const val DEFAULT_MAX_REPORTS = 16

        /** Long enough that no in-flight write is ever this old. */
        const val DEFAULT_STALE_TEMP_MILLIS = 5 * 60 * 1000L
        val SAFE_ID = Regex("^[A-Za-z0-9_-]+$")
    }
}
