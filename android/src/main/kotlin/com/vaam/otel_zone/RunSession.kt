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
     * the build was recorded (see [decodeTag]) has only the session.
     */
    class Tag(
        val sessionId: String?,
        val versionName: String?,
        val buildId: String?,
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
     * Each `len` is one byte, and each field is UTF-8 (the build id is decimal
     * digits). A field that is not known is written with length 0. The first
     * byte is what tells this from a **legacy** summary, which is the bare
     * session id as text: text never starts with 0x01.
     *
     * The limit is enforced here, not hoped for. When everything does not fit,
     * the version is left out first and the build id second; a value is never
     * truncated, because a cut version is a wrong one.
     */
    fun encode(sessionId: String, build: AppBuild = AppBuild.UNKNOWN): ByteArray {
        val session = sessionId.toByteArray(Charsets.UTF_8)
        require(session.size in 1..MAX_SESSION_ID_BYTES) { "session id is ${session.size} bytes" }
        var version = build.versionName?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        var buildId = build.buildId?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)

        fun size() = 1 + (1 + session.size) + (1 + version.size) + (1 + buildId.size)
        if (version.size > MAX_VERSION_BYTES) version = ByteArray(0)
        if (buildId.size > MAX_BUILD_ID_BYTES) buildId = ByteArray(0)
        if (size() > MAX_SUMMARY_BYTES) version = ByteArray(0)
        if (size() > MAX_SUMMARY_BYTES) buildId = ByteArray(0)

        val out = java.io.ByteArrayOutputStream(size())
        out.write(FORMAT_1.toInt())
        for (field in listOf(session, version, buildId)) {
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
     * they are read as untrusted. Two shapes are accepted: the current
     * [encode] format, and the legacy bare session id. A summary that is
     * neither, or whose structure does not add up, is `null`. Inside a
     * well-formed summary a field that does not look like what it should
     * (a version with control characters, a build id that is not digits) is
     * absent rather than exported. Nothing here guesses: a legacy summary has
     * no build, and that means *unknown*, never the current one.
     */
    fun decodeTag(summary: ByteArray?): Tag? {
        if (summary == null || summary.isEmpty() || summary.size > MAX_SUMMARY_BYTES) return null
        if (summary[0] != FORMAT_1) {
            val text = String(summary, Charsets.UTF_8)
            return text.takeIf { SESSION_ID.matches(it) }?.let { Tag(it, null, null) }
        }
        var offset = 1
        val fields = ArrayList<ByteArray>(FIELD_COUNT)
        repeat(FIELD_COUNT) {
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
        return Tag(session, version, buildId)
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
     * Writes [sessionId] and [build] as this process's summary. Returns
     * whether it did.
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
        setSummary: (ByteArray) -> Unit,
    ): Boolean {
        if (sdkInt < Build.VERSION_CODES.R) return false
        return try {
            setSummary(encode(sessionId, build))
            true
        } catch (_: Exception) {
            false
        }
    }

    /** The OS's limit on `setProcessStateSummary`. */
    const val MAX_SUMMARY_BYTES = 128

    private const val FORMAT_1: Byte = 1
    private const val FIELD_COUNT = 3
    private const val MAX_SESSION_ID_BYTES = 64
    private const val MAX_VERSION_BYTES = 64
    private const val MAX_BUILD_ID_BYTES = 20
    private val SESSION_ID = Regex("^[A-Za-z0-9-]{1,64}$")
    private val BUILD_ID = Regex("^[0-9]{1,20}$")
}
