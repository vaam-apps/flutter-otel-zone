package com.vaam.otel_zone

import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Locale

/**
 * The identity of one OS exit record, as it crosses the channel.
 *
 * `exit-<timestamp>-<pid>-<reason>`, every part a decimal number. Nothing but
 * the record's own coordinates is in it, so the id is stable across launches
 * (the OS hands the same record back every time) and can be turned back into
 * the watermark timestamp on acknowledge without holding any state between
 * `pending()` and `acknowledge()`.
 */
internal class ExitId(val timestampMillis: Long, val pid: Int, val reason: Int) {

    val value: String
        get() = String.format(Locale.ROOT, "exit-%016d-%d-%d", timestampMillis, pid, reason)

    companion object {
        const val PREFIX = "exit-"
        private val SHAPE = Regex("^exit-(\\d{16})-(\\d{1,10})-(\\d{1,3})$")

        /**
         * The id [value] names, or `null` when it is not exactly one this
         * source could have produced. Ids arrive over the channel, so a
         * string is only ever believed after it matches this shape.
         */
        fun parse(value: String): ExitId? {
            val match = SHAPE.matchEntire(value) ?: return null
            val (timestamp, pid, reason) = match.destructured
            return ExitId(
                timestampMillis = timestamp.toLongOrNull() ?: return null,
                pid = pid.toIntOrNull() ?: return null,
                reason = reason.toIntOrNull() ?: return null,
            )
        }
    }
}

/**
 * A report built from an OS exit record, with the coordinates the JVM-crash
 * merge needs.
 */
internal class ExitEntry(
    val id: ExitId,
    val report: NativeCrashReport,
)

/**
 * The Android side of the OS's own record of why previous runs died.
 *
 * `getHistoricalProcessExitReasons` returns the same ring buffer on every
 * launch and cannot be cleared, so the only way to report each record once is
 * a watermark: the newest timestamp already reported, persisted in
 * `noBackupFilesDir`. [pending] returns records newer than it; [acknowledge]
 * is the **only** thing that moves it, to the newest timestamp among the ids
 * it is given.
 *
 * That last rule is the whole reliability story. A record is durable to the
 * caller only once it is acknowledged, so a launch that reads a record and
 * dies before spooling it leaves the watermark alone and the record is read
 * again. The price is that the watermark is a single number: acknowledging a
 * newer record makes every older unacknowledged one look reported. The Dart
 * drain acknowledges a batch together, so it does not arise in practice, but
 * a record the caller chose to drop while keeping a later one is not coming
 * back.
 *
 * Below API 30 there is no such record. This contributes nothing there and
 * never throws.
 */
