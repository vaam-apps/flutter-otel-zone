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
 * anything at the moment it dies. The app's version and build go in the same
 * bytes, for the same reason: the launch that reports the exit may be a newer
 * build, and only the process that died knows which one it was.
 *
 * Minted natively, per process, because Dart has no session concept yet:
 * `otel_zone` exports no `session.id` of its own, and the id has to exist
 * before the Dart VM does (a crash during startup is exactly the one worth
 * tying to a session). When Dart grows one, the seam is [id].
 */
internal object RunSession {

    /** One per process start. Multi-process apps get one per process. */
    val id: String by lazy { UUID.randomUUID().toString() }

    /**
     * What a process's summary says about its run.
     *
     * Every part but the session is optional, and a summary written before
     * the build was recorded (see [decodeTag]) has only the session. The
     * [screen] is absent in every summary written before it was recorded.
     */
    class Tag(
        val sessionId: String?,
        val versionName: String?,
        val buildId: String?,
        val screen: String? = null,
    )

    /**
     * The summary for a run: the session id and, when known, the build that
     * is running.
     *
     * **Format 1**, compact and length-prefixed, because the OS keeps at most
     * 128 bytes and a session id alone is 36 of them:
     *
     *     0x01 | len | session id | len | versionName | len | buildId
     *
     * **Format 2** is format 1 with one more field, the screen, after the build
     * id, and the first byte is 0x02:
     *
     *     0x02 | len | session id | len | versionName | len | buildId | len | screen
     *
     * Each `len` is one byte, and each field is UTF-8 (the build id is decimal
     * digits). A field that is not known is written with length 0. A summary
     * with no screen is format 1, byte for byte what the previous release
     * wrote. The first byte is what tells this from a **legacy** summary, which
     * is the bare session id as text: text never starts with 0x01 or 0x02.
     *
     * The limit is enforced here, not hoped for. When everything does not fit,
     * the screen is left out first, then the version, then the build id; a value
     * is never truncated, because a cut version or a cut route is a wrong one.
     */
    fun encode(
        sessionId: String,
        build: AppBuild = AppBuild.UNKNOWN,
        screen: String? = null,
    ): ByteArray {
        val session = sessionId.toByteArray(Charsets.UTF_8)
        require(session.size in 1..MAX_SESSION_ID_BYTES) { "session id is ${session.size} bytes" }
        var version = build.versionName?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        var buildId = build.buildId?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        var named = CrashScreen.clean(screen)?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)

        fun size() =
            1 + (1 + session.size) + (1 + version.size) + (1 + buildId.size) +
                (if (named.isEmpty()) 0 else 1 + named.size)
        if (version.size > MAX_VERSION_BYTES) version = ByteArray(0)
        if (buildId.size > MAX_BUILD_ID_BYTES) buildId = ByteArray(0)
        if (size() > MAX_SUMMARY_BYTES) named = ByteArray(0)
        if (size() > MAX_SUMMARY_BYTES) version = ByteArray(0)
        if (size() > MAX_SUMMARY_BYTES) buildId = ByteArray(0)

        val fields = if (named.isEmpty()) {
            listOf(session, version, buildId)
        } else {
            listOf(session, version, buildId, named)
        }
        val format = if (named.isEmpty()) FORMAT_1 else FORMAT_2
        val out = java.io.ByteArrayOutputStream(size())
        out.write(format.toInt())
        for (field in fields) {
            out.write(field.size)
            out.write(field)
        }
        return out.toByteArray()
    }

    /**
     * The session id in a summary, or `null` when it is not one of ours.
     * See [decodeTag] for the rest of what a summary can say.
     */
    fun decode(summary: ByteArray?): String? = decodeTag(summary)?.sessionId

    /**
     * What a summary says about its run, or `null` when it is not one of ours.
     *
     * The bytes come from the OS but any app code can also write them, so
     * they are read as untrusted. Three shapes are accepted: format 1 and
     * format 2 of [encode], and the legacy bare session id. A summary that is
     * none of these, or whose structure does not add up (a format 2 summary
     * without its screen field counts), is `null`. Inside a well-formed
     * summary a field that does not look like what it should (a version with
     * control characters, a build id that is not digits, a screen that is not
     * [CrashScreen.clean]) is absent rather than exported. Nothing here guesses:
     * a legacy summary has no build and no screen, and that means *unknown*,
     * never the current one.
     */
    fun decodeTag(summary: ByteArray?): Tag? {
        if (summary == null || summary.isEmpty() || summary.size > MAX_SUMMARY_BYTES) return null
        if (summary[0] != FORMAT_1 && summary[0] != FORMAT_2) {
            val text = String(summary, Charsets.UTF_8)
            return text.takeIf { SESSION_ID.matches(it) }?.let { Tag(it, null, null) }
        }
        val fieldCount = if (summary[0] == FORMAT_2) FORMAT_2_FIELD_COUNT else FIELD_COUNT
        var offset = 1
        val fields = ArrayList<ByteArray>(fieldCount)
        repeat(fieldCount) {
            if (offset >= summary.size) return null
            val length = summary[offset++].toInt() and 0xff
            if (offset + length > summary.size) return null
            fields.add(summary.copyOfRange(offset, offset + length))
            offset += length
        }
        if (offset != summary.size) return null

        val session = strictText(fields[0])?.takeIf { SESSION_ID.matches(it) } ?: return null
        val version = strictText(fields[1])?.takeIf { it.isNotBlank() && it.none(Char::isISOControl) }
        val buildId = strictText(fields[2])?.takeIf { BUILD_ID.matches(it) }
        val screen = if (fieldCount == FORMAT_2_FIELD_COUNT) {
            strictText(fields[3])?.let { CrashScreen.clean(it) }
        } else {
            null
        }
        return Tag(session, version, buildId, screen)
    }

    /** UTF-8 that is exactly UTF-8: malformed input is `null`, not U+FFFD. */
    private fun strictText(bytes: ByteArray): String? =
        try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            null
        }

    /**
     * Writes [sessionId], [build] and [screen] as this process's summary.
     * Returns whether it did.
     *
     * [setSummary] is `ActivityManager.setProcessStateSummary`, passed in so
     * the API gate and the failure handling can be tested. It is only called
     * on API 30+, and never lets a failure out: tagging a run is a nicety and
     * must not be able to stop the app starting.
     */
    fun tag(
        sdkInt: Int = Build.VERSION.SDK_INT,
        sessionId: String = id,
        build: AppBuild = AppBuild.UNKNOWN,
        screen: String? = null,
        setSummary: (ByteArray) -> Unit,
    ): Boolean {
        if (sdkInt < Build.VERSION_CODES.R) return false
        return try {
            setSummary(encode(sessionId, build, screen))
            true
        } catch (_: Exception) {
            false
        }
    }

    /** The OS's limit on `setProcessStateSummary`. */
    const val MAX_SUMMARY_BYTES = 128

    private const val FORMAT_1: Byte = 1
    private const val FORMAT_2: Byte = 2
    private const val FIELD_COUNT = 3
    private const val FORMAT_2_FIELD_COUNT = 4
    private const val MAX_SESSION_ID_BYTES = 64
    private const val MAX_VERSION_BYTES = 64
    private const val MAX_BUILD_ID_BYTES = 20
    private val SESSION_ID = Regex("^[A-Za-z0-9-]{1,64}$")
    private val BUILD_ID = Regex("^[0-9]{1,20}$")
}
