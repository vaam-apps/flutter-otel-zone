package com.vaam.otel_zone

import java.util.Locale

/**
 * One frame of a native backtrace, as `debuggerd` recorded it.
 */
internal data class TombstoneFrame(
    val pc: Long,
    val relativePc: Long,
    val functionName: String?,
    val functionOffset: Long,
    val fileName: String?,
    val buildId: String?,
)

/**
 * The parts of a `tombstone.proto` that a crash report needs.
 *
 * [frames] are the crashing thread's only. Every other thread, register,
 * memory dump and log buffer in the tombstone is deliberately never read.
 */
internal data class Tombstone(
    val signalNumber: Int?,
    val signalName: String?,
    val signalCode: Int?,
    val signalCodeName: String?,
    val faultAddress: Long?,
    val abortMessage: String?,
    val crashingThreadId: Int?,
    val crashingThreadName: String?,
    val frames: List<TombstoneFrame>,
    /** How many frames the crashing thread had beyond [MAX_FRAMES]. */
    val droppedFrames: Int,
)

/**
 * Reads a `tombstone.proto` with a hand-written protobuf wire-format decoder.
 *
 * A generated protobuf-lite decoder would be the conventional route, and it
 * was the ticket's other option. It was not taken because it costs more than
 * it buys here: a runtime dependency in every consuming app (and its R8
 * rules), the protoc Gradle plugin in the build, and a vendored copy of a
 * schema that AOSP owns — all to read about a dozen fields out of a message
 * with well over a hundred. The wire format itself is four wire types and has
 * been frozen since 2008, and protobuf's own compatibility rule is that a
 * field number is never reused, so the numbers below cannot silently change
 * meaning. What can drift is the schema *gaining* fields, and a decoder that
 * skips what it does not know is exactly what tolerates that.
 *
 * The decoder is lenient on purpose. A tombstone reaches here after a
 * process has died, possibly truncated by [readBounded]'s cap, and a partial
 * answer (the signal but not the frames, say) is worth more than none. A
 * malformed or truncated message ends that message's scan and keeps
 * whatever was read before it; this never throws.
 *
 * Field numbers, from AOSP `debuggerd/proto/tombstone.proto`:
 *
 * - `Tombstone`: `tid = 6`, `signal_info = 10`, `abort_message = 14`,
 *   `threads = 16` (a `map<uint32, Thread>`, which the wire carries as
 *   repeated entries of `key = 1`, `value = 2`)
 * - `Signal`: `number = 1`, `name = 2`, `code = 3`, `code_name = 4`,
 *   `has_fault_address = 8`, `fault_address = 9`
 * - `Thread`: `id = 1`, `name = 2`, `current_backtrace = 4`
 * - `BacktraceFrame`: `rel_pc = 1`, `pc = 2`, `function_name = 4`,
 *   `function_offset = 5`, `file_name = 6`, `build_id = 8`
 */
internal object TombstoneDecoder {

    /** Frames kept per report; a stack-overflow crash has thousands. */
    const val MAX_FRAMES = 128

    /** An abort message is free text from the app, so it is bounded. */
    const val MAX_TEXT_CHARS = 4096

    /**
     * The crashing thread's summary, or `null` when [bytes] holds nothing
     * recognisable as a tombstone.
     */
    fun decode(bytes: ByteArray): Tombstone? {
        var threadId: Int? = null
        var signal: SignalFields? = null
        var abortMessage: String? = null
        // Threads are located, not parsed, while scanning: `tid` is field 6
        // and `threads` is field 16, so on the wire the id normally comes
        // first, but the format does not promise order and a thread's frames
        // are only worth decoding once we know whose they are.
        val threads = mutableListOf<Range>()

        scan(Reader(bytes, 0, bytes.size)) { field, reader ->
            when (field) {
                6 -> threadId = reader.varint().toInt()
                10 -> signal = decodeSignal(reader.lengthDelimited())
                14 -> abortMessage = reader.text()
                16 -> threads.add(reader.lengthDelimited().range())
                else -> reader.skip()
            }
        }

        var thread: ThreadFields? = null
        for (range in threads) {
            val (key, value) = decodeThreadEntry(Reader(bytes, range.start, range.end)) ?: continue
            if (key == threadId) {
                thread = decodeThread(value)
                break
            }
        }

        val found = signal != null || abortMessage != null || thread != null
        if (!found) return null

        val allFrames = thread?.frames.orEmpty()
        return Tombstone(
            signalNumber = signal?.number,
            signalName = signal?.name,
            signalCode = signal?.code,
            signalCodeName = signal?.codeName,
            faultAddress = signal?.faultAddress,
            abortMessage = abortMessage,
            crashingThreadId = threadId,
            crashingThreadName = thread?.name,
            frames = allFrames.take(MAX_FRAMES),
            droppedFrames = (allFrames.size - MAX_FRAMES).coerceAtLeast(0),
        )
    }

    /**
     * One line per frame, in the shape `logcat` and the tombstone's own text
     * form use, so that an engineer reading it needs no key:
     *
     *     #00 pc 0x1234  /path/libapp.so (crash_now+24) (BuildId: 0123…)
     */
    fun format(frames: List<TombstoneFrame>, droppedFrames: Int = 0): String =
        buildString {
            frames.forEachIndexed { index, frame ->
                append(String.format(Locale.ROOT, "#%02d pc 0x%x", index, frame.relativePc.takeIf { it != 0L } ?: frame.pc))
                frame.fileName?.let { append("  ").append(it) }
                frame.functionName?.let { name ->
                    append(" (").append(name)
                    if (frame.functionOffset != 0L) append('+').append(frame.functionOffset)
                    append(')')
                }
                frame.buildId?.let { append(" (BuildId: ").append(it).append(')') }
                append('\n')
            }
            if (droppedFrames > 0) append("... $droppedFrames more frames not shown\n")
        }.trimEnd()

