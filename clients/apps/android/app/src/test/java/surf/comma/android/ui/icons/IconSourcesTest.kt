package surf.comma.android.ui.icons

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/** The licensed icons stay registered, drawn the way the Mac draws them, and tintable. */
class IconSourcesTest {

    private val drawables = File(repoRoot(), "app/src/main/res/drawable")

    @Test
    fun everyComposerTaskSettingsAndCallIconIsRegisteredExactlyOnce() {
        val onDisk = drawables.listFiles()!!.map { it.nameWithoutExtension }
            .filter { it.startsWith("ic_composer_") || it.startsWith("ic_task_") || it.startsWith("ic_media_") || it.startsWith("ic_settings_") || it.startsWith("ic_connection_") || it.startsWith("ic_chat_") || it.startsWith("ic_call_") ||
                listOf("ic_tab_", "ic_list_", "ic_nav_", "ic_action_", "ic_filter_", "ic_inbox_", "ic_chevron_", "ic_plus_",
                    "ic_routine_", "ic_warning_", "ic_arrow_", "ic_empty_", "ic_share_", "ic_circle_", "ic_trash_", "ic_history", "ic_people")
                    .any(it::startsWith) }
            .toSet()
        val registered = IconSources.entries.map { it.resource }
        assertEquals("no duplicates", registered.size, registered.toSet().size)
        assertEquals(onDisk, registered.toSet() + IconSources.pending + IconSources.pendingReplacement.keys)
        assertTrue("pending glyphs are not also registered", IconSources.pending.none { it in registered })
    }

