package surf.comma.android.chat.render

import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.TypefaceSpan
import surf.comma.android.ui.theme.UiSansSemiBold
import surf.comma.android.ui.theme.uiSansAt

/**
 * A message as one run of text for selection: its blocks drawn the way the chat shows
 * them (bold, headings, list markers, code in monospace), so a selection copies what the reader
 * sees. Blocks are separated by a blank line, list items by a line break; pictures and status
 * lines have no text and are left out.
 */
object SelectableText {
    data class Document(val text: SpannableStringBuilder, val ranges: List<IntRange?>)

    fun build(blocks: List<MessageContent>, palette: ChatPalette? = null): SpannableStringBuilder =
        document(blocks, palette).text

    fun document(blocks: List<MessageContent>, palette: ChatPalette? = null): Document {
        val out = SpannableStringBuilder()
        val ranges = ArrayList<IntRange?>()
        var previous: MessageContent? = null
        for (block in blocks) {
            val piece = piece(block, palette)
            if (piece == null) {
                ranges += null
                continue
            }
            if (out.isNotEmpty()) out.append(if (block is MessageContent.ListItem && previous is MessageContent.ListItem) "\n" else "\n\n")
            val start = out.length
            out.append(piece)
            ranges += start until out.length
            previous = block
        }
        return Document(out, ranges)
    }

    private fun piece(block: MessageContent, palette: ChatPalette?): CharSequence? = when (block) {
        is MessageContent.Paragraph -> MarkdownSpans.spannable(block.text, palette)
        is MessageContent.Heading -> MarkdownSpans.spannable(block.text, palette).also { text ->
            text.span(TypefaceSpan(uiSansAt(UiSansSemiBold)))
            HEADING_SCALE.getOrNull(block.level - 1)?.let { text.span(RelativeSizeSpan(it)) }
        }
        is MessageContent.ListItem -> SpannableStringBuilder(LIST_INDENT.repeat(block.depth))
            .append(if (block.ordered) "${block.index}. " else "${BULLETS[block.depth % BULLETS.size]} ")
            .append(MarkdownSpans.spannable(block.text, palette))
        is MessageContent.Code -> SpannableStringBuilder(block.text.trimEnd('\n')).also { it.span(TypefaceSpan("monospace")) }
        is MessageContent.Quote -> MarkdownSpans.spannable(block.text, palette).also { text ->
            palette?.let { text.span(ForegroundColorSpan(it.secondaryText)) }
        }
        is MessageContent.Table -> SpannableStringBuilder().also { text ->
            (listOf(block.header) + block.rows).forEachIndexed { index, row ->
                if (index > 0) text.append('\n')
                val start = text.length
                row.forEachIndexed { column, cell ->
                    if (column > 0) text.append('\t')
                    text.append(MarkdownSpans.spannable(cell, palette))
                }
                if (index == 0) text.setSpan(TypefaceSpan(uiSansAt(UiSansSemiBold)), start, text.length,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        // A formula's selectable text is its source.
        is MessageContent.Math -> block.source
        MessageContent.Divider, is MessageContent.Image, is MessageContent.Status -> null
    }?.takeIf { it.isNotEmpty() }

    private fun SpannableStringBuilder.span(what: Any) {
        if (isNotEmpty()) setSpan(what, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    /** The chat's heading sizes, relative to body text (docs/DESIGN.md §3.1). */
    private val HEADING_SCALE = listOf(1.6f, 1.4f, 1.2f, 1.1f, 1.0f, 0.9f)
    private val BULLETS = listOf("•", "◦", "▪")
    private const val LIST_INDENT = "    "
}