internal class ExitInfoSource(
    private val records: ExitRecords,
    private val directory: File,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
    private val lowMemoryReportSupported: Boolean = false,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {

    private val lock = Any()

    /**
     * Records the OS holds that have not been acknowledged, oldest first,
     * already mapped to reports.
     *
     * Records of exits the app chose (`REASON_EXIT_SELF`) or a user or the
     * OS chose on the app's behalf are not crashes and are skipped; see
     * [SKIPPED_REASONS].
     */
    fun pending(): List<ExitEntry> {
        if (sdkInt < Build.VERSION_CODES.R) return emptyList()
        return try {
            val watermark = readWatermark()
            records.historical()
                .filter { it.timestampMillis > watermark && it.reason !in SKIPPED_REASONS }
                .sortedWith(compareBy({ it.timestampMillis }, { it.pid }))
                // A process dies once. See [acknowledge] for why the OS
                // sometimes files the same death twice, and why only the
                // first of them is reported.
                .distinctBy { it.pid to it.reason }
                .mapNotNull(::entry)
        } catch (_: Exception) {
            // A failing OS call must not take the JVM reports down with it.
            emptyList()
        }
    }

    /**
     * Advances the watermark to the newest of [ids] and returns the ids it
     * accepted.
     *
     * Anything that is not an id [pending] could have produced is ignored,
     * and so is a timestamp from the future: the ids come over the channel,
     * and one bad value must not push the watermark past every record the OS
     * will ever write.
     */
    fun acknowledge(ids: List<String>): List<ExitId> {
        if (sdkInt < Build.VERSION_CODES.R) return emptyList()
        val horizon = nowMillis() + FUTURE_TOLERANCE_MILLIS
        val accepted = ids.mapNotNull(ExitId::parse).filter { it.timestampMillis <= horizon }
        if (accepted.isEmpty()) return accepted
        val newest = maxOf(accepted.maxOf { it.timestampMillis }, newestDuplicate(accepted))
        synchronized(lock) {
            if (newest > readWatermark()) writeWatermark(newest)
        }
        return accepted
    }

    /**
     * The newest timestamp among the OS's other records of the deaths in
     * [accepted].
     *
     * Observed on an API 36 emulator: a JVM crash is filed as `REASON_CRASH`
     * twice for one pid, the second when the "keeps stopping" dialog is
     * dismissed and the process is finally killed, which can be any time
     * later. [pending] reports the first; if only that one were acknowledged
     * the second, being newer than the watermark, would be reported as a
     * crash of its own on the next launch. A record for the same pid and the
     * same reason is the same death, so acknowledging one acknowledges all.
     */
    private fun newestDuplicate(accepted: List<ExitId>): Long {
        val deaths = accepted.map { it.pid to it.reason }.toSet()
        return try {
            records.historical()
                .filter { (it.pid to it.reason) in deaths && it.timestampMillis <= nowMillis() + FUTURE_TOLERANCE_MILLIS }
                .maxOfOrNull { it.timestampMillis } ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    /**
     * The persisted watermark, or 0 (report everything) when there is none.
     *
     * An unreadable file is 0 too: re-reporting is the safe direction, a
     * duplicate being better than a loss. So is a value from the future,
     * which can only mean the clock was set back after it was written: kept,
     * it would silence every record until the clock caught up with it, and
     * clamping it to now would still hide everything already in the buffer.
     * The cost is that the OS's whole buffer (a few dozen records at most)
     * is reported once more.
     */
    private fun readWatermark(): Long =
        synchronized(lock) {
            val stored = try {
                File(directory, WATERMARK_FILE).readText().trim().toLongOrNull()
            } catch (_: IOException) {
                null
            } ?: 0L
            if (stored < 0L || stored > nowMillis() + FUTURE_TOLERANCE_MILLIS) 0L else stored
        }

    private fun writeWatermark(value: Long) {
        directory.mkdirs()
        val target = File(directory, WATERMARK_FILE)
        val temp = File(directory, "$WATERMARK_FILE.tmp")
        temp.writeText(value.toString())
        if (!temp.renameTo(target)) {
            temp.delete()
            throw IOException("could not rename ${temp.path} to ${target.path}")
        }
    }

    /** One record's report, or `null` if even the reason-only form fails. */
    private fun entry(record: ExitRecord): ExitEntry? {
        val id = ExitId(record.timestampMillis, record.pid, record.reason)
        val report = try {
            toReport(id, record, withTrace = true)
        } catch (_: Exception) {
            // A trace we could not read is not a reason to lose the record.
            try {
                toReport(id, record, withTrace = false)
            } catch (_: Exception) {
                return null
            }
        }
        return ExitEntry(id, report)
    }

    private fun toReport(id: ExitId, record: ExitRecord, withTrace: Boolean): NativeCrashReport {
        val attributes = linkedMapOf(
            "exit.reason" to reasonName(record.reason).lowercase(Locale.ROOT),
            "exit.status" to record.status.toString(),
            "exit.importance" to record.importance.toString(),
            "process.pid" to record.pid.toString(),
        )
        record.processName?.let { attributes["process.name"] = it }
        if (record.pssKb > 0) attributes["exit.pss_kb"] = record.pssKb.toString()
        if (record.rssKb > 0) attributes["exit.rss_kb"] = record.rssKb.toString()

        var type: String
        var message: String? = record.description
        var stacktrace: String? = null
        val kind: String

        when (record.reason) {
            ApplicationExitInfo.REASON_CRASH_NATIVE -> {
                kind = "native"
                // For a native crash the OS's status is the signal number,
                // so the name survives a missing or unreadable tombstone.
                type = signalName(record.status) ?: "CRASH_NATIVE"
                val tombstone =
                    if (withTrace && sdkInt >= Build.VERSION_CODES.S) readTombstone(record) else null
                if (tombstone == null) {
                    attributes["exit.trace_available"] = "false"
                } else {
                    tombstone.signalName?.let { type = it }
                    tombstone.abortMessage?.let { message = it }
                    tombstone.signalNumber?.let { attributes["signal.number"] = it.toString() }
                    tombstone.signalCode?.let { attributes["signal.code"] = it.toString() }
                    tombstone.signalCodeName?.let { attributes["signal.code_name"] = it }
                    tombstone.faultAddress?.let {
                        attributes["signal.fault_address"] = String.format(Locale.ROOT, "0x%x", it)
                    }
                    tombstone.crashingThreadId?.let { attributes["crash.thread.id"] = it.toString() }
                    tombstone.crashingThreadName?.let { attributes["crash.thread.name"] = it }
                    if (tombstone.frames.isNotEmpty()) {
                        stacktrace = TombstoneDecoder.format(tombstone.frames, tombstone.droppedFrames)
                    }
                }
            }

            ApplicationExitInfo.REASON_ANR -> {
                kind = "anr"
                type = "ANR"
                val trace = if (withTrace) readAnrTrace(record) else null
                if (trace == null) attributes["exit.trace_available"] = "false" else stacktrace = trace
            }

            ApplicationExitInfo.REASON_CRASH -> {
                // No JVM trace here: that is what the JVM handler's own
                // report is for, and CrashReports folds the two together.
                kind = "jvm"
                type = "CRASH"
            }

            ApplicationExitInfo.REASON_SIGNALED -> {
                kind = "signal"
                type = signalName(record.status) ?: "SIGNALED"
                if (record.status == SIGKILL && !lowMemoryReportSupported) {
                    // Without this the OS files an lmkd kill as a plain
                    // SIGKILL; a reader should know it may not be one.
                    attributes["exit.low_memory_report_supported"] = "false"
                }
            }

            else -> {
                kind = "signal"
                type = reasonName(record.reason)
            }
        }

        return NativeCrashReport(
            id = id.value,
            kind = kind,
            timestampMicros = record.timestampMillis * 1000L,
            type = type,
            message = message?.take(MAX_MESSAGE_CHARS),
            stacktrace = stacktrace,
            threads = null,
            sessionId = RunSession.decode(record.processStateSummary),
            attributes = attributes,
        )
    }

    private fun readTombstone(record: ExitRecord): Tombstone? {
        val bytes = record.trace()?.use { readBounded(it, MAX_TOMBSTONE_BYTES).first } ?: return null
        return TombstoneDecoder.decode(bytes)
    }

    private fun readAnrTrace(record: ExitRecord): String? {
        val (bytes, truncated) =
            record.trace()?.use { readBounded(it, MAX_ANR_TRACE_BYTES) } ?: return null
        val text = String(bytes, Charsets.UTF_8)
        return if (truncated) "$text\n... trace truncated at $MAX_ANR_TRACE_BYTES bytes" else text
    }

    companion object {
        /** Longest description kept; the OS's are one line, this is a bound. */
        const val MAX_MESSAGE_CHARS = 4096

        /**
         * A tombstone is read up to here. Threads come before memory dumps
         * and logs in the serialised order, so what the cap cuts is what is
         * not read anyway, and the decoder tolerates the cut.
         */
        const val MAX_TOMBSTONE_BYTES = 2 * 1024 * 1024

        /**
         * An ANR trace covers every thread and can run to megabytes, on a
         * radio that is metered. The main thread, which is what an ANR is
         * about, is first.
         */
        const val MAX_ANR_TRACE_BYTES = 64 * 1024

        /** Clock skew allowed between an id's timestamp and now. */
        const val FUTURE_TOLERANCE_MILLIS = 5 * 60 * 1000L

        const val WATERMARK_FILE = "exit-info-watermark"

        private const val SIGKILL = 9

        /**
         * Exits that are not faults.
         *
         * `EXIT_SELF` and `USER_REQUESTED` are the ticket's. The other four
         * are the same kind of thing — the user or the package manager
         * stopping the app on purpose — and each would otherwise file a
         * FATAL record for an app update or a permission toggle, which every
         * install produces.
         */
        val SKIPPED_REASONS = setOf(
            ApplicationExitInfo.REASON_EXIT_SELF,
            ApplicationExitInfo.REASON_USER_REQUESTED,
            ApplicationExitInfo.REASON_USER_STOPPED,
            ApplicationExitInfo.REASON_PACKAGE_UPDATED,
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE,
            ApplicationExitInfo.REASON_PERMISSION_CHANGE,
        )

        fun reasonName(reason: Int): String =
            when (reason) {
                ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
                ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
                ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
                ApplicationExitInfo.REASON_CRASH -> "CRASH"
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
                ApplicationExitInfo.REASON_ANR -> "ANR"
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
                ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
                ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
                ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
                ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
                ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
                ApplicationExitInfo.REASON_OTHER -> "OTHER"
                ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
                ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
                ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
                else -> "UNKNOWN"
            }

        /**
         * The name of a Linux signal number, for the ones a process is
         * realistically ended by. The numbering below 32 is the same on every
         * architecture Android runs on.
         */
        fun signalName(number: Int): String? =
            when (number) {
                1 -> "SIGHUP"
                2 -> "SIGINT"
                3 -> "SIGQUIT"
                4 -> "SIGILL"
                5 -> "SIGTRAP"
                6 -> "SIGABRT"
                7 -> "SIGBUS"
                8 -> "SIGFPE"
                9 -> "SIGKILL"
                10 -> "SIGUSR1"
                11 -> "SIGSEGV"
                12 -> "SIGUSR2"
                13 -> "SIGPIPE"
                14 -> "SIGALRM"
                15 -> "SIGTERM"
                16 -> "SIGSTKFLT"
                31 -> "SIGSYS"
                else -> null
            }
    }
}

/**
 * Reads at most [limit] bytes and says whether there was more.
 */
internal fun readBounded(stream: InputStream, limit: Int): Pair<ByteArray, Boolean> {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1024)
    var total = 0
    while (total < limit) {
        val read = stream.read(buffer, 0, minOf(buffer.size, limit - total))
        if (read < 0) return out.toByteArray() to false
        out.write(buffer, 0, read)
        total += read
    }
    return out.toByteArray() to (stream.read() >= 0)
}

/**
 * The [ExitInfoSource] for this device.
 *
 * The API 30 class is only constructed inside the lambda, so a device below
 * that never loads it.
 */
internal fun exitInfoSource(context: Context): ExitInfoSource {
    val sdkInt = Build.VERSION.SDK_INT
    return ExitInfoSource(
        records = ExitRecords { AndroidExitRecords(context).historical() },
        directory = File(context.noBackupFilesDir, "otel_zone"),
        sdkInt = sdkInt,
        lowMemoryReportSupported = isLowMemoryReportSupported(sdkInt),
    )
}