    @Test
    fun eachDrawableNamesItsSourceAndKeepsThe24Grid() {
        IconSources.entries.forEach { entry ->
            val xml = xml(entry.resource)
            assertTrue(entry.resource, xml.contains("Central Icons (commercially licensed): ${entry.glyph}, ${entry.pack.substringAfter('/')}."))
            assertTrue(entry.resource, xml.contains("""android:width="24dp" android:height="24dp""""))
            assertTrue(entry.resource, xml.contains("""android:viewportWidth="24" android:viewportHeight="24""""))
            assertFalse("no local paths in ${entry.resource}", xml.contains("/Users/") || xml.contains("Desktop"))
        }
    }

    @Test
    fun everyPathIsPathDataNotSomethingElseCopiedFromTheSource() {
        IconSources.entries.forEach { entry ->
            val paths = Regex("""android:pathData="([^"]*)"""").findAll(xml(entry.resource)).map { it.groupValues[1] }.toList()
            assertTrue(entry.resource, paths.isNotEmpty())
            paths.forEach { assertTrue("${entry.resource}: $it", Regex("""^[Mm][\d.\s,-]""").containsMatchIn(it)) }
        }
    }

    @Test
    fun strokesAreTwoWideRoundAndColourComesFromCode() {
        IconSources.entries.forEach { entry ->
            val xml = xml(entry.resource)
            val colours = Regex("""android:(?:stroke|fill)Color="([^"]+)"""").findAll(xml).map { it.groupValues[1] }.toSet()
            assertEquals("${entry.resource} is tinted in code", setOf("#FF000000"), colours)
            val strokes = Regex("""android:strokeColor=""").findAll(xml).count()
            if (entry.pack == IconSources.FILLED) {
                assertEquals("${entry.resource} is a filled glyph", 0, strokes)
            } else if (entry.note?.contains("no strokes") == true) {
                assertEquals("${entry.resource} is drawn as filled outlines", 0, strokes)
            } else {
                assertTrue(entry.resource, strokes > 0)
                // A filled dot (the "i" of info, a key's hole) keeps Central's hairline outline; every line is 2 wide.
                val dots = Regex("""<path[^>]*android:strokeWidth="0\.\d+"[^>]*android:fillColor""").findAll(xml).count()
                assertEquals(entry.resource, strokes - dots, Regex("""android:strokeWidth="2"""").findAll(xml).count())
                // Copied as the source sets them: round wherever present, absent only where the note says so.
                val caps = Regex("""android:strokeLineCap="(\w+)"""").findAll(xml).map { it.groupValues[1] }.toList()
                val joins = Regex("""android:strokeLineJoin="(\w+)"""").findAll(xml).map { it.groupValues[1] }.toList()
                assertTrue(entry.resource, (caps + joins).all { it == "round" })
                if (entry.note?.contains("no line cap") != true) assertEquals(entry.resource, strokes, caps.size)
                if (entry.note?.contains("no line join") != true) assertEquals(entry.resource, strokes, joins.size)
            }
        }
    }

    @Test
    fun brandMarksShipForEveryDensityAndNowhereElse() {
        val res = File(repoRoot(), "app/src/main/res")
        IconSources.brandMarks.forEach { mark ->
            listOf("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi").forEach { density ->
                assertTrue("${mark.resource} @$density", File(res, "drawable-$density/${mark.resource}.png").isFile)
            }
            assertFalse("${mark.resource} has no vector copy", File(drawables, "${mark.resource}.xml").exists())
            assertFalse(mark.resource, mark.resource in IconSources.entries.map { it.resource })
        }
    }

    /** Placeholders exist, are not labelled as licensed glyphs, and are not also registered as licensed. */
    @Test
    fun placeholdersAwaitingReplacementAreListedSeparately() {
        val licensed = IconSources.entries.map { it.resource }.toSet()
        IconSources.pendingReplacement.keys.forEach { resource ->
            assertTrue("$resource exists", File(drawables, "$resource.xml").isFile)
            assertFalse(resource, xml(resource).contains("Central Icons"))
            assertFalse(resource, resource in licensed)
        }
    }

    /** The in-progress glyph spins about the view centre, so it must be symmetric about (12, 12). */
    @Test
    fun theSpinningGlyphIsCentred() {
        val data = Regex("""android:pathData="([^"]+)"""").findAll(xml("ic_task_in_progress"))
            .joinToString("") { it.groupValues[1] }
        val points = straightPathPoints(data)
        assertTrue(points.size >= 8)
        val xs = points.map { it.first }
        val ys = points.map { it.second }
        assertEquals(12.0, (xs.min() + xs.max()) / 2, 0.01)
        assertEquals(12.0, (ys.min() + ys.max()) / 2, 0.01)
        points.forEach { (x, y) ->
            assertTrue(
                "($x, $y) has a partner through the centre",
                points.any { (u, v) -> abs(u - (24 - x)) < 0.01 && abs(v - (24 - y)) < 0.01 },
            )
        }
    }

    /** Back is the full-height chevron (4..20), not the 8-unit Small one, so it reads as a nav target. */
    @Test
    fun theBackChevronIsFullHeight() {
        val xml = xml("ic_task_back")
        val ys = Regex("""[ML]([0-9.]+) ([0-9.]+)""").findAll(xml).map { it.groupValues[2].toDouble() }.toList()
        assertEquals(4.0, ys.min(), 0.01)
        assertEquals(20.0, ys.max(), 0.01)
    }

    /** Endpoints of an absolute M/L/H/V path; the loader uses nothing else. */
    private fun straightPathPoints(data: String): List<Pair<Double, Double>> {
        val tokens = Regex("""[MLHVZ]|-?[0-9]*\.?[0-9]+""").findAll(data).map { it.value }.toList()
        assertFalse("only absolute straight segments", Regex("""[^MLHVZ0-9.,\s-]""").containsMatchIn(data))
        val points = mutableListOf<Pair<Double, Double>>()
        var x = 0.0
        var y = 0.0
        var i = 0
        var command = ""
        while (i < tokens.size) {
            if (tokens[i].first().isLetter()) command = tokens[i++]
            when (command) {
                "M", "L" -> { x = tokens[i++].toDouble(); y = tokens[i++].toDouble() }
                "H" -> x = tokens[i++].toDouble()
                "V" -> y = tokens[i++].toDouble()
                "Z" -> continue
            }
            points += x to y
        }
        return points
    }

    private fun xml(resource: String) = File(drawables, "$resource.xml").readText()

    private fun repoRoot(): File = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) {
        it.parentFile
    }.first { File(it, "app/build.gradle.kts").isFile }
}
