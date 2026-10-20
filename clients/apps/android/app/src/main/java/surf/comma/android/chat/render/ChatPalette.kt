package surf.comma.android.chat.render

import android.content.Context
import androidx.core.content.ContextCompat
import surf.comma.android.R

/**
 * Message colours resolved from the design tokens on the UI thread, so background layout never
 * touches resources. Part of every layout cache key: a theme change lays everything out again.
 */
data class ChatPalette(
    val agentText: Int,
    val userText: Int,
    val secondaryText: Int,
    val link: Int,
    val inlineCodeText: Int,
    val inlineCodeBackground: Int,
    val error: Int,
    /** What code sits on inside an agent bubble: the page colour, so it stands off the grey. */
    val bubbleInset: Int = 0xFFFFFFFF.toInt(),
) {
    companion object {
        /** Light-theme token values; used where no Context exists (JVM tests). */
        val DEFAULT = ChatPalette(
            agentText = 0xFF1A1B1E.toInt(),
            userText = 0xFFFFFFFF.toInt(),
            secondaryText = 0xFF7F8286.toInt(),
            link = 0xFF3B7CFF.toInt(),
            inlineCodeText = 0xFF1A1B1E.toInt(),
            inlineCodeBackground = 0xFFF5F5F5.toInt(),
            error = 0xFFD92D20.toInt(),
        )

        fun from(context: Context): ChatPalette {
            fun color(id: Int) = ContextCompat.getColor(context, id)
            return ChatPalette(
                agentText = color(R.color.token_markdown_text_primary),
                userText = 0xFFFFFFFF.toInt(),
                secondaryText = color(R.color.token_markdown_text_secondary),
                link = color(R.color.token_markdown_text_link),
                inlineCodeText = color(R.color.token_markdown_text_inline_code),
                inlineCodeBackground = color(R.color.token_markdown_bg_inline_code),
                error = color(R.color.token_text_error_primary),
                bubbleInset = color(R.color.token_bg_primary),
            )
        }
    }
}

/** Syntax colours for code blocks, resolved from resources on the UI thread. */
/** The code block header's labels in the app's language. */
fun codeLabels(context: Context) = MessageCodeLabels(copy = context.getString(R.string.code_block_copy))

fun codeSyntaxTheme(context: Context): CodeSyntaxTheme {
    fun color(id: Int) = ContextCompat.getColor(context, id)
    return CodeSyntaxTheme(mapOf(
        CodeToken.KEYWORD to color(R.color.syntax_keyword),
        CodeToken.STRING to color(R.color.syntax_string),
        CodeToken.COMMENT to color(R.color.syntax_comment),
        CodeToken.NUMBER to color(R.color.syntax_number),
        CodeToken.TYPE to color(R.color.syntax_type),
        CodeToken.FUNCTION to color(R.color.syntax_function),
        CodeToken.CONSTANT to color(R.color.syntax_constant),
        CodeToken.PREPROCESSOR to color(R.color.syntax_preprocessor),
        CodeToken.ATTRIBUTE to color(R.color.syntax_attribute),
    ))
}
