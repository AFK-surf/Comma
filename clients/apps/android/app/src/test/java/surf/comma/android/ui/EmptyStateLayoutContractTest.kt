package surf.comma.android.ui

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * [EmptyStateLayout] is arithmetic and its own tests prove the arithmetic. What they cannot
 * see is the layout the numbers describe, and that is where this went wrong once: the gap
 * below the dot field was the *title's* top margin, so hiding the field removed 70dp while
 * the controller added 84dp back, and a viewport that had shown the field needed 14dp more
 * than it started with to show it again.
 *
 * So the claim `naturalHeadlineHeight` makes -- hiding the field removes exactly the field
 * plus its gap -- is asserted against the XML itself.
 */
class EmptyStateLayoutContractTest {

    private val layout: Element by lazy {
        val file = sequenceOf(
            "src/main/res/layout/view_empty_timeline.xml",
            "app/src/main/res/layout/view_empty_timeline.xml",
            "Chat/app/src/main/res/layout/view_empty_timeline.xml",
        ).map(::File).first(File::isFile)
        DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
    }

    private fun element(tag: String): Element {
        val nodes = layout.getElementsByTagName(tag)
        assertTrue("$tag is missing from the layout", nodes.length > 0)
        return nodes.item(0) as Element
    }

    private fun Element.attr(name: String): String? =
        getAttribute("android:$name").ifEmpty { null }

    @Test
    fun `the gap below the dot field is the field's own margin`() {
        val glyph = element("surf.comma.android.ui.widget.DotMatrixView")
        assertEquals(
            "the gap has to go when the field goes, so it must be the field's marginBottom",
            "@dimen/empty_glyph_gap",
            glyph.attr("layout_marginBottom"),
        )
        assertEquals("@dimen/empty_glyph_height", glyph.attr("layout_height"))
    }

    @Test
    fun `nothing else in the headline re-adds that gap`() {
        val title = element("TextView")
        assertNull(
            "a top margin here survives the hidden field and puts the arithmetic 14dp out",
            title.attr("layout_marginTop"),
        )
    }

    /** The row is bottom-anchored in the layout; the controller only lifts it. */
    @Test
    fun `the suggestion row is bottom anchored and does not clip its padding`() {
        val row = element("surf.comma.android.scroll.widget.ScrollContainer")
        assertEquals("bottom", row.attr("layout_gravity"))
        assertEquals("false", row.attr("clipToPadding"))
        assertEquals("@dimen/screen_gutter", row.attr("paddingStart"))
        assertEquals("@dimen/screen_gutter", row.attr("paddingEnd"))
    }
}
