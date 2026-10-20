package surf.comma.android.chat.math

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.os.Parcel
import android.text.Spanned
import android.view.View
import androidx.activity.ComponentActivity
import io.ratex.DisplayItem
import io.ratex.DisplayList
import io.ratex.PathCommand
import io.ratex.RaTeXColor
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.render.BlockScrollBook
import surf.comma.android.chat.render.ChatMessageCell
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.MessageCopy
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.PreparedContentBlock
import surf.comma.android.chat.render.SelectableText
import surf.comma.android.chat.render.Md
import surf.comma.android.chat.render.MarkdownText
import surf.comma.android.chat.render.MarkdownSpan
import surf.comma.android.chat.render.MarkdownStyle
import surf.comma.android.scroll.widget.ScrollContainer

/**
 * Formulas through the real layout and cell, with a stand-in engine: what is drawn, where it
 * falls back to its source, what is cached, and what a reused cell keeps.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MathRenderingTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val width = (411 * density).toInt()

    /** Lays every formula out as one glyph per character, half an em each; `\bad` fails. */
    private class FakeEngine : MathEngine {
        val calls = ArrayList<Pair<String, Boolean>>()
        override fun layout(latex: String, display: Boolean): MathResult {
            calls += latex to display
            if ("\\bad" in latex) return MathResult.Failed("Undefined control sequence")
            if ("\\down" in latex) return MathResult.Unavailable
            val n = latex.length
            return MathResult.Laid(
                MathLayout(
                    width = n * 0.5f, height = 0.75f, depth = if (display) 0.5f else 0.25f,
                    glyphGeometry = FloatArray(n * 3) { if (it % 3 == 0) (it / 3) * 0.5f else if (it % 3 == 1) 0.75f else 1f },
                    glyphFonts = IntArray(n) { MathFontIds.indexOf("Math-Italic") },
                    glyphCodePoints = IntArray(n) { latex[it].code },
                    glyphColors = IntArray(n) { MathLayout.DEFAULT_COLOR },
                    rules = floatArrayOf(0f, 0.7f, n * 0.5f, 0.04f),
                    ruleColors = intArrayOf(MathLayout.DEFAULT_COLOR),
                    paths = emptyList(),
                    order = ByteArray(n) { MathLayout.GLYPH } + MathLayout.RULE,
                ),
            )
        }
    }

    private val engine = FakeEngine()
    private val typesetter = MathTypesetter(engine, { null })
    private val precomputer = MessageLayoutPrecomputer(bubbles = true, math = typesetter)

    private fun message(id: Long, text: String, role: ChatRole = ChatRole.AGENT, status: MessageStatus = MessageStatus.COMPLETED) =
        ChatMessage(id = id, conversationId = "c", turnId = "t$id", role = role, text = text, createdAt = id, status = status,
            // An agent's text as the core parsed it; a person's is shown as written.
            markdown = if (role == ChatRole.AGENT && text.isNotEmpty()) Md.of(text) else null)

    private fun prepare(
        vararg messages: ChatMessage,
        fontScale: Float = 1f,
        dark: Boolean = false,
        viewport: Int = width,
        with: MessageLayoutPrecomputer = precomputer,
    ): List<PreparedChatMessage> = runBlocking {
        val palette = if (dark) ChatPalette.DEFAULT.copy(agentText = 0xFFF6F6F6.toInt()) else ChatPalette.DEFAULT
        with.prepare(messages.toList(), viewportWidthPx = viewport, density = density, fontScale = fontScale,
            darkTheme = dark, palette = palette)
    }

    private fun spans(block: PreparedContentBlock): List<MathSpan> {
        val text = (block as PreparedContentBlock.Text).layout.text as Spanned
        return text.getSpans(0, text.length, MathSpan::class.java).sortedBy { text.getSpanStart(it) }
    }

    private fun sourceUnder(block: PreparedContentBlock, span: MathSpan): String {
        val text = (block as PreparedContentBlock.Text).layout.text as Spanned
        return text.subSequence(text.getSpanStart(span), text.getSpanEnd(span)).toString()
    }

    @Test fun `inline formulas the core found draw over their own source, and code stays text`() {
        val item = prepare(message(1, "Roots of \$x^2\$ and \$y\$, nor `\$z\$`.")).single()
        val block = item.blocks.single()
        val spans = spans(block)
        assertEquals(listOf("\$x^2\$", "\$y\$"), spans.map { sourceUnder(block, it) })
        assertEquals(listOf("x^2" to false, "y" to false), engine.calls)
        // The layout's text keeps each formula's source: copy and accessibility read it.
        assertTrue((block as PreparedContentBlock.Text).layout.text.toString().startsWith("Roots of \$x^2\$ and \$y\$"))
        assertEquals(listOf("Roots of \$x^2\$ and \$y\$, nor `\$z\$`."),
            MessageCopy.targets(item.message.text, item.contents).map { it.second })
    }

    @Test fun `an inline formula makes its line tall enough and sits on the baseline`() {
        val plain = prepare(message(1, "one line")).single().blocks.single() as PreparedContentBlock.Text
        val item = prepare(message(2, "one \$\\frac{a}{b}\\frac{c}{d}\$ line")).single()
        val block = item.blocks.single() as PreparedContentBlock.Text
        val span = spans(block).single()
        val layout = block.layout
        // Not clipped: the line holds the formula above and below the baseline.
        assertTrue(-layout.getLineAscent(0) >= span.box.ascentPx)
        assertTrue(layout.getLineDescent(0) >= span.box.descentPx)
        assertTrue(layout.height >= plain.layout.height)
        assertEquals(1, layout.lineCount)
    }

    @Test fun `a broken formula keeps its source and is not asked for again`() {
        val first = prepare(message(1, "see \$\\bad{x}\$ here")).single()
        assertEquals(emptyList<MathSpan>(), spans(first.blocks.single()))
        assertEquals("see \$\\bad{x}\$ here", (first.blocks.single() as PreparedContentBlock.Text).layout.text.toString())
        prepare(message(2, "again \$\\bad{x}\$"))
        assertEquals(1, engine.calls.count { it.first == "\\bad{x}" })
        // An engine that could not be reached is asked again next time.
        prepare(message(3, "\$\\down\$"))
        prepare(message(4, "\$\\down\$"))
        assertEquals(2, engine.calls.count { it.first == "\\down" })
    }

    @Test fun `display formulas are their own scrolling block, centred, with the source when they cannot be drawn`() {
        val item = prepare(message(1, "Before\n\$\$\nx+1\n\$\$\nMiddle\n\$\$\n\\bad\n\$\$")).single()
        val math = item.blocks.filterIsInstance<PreparedContentBlock.Math>().single()
        assertEquals(1, math.contentIndex)
        assertTrue(math.leftInsetPx > 0)
        val texts = item.blocks.filterIsInstance<PreparedContentBlock.Text>().map { it.layout.text.toString() }
        assertEquals(listOf("Before", "Middle", "\$\$\n\\bad\n\$\$"), texts)
        assertEquals(listOf("x+1" to true, "\\bad" to true), engine.calls)
        // The bubble is as wide as its widest content and holds the formula.
        val inner = item.bubbleWidthPx - item.horizontalPaddingPx * 2
        assertTrue(math.leftInsetPx + math.contentWidthPx <= inner)
    }

    @Test fun `a wide display formula scrolls sideways in a scroll container, left to right even on a right-to-left page`() {
        val wide = "\$\$" + "a+".repeat(60) + "b\$\$"
        val item = prepare(message(1, "Wide:\n$wide\nafter")).single()
        val math = item.blocks.filterIsInstance<PreparedContentBlock.Math>().single()
        assertTrue(math.contentWidthPx > math.viewportWidthPx)
        assertEquals(0, math.leftInsetPx)
        val cell = ChatMessageCell(activity).apply {
            layoutDirection = View.LAYOUT_DIRECTION_RTL
            bind(item)
        }
        layOut(cell)
        val slot = slots(cell).single()
        assertEquals(View.LAYOUT_DIRECTION_LTR, slot.layoutDirection)
        assertTrue(slot.canScroll)
        assertEquals(math.viewportWidthPx, slot.width)
        assertEquals(0, slot.scrollOffset)
        // The block draws without a layout pass of its own.
        cell.draw(Canvas(Bitmap.createBitmap(cell.width, cell.height, Bitmap.Config.ARGB_8888)))
    }

    @Test fun `a formula past the width cap shows its source`() {
        val huge = "\$\$" + "x".repeat(1_900) + "\$\$"
        val item = prepare(message(1, huge), viewport = (320 * density).toInt()).single()
        assertTrue(item.blocks.none { it is PreparedContentBlock.Math })
        assertTrue(item.blocks.all { it is PreparedContentBlock.Text })
    }

    @Test fun `an inline formula wider than its column is set smaller, or left as source`() {
        val narrow = (320 * density).toInt()
        val fits = prepare(message(1, "a \$" + "y".repeat(26) + "\$ b"), viewport = narrow).single()
        val span = spans(fits.blocks.single()).single()
        val column = narrow - (28 * 2 + 42 + 13 * 2) * density
        assertTrue(span.widthPx <= column)
        assertTrue(span.box.textSizePx < 16 * density * 1.1f)
        val tooWide = prepare(message(2, "a \$" + "z".repeat(120) + "\$ b"), viewport = narrow).single()
        assertEquals(emptyList<MathSpan>(), spans(tooWide.blocks.first()))
    }

    @Test fun `each formula is asked for once, and a new size or theme reuses the layouts`() {
        val reply = "First \$a\$ then\n\$\$\nb\n\$\$\nand \$c\$ end"
        prepare(message(1, reply)).single()
        assertEquals(engine.calls.size, engine.calls.toSet().size)
        assertTrue(("a" to false) in engine.calls && ("b" to true) in engine.calls && ("c" to false) in engine.calls)
        val before = engine.calls.size
        val bigger = prepare(message(1, reply), fontScale = 1.5f).single()
        val dark = prepare(message(1, reply), dark = true).single()
        assertEquals("layouts are kept in ems", before, engine.calls.size)
        val small = prepare(message(1, reply)).single().blocks.filterIsInstance<PreparedContentBlock.Math>().single()
        val large = bigger.blocks.filterIsInstance<PreparedContentBlock.Math>().single()
        assertEquals(small.box.textSizePx * 1.5f, large.box.textSizePx, 0.01f)
        assertTrue(large.heightPx > small.heightPx)
        val darkMath = dark.blocks.filterIsInstance<PreparedContentBlock.Math>().single()
        assertTrue("the theme changes the text colour the formula takes", darkMath.color != small.color)
    }

    @Test fun `a message typesets a bounded number of formulas`() {
        val many = (1..MathLimits.MAX_PER_MESSAGE + 30).joinToString(" ") { "\$v_{$it}\$" }
        val item = prepare(message(1, many)).single()
        // Long text is cut into several blocks over one text; count its spans once.
        val drawn = spans(item.blocks.first()).size
        assertEquals(MathLimits.MAX_PER_MESSAGE, drawn)
    }

    @Test fun `lists, quotes, headings and tables get formulas too, and a person's words are shown as written`() {
        val item = prepare(message(1, "# Title \$h\$\n\n- item \$l\$\n\n> quote \$q\$\n\n| a | b |\n|---|---|\n| \$t\$ | 2 |")).single()
        assertEquals(listOf("h", "l", "q", "t"), engine.calls.map { it.first })
        val user = prepare(message(2, "is \$u\$ right?", role = ChatRole.USER)).single()
        assertEquals(0, spans(user.blocks.single()).size)
        val table = item.blocks.filterIsInstance<PreparedContentBlock.Table>().single()
        val cell = table.cells.first { it.row == 1 && it.column == 0 }.layout.text as Spanned
        assertEquals(1, cell.getSpans(0, cell.length, MathSpan::class.java).size)
    }

    @Test fun `the select-text page and copy keep the source`() {
        val markdown = "A \$x\$ and\n\$\$\ny^2\n\$\$"
        assertEquals("A \$x\$ and\n\n\$\$\ny^2\n\$\$", SelectableText.build(Md.blocks(markdown)).toString())
        val item = prepare(message(1, markdown)).single()
        assertEquals(listOf(markdown), MessageCopy.targets(item.message.text, item.contents).map { it.second })
    }

    @Test fun `a reused cell shows the new message's formulas at their own offsets`() {
        val book = BlockScrollBook()
        val wide = "\$\$" + "a+".repeat(60) + "b\$\$"
        val a = prepare(message(1, "One\n$wide")).single()
        val b = prepare(message(2, "Two\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\nthen\n\$\$\nshort\n\$\$")).single()
        val cell = ChatMessageCell(activity).apply { blockScrolls = book; bind(a) }
        layOut(cell)
        slots(cell).single().scrollOffset = 300
        layOut(cell)
        assertEquals(300, book[BlockScrollBook.Key(1, a.blocks.first { it is PreparedContentBlock.Math }.contentIndex)])
        cell.bind(b)
        layOut(cell)
        val bodies = slots(cell)
        assertEquals(2, bodies.size)
        assertEquals(listOf(0, 0), bodies.map { it.scrollOffset })
        // The slot the formula used is now the table's, and follows the page's direction again.
        assertEquals(View.LAYOUT_DIRECTION_INHERIT, bodies[0].rawDirection())
        assertEquals(View.LAYOUT_DIRECTION_LTR, bodies[1].layoutDirection)
        cell.bind(a)
        layOut(cell)
        assertEquals(300, slots(cell).single().scrollOffset)
    }

    @Test fun `typesetting is refused on the main thread unless cached`() {
        assertTrue(Looper.getMainLooper().isCurrentThread)
        assertNull(typesetter.layout("m", display = false))
        assertEquals(emptyList<Any>(), engine.calls)
        prepare(message(1, "\$m\$"))
        assertNotNull(typesetter.layout("m", display = false))
    }

    @Test fun `the layout cache is bounded by how much it draws`() {
        val small = MathTypesetter(engine, { null }, maxWeight = 200)
        Thread {
            (1..40).forEach { small.layout("f$it" + "x".repeat(20), display = false) }
        }.apply { start(); join() }
        val calls = engine.calls.size
        Thread { small.layout("f1" + "x".repeat(20), display = false) }.apply { start(); join() }
        assertEquals("the oldest layouts were let go", calls + 1, engine.calls.size)
    }

    @Test fun `a box draws its glyphs, rules and outlines in the text colour unless it has its own`() {
        val list = DisplayList(
            width = 2.0, height = 1.0, depth = 0.5,
            items = listOf(
                DisplayItem.GlyphPath(0.0, 1.0, 1.0, "Main-Regular", 'x'.code, color = RaTeXColor.Black),
                DisplayItem.GlyphPath(1.0, 1.0, 1.0, "CJK-Regular", '中'.code, color = RaTeXColor(1f, 0f, 0f, 1f)),
                DisplayItem.Line(0.0, 0.5, 2.0, 0.04, RaTeXColor.Black),
                DisplayItem.Rect(0.0, 0.0, 0.1, 1.5, RaTeXColor.Black),
                DisplayItem.Path(0.0, 0.0, listOf(PathCommand.MoveTo(0.0, 0.0), PathCommand.LineTo(1.0, 1.0),
                    PathCommand.QuadTo(1.0, 0.0, 2.0, 1.0), PathCommand.CubicTo(0.0, 0.0, 1.0, 1.0, 2.0, 0.0), PathCommand.Close),
                    fill = true, color = RaTeXColor.Black),
            ),
        )
        val layout = MathLayout.from(list)
        assertEquals(2, layout.glyphCount)
        assertEquals(-1, layout.glyphFonts[1])
        assertEquals(0xFFFF0000.toInt(), layout.glyphColors[1])
        assertEquals(2, layout.ruleColors.size)
        assertArrayEquals(floatArrayOf(0f, 0.48f, 2f, 0.04f), layout.rules.copyOfRange(0, 4), 1e-5f)
        assertArrayEquals(byteArrayOf(MathLayout.MOVE, MathLayout.LINE, MathLayout.QUAD, MathLayout.CUBIC, MathLayout.CLOSE),
            layout.paths.single().verbs)
        val box = MathBox(layout, 40f) { null }
        assertEquals(80f, box.widthPx)
        val bitmap = Bitmap.createBitmap(100, 80, Bitmap.Config.ARGB_8888)
        box.draw(Canvas(bitmap), 0f, 0f, 0xFF00FF00.toInt())
        // The rule at the left edge takes the text colour.
        assertEquals(0xFF00FF00.toInt(), bitmap.getPixel(1, 30))
    }

    @Test fun `a layout crosses the process boundary intact, and a damaged one is refused`() {
        val layout = (engine.layout("abc", true) as MathResult.Laid).layout
        val parcel = Parcel.obtain()
        layout.writeTo(parcel)
        parcel.setDataPosition(0)
        val read = MathLayout.read(parcel)!!
        assertEquals(layout.width, read.width)
        assertArrayEquals(layout.glyphCodePoints, read.glyphCodePoints)
        assertArrayEquals(layout.rules, read.rules, 0f)
        parcel.recycle()

        val broken = MathLayout(1f, 1f, 0f, FloatArray(5), IntArray(2), IntArray(2), IntArray(2), FloatArray(0), IntArray(0),
            emptyList(), ByteArray(2))
        val other = Parcel.obtain()
        broken.writeTo(other)
        other.setDataPosition(0)
        assertNull(MathLayout.read(other))
        other.recycle()
        val tooWide = MathLayout(1e6f, 1f, 0f, FloatArray(0), IntArray(0), IntArray(0), IntArray(0), FloatArray(0), IntArray(0),
            emptyList(), ByteArray(0))
        assertFalse(MathLimits.accepts(tooWide))
        assertFalse(MathLimits.accepts(MathLayout(Float.NaN, 1f, 0f, FloatArray(0), IntArray(0), IntArray(0), IntArray(0),
            FloatArray(0), IntArray(0), emptyList(), ByteArray(0))))
    }

    /** One glyph over one rule covering the whole box, in the given drawing order. */
    private fun glyphAndRule(codePoint: Int = 'X'.code, font: Int = -1, order: ByteArray = byteArrayOf(MathLayout.RULE, MathLayout.GLYPH)) =
        MathLayout(
            width = 1f, height = 1f, depth = 0f,
            glyphGeometry = floatArrayOf(0.1f, 0.9f, 1f), glyphFonts = intArrayOf(font),
            glyphCodePoints = intArrayOf(codePoint), glyphColors = intArrayOf(MathLayout.DEFAULT_COLOR),
            rules = floatArrayOf(0f, 0f, 1f, 1f), ruleColors = intArrayOf(0xFFFFFF00.toInt()),
            paths = emptyList(), order = order,
        )

    @Test fun `a background drawn before its text stays under it`() {
        // \colorbox{yellow}{X}: the engine sends the box first, then the letter.
        val box = MathBox(glyphAndRule(), 60f) { null }
        val bitmap = Bitmap.createBitmap(60, 60, Bitmap.Config.ARGB_8888)
        box.draw(Canvas(bitmap), 0f, 0f, 0xFF000000.toInt())
        val pixels = IntArray(60 * 60).also { bitmap.getPixels(it, 0, 60, 0, 0, 60, 60) }
        assertTrue("the letter shows on the yellow", pixels.any { (it and 0xFFFFFF) < 0x404040 })
        assertTrue("the yellow is there", pixels.any { it == 0xFFFFFF00.toInt() })
    }

    @Test fun `a layout with a bad glyph code or face is refused, and the formula shows its source`() {
        assertTrue(MathLimits.accepts(glyphAndRule()))
        assertFalse(MathLimits.accepts(glyphAndRule(codePoint = 0x110000)))
        assertFalse(MathLimits.accepts(glyphAndRule(codePoint = -1)))
        assertFalse(MathLimits.accepts(glyphAndRule(font = MathFontIds.ALL.size)))
        assertFalse("the order has to match the items", MathLimits.accepts(glyphAndRule(order = byteArrayOf(MathLayout.GLYPH))))
        // The same through the process boundary.
        val parcel = Parcel.obtain()
        glyphAndRule(codePoint = 0x110000).writeTo(parcel)
        parcel.setDataPosition(0)
        assertNull(MathLayout.read(parcel))
        parcel.recycle()
        // And through the typesetter: no span, no exception, the source stays.
        val hostile = MathTypesetter({ _, _ -> MathResult.Laid(glyphAndRule(codePoint = 0x110000)) }, { null })
        val plain = MessageLayoutPrecomputer(bubbles = true, math = hostile)
        val item = prepare(message(1, "see \$x\$ here"), with = plain).single()
        assertEquals(emptyList<MathSpan>(), spans(item.blocks.single()))
        assertEquals("see \$x\$ here", (item.blocks.single() as PreparedContentBlock.Text).layout.text.toString())
    }

    @Test fun `without a typesetter nothing changes`() {
        val plain = MessageLayoutPrecomputer(bubbles = true, math = null)
        val item = prepare(message(1, "a \$x\$ b\n\$\$\ny\n\$\$"), with = plain).single()
        assertEquals(listOf(
            MessageContent.Paragraph(MarkdownText("a \$x\$ b", listOf(MarkdownSpan(2, 5, MarkdownStyle.MATH, latex = "x")))),
            MessageContent.Math("y", "\$\$\ny\n\$\$"),
        ), item.contents)
        assertTrue(item.blocks.all { it is PreparedContentBlock.Text })
        assertEquals(emptyList<Any>(), engine.calls)
    }

    @Test fun `prepared formulas keep their boxes across rebinds of the same message`() {
        val first = prepare(message(1, "x \$q\$")).single()
        val again = prepare(message(1, "x \$q\$")).single()
        assertSame(first.blocks.single(), again.blocks.single())
    }

    private fun layOut(cell: ChatMessageCell) {
        cell.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        cell.layout(0, 0, cell.measuredWidth, cell.measuredHeight)
        shadowOf(Looper.getMainLooper()).idle()
        cell.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        cell.layout(0, 0, cell.measuredWidth, cell.measuredHeight)
    }

    private fun slots(cell: ChatMessageCell) =
        (0 until cell.childCount).map(cell::getChildAt).filterIsInstance<ScrollContainer>().filter { it.visibility == View.VISIBLE }

    /** The direction set on the view itself, before inheriting from its parent. */
    private fun View.rawDirection(): Int =
        View::class.java.getDeclaredMethod("getRawLayoutDirection").apply { isAccessible = true }.invoke(this) as Int
}
