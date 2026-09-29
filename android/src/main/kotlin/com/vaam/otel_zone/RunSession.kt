package com.vaam.otel_zone

import android.os.Build
import java.util.UUID

/**
 * The identity of this process's run, so its exit record can be tied back to
 * the run that produced it.
 *
 * The OS keeps a small byte string per process and hands it back on that
 * process's `ApplicationExitInfo` after it dies (`setProcessStateSummary`).
 * Writing the session id there is what lets a report from the next launch say
 * *which* session it ended, without the dying process having to write
 * anything at the moment it dies.
 *
 * Minted natively, per process, because Dart has no session concept yet:
 * `otel_zone` exports no `session.id` of its own, and the id has to exist
 * before the Dart VM does (a crash during startup is exactly the one worth
 * tying to a session). When Dart grows one, the seam is [id].
 */
internal object RunSession {

    /** One per process start. Multi-process apps get one per process. */
    val id: String by lazy { UUID.randomUUID().toString() }

    /** The summary must stay under the OS's 128-byte limit; a UUID is 36. */
    fun encode(sessionId: String): ByteArray = sessionId.toByteArray(Charsets.UTF_8)

    /**
     * The session id in a summary, or `null` when it is not one of ours.
     *
     * The bytes come from the OS but any app code can also write them, so
     * they are read as untrusted: only the shape [id] produces is accepted,
     * and anything else is treated as absent rather than exported.
     */
    fun decode(summary: ByteArray?): String? {
        if (summary == null || summary.isEmpty() || summary.size > MAX_SUMMARY_BYTES) return null
        val text = String(summary, Charsets.UTF_8)
        return text.takeIf { SESSION_ID.matches(it) }
    }

    /**
     * Writes [sessionId] as this process's summary. Returns whether it did.
     *
     * [setSummary] is `ActivityManager.setProcessStateSummary`, passed in so
     * the API gate and the failure handling can be tested. It is only called
     * on API 30+, and never lets a failure out: tagging a run is a nicety and
     * must not be able to stop the app starting.
     */
    fun tag(
        sdkInt: Int = Build.VERSION.SDK_INT,
        sessionId: String = id,
        setSummary: (ByteArray) -> Unit,
    ): Boolean {
        if (sdkInt < Build.VERSION_CODES.R) return false
        return try {
            setSummary(encode(sessionId))
            true
        } catch (_: Exception) {
            false
        }
    }

    private const val MAX_SUMMARY_BYTES = 128
    private val SESSION_ID = Regex("^[A-Za-z0-9-]{1,64}$")
}
