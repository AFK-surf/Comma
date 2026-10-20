package surf.comma.android.ui.theme

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.w3c.dom.Element
import surf.comma.android.R

class DesignLabelColorsTest {
    private data class Preset(val name: String, val resource: Int, val hex: String)
    private val presets = listOf(
        Preset("gray", R.color.token_label_gray, "#B6B8BB"),
        Preset("blue", R.color.token_label_blue, "#0BA5EC"),
        Preset("indigo", R.color.token_label_indigo, "#6172F3"),
        Preset("purple", R.color.token_label_purple, "#7A5AF8"),
        Preset("pink", R.color.token_label_pink, "#F670C7"),
        Preset("orange", R.color.token_label_orange, "#F38744"),
        Preset("warning", R.color.token_label_warning, "#FAC515"),
        Preset("success", R.color.token_label_success, "#47CD89"),
        Preset("error", R.color.token_label_error, "#F97066"),
        Preset("brand", R.color.token_label_brand, "#205BFF"),
    )
    private val resourceRoot: File by lazy {
        sequenceOf("src/main/res", "app/src/main/res").map(::File).first(File::isDirectory)
    }

    @Test fun everyPresetUsesItsNamedColorToken() {
        presets.forEach { preset ->
            val requested = mutableListOf<Int>()
            val result = DesignLabelColors.resolve(preset.name) { resource ->
                requested += resource
                0xFF123456.toInt()
            }
            assertEquals(preset.name, listOf(preset.resource), requested)
            assertEquals(0xFF123456.toInt(), result)
        }
    }

    @Test fun presetResourcesMatchTheLabelPalette() {
        val colors = colorsIn(File(resourceRoot, "values/colors_tokens.xml"))
            .filterKeys { it.startsWith("token_label_") }
        assertEquals(presets.map { "token_label_${it.name}" }.toSet(), colors.keys)
        presets.forEach { preset ->
            assertEquals(preset.name, preset.hex, colors["token_label_${preset.name}"])
        }
    }

    @Test fun nightThemesDoNotOverrideLabelColors() {
        val nightFiles = resourceRoot.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("values") && "night" in it.name }
            .flatMap { it.listFiles().orEmpty().filter { file -> file.extension == "xml" } }
        assertTrue(nightFiles.isNotEmpty())
        nightFiles.forEach { file ->
            assertTrue(file.name, colorsIn(file).keys.none { it.startsWith("token_label_") })
        }
    }

    @Test fun sixDigitHexPreservesRgbAndAddsFullOpacityWithoutReadingResources() {
        mapOf(
            "#000000" to 0xFF000000.toInt(),
            "#ffffff" to 0xFFFFFFFF.toInt(),
            "#123456" to 0xFF123456.toInt(),
            "#00aF10" to 0xFF00AF10.toInt(),
            "#0BA5EC" to 0xFF0BA5EC.toInt(),
        ).forEach { (input, expected) ->
            val actual = DesignLabelColors.resolve(input) {
                fail("Custom hex must not use a preset resource")
                0
            }
            assertEquals(input, expected, actual)
        }
    }

    @Test fun nullEmptyAndUnknownValuesUseTheGrayToken() {
        listOf(null, "", " ", "unknown", "Gray", "BLUE", " blue ", "red").forEach(::assertGray)
    }

    @Test fun malformedHexAndUnsupportedFormatsUseTheGrayToken() {
        listOf("#fff", "#12345", "#1234567", "#80123456", "#ffffffff", "#gg1122",
            "123456", "0x123456", " #123456", "#123456 ", "#123456\n", "rgb(1,2,3)")
            .forEach(::assertGray)
    }

    private fun assertGray(input: String?) {
        val requested = mutableListOf<Int>()
        val actual = DesignLabelColors.resolve(input) {
            requested += it
            0xFFB6B8BB.toInt()
        }
        assertEquals("Input: $input", listOf(R.color.token_label_gray), requested)
        assertEquals("Input: $input", 0xFFB6B8BB.toInt(), actual)
    }

    private fun colorsIn(file: File): Map<String, String> {
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(file).documentElement.getElementsByTagName("color")
        return (0 until nodes.length).associate { index ->
            val element = nodes.item(index) as Element
            element.getAttribute("name") to element.textContent.trim()
        }
    }
}
