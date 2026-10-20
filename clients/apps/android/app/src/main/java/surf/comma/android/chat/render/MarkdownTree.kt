package surf.comma.android.chat.render

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.text.style.UnderlineSpan
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.ui.theme.UiSansSemiBold
import surf.comma.android.ui.theme.uiSansAt

/**
 * A run of text with its inline styles, as the client core parsed it: what a paragraph, a heading, a list item, a
 * quote or a table cell says. Nothing here reads Markdown syntax; [MarkdownTree] gives the runs.
 */
data class MarkdownText(val text: String, val spans: List<MarkdownSpan> = emptyList()) {
    companion object {
        fun plain(text: String) = MarkdownText(text)
        fun bold(text: String) = MarkdownText(text, listOf(MarkdownSpan(0, text.length, MarkdownStyle.BOLD)))
    }
}

/** One style over `start until end` of a [MarkdownText]: a link's [href], a formula's [latex]. */
data class MarkdownSpan(
    val start: Int,
    val end: Int,
    val style: MarkdownStyle,
    val href: String? = null,
    val latex: String? = null,
)

enum class MarkdownStyle { BOLD, ITALIC, STRIKE, CODE, LINK, MATH }

/**
 * The Markdown a message carries (`ChatMessage.markdown` from the client core) read as blocks to draw. The core parses
 * every message once for every client; this only reads its tree: text is a string, any other node
 * `[kind, children?, attributes?]` (`@comma/core/markdown`'s tree), a Task chip or card `["comma-inline", { key }]`.
 */
object MarkdownTree {
    /** What a message shows, in order: runs of its tree, and the parts the tree puts between them. */
    sealed interface Piece {
        /** Root nodes of the tree, as a tree of their own ([blocks] reads it). */
        data class Tree(val nodes: JSONArray) : Piece
        /** The message part [key] names (`element-<index in base 36>`), in its place. */
        data class Element(val key: String) : Piece
    }

    /** The part index an element [key] names; null for another key. */
    fun partIndex(key: String): Int? = key.removePrefix("element-").takeIf { it != key }?.toIntOrNull(36)

    /**
     * The message's pieces: a card is a piece of its own, and a Task chip inside a paragraph cuts it in two, the chip
     * between the halves.
     */
    fun pieces(tree: JSONArray): List<Piece> {
        val out = ArrayList<Piece>()
        var run = JSONArray()
        fun flush() {
            if (run.length() > 0) out += Piece.Tree(run)
            run = JSONArray()
        }
        for (node in nodes(tree)) {
            when {
                kindOf(node) == ELEMENT -> {
                    flush()
                    out += Piece.Element(keyOf(node))
                }
                kindOf(node) == "p" && children(node).any { kindOf(it) == ELEMENT } -> {
                    var words = JSONArray()
                    fun paragraph() {
                        if (words.length() > 0) run.put(JSONArray().put("p").put(words))
                        words = JSONArray()
                    }
                    for (child in children(node)) {
                        if (kindOf(child) == ELEMENT) {
                            paragraph()
                            flush()
                            out += Piece.Element(keyOf(child))
                        } else words.put(child)
                    }
                    paragraph()
                }
                else -> run.put(node)
            }
        }
        flush()
        return out
    }

    /** [blocks] as selectable words without their styles. */
    fun plainText(blocks: List<MessageContent>): String {
        val out = StringBuilder()
        var previous: MessageContent? = null
        for (block in blocks) {
            val words = when (block) {
                is MessageContent.Paragraph -> block.text.text
                is MessageContent.Heading -> block.text.text
                is MessageContent.ListItem -> block.text.text
                is MessageContent.Quote -> block.text.text
                is MessageContent.Code -> block.text
                is MessageContent.Math -> block.source
                is MessageContent.Table -> (listOf(block.header) + block.rows)
                    .joinToString("\n") { row -> row.joinToString("\t") { it.text } }
                MessageContent.Divider, is MessageContent.Image, is MessageContent.Status -> ""
            }
            if (words.isEmpty()) continue
            if (out.isNotEmpty()) out.append(if (block is MessageContent.ListItem && previous is MessageContent.ListItem) "\n" else "\n\n")
            out.append(words)
            previous = block
        }
        return out.toString()
    }

