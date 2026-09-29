package com.vaam.otel_zone

import android.app.ApplicationExitInfo
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CrashReportsTest {

    private val root: File = Files.createTempDirectory("otel-zone-reports").toFile()
    private val crashes = File(root, "crashes")
    private val now = 1_800_000_000_000L

    @AfterTest
    fun removeDirectory() {
        root.deleteRecursively()
    }

    private class Device(var records: List<ExitRecord> = emptyList()) : ExitRecords {
        override fun historical(): List<ExitRecord> = records
    }

    private fun exit(
        timestamp: Long,
        reason: Int,
        pid: Int,
        summary: String? = null,
        build: AppBuild = AppBuild.UNKNOWN,
    ) =
        ExitRecord(
            pid = pid,
            processName = "com.example.app",
            timestampMillis = timestamp,
            reason = reason,
            status = 0,
            importance = 100,
            description = "java.lang.RuntimeException: boom",
            processStateSummary = summary?.let { RunSession.encode(it, build) },
            pssKb = 0,
            rssKb = 0,
            openTrace = { null },
        )

    private fun store(
        pid: Int,
        at: Long,
        session: String? = null,
        build: AppBuild = AppBuild.UNKNOWN,
    ) = CrashStore(crashes, nowMillis = { at }, pid = { pid }, sessionId = session, build = build)

    private fun reports(device: ExitRecords, sdkInt: Int = 34) =
        CrashReports(
            store = store(pid = 0, at = now),
            exitInfo = ExitInfoSource(device, root, sdkInt, nowMillis = { now }),
        )

    private fun jvmCrash(
        pid: Int,
        at: Long,
        message: String = "boom",
        session: String? = null,
        build: AppBuild = AppBuild.UNKNOWN,
    ) {
        store(pid, at, session, build).record(Thread.currentThread(), RuntimeException(message))
    }

    @Test
    fun `a jvm crash the OS also saw is one record, not two`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))

        val pending = reports(device).pending()

        val report = pending.single()
        assertEquals("jvm", report.kind)
        assertEquals("java.lang.RuntimeException", report.type)
        assertEquals("boom", report.message)
        assertTrue(report.stacktrace.orEmpty().contains("RuntimeException"))
    }

    @Test
    fun `the joined record carries the exit record's id, session and attributes`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val device = Device(
            listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100, summary = "sess-1")),
        )

        val report = reports(device).pending().single()

        assertTrue(report.id.startsWith("exit-"))
        assertEquals("sess-1", report.sessionId)
        assertEquals("crash", report.attributes?.get("exit.reason"))
        assertEquals("100", report.attributes?.get("process.pid"))
        // From the JVM report, still there after the join.
        assertEquals(Thread.currentThread().name, report.attributes?.get("thread.name"))
        // The moment the exception was thrown, not the moment the OS noticed.
        assertEquals((now - 5_000) * 1000, report.timestampMicros)
    }

    @Test
    fun `a joined record carries the build that crashed, from either half`() {
        val old = AppBuild.of("1.0.0", 1)
        jvmCrash(pid = 100, at = now - 5_000, session = "sess-1", build = old)
        jvmCrash(pid = 200, at = now - 3_000, session = "sess-2", build = old)
        val device = Device(
            listOf(
                // Its summary names the build too.
                exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100, summary = "sess-1", build = old),
                // Written by a run that predates the build in the summary: the
                // JVM report still knows.
                exit(now - 2_000, ApplicationExitInfo.REASON_CRASH, pid = 200, summary = "sess-2"),
            ),
        )

        val (first, second) = reports(device).pending()

        for (report in listOf(first, second)) {
            assertEquals("1.0.0", report.attributes?.get("otel_zone.crashed.service.version"))
            assertEquals("1", report.attributes?.get("otel_zone.crashed.app.build_id"))
        }
    }

    @Test
    fun `acknowledging the joined record clears both sources, so it is never reported again`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))
        val first = reports(device).pending()

        reports(device).acknowledge(first.map { it.id })

        assertTrue(reports(device).pending().isEmpty(), "second launch")
        assertTrue(reports(device).pending().isEmpty(), "third launch")
        assertEquals(0, crashes.listFiles { f -> f.name.endsWith(".json") }?.size)
    }

    @Test
    fun `a report the drain never acknowledged is returned again, still joined`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))

        reports(device).pending()

        assertEquals(1, reports(device).pending().size)
    }

    @Test
    fun `an OS that files one crash twice still yields one record, and acknowledging it clears both`() {
        // Observed on an API 36 emulator: the second CRASH record for the pid
        // arrives when the crash dialog is dismissed, well past the window.
        jvmCrash(pid = 100, at = now - 50_000)
        val first = exit(now - 49_997, ApplicationExitInfo.REASON_CRASH, pid = 100)
        val second = exit(now - 10_000, ApplicationExitInfo.REASON_CRASH, pid = 100)
        val device = Device(listOf(second, first))

        val pending = reports(device).pending()
        assertEquals(1, pending.size)
        assertEquals("jvm", pending.single().kind)

        reports(device).acknowledge(pending.map { it.id })

        assertTrue(reports(device).pending().isEmpty(), "the duplicate must not resurface")
        assertEquals("${second.timestampMillis}", File(root, "exit-info-watermark").readText())
    }

    @Test
    fun `a jvm report of a different process is not joined`() {
        jvmCrash(pid = 200, at = now - 5_000)
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))

        val pending = reports(device).pending()

        assertEquals(2, pending.size)
    }

    @Test
    fun `a jvm report outside the window is not joined`() {
        jvmCrash(pid = 100, at = now - 5_000 - CrashReports.CORRELATION_WINDOW_MILLIS - 1)
        val device = Device(listOf(exit(now - 5_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))

        assertEquals(2, reports(device).pending().size)
    }

    @Test
    fun `a jvm report exactly at the edge of the window is joined`() {
        jvmCrash(pid = 100, at = now - 5_000 - CrashReports.CORRELATION_WINDOW_MILLIS)
        val device = Device(listOf(exit(now - 5_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))

        assertEquals(1, reports(device).pending().size)
    }

    @Test
    fun `a jvm report without a recorded pid is never joined, so it cannot join the wrong process`() {
        jvmCrash(pid = 100, at = now - 5_000)
        // Rewrite as an older build would have: no process.pid.
        val file = crashes.listFiles { f -> f.name.endsWith(".json") }!!.single()
        file.writeText(file.readText().replace("\"process.pid\":\"100\"", "\"x\":\"y\""))
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))

        val pending = reports(device).pending()

        assertEquals(2, pending.size)
        assertEquals(1, pending.count { it.id.startsWith("jvm-") })
    }

    @Test
    fun `a jvm crash with no exit record is reported alone, as on API 29`() {
        jvmCrash(pid = 100, at = now - 5_000)

        val pending = reports(Device(), sdkInt = 29).pending()

        assertEquals("jvm-", pending.single().id.take(4))
    }

    @Test
    fun `acknowledging a jvm-only report deletes it`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val api = reports(Device(), sdkInt = 29)

        api.acknowledge(api.pending().map { it.id })

        assertTrue(api.pending().isEmpty())
    }

    @Test
    fun `two crashes of one process each join their own exit record`() {
        // Same pid cannot die twice, so these are two runs; pids differ.
        jvmCrash(pid = 100, at = now - 50_000_000, message = "first")
        jvmCrash(pid = 101, at = now - 5_000, message = "second")
        val device = Device(
            listOf(
                exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 101),
                exit(now - 49_999_000, ApplicationExitInfo.REASON_CRASH, pid = 100),
            ),
        )

        val pending = reports(device).pending()

        assertEquals(listOf("first", "second"), pending.map { it.message })
    }

    @Test
    fun `when two jvm reports qualify the nearest joins and the other stays`() {
        jvmCrash(pid = 100, at = now - 20_000, message = "earlier")
        jvmCrash(pid = 100, at = now - 4_500, message = "nearer")
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_CRASH, pid = 100)))
        val api = reports(device)

        val pending = api.pending()

        assertEquals(setOf("earlier", "nearer"), pending.map { it.message }.toSet())
        assertEquals(1, pending.count { it.id.startsWith("exit-") })
        assertEquals("nearer", pending.single { it.id.startsWith("exit-") }.message)

        api.acknowledge(pending.map { it.id })

        assertTrue(reports(device).pending().isEmpty())
    }

    @Test
    fun `an anr is never joined to a jvm report`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val device = Device(listOf(exit(now - 4_000, ApplicationExitInfo.REASON_ANR, pid = 100)))

        assertEquals(2, reports(device).pending().size)
    }

    @Test
    fun `reports come back oldest first across both sources`() {
        jvmCrash(pid = 300, at = now - 1_000_000, message = "jvm only")
        val device = Device(
            listOf(
                exit(now - 10_000, ApplicationExitInfo.REASON_ANR, pid = 400),
                exit(now - 2_000_000, ApplicationExitInfo.REASON_CRASH_NATIVE, pid = 500),
            ),
        )

        val kinds = reports(device).pending().map { it.kind }

        assertEquals(listOf("native", "jvm", "anr"), kinds)
    }

    @Test
    fun `ids that are neither report names nor exit ids delete nothing`() {
        jvmCrash(pid = 100, at = now - 5_000)
        val outside = File(root, "outside.json").apply { writeText("{}") }
        val api = reports(Device(), sdkInt = 29)

        api.acknowledge(listOf("..", "../outside", "exit-bogus", "exit-1-1-1"))

        assertTrue(outside.exists())
        assertEquals(1, api.pending().size)
        assertFalse(File(root, "exit-info-watermark").exists())
    }
}
