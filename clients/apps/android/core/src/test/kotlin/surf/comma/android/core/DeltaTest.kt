package surf.comma.android.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** A topic's deltas applied as the core sends them (the core's `delta.ts` and `collections.ts` make them). */
class DeltaTest {
    private fun apply(value: String, ops: String): String = applyDelta(JSONObject(value), JSONArray(ops)).toString()
    private fun same(expected: String, actual: String) = assertEquals(JSONObject(expected).toString(), actual)

    @Test fun setsAppendsAndRemovesAtAPath() {
        same("""{"a":{"b":2},"list":[1,2,3],"n":null}""", apply("""{"a":{"b":1,"c":1},"list":[1]}""", """[
            {"path":["a","b"],"set":2},{"path":["a","c"],"remove":true},
            {"path":["list"],"append":[2,3]},{"path":["n"],"set":null}]"""))
    }

    @Test fun extendsAStringByTheTextItGained() {
        same("""{"draft":{"text":"Hello there"}}""", apply("""{"draft":{"text":"Hel"}}""",
            """[{"path":["draft","text"],"extend":"lo there"}]"""))
        // Not a string there: skipped.
        same("""{"n":1}""", apply("""{"n":1}""", """[{"path":["n"],"extend":"x"}]"""))
    }

    @Test fun replacesTheWholeValue() {
        assertEquals("""{"x":1}""", applyDelta(JSONObject("""{"a":1}"""), JSONArray("""[{"path":[],"set":{"x":1}}]""")).toString())
    }

    @Test fun skipsAnOpWhosePathDoesNotFit() {
        same("""{"a":1}""", apply("""{"a":1}""", """[{"path":["b","c"],"set":2},{"path":["a",0],"set":2}]"""))
    }

    @Test fun putsPatchesMovesAndDropsItemsByTheirKey() {
        val start = """{"items":[{"id":"a","n":1},{"id":"b","n":1},{"id":"c","n":1}]}"""
        same("""{"items":[{"id":"z","n":9},{"id":"c","n":1},{"id":"a","n":2}]}""", apply(start, """[
            {"path":["items"],"key":["id"],"drop":"b"},
            {"path":["items"],"key":["id"],"patch":"a","ops":[{"path":["n"],"set":2}]},
            {"path":["items"],"key":["id"],"move":"a","before":null},
            {"path":["items"],"key":["id"],"put":{"id":"z","n":9},"before":"c"}]"""))
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