    /** The tree's blocks, a part shown as [element] says (left out when it says null). */
    fun blocks(tree: JSONArray, element: (key: String) -> String? = { null }): List<MessageContent> {
        val out = ArrayList<MessageContent>()
        for (piece in pieces(tree)) when (piece) {
            is Piece.Tree -> for (node in nodes(piece.nodes)) block(node, out, 0)
            is Piece.Element -> element(piece.key)?.let { out += MessageContent.Paragraph(MarkdownText.plain(it)) }
        }
        return out
    }

    /**
     * [nodes] with each part placed deeper than a paragraph of its own (a Task chip in a list item, a quote) as words:
     * what [words] says for its key, in bold; left out when it says null.
     */
    fun withElements(nodes: JSONArray, words: (key: String) -> String?): JSONArray {
        fun copy(node: Any?): Any? {
            if (node !is JSONArray) return node
            if (kindOf(node) == ELEMENT) return words(keyOf(node))?.let { JSONArray().put("b").put(JSONArray().put(it)) }
            val out = JSONArray()
            for (index in 0 until node.length()) {
                val item = node.opt(index)
                out.put(if (index == 1 && item is JSONArray) JSONArray().apply { nodes(item).mapNotNull(::copy).forEach { put(it) } } else item)
            }
            return out
        }
        return JSONArray().apply { nodes(nodes).mapNotNull(::copy).forEach { put(it) } }
    }

    /**
     * The punctuation [length] says opens [nodes]' first paragraph, and [nodes] without it: what follows a Task chip on
     * its own line.
     */
    fun leadingPunctuation(nodes: JSONArray, length: (String) -> Int): Pair<String, JSONArray> {
        val first = nodes.opt(0)
        if (kindOf(first) != "p") return "" to nodes
        val words = (first as JSONArray).opt(1) as? JSONArray ?: return "" to nodes
        val text = words.opt(0) as? String ?: return "" to nodes
        val stop = length(text)
        if (stop == 0) return "" to nodes
        val rest = JSONArray()
        if (stop < text.length) rest.put(text.substring(stop))
        for (index in 1 until words.length()) rest.put(words.opt(index))
        val out = JSONArray()
        if (rest.length() > 0) out.put(JSONArray().put("p").put(rest))
        for (index in 1 until nodes.length()) out.put(nodes.opt(index))
        return text.substring(0, stop) to out
    }

    private fun block(node: Any?, out: MutableList<MessageContent>, depth: Int) {
        if (node is String) {
            if (node.isNotBlank()) out += MessageContent.Paragraph(MarkdownText.plain(node))
            return
        }
        val attributes = attributesOf(node)
        when (kindOf(node)) {
            "p" -> paragraph(children(node), out)
            "h" -> out += MessageContent.Heading(attributes.optInt("level", 1), text(children(node)))
            "list" -> list(node, out, depth)
            "quote" -> quote(node, out, 1)
            "pre" -> out += MessageContent.Code(
                language = attributes.optString("language"),
                text = attributes.optString("code").removeSuffix("\n"),
                closed = !attributes.optBoolean("loading"),
            )
            "mathblock" -> {
                val latex = attributes.optString("content")
                val open = attributes.optString("markup").ifEmpty { "$$" }
                out += MessageContent.Math(latex, "$open\n$latex\n${closing(open)}", closed = !attributes.optBoolean("loading"))
            }
            "table" -> table(node, out)
            "hr" -> out += MessageContent.Divider
            "img" -> image(node, out)
            "html_block" -> attributes.optString("raw").takeIf(String::isNotBlank)?.let {
                out += MessageContent.Paragraph(MarkdownText.plain(it.trimEnd()))
            }
            ELEMENT -> Unit
            else -> {
                val nested = children(node)
                if (nested.any { it !is String && kindOf(it) in BLOCKS }) nested.forEach { block(it, out, depth) }
                else text(nested).takeIf { it.text.isNotBlank() }?.let { out += MessageContent.Paragraph(it) }
            }
        }
    }

