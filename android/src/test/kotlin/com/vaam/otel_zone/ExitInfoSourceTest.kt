package com.vaam.otel_zone

import android.app.ApplicationExitInfo
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ExitInfoSourceTest {

    private val directory: File = Files.createTempDirectory("otel-zone-exit-info").toFile()
    private val now = 1_800_000_000_000L

    @AfterTest
    fun removeDirectory() {
        directory.deleteRecursively()
    }

    /**
     * A device's ring buffer, which returns the same records on every call.
     */
    private class Device(var records: List<ExitRecord> = emptyList()) : ExitRecords {
        var calls = 0

        override fun historical(): List<ExitRecord> {
            calls++
            return records
        }
    }

    private fun record(
        timestamp: Long,
        reason: Int,
        pid: Int = 100,
        status: Int = 0,
        description: String? = null,
        summary: ByteArray? = null,
        trace: () -> InputStream? = { null },
    ) = ExitRecord(
        pid = pid,
        processName = "com.example.app",
        timestampMillis = timestamp,
        reason = reason,
        status = status,
        importance = 100,
        description = description,
        processStateSummary = summary,
        pssKb = 0,
        rssKb = 0,
        openTrace = trace,
    )

    /** One process launch: a new source over the same directory and device. */
    private fun launch(
        device: ExitRecords,
        sdkInt: Int = 34,
        lowMemorySupported: Boolean = true,
    ) = ExitInfoSource(
        records = device,
        directory = directory,
        sdkInt = sdkInt,
        lowMemoryReportSupported = lowMemorySupported,
        nowMillis = { now },
    )

    private fun ExitInfoSource.pendingIds() = pending().map { it.report.id }

    private fun ExitInfoSource.acknowledgeAll() = acknowledge(pending().map { it.report.id })

    @Test
    fun `a native crash is returned by the first launch only, once acknowledged`() {
        val device = Device(listOf(record(now - 5_000, ApplicationExitInfo.REASON_CRASH_NATIVE, status = 11)))

        val first = launch(device)
        assertEquals(1, first.pending().size)
        first.acknowledgeAll()

        assertTrue(launch(device).pending().isEmpty(), "second launch")
        assertTrue(launch(device).pending().isEmpty(), "third launch")
    }

    @Test
    fun `a record that was read but not acknowledged is returned again`() {
        val device = Device(listOf(record(now - 5_000, ApplicationExitInfo.REASON_ANR)))

        // The process died between reading and spooling: no acknowledge.
        launch(device).pending()

        assertEquals(1, launch(device).pending().size)
    }

    @Test
    fun `a newer crash is returned after an older one was acknowledged`() {
        val older = record(now - 9_000, ApplicationExitInfo.REASON_CRASH_NATIVE, pid = 1, status = 11)
        val newer = record(now - 3_000, ApplicationExitInfo.REASON_CRASH_NATIVE, pid = 2, status = 6)
        val device = Device(listOf(older))
        launch(device).acknowledgeAll()

        device.records = listOf(newer, older)
        val third = launch(device)

        assertEquals(listOf(newer.timestampMillis), third.pending().map { it.id.timestampMillis })
    }

    @Test
    fun `the watermark moves only to the newest of the acknowledged ids`() {
        val a = record(now - 9_000, ApplicationExitInfo.REASON_ANR, pid = 1)
        val b = record(now - 6_000, ApplicationExitInfo.REASON_ANR, pid = 2)
        val c = record(now - 3_000, ApplicationExitInfo.REASON_ANR, pid = 3)
        val device = Device(listOf(c, b, a))
        val source = launch(device)
        val ids = source.pendingIds()

        // Acknowledging the middle one leaves the newest still pending.
        source.acknowledge(listOf(ids[1]))

        assertEquals(listOf(c.timestampMillis), source.pending().map { it.id.timestampMillis })
        assertEquals("${b.timestampMillis}", File(directory, "exit-info-watermark").readText())
    }

    @Test
    fun `the watermark never moves backwards`() {
        val newer = record(now - 3_000, ApplicationExitInfo.REASON_ANR, pid = 2)
        val older = record(now - 9_000, ApplicationExitInfo.REASON_ANR, pid = 1)
        val source = launch(Device(listOf(newer, older)))
        val ids = source.pendingIds()

        source.acknowledge(listOf(ids[1]))
        source.acknowledge(listOf(ids[0]))
        source.acknowledge(listOf(ids[0]))

        assertEquals("${newer.timestampMillis}", File(directory, "exit-info-watermark").readText())
    }

    @Test
    fun `exit-self and user-requested exits are skipped`() {
        val device = Device(
            listOf(
                record(now - 9_000, ApplicationExitInfo.REASON_EXIT_SELF, pid = 1),
                record(now - 8_000, ApplicationExitInfo.REASON_USER_REQUESTED, pid = 2),
                record(now - 7_000, ApplicationExitInfo.REASON_CRASH_NATIVE, pid = 3, status = 11),
            ),
        )

        val pending = launch(device).pending()

        assertEquals(listOf(3), pending.map { it.id.pid })
    }

    @Test
    fun `an app update, a permission toggle and a user stop are not faults`() {
        val skipped = listOf(
            ApplicationExitInfo.REASON_PACKAGE_UPDATED,
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE,
            ApplicationExitInfo.REASON_PERMISSION_CHANGE,
            ApplicationExitInfo.REASON_USER_STOPPED,
        )
        val device = Device(skipped.mapIndexed { i, reason -> record(now - 1_000L * (i + 1), reason, pid = i) })

        assertTrue(launch(device).pending().isEmpty())
    }

    @Test
    fun `skipped records do not move the watermark or hide later ones`() {
        val device = Device(listOf(record(now - 9_000, ApplicationExitInfo.REASON_EXIT_SELF)))
        val source = launch(device)
        assertTrue(source.pending().isEmpty())

        assertFalse(File(directory, "exit-info-watermark").exists())
    }

    @Test
    fun `reasons map to the kinds the schema defines`() {
        val device = Device(
            listOf(
                record(now - 7_000, ApplicationExitInfo.REASON_CRASH_NATIVE, pid = 1, status = 11),
                record(now - 6_000, ApplicationExitInfo.REASON_ANR, pid = 2),
                record(now - 5_000, ApplicationExitInfo.REASON_LOW_MEMORY, pid = 3, status = 9),
                record(now - 4_000, ApplicationExitInfo.REASON_SIGNALED, pid = 4, status = 6),
                record(now - 3_000, ApplicationExitInfo.REASON_CRASH, pid = 5),
                record(now - 2_000, ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE, pid = 6),
            ),
        )

        val reports = launch(device).pending().map { it.report }

        assertEquals(
            listOf("native", "anr", "signal", "signal", "jvm", "signal"),
            reports.map { it.kind },
        )
        assertEquals(
            listOf("SIGSEGV", "ANR", "LOW_MEMORY", "SIGABRT", "CRASH", "EXCESSIVE_RESOURCE_USAGE"),
            reports.map { it.type },
        )
        assertEquals("native", reports[0].kind)
        assertEquals("11", reports[0].attributes?.get("exit.status"))
        assertEquals("crash_native", reports[0].attributes?.get("exit.reason"))
    }

    @Test
    fun `a null trace stream still yields the record with reason and status`() {
        val device = Device(
            listOf(
                record(
                    now - 5_000,
                    ApplicationExitInfo.REASON_CRASH_NATIVE,
                    status = 11,
                    description = "signal 11 (SIGSEGV), code 1 (SEGV_MAPERR)",
                    trace = { null },
                ),
                record(now - 4_000, ApplicationExitInfo.REASON_ANR, pid = 101, trace = { null }),
            ),
        )

        val (native, anr) = launch(device).pending().map { it.report }

        assertEquals("SIGSEGV", native.type)
        assertEquals("signal 11 (SIGSEGV), code 1 (SEGV_MAPERR)", native.message)
        assertNull(native.stacktrace)
        assertEquals("false", native.attributes?.get("exit.trace_available"))
        assertNull(anr.stacktrace)
        assertEquals("false", anr.attributes?.get("exit.trace_available"))
    }

    @Test
    fun `a trace stream that throws still yields the record`() {
        val device = Device(
            listOf(
                record(
                    now - 5_000,
                    ApplicationExitInfo.REASON_CRASH_NATIVE,
                    status = 6,
                    trace = { throw IOException("gone") },
                ),
            ),
        )

        val report = launch(device).pending().single().report

        assertEquals("SIGABRT", report.type)
        assertNull(report.stacktrace)
    }

    @Test
    fun `a native crash on API 31 carries the tombstone's signal, message and frames`() {
        val tombstone = checkNotNull(javaClass.getResourceAsStream("/tombstone/native-crash.bin")).readBytes()
        val device = Device(
            listOf(
                record(
                    now - 5_000,
                    ApplicationExitInfo.REASON_CRASH_NATIVE,
                    status = 11,
                    description = "signal 11",
                    trace = { ByteArrayInputStream(tombstone) },
                ),
            ),
        )

        val report = launch(device, sdkInt = 34).pending().single().report

        assertEquals("SIGSEGV", report.type)
        assertTrue(report.message.orEmpty().startsWith("Fatal signal 11"))
        assertTrue(report.stacktrace.orEmpty().contains("crash_now+24"))
        assertTrue(report.stacktrace.orEmpty().contains("BuildId: 0123456789abcdef"))
        assertEquals("0x10", report.attributes?.get("signal.fault_address"))
        assertEquals("1.ui", report.attributes?.get("crash.thread.name"))
        assertNull(report.attributes?.get("exit.trace_available"))
    }

    @Test
    fun `on API 30 the tombstone is not parsed`() {
        val tombstone = checkNotNull(javaClass.getResourceAsStream("/tombstone/native-crash.bin")).readBytes()
        val device = Device(
            listOf(
                record(
                    now - 5_000,
                    ApplicationExitInfo.REASON_CRASH_NATIVE,
                    status = 11,
                    trace = { ByteArrayInputStream(tombstone) },
                ),
            ),
        )

        val report = launch(device, sdkInt = 30).pending().single().report

        assertEquals("SIGSEGV", report.type)
        assertNull(report.stacktrace)
        assertEquals("false", report.attributes?.get("exit.trace_available"))
    }

    @Test
    fun `an anr trace is included and bounded`() {
        val text = "\"main\" prio=5 tid=1 Blocked\n" + "  at Foo.bar(Foo.java:1)\n".repeat(10_000)
        val device = Device(
            listOf(
                record(now - 5_000, ApplicationExitInfo.REASON_ANR, trace = { ByteArrayInputStream(text.toByteArray()) }),
            ),
        )

        val trace = assertNotNull(launch(device).pending().single().report.stacktrace)

        assertTrue(trace.startsWith("\"main\" prio=5"))
        assertTrue(trace.contains("trace truncated"))
        assertTrue(trace.length < ExitInfoSource.MAX_ANR_TRACE_BYTES + 200)
    }

    @Test
    fun `a short anr trace is not marked truncated`() {
        val device = Device(
            listOf(
                record(now - 5_000, ApplicationExitInfo.REASON_ANR, trace = { ByteArrayInputStream("\"main\"".toByteArray()) }),
            ),
        )

        assertEquals("\"main\"", launch(device).pending().single().report.stacktrace)
    }

    @Test
    fun `the previous run's session id is on its exit record`() {
        val device = Device(
            listOf(
                record(
                    now - 5_000,
                    ApplicationExitInfo.REASON_CRASH_NATIVE,
                    status = 11,
                    summary = RunSession.encode("6f1c2a3e-1111-4222-8333-444455556666"),
                ),
                record(now - 4_000, ApplicationExitInfo.REASON_ANR, pid = 101, summary = "not a session!".toByteArray()),
                record(now - 3_000, ApplicationExitInfo.REASON_ANR, pid = 102, summary = null),
            ),
        )

        val (withSession, malformed, absent) = launch(device).pending().map { it.report }

        assertEquals("6f1c2a3e-1111-4222-8333-444455556666", withSession.sessionId)
        assertNull(malformed.sessionId)
        assertNull(absent.sessionId)
    }

    @Test
    fun `a sigkill says whether the OS can tell a low-memory kill apart`() {
        val kill = record(now - 5_000, ApplicationExitInfo.REASON_SIGNALED, status = 9)

        val unsupported = launch(Device(listOf(kill)), lowMemorySupported = false).pending().single().report
        val supported = launch(Device(listOf(kill)), lowMemorySupported = true).pending().single().report

        assertEquals("false", unsupported.attributes?.get("exit.low_memory_report_supported"))
        assertNull(supported.attributes?.get("exit.low_memory_report_supported"))
    }

    @Test
    fun `below API 30 nothing is returned, acknowledged or asked of the OS`() {
        val device = Device(listOf(record(now - 5_000, ApplicationExitInfo.REASON_CRASH_NATIVE)))
        val source = launch(device, sdkInt = 29)

        assertTrue(source.pending().isEmpty())
        assertTrue(source.acknowledge(listOf("exit-0000001799999995000-100-5")).isEmpty())

        assertEquals(0, device.calls)
        assertFalse(File(directory, "exit-info-watermark").exists())
    }

    @Test
    fun `a failing OS call yields nothing instead of throwing`() {
        val source = ExitInfoSource(
            records = { throw SecurityException("no") },
            directory = directory,
            sdkInt = 34,
            nowMillis = { now },
        )

        assertTrue(source.pending().isEmpty())
    }

    @Test
    fun `ids that are not ours never touch the watermark`() {
        val source = launch(Device())
        val hostile = listOf(
            "",
            "..",
            "../../etc/passwd",
            "exit-../x-1-1",
            "exit-1-1-1",
            "exit-00000000000000001-1-1",
            "exit-0000001799999995000-1",
            "exit-0000001799999995000-99999999999-1",
            "jvm-0000001799999995000-0000",
            "exit-0000001799999995000-100-5\n",
            "exit-000000179999999500a-100-5",
            "exit--000000179999999500-100-5",
        )

        val accepted = source.acknowledge(hostile)

        assertTrue(accepted.isEmpty())
        assertFalse(File(directory, "exit-info-watermark").exists())
        assertEquals(setOf<String>(), directory.list().orEmpty().toSet())
    }

    @Test
    fun `an id from the future cannot silence every later record`() {
        val source = launch(Device())

        val accepted = source.acknowledge(listOf("exit-9999999999999999-100-5"))

        assertTrue(accepted.isEmpty())
        assertFalse(File(directory, "exit-info-watermark").exists())
    }

    @Test
    fun `a watermark from the future, after the clock was set back, is discarded rather than obeyed`() {
        directory.mkdirs()
        File(directory, "exit-info-watermark").writeText((now + 10 * 24 * 3600 * 1000L).toString())
        val device = Device(listOf(record(now - 5_000, ApplicationExitInfo.REASON_ANR)))

        assertEquals(1, launch(device).pending().size)
    }

    @Test
    fun `a corrupt watermark file means report everything rather than nothing`() {
        directory.mkdirs()
        File(directory, "exit-info-watermark").writeText("not a number")
        val device = Device(listOf(record(now - 5_000, ApplicationExitInfo.REASON_ANR)))

        assertEquals(1, launch(device).pending().size)
    }

    @Test
    fun `an id round-trips through its string form`() {
        val id = ExitId(timestampMillis = 1_799_999_995_000L, pid = 4321, reason = 5)

        val parsed = assertNotNull(ExitId.parse(id.value))

        assertEquals(id.timestampMillis, parsed.timestampMillis)
        assertEquals(4321, parsed.pid)
        assertEquals(5, parsed.reason)
        assertContentEquals(listOf(id.value), listOf(parsed.value))
    }
}
