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

    @Test fun `continued cards from one connection merge into one platform with unique item ids`() {
        val parsed = RecommendationFeed.parse(JSONObject("""
            {"state":"fresh","settings":{"sources":[
              {"appId":"linear","appName":"Linear","connectionId":"oauth-linear","enabled":true,"kind":"managed_oauth","label":"Comma"},
              {"appId":"github","appName":"GitHub","connectionId":"gh-1","enabled":true,"kind":"managed_oauth","label":"zan"},
              {"appId":"github","appName":"GitHub","connectionId":"gh-2","enabled":true,"kind":"managed_oauth","label":"acme"}]},
             "snapshot":{"generation":2,
              "cards":[
                {"id":"linear","title":"Linear","template":"text-list@1","sourceIds":["oauth-linear"],"items":[
                  {"id":"item-1","parts":[{"kind":"markdown","text":"Issue 1"}]},
                  {"id":"item-2","parts":[{"kind":"markdown","text":"Issue 2"}]}]},
                {"id":"linear-2","title":"Linear","template":"text-list@1","sourceIds":["oauth-linear"],"items":[
                  {"id":"item-1","parts":[{"kind":"markdown","text":"Issue 3"}]},
                  {"id":"item-2","parts":[{"kind":"markdown","text":"Issue 4"}]}]}]}}
        """.trimIndent()))
        val platforms = parsed.platforms
        assertEquals(listOf("oauth-linear", "gh-1", "gh-2"), platforms.map { it.id })
        assertNull(platforms[0].connectionLabel)
        assertEquals("zan", platforms[1].connectionLabel)
        assertEquals("acme", platforms[2].connectionLabel)
        val items = platforms[0].preTasks { null }
        assertEquals(listOf("item-1", "item-2", "linear-2:item-1", "linear-2:item-2"), items.map { it.id })
        assertEquals(listOf("Issue 1", "Issue 2", "Issue 3", "Issue 4"), items.map { it.text })
    }
}