    /** A paragraph's text, and its pictures as blocks of their own after it. */
    private fun paragraph(children: List<Any?>, out: MutableList<MessageContent>) {
        val text = text(children)
        if (text.text.isNotBlank()) out += MessageContent.Paragraph(trimmed(text))
        children.filter { kindOf(it) == "img" }.forEach { image(it, out) }
    }

    private fun image(node: Any?, out: MutableList<MessageContent>) {
        val source = attributesOf(node).optString("src")
        if (source.isNotBlank() && out.none { it is MessageContent.Image && it.source == source })
            out += MessageContent.Image(source)
    }

    private fun list(node: Any?, out: MutableList<MessageContent>, depth: Int) {
        val attributes = attributesOf(node)
        val ordered = attributes.optBoolean("ordered")
        var index = attributes.optInt("start", 1)
        for (item in children(node)) {
            var first = true
            for (child in children(item)) {
                when (kindOf(child)) {
                    "list" -> list(child, out, depth + 1)
                    "p" -> {
                        val text = trimmed(text(children(child)))
                        if (first) out += MessageContent.ListItem(ordered, index, text, depth)
                        else out += MessageContent.ListItem(ordered, index, text, depth + 1)
                        first = false
                    }
                    else -> block(child, out, depth + 1)
                }
            }
            if (first) out += MessageContent.ListItem(ordered, index, MarkdownText.plain(""), depth)
            index++
        }
    }

    private fun quote(node: Any?, out: MutableList<MessageContent>, depth: Int) {
        val lines = ArrayList<MarkdownText>()
        fun flush() {
            if (lines.isNotEmpty()) out += MessageContent.Quote(join(lines, "\n"), depth)
            lines.clear()
        }
        for (child in children(node)) {
            if (kindOf(child) == "quote") {
                flush()
                quote(child, out, depth + 1)
            } else if (kindOf(child) == "p") lines += trimmed(text(children(child)))
            else {
                flush()
                block(child, out, 0)
            }
        }
        flush()
    }

    private fun table(node: Any?, out: MutableList<MessageContent>) {
        val rows = children(node).map { row -> children(row) }
        val header = rows.firstOrNull().orEmpty()
        out += MessageContent.Table(
            header = header.map { trimmed(text(children(it))) },
            alignments = header.map { cell ->
                when (attributesOf(cell).optString("align")) {
                    "center" -> TableAlign.CENTER
                    "right" -> TableAlign.RIGHT
                    else -> TableAlign.LEFT
                }
            },
            rows = rows.drop(1).map { row -> row.map { trimmed(text(children(it))) } },
            delimited = true,
        )
    }

    /** Inline nodes as one run of styled text. */
    fun text(nodes: List<Any?>): MarkdownText {
        val out = StringBuilder()
        val spans = ArrayList<MarkdownSpan>()
        fun visit(node: Any?) {
            if (node is String) {
                out.append(node)
                return
            }
            val attributes = attributesOf(node)
            val start = out.length
            when (kindOf(node)) {
                "b" -> children(node).forEach(::visit).also { spans += MarkdownSpan(start, out.length, MarkdownStyle.BOLD) }
                "i" -> children(node).forEach(::visit).also { spans += MarkdownSpan(start, out.length, MarkdownStyle.ITALIC) }
                "s" -> children(node).forEach(::visit).also { spans += MarkdownSpan(start, out.length, MarkdownStyle.STRIKE) }
                "a" -> {
                    children(node).forEach(::visit)
                    spans += MarkdownSpan(start, out.length, MarkdownStyle.LINK, href = attributes.optString("href"))
                }
                "code" -> {
                    out.append(attributes.optString("code"))
                    spans += MarkdownSpan(start, out.length, MarkdownStyle.CODE)
                }
                "math" -> {
                    val latex = attributes.optString("content")
                    val open = attributes.optString("markup").ifEmpty { "$" }
                    // A formula's text is its source: what shows if it cannot be drawn, and what a selection copies.
                    out.append(open).append(latex).append(closing(open))
                    spans += MarkdownSpan(start, out.length, MarkdownStyle.MATH, latex = latex)
                }
                "br" -> out.append('\n')
                "img", ELEMENT -> Unit
                "html_inline" -> out.append(attributes.optString("raw"))
                else -> if (children(node).isNotEmpty()) children(node).forEach(::visit)
                    else out.append(attributes.optString("content"))
            }
        }
        nodes.forEach(::visit)
        return MarkdownText(out.toString(), spans.filter { it.end > it.start })
    }

