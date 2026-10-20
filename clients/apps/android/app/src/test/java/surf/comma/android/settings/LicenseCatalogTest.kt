package surf.comma.android.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LicenseCatalogTest {
    private val app = RuntimeEnvironment.getApplication()

    @Test fun parsesTheGeneratedListAndAddsWhatGradleDoesNotKnow() {
        val json = """
            {"libraries":[
              {"uniqueId":"com.squareup.okhttp3:okhttp","artifactVersion":"4.12.0","name":"OkHttp","licenses":["Apache-2.0"]},
              {"uniqueId":"io.coil-kt.coil3:coil-core","artifactVersion":"3.3.0","name":"coil-core","licenses":["Apache-2.0"]},
              {"uniqueId":"org.jetbrains.kotlin:kotlin-bom","artifactVersion":"2.2.10","name":"Kotlin BOM","licenses":["Apache-2.0"]}
            ],"licenses":{"Apache-2.0":{"name":"Apache License 2.0","content":"Apache text"}}}
        """.trimIndent()
        val entries = LicenseCatalog.parse(json, "Commercial").associateBy { it.name }
        assertEquals(LicenseText.Inline("Apache text"), entries.getValue("OkHttp").text)
        assertEquals(listOf("Apache License 2.0"), entries.getValue("OkHttp").licenses)
        // Coil's own license file ships with the app.
        assertEquals(LicenseText.Assets(listOf("licenses/Coil-3.3.0-LICENSE.txt")), entries.getValue("coil-core").text)
        assertTrue("BOMs ship nothing", "Kotlin BOM" !in entries)
        assertEquals(LicenseText.Assets(listOf("licenses/Inter-OFL.txt")), entries.getValue("Inter").text)
        assertEquals(LicenseText.Assets(listOf("licenses/KaTeX-fonts-OFL.txt")), entries.getValue("KaTeX fonts").text)
        assertTrue(entries.keys.any { it.startsWith("AndroidX RecyclerView (scroll module") })
        assertTrue(entries.keys.any { it.startsWith("FluidRecyclerView") })
        val central = entries.getValue("Central Icons")
        assertEquals(listOf("Commercial"), central.licenses)
        assertNull("commercial icons ship no license file", central.text)
    }

    @Test fun theBuildGeneratesTheListAndEveryBundledTextExists() {
        val entries = LicenseCatalog.load(app)
        assertTrue("dependencies come from the build", entries.any { it.name.equals("okhttp", ignoreCase = true) })
        entries.mapNotNull { it.text }.distinct().forEach { text ->
            assertTrue(LicenseCatalog.read(app, text).isNotBlank())
        }
    }
}
