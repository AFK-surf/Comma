package surf.comma.android.routines

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import surf.comma.android.routines.RoutineQuote.Kind
import surf.comma.android.routines.RoutineQuote.Line
import surf.comma.android.routines.RoutineQuote.Run

/** What a pre-task card shows: a member task row's task and the source words it quotes, as the core publishes them. */
class RoutineCardTest {
    private val url = "https://acme.slack.com/archives/C1/p1"

    private fun feed(parts: String) = RecommendationFeed.parse(JSONObject("""
        {"state":"fresh","settings":{"sources":[
          {"appId":"slack","appName":"Slack","connectionId":"conn-sl","enabled":true,"kind":"composio","label":"acme"}]},
         "snapshot":{"generation":2,"summary":[{"kind":"markdown","text":"One thing needs you."}],
          "cards":[{"id":"slack","title":"Slack","template":"text-list@1","sourceIds":["conn-sl"],"fallbackText":"Slack","items":[
            {"id":"i1","parts":$parts,
             "action":{"type":"send_to_comma","label":"Decide","memberTask":true,"prompt":"Decide on PR 3986\n\n$url","requiresConfirmation":true}}]}]}}
    """.trimIndent()))

    @Test fun `a member task row leads with its objective and quotes its source as the core reads it`() {
        val row = feed("""[{"kind":"inline-link","link":{"href":"$url","label":"PR 3986","sourceId":"conn-sl",
            "objective":"Decide on PR 3986","previewText":"Ember: <@U1|zanwei> CI is green.\n• Retry",
            "quote":[{"runs":[{"kind":"text","text":"Ember: "},{"kind":"mention","text":"@zanwei","href":"https://acme.slack.com/team/U1"},
              {"kind":"text","text":" CI is green."}]},{"listItem":true,"runs":[{"kind":"text","text":"Retry"}]}]}}]""").cards[0].items[0]
        assertEquals("Decide on PR 3986", row.objective)
        assertEquals(
            listOf(
                Line(listOf(Run("Ember: ", Kind.TEXT), Run("@zanwei", Kind.MENTION), Run(" CI is green.", Kind.TEXT))),
                Line(listOf(Run("Retry", Kind.TEXT)), listItem = true),
            ),
            row.quote?.lines,
        )
        assertEquals("Ember: @zanwei CI is green.\n• Retry", row.quote?.plainText)
    }

    @Test fun `a source link row without an objective leads with the link's label`() {
        val row = feed("""[{"kind":"inline-link","link":{"href":"$url","label":"Open report","sourceId":"conn-sl"}}]""").cards[0].items[0]
        assertEquals("Open report", row.objective)
        assertNull(row.quote)
    }

    @Test fun `a row with prose around its link quotes nothing`() {
        val row = feed("""[{"kind":"markdown","text":"Reply to "},{"kind":"inline-link","link":{"href":"$url","label":"Ada",
            "sourceId":"conn-sl","previewText":"Ada: is it final?","quote":[{"runs":[{"kind":"text","text":"Ada: is it final?"}]}]}}]""").cards[0].items[0]
        assertNull(row.objective)
        assertNull(row.quote)
    }
}
