package surf.comma.android.routines

import org.json.JSONArray

/**
 * A member task's quoted source words, as the client core reads the server's quote markup for every client
 * (`recommendationSourceQuote` in the recommendation contract): one line per source line, each as runs of words, Slack
 * mentions and channels, and links. Nothing in a quote is a target of its own: the card around it is.
 */
data class RoutineQuote(val lines: List<Line>) {
    enum class Kind { TEXT, MENTION, CHANNEL, LINK }

    data class Run(val text: String, val kind: Kind)

    /** A source line; a list item is drawn after a bullet. */
    data class Line(val runs: List<Run>, val listItem: Boolean = false)

    /** The quote as plain words, for accessibility. */
    val plainText: String
        get() = lines.joinToString("\n") { line ->
            (if (line.listItem) "• " else "") + line.runs.joinToString("") { it.text }
        }

    companion object {
        /** The `quote` of an inline link, as the core publishes it; null when it has no line. */
        fun parse(array: JSONArray?): RoutineQuote? {
            val lines = RecommendationFeed.objects(array).map { line ->
                Line(RecommendationFeed.objects(line.optJSONArray("runs")).map { run ->
                    Run(run.optString("text"), when (run.optString("kind")) {
                        "mention" -> Kind.MENTION
                        "channel" -> Kind.CHANNEL
                        "link" -> Kind.LINK
                        else -> Kind.TEXT
                    })
                }, listItem = line.optBoolean("listItem"))
            }
            return lines.takeIf(List<Line>::isNotEmpty)?.let(::RoutineQuote)
        }
    }
}