    /** [text] without the blank space at its ends, its spans moved with it. */
    private fun trimmed(text: MarkdownText): MarkdownText {
        val start = text.text.indexOfFirst { !it.isWhitespace() }.takeIf { it >= 0 } ?: return MarkdownText("")
        val end = text.text.indexOfLast { !it.isWhitespace() } + 1
        if (start == 0 && end == text.text.length) return text
        return MarkdownText(
            text.text.substring(start, end),
            text.spans.mapNotNull { span ->
                val from = (span.start - start).coerceAtLeast(0)
                val to = (span.end - start).coerceAtMost(end - start)
                if (to > from) span.copy(start = from, end = to) else null
            },
        )
    }

    private fun join(texts: List<MarkdownText>, separator: String): MarkdownText {
        val out = StringBuilder()
        val spans = ArrayList<MarkdownSpan>()
        texts.forEachIndexed { index, text ->
            if (index > 0) out.append(separator)
            val offset = out.length
            out.append(text.text)
            text.spans.forEach { spans += it.copy(start = it.start + offset, end = it.end + offset) }
        }
        return MarkdownText(out.toString(), spans)
    }

    private fun closing(open: String) = when (open) {
        "\\(" -> "\\)"
        "\\[" -> "\\]"
        else -> open
    }

    private fun nodes(array: JSONArray): List<Any?> = (0 until array.length()).map { array.opt(it) }
    private fun kindOf(node: Any?): String? = (node as? JSONArray)?.optString(0)
    private fun children(node: Any?): List<Any?> = ((node as? JSONArray)?.opt(1) as? JSONArray)?.let(::nodes).orEmpty()
    private fun attributesOf(node: Any?): JSONObject {
        val array = node as? JSONArray ?: return JSONObject()
        return (array.opt(1) as? JSONObject) ?: (array.opt(2) as? JSONObject) ?: JSONObject()
    }
    private fun keyOf(node: Any?): String = attributesOf(node).optString("key")

    private const val ELEMENT = "comma-inline"
    private val BLOCKS = setOf("p", "h", "list", "quote", "pre", "mathblock", "table", "hr", "html_block")
}

/**
 * A [MarkdownText] as the chat draws it. With [colors], inline code gets its quiet block ([InlineCodeSpan]) and links
 * the link colour; without, both keep the surrounding text colour. With [math], each formula is drawn by the span it
 * gives (null leaves its source showing).
 */
object MarkdownSpans {
    fun spannable(
        text: MarkdownText,
        colors: ChatPalette? = null,
        math: ((latex: String, display: Boolean) -> Any?)? = null,
    ): SpannableStringBuilder {
        val out = SpannableStringBuilder(text.text)
        for (span in text.spans) {
            fun mark(what: Any) = out.setSpan(what, span.start, span.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            when (span.style) {
                // 真字重，不是描粗的——理由见 ui/theme/Type.kt 的 uiSansAt。
                MarkdownStyle.BOLD -> mark(TypefaceSpan(uiSansAt(UiSansSemiBold)))
                MarkdownStyle.ITALIC -> mark(StyleSpan(Typeface.ITALIC))
                MarkdownStyle.STRIKE -> mark(StrikethroughSpan())
                MarkdownStyle.CODE -> {
                    mark(TypefaceSpan("monospace"))
                    colors?.let { mark(InlineCodeSpan(it.inlineCodeText, it.inlineCodeBackground)) }
                }
                MarkdownStyle.LINK -> {
                    mark(UnderlineSpan())
                    colors?.let { mark(ForegroundColorSpan(it.link)) }
                }
                MarkdownStyle.MATH -> span.latex?.let { latex -> math?.invoke(latex, false)?.let(::mark) }
            }
        }
        return out
    }
}
