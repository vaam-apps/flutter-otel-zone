package com.vaam.otel_zone

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CrashStoreTest {

    private val directory: File = Files.createTempDirectory("otel-zone-crashes").toFile()
    private var millis = 1_700_000_000_000L

    /** Shorter than the production five minutes, so tests stay readable. */
    private val staleWindow = 60_000L

    private fun store(maxReports: Int = 16): CrashStore =
        CrashStore(
            directory = directory,
            maxReports = maxReports,
            nowMillis = { millis++ },
            staleTempMillis = staleWindow,
        )

    @AfterTest
    fun removeDirectory() {
        directory.deleteRecursively()
    }

    @Test
    fun `a recorded crash is read back as a jvm report`() {
        store().record(Thread.currentThread(), RuntimeException("boom"))

        val report = store().pending().single()
        assertEquals("jvm", report.kind)
        assertEquals("java.lang.RuntimeException", report.type)
        assertEquals("boom", report.message)
        assertTrue(report.stacktrace.orEmpty().contains("RuntimeException"))
        assertEquals(Thread.currentThread().name, report.attributes?.get("thread.name"))
        assertTrue(report.timestampMicros > 0)
    }

    @Test
    fun `the report is named by the id it is acknowledged with`() {
        val store = store()
        store.record(Thread.currentThread(), RuntimeException("boom"))

        val report = store.pending().single()

        assertTrue(File(directory, "${report.id}.json").exists())
    }

    @Test
    fun `acknowledge deletes exactly the reports it names`() {
        val store = store()
        store.record(Thread.currentThread(), RuntimeException("one"))
        store.record(Thread.currentThread(), RuntimeException("two"))
        val ids = store.pending().map { it.id }

        store.acknowledge(listOf(ids.first()))

        assertContentEquals(listOf("two"), store.pending().map { it.message })
    }

    @Test
    fun `an id that is not a report name cannot reach outside the directory`() {
        val store = store()
        store.record(Thread.currentThread(), RuntimeException("kept"))
        val outside = File(directory.parentFile, "otel-zone-outside-${System.nanoTime()}.json")
        outside.writeText("{}")

        store.acknowledge(listOf("..", "../../..", "../${outside.name}"))

        assertTrue(outside.exists())
        assertEquals(1, store.pending().size)
        outside.delete()
    }

    @Test
    fun `the oldest report is dropped once the cap is reached`() {
        val store = store(maxReports = 2)
        repeat(3) { store.record(Thread.currentThread(), RuntimeException("crash $it")) }

        assertContentEquals(
            listOf("crash 1", "crash 2"),
            store.pending().map { it.message },
        )
    }

    @Test
    fun `an unreadable report is skipped rather than failing the drain`() {
        val store = store()
        store.record(Thread.currentThread(), RuntimeException("kept"))
        File(directory, "jvm-0000000000000000-0000.json").writeText("{ not json")

        assertContentEquals(listOf("kept"), store.pending().map { it.message })
    }

    @Test
    fun `a temp file a dead process left behind is swept`() {
        directory.mkdirs()
        val orphan = File(directory, "jvm-0000000000000000-0000.json.tmp")
        orphan.writeText("half")
        orphan.setLastModified(millis - 2 * staleWindow)

        store().record(Thread.currentThread(), RuntimeException("kept"))

        assertFalse(orphan.exists())
    }

    @Test
    fun `a temp file a live write owns is not swept`() {
        directory.mkdirs()
        val inFlight = File(directory, "jvm-0000000000000000-0000.json.tmp")
        inFlight.writeText("half")
        // Modified on the clock the store reads, so this is a write happening
        // right now — a crash landing while a drain is in flight.
        inFlight.setLastModified(millis)

        store().pending()

        assertTrue(
            inFlight.exists(),
            "a drain must not delete a temp file a crash is still writing",
        )
        inFlight.delete()
    }

    @Test
    fun `a directory that cannot be written reports the failure to its caller`() {
        val blocker = File(directory.parentFile, "otel-zone-blocker-${System.nanoTime()}")
        blocker.writeText("not a directory")
        val store = CrashStore(directory = blocker, nowMillis = { millis++ })

        assertFailsWith<Exception> {
            store.record(Thread.currentThread(), RuntimeException("boom"))
        }

        blocker.delete()
    }
}
