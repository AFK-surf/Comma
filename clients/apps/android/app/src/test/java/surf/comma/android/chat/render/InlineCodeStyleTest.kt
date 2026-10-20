package surf.comma.android.chat.render

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.text.Layout
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.R

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class InlineCodeStyleTest {
    /** [before], then [code] as inline code, then [after]. */
    private fun code(before: String, code: String, after: String) = MarkdownText(
        before + code + after,
        listOf(MarkdownSpan(before.length, before.length + code.length, MarkdownStyle.CODE)),
    )

    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()

    @Test fun `inline code is body coloured on a quiet block, smaller than the text`() {
        val palette = ChatPalette.from(activity)
        assertEquals(ContextCompat.getColor(activity, R.color.token_markdown_text_primary), palette.inlineCodeText)
        assertEquals(ContextCompat.getColor(activity, R.color.token_bg_tertiary), palette.inlineCodeBackground)

        val text = MarkdownSpans.spannable(code("Use ", "SLACK_SEARCH_MESSAGES", " here"), palette)
        assertEquals("Use SLACK_SEARCH_MESSAGES here", text.toString())
        val spans = text.getSpans(0, text.length, Any::class.java)
        assertTrue(spans.none { it is ForegroundColorSpan || it is BackgroundColorSpan })
        val code = text.getSpans(0, text.length, InlineCodeSpan::class.java).single()
        assertEquals(4, text.getSpanStart(code))
        assertEquals(Spanned.SPAN_EXCLUSIVE_EXCLUSIVE, text.getSpanFlags(code))
        val paint = TextPaint().apply { textSize = 100f; color = 0 }
        code.updateDrawState(paint)
        assertEquals(palette.inlineCodeText, paint.color)
        assertEquals(100f * InlineCodeSpan.SIZE_SCALE, paint.textSize)

        // The user's own bubble keeps plain text: no block on brand blue.
        val plain = MarkdownSpans.spannable(code("Use ", "CODE", " here"))
        assertTrue(plain.getSpans(0, plain.length, InlineCodeSpan::class.java).isEmpty())
    }

    @Test fun `the layout draws the block behind the code only`() {
        val palette = ChatPalette.DEFAULT
        val text = MarkdownSpans.spannable(code("ab ", "CODE", " cd"), palette)
        val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply { textSize = 40f; color = Color.BLACK }
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, 600).build()
        val bitmap = Bitmap.createBitmap(600, layout.height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).apply { drawColor(Color.WHITE); layout.draw(this) }

        val codeStart = Layout.getDesiredWidth(text, 0, 3, paint)
        val codeEnd = codeStart + Layout.getDesiredWidth(text, 3, 7, paint)
        val y = layout.getLineBaseline(0) - 2
        // The block's side padding, left of the first glyph and right of the last.
        assertEquals(palette.inlineCodeBackground, bitmap.getPixel((codeStart - 2).toInt(), y))
        assertEquals(palette.inlineCodeBackground, bitmap.getPixel((codeEnd + 2).toInt(), y))
        // Plain text around it stays on the page colour.
        assertEquals(Color.WHITE, bitmap.getPixel((codeStart - 12).toInt(), y))
        assertEquals(Color.WHITE, bitmap.getPixel((codeEnd + 12).toInt(), y))
    }
}
