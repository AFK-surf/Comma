package surf.comma.android.chat.render

import org.json.JSONArray
import org.json.JSONObject

/**
 * The client core's parse of a message, as tests show messages: the trees in `markdown/trees.json`, made by the core
 * (`packages/core/scripts/android-markdown-fixtures.ts`). The app parses no Markdown itself.
 */
internal object Md {
    /** The trees by key: a message's text, or `parts:` and its parts as this runtime writes them. */
    private val trees: Map<String, JSONArray> by lazy {
        val file = JSONObject(Md::class.java.getResourceAsStream("/markdown/trees.json")!!.bufferedReader().readText())
        file.keys().asSequence().associate { key ->
            val canonical = if (key.startsWith(PARTS)) PARTS + JSONArray(key.removePrefix(PARTS)) else key
            canonical to file.getJSONArray(key)
        }
    }

    /** The tree of [text], as `ChatMessage.markdown` carries it. */
    fun of(text: String): String = tree(text)

    /** The tree of a message of [parts] (the core's parts, Task chips and cards among them). */
    fun ofParts(parts: JSONArray): String = tree(PARTS + parts)

    /** The blocks the chat draws of [text]. */
    fun blocks(text: String): List<MessageContent> = MarkdownTree.blocks(JSONArray(of(text)))

    fun plain(text: String) = MarkdownText.plain(text)

    private fun tree(key: String): String = trees[key]?.toString()
        ?: error("No tree for \"$key\": add it to markdown/trees.json and run the core's android-markdown-fixtures.ts")

    private const val PARTS = "parts:"
}
