package com.vaam.otel_zone

import android.app.ApplicationExitInfo
import kotlin.math.abs

/**
 * Every unacknowledged report on this device, from both places it can come
 * from: the JVM handler's files and the OS's exit records.
 *
 * The two overlap. A JVM crash is seen twice, once by the handler (which has
 * the stack trace) and once by the OS as `REASON_CRASH` (which has the
 * session, the process and the memory figures, and no trace). Reporting both
 * would file every JVM crash as two FATAL records, so they are joined.
 *
 * **The rule.** A `REASON_CRASH` exit record and a JVM report are the same
 * crash when they name the same process and their timestamps are within
 * [CORRELATION_WINDOW_MILLIS] of each other. The process is compared through
 * the `process.pid` attribute the store writes. A report without one (left by
 * a build that did not record it) is never joined: the window alone cannot say
 * which of an app's processes it came from, and a wrong join files one
 * process's trace under another's exit record. The price is one duplicate for
 * such a leftover. When several reports qualify the nearest in time wins, ties
 * broken by id, and one report joins at most one exit record.
 *
 * The joined record keeps the JVM report's content (its trace is the point)
 * and takes the exit record's id, the session and the exit attributes. Its
 * id is the exit record's, because that is what has to be acknowledged for
 * the OS watermark to move; acknowledging it deletes the JVM file it
 * absorbed, found again by the same rule. A JVM report with no exit record —
 * below API 30, past the OS's retention, or its timestamp outside the window
 * — is reported on its own, as before.
 */
internal class CrashReports(
    private val store: CrashStore,
    private val exitInfo: ExitInfoSource,
) {

    fun pending(): List<NativeCrashReport> {
        val unmatched = store.pending().toMutableList()
        val reports = mutableListOf<NativeCrashReport>()

        for (entry in exitInfo.pending()) {
            val joined = if (entry.id.reason == ApplicationExitInfo.REASON_CRASH) {
                nearestJvmReport(unmatched, entry.id)
            } else {
                null
            }
            if (joined == null) {
                reports.add(entry.report)
            } else {
                unmatched.remove(joined)
                reports.add(merge(joined, entry.report))
            }
        }
        reports.addAll(unmatched)
        return reports.sortedBy { it.timestampMicros }
    }

    /**
     * Acknowledges [ids] across both sources.
     *
     * The watermark moves first. If that write fails nothing else has been
     * touched, so the next launch sees the same joined record again; the other
     * order could delete the JVM file and then re-report the crash from the OS
     * record alone, without its trace.
     */
    fun acknowledge(ids: List<String>) {
        val (exitIds, jvmIds) = ids.partition { it.startsWith(ExitId.PREFIX) }
        val accepted = exitInfo.acknowledge(exitIds)

        val crashIds = accepted.filter { it.reason == ApplicationExitInfo.REASON_CRASH }
        if (crashIds.isNotEmpty()) {
            val candidates = store.pending().toMutableList()
            val absorbed = mutableListOf<String>()
            for (id in crashIds) {
                val match = nearestJvmReport(candidates, id) ?: continue
                candidates.remove(match)
                absorbed.add(match.id)
            }
            store.acknowledge(absorbed)
        }
        store.acknowledge(jvmIds)
    }

    private fun merge(jvm: NativeCrashReport, exit: NativeCrashReport): NativeCrashReport =
        NativeCrashReport(
            id = exit.id,
            kind = jvm.kind,
            timestampMicros = jvm.timestampMicros,
            type = jvm.type,
            message = jvm.message,
            stacktrace = jvm.stacktrace,
            threads = jvm.threads,
            sessionId = exit.sessionId ?: jvm.sessionId,
            attributes = (jvm.attributes.orEmpty() + exit.attributes.orEmpty()),
        )

    companion object {
        /**
         * How far apart a JVM report and its exit record can be. The handler
         * stamps the report when the exception is thrown and the OS stamps the
         * death once the process is gone, with the previous handler chain
         * (another reporter, the crash dialog) in between. Seconds in
         * practice; this is generous enough for a slow chained reporter and
         * far below the gap between two distinct crashes of one process,
         * which is a whole restart.
         */
        const val CORRELATION_WINDOW_MILLIS = 30_000L

        /** The JVM report that [id]'s record is the OS's view of, if any. */
        fun nearestJvmReport(candidates: List<NativeCrashReport>, id: ExitId): NativeCrashReport? =
            candidates
                .filter { it.kind == "jvm" }
                .filter { it.attributes?.get("process.pid")?.toIntOrNull() == id.pid }
                .map { it to abs(it.timestampMicros / 1000L - id.timestampMillis) }
                .filter { (_, distance) -> distance <= CORRELATION_WINDOW_MILLIS }
                .minWithOrNull(compareBy({ it.second }, { it.first.id }))
                ?.first
    }
}
