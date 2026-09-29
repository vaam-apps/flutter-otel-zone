package com.vaam.otel_zone

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.InputStream

/**
 * One entry of the OS's record of why a process of this app died.
 *
 * A plain value so [ExitInfoSource] can be tested without an
 * [ApplicationExitInfo], which is a final framework class no unit test can
 * construct.
 */
internal class ExitRecord(
    val pid: Int,
    val processName: String?,
    val timestampMillis: Long,
    /** One of `ApplicationExitInfo.REASON_*`. */
    val reason: Int,
    /** A signal number for a native crash or a signal, an exit code otherwise. */
    val status: Int,
    val importance: Int,
    val description: String?,
    val processStateSummary: ByteArray?,
    val pssKb: Long,
    val rssKb: Long,
    private val openTrace: () -> InputStream?,
) {
    /**
     * The trace the OS took before the process died, or `null` when it did
     * not keep one. A trace that cannot be opened is the same answer: the
     * record is still worth reporting without it.
     */
    fun trace(): InputStream? =
        try {
            openTrace()
        } catch (_: Exception) {
            null
        }
}

/**
 * The OS's exit records for this package, newest first as the OS keeps them.
 */
internal fun interface ExitRecords {
    fun historical(): List<ExitRecord>
}

/**
 * [ExitRecords] over `ActivityManager.getHistoricalProcessExitReasons`.
 *
 * `(packageName, 0, 0)` asks for every process of this package, up to the
 * OS's own cap, which is the only way to see a process other than the one
 * asking. Only ever constructed on API 30+, which is where the call exists.
 */
@RequiresApi(Build.VERSION_CODES.R)
internal class AndroidExitRecords(context: Context) : ExitRecords {

    private val activityManager =
        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private val packageName = context.packageName

    override fun historical(): List<ExitRecord> =
        activityManager.getHistoricalProcessExitReasons(packageName, 0, 0).map { info ->
            ExitRecord(
                pid = info.pid,
                processName = info.processName,
                timestampMillis = info.timestamp,
                reason = info.reason,
                status = info.status,
                importance = info.importance,
                description = info.description,
                processStateSummary = info.processStateSummary,
                pssKb = info.pss,
                rssKb = info.rss,
                openTrace = { info.traceInputStream },
            )
        }
}

/**
 * Whether the OS distinguishes a low-memory kill from any other `SIGKILL`.
 *
 * Where it does not, an `lmkd` kill arrives as `REASON_SIGNALED` with status
 * 9, indistinguishable from a real one, and that is worth saying on the
 * record rather than leaving a reader to assume.
 */
internal fun isLowMemoryReportSupported(sdkInt: Int): Boolean =
    sdkInt >= Build.VERSION_CODES.R && ActivityManager.isLowMemoryKillReportSupported()
