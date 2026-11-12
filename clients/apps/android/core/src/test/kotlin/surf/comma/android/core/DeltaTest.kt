package surf.comma.android.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A topic's deltas applied as the core sends them (the core's `collections.ts` makes them). */
class DeltaTest {
    private fun apply(value: String, ops: String): String = applyDelta(JSONObject(value), JSONArray(ops)).toString()
    private fun same(expected: String, actual: String) = assertEquals(JSONObject(expected).toString(), actual)

    /** The cases the core's own test (core-kernel `delta-cases.test.ts`) makes the ops of: each applies to its value after. */
    @Test fun appliesEveryCaseTheCoreMakes() {
        val cases = JSONArray(File("../../../packages/core-kernel/test/fixtures/delta-cases.json").readText())
        assertTrue(cases.length() > 0)
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val applied = applyDelta(case.get("old"), case.getJSONArray("ops"))
            assertTrue(case.getString("name"), similar(case.get("next"), applied))
        }
    }

    // Android's org.json, which the compiler resolves first, has no similar().
    private fun similar(expected: Any?, actual: Any?): Boolean = when (expected) {
        is JSONObject -> actual is JSONObject && expected.length() == actual.length() &&
            expected.keys().asSequence().all { actual.has(it) && similar(expected.get(it), actual.get(it)) }
        is JSONArray -> actual is JSONArray && expected.length() == actual.length() &&
            (0 until expected.length()).all { similar(expected.get(it), actual.get(it)) }
        is Number -> actual is Number && expected.toDouble() == actual.toDouble()
        else -> expected == actual
    }

    @Test fun skipsAnOpWhosePathDoesNotFit() {
        same("""{"a":1}""", apply("""{"a":1}""", """[{"path":["b","c"],"set":2},{"path":["a",0],"set":2}]"""))
    }

    @Test fun putWithoutAPlaceReplacesTheItemWithItsKey() {
        same("""{"items":[{"id":"a","n":5}]}""", apply("""{"items":[{"id":"a","n":1}]}""",
            """[{"path":["items"],"key":["id"],"put":{"id":"a","n":5}}]"""))
    }

    @Test fun keysOfSeveralFieldsAndNumbersMatch() {
        same("""{"items":[{"s":"x","n":2}]}""", apply("""{"items":[{"s":"x","n":1},{"s":"x","n":2}]}""",
            """[{"path":["items"],"key":["s","n"],"drop":["x",1]}]"""))
    }

    @Test fun leavesTheValueAsItWasAndSharesWhatDidNotChange() {
        val before = JSONObject("""{"list":[{"id":"a","n":1},{"id":"b","n":1}],"other":{"x":1}}""")
        val text = before.toString()
        val after = applyDelta(before, JSONArray("""[{"path":["list",1,"n"],"set":2}]""")) as JSONObject
        assertEquals(text, before.toString())
        assertEquals(2, after.getJSONArray("list").getJSONObject(1).getInt("n"))
        assertSame(before.getJSONArray("list").get(0), after.getJSONArray("list").get(0))
        assertSame(before.get("other"), after.get("other"))
    }
}
