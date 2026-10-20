package surf.comma.android.chat.render

import org.json.JSONObject

/** Injectable JSON boundary for host-side layout tests that cannot load Android's JSON classes. */
fun interface JsonParser {
    /** Returns null when the payload/key is malformed, otherwise the string members (possibly empty). */
    fun stringArray(payload: String, key: String): List<String>?
}

/** Production parser. org.json owns escaping, brackets inside strings, and Unicode decoding. */
object OrgJsonParser : JsonParser {
    override fun stringArray(payload: String, key: String): List<String>? = runCatching {
        val array = JSONObject(payload).optJSONArray(key) ?: return null
        buildList {
            repeat(array.length()) { index ->
                val value = array.opt(index)
                if (value is String) add(value)
            }
        }
    }.getOrNull()
}

/** Photo-grid parsing shares the same card-payload boundary as calendar and metric cards. */
object PhotoGridCardPayload {
    fun images(payload: String?, parser: JsonParser = OrgJsonParser): List<String>? {
        val raw = payload?.trim().orEmpty()
        if (raw.isEmpty()) return null
        return parser.stringArray(raw, "images")
    }
}
