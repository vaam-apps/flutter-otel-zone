package com.vaam.otel_zone

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AppBuildTest {

    @Test
    fun `a known version and build become the two crashed-build attributes`() {
        val attributes = AppBuild.of("1.0.1", 2).attributes()

        assertEquals(
            mapOf(
                "otel_zone.crashed.service.version" to "1.0.1",
                "otel_zone.crashed.app.build_id" to "2",
            ),
            attributes,
        )
    }

    @Test
    fun `an unknown half is omitted, not filled in`() {
        assertEquals(emptyMap(), AppBuild.UNKNOWN.attributes())
        assertEquals(
            mapOf("otel_zone.crashed.app.build_id" to "9"),
            AppBuild.of(null, 9).attributes(),
        )
        assertEquals(
            mapOf("otel_zone.crashed.service.version" to "3.1"),
            AppBuild.of("3.1", null).attributes(),
        )
    }

    @Test
    fun `a blank or control-character version and a negative code are unknown`() {
        assertNull(AppBuild.of("", 1).versionName)
        assertNull(AppBuild.of("   ", 1).versionName)
        assertNull(AppBuild.of("1.0\n2", 1).versionName)
        assertNull(AppBuild.of("1.0", -1).buildId)
    }

    @Test
    fun `a code past what an Int holds is kept whole`() {
        assertEquals("4294967296", AppBuild.of("1", 4_294_967_296L).buildId)
    }

    @Test
    fun `API 28 and up read the long version code and never touch the int one`() {
        val build = AppBuild.select(
            versionName = "1.0.1",
            sdkInt = 34,
            intCode = { error("versionCode is not read on API 28+") },
            longCode = { 4_294_967_298L },
        )

        assertEquals("1.0.1", build.versionName)
        assertEquals("4294967298", build.buildId)
    }

    @Test
    fun `below API 28 the int version code is used and longVersionCode is never touched`() {
        val build = AppBuild.select(
            versionName = "0.9",
            sdkInt = 24,
            intCode = { 12L },
            longCode = { error("longVersionCode does not exist below API 28") },
        )

        assertEquals("0.9", build.versionName)
        assertEquals("12", build.buildId)
    }
}
