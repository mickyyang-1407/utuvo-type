package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import org.json.JSONArray
import java.io.File

class ListOnlyPresentationTest {
    @Test fun sharedLayoutFixturesAndIdempotence() {
        val rows = JSONArray(File("../../benchmarks/list-layout-regression.json").readText())
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i)
            val actual = OutputShape.expandingInlineNumberedList(row.getString("input"))
            assertEquals(row.getString("expected"), actual, row.getString("id"))
            assertEquals(actual, OutputShape.expandingInlineNumberedList(actual), row.getString("id"))
        }
        println("List-only shared fixtures: ${rows.length()} exact outputs + idempotence")
    }
}