    private class SignalFields(
        var number: Int? = null,
        var name: String? = null,
        var code: Int? = null,
        var codeName: String? = null,
        var hasFaultAddress: Boolean = false,
        var faultAddress: Long? = null,
    )

    private class ThreadFields(
        var name: String? = null,
        val frames: MutableList<TombstoneFrame> = mutableListOf(),
    )

    private fun decodeSignal(reader: Reader): SignalFields {
        val signal = SignalFields()
        scan(reader) { field, r ->
            when (field) {
                1 -> signal.number = r.varint().toInt()
                2 -> signal.name = r.text()
                3 -> signal.code = r.varint().toInt()
                4 -> signal.codeName = r.text()
                8 -> signal.hasFaultAddress = r.varint() != 0L
                9 -> signal.faultAddress = r.varint()
                else -> r.skip()
            }
        }
        // `has_fault_address` is what says a zero address means "address 0"
        // rather than "no address"; without it the field carries no claim.
        if (!signal.hasFaultAddress) signal.faultAddress = null
        return signal
    }

    /** One `map<uint32, Thread>` entry: its key and the value's bytes. */
    private fun decodeThreadEntry(reader: Reader): Pair<Int, Reader>? {
        var key: Int? = null
        var value: Reader? = null
        scan(reader) { field, r ->
            when (field) {
                1 -> key = r.varint().toInt()
                2 -> value = r.lengthDelimited()
                else -> r.skip()
            }
        }
        val k = key ?: return null
        val v = value ?: return null
        return k to v
    }

    private fun decodeThread(reader: Reader): ThreadFields {
        val thread = ThreadFields()
        scan(reader) { field, r ->
            when (field) {
                2 -> thread.name = r.text()
                4 -> thread.frames.add(decodeFrame(r.lengthDelimited()))
                else -> r.skip()
            }
        }
        return thread
    }

    private fun decodeFrame(reader: Reader): TombstoneFrame {
        var relPc = 0L
        var pc = 0L
        var functionName: String? = null
        var functionOffset = 0L
        var fileName: String? = null
        var buildId: String? = null
        scan(reader) { field, r ->
            when (field) {
                1 -> relPc = r.varint()
                2 -> pc = r.varint()
                4 -> functionName = r.text()
                5 -> functionOffset = r.varint()
                6 -> fileName = r.text()
                8 -> buildId = r.text()
                else -> r.skip()
            }
        }
        return TombstoneFrame(pc, relPc, functionName, functionOffset, fileName, buildId)
    }

    /**
     * Walks one message's fields, calling [onField] for each and stopping
     * quietly at the first thing that cannot be read.
     */
    private inline fun scan(reader: Reader, onField: (field: Int, reader: Reader) -> Unit) {
        try {
            while (reader.hasMore()) {
                val tag = reader.rawVarint()
                val field = (tag ushr 3).toInt()
                reader.wireType = (tag and 7).toInt()
                if (field <= 0) return
                onField(field, reader)
            }
        } catch (_: MalformedProtobuf) {
            // Truncated or corrupt: keep what was read.
        }
    }

    private class MalformedProtobuf : Exception()

    private class Range(val start: Int, val end: Int)

    /**
     * A cursor over `[start, end)` of [bytes]. Every read is bounds-checked
     * against `end`, so a length that lies about its size cannot read into the
     * next field or off the array.
     */
    private class Reader(private val bytes: ByteArray, start: Int, private val end: Int) {
        private var position = start
        private val begin = start
        var wireType = 0

        fun hasMore(): Boolean = position < end

        fun range(): Range = Range(begin, end)

        fun varint(): Long {
            expect(WIRE_VARINT)
            return rawVarint()
        }

        /** A length-delimited field's payload, as its own cursor. */
        fun lengthDelimited(): Reader {
            expect(WIRE_LEN)
            val length = rawVarint()
            if (length < 0 || length > end - position) throw MalformedProtobuf()
            val start = position
            position += length.toInt()
            return Reader(bytes, start, position)
        }

        fun text(): String {
            val payload = lengthDelimited()
            val length = minOf(payload.end - payload.begin, MAX_TEXT_BYTES)
            return String(bytes, payload.begin, length, Charsets.UTF_8).take(MAX_TEXT_CHARS)
        }

        fun skip() {
            when (wireType) {
                WIRE_VARINT -> varint()
                WIRE_FIXED64 -> advance(8)
                WIRE_LEN -> lengthDelimited()
                WIRE_FIXED32 -> advance(4)
                // Groups were deprecated before tombstones existed.
                else -> throw MalformedProtobuf()
            }
        }

        private fun advance(count: Int) {
            if (count > end - position) throw MalformedProtobuf()
            position += count
        }

        fun rawVarint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                if (position >= end || shift > 63) throw MalformedProtobuf()
                val b = bytes[position++].toInt()
                result = result or ((b and 0x7f).toLong() shl shift)
                if (b and 0x80 == 0) return result
                shift += 7
            }
        }

        private fun expect(expected: Int) {
            if (wireType != expected) throw MalformedProtobuf()
        }
    }

    private const val WIRE_VARINT = 0
    private const val WIRE_FIXED64 = 1
    private const val WIRE_LEN = 2
    private const val WIRE_FIXED32 = 5

    /** UTF-8 can take four bytes a char; cap the copy before decoding. */
    private const val MAX_TEXT_BYTES = MAX_TEXT_CHARS * 4
}
