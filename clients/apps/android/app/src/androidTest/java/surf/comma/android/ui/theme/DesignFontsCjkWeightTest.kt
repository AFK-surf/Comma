package surf.comma.android.ui.theme

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.R
import java.io.File

/** Draws real text and compares pixels, so it checks what the system fallback actually renders. */
class DesignFontsCjkWeightTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val han = "中文字重"
    private val latin = "Oct Dec"

    private fun pixels(typeface: Typeface, text: String): IntArray {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.typeface = typeface; textSize = 64f; color = Color.BLACK }
        val bitmap = Bitmap.createBitmap(320, 96, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).apply { drawColor(Color.WHITE); drawText(text, 8f, 72f, paint) }
        return IntArray(bitmap.width * bitmap.height).also { bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height) }
    }

    private fun same(a: Typeface, b: Typeface, text: String) = pixels(a, text).contentEquals(pixels(b, text))
    private fun system(weight: Int) = Typeface.create(Typeface.SANS_SERIF, weight, false)
    private fun alone(font: Font) = Typeface.CustomFallbackBuilder(FontFamily.Builder(font).build()).build()
    private fun inter(weight: Int) = alone(
        Font.Builder(context.resources, R.font.inter_variable).setFontVariationSettings("'wght' $weight").setWeight(weight).build()
    )
    private val roboto = File("/system/fonts/Roboto-Regular.ttf")
    private fun roboto(weight: Int) = alone(Font.Builder(roboto).setFontVariationSettings("'wght' $weight").setWeight(weight).build())

    @Test fun regularChineseRendersAtTheSystemMediumWeight() {
        val regular = DesignFonts.inter(context, DesignFonts.regular)
        assertTrue(same(regular, system(500), han))
        assertFalse(same(regular, system(400), han))
    }

    @Test fun heavierWeightsRenderChineseAtTheirOwnWeight() {
        for (weight in listOf(DesignFonts.medium, DesignFonts.semibold, DesignFonts.bold)) {
            assertTrue("weight $weight", same(DesignFonts.inter(context, weight), system(weight), han))
        }
    }

    @Test fun latinStaysOnInterAtTheRequestedWeight() {
        for (weight in listOf(DesignFonts.regular, DesignFonts.medium, DesignFonts.semibold, DesignFonts.bold)) {
            assertTrue("weight $weight", same(DesignFonts.inter(context, weight), inter(weight), latin))
        }
    }

    @Test fun chatSansRendersBodyChineseAtMediumAndBoldAtItsOwnWeight() {
        assertTrue(same(UiSansTypeface, system(500), han))
        assertFalse(same(UiSansTypeface, system(400), han))
        assertTrue(same(uiSansAt(UiSansSemiBold), system(UiSansSemiBold), han))
    }

    @Test fun chatSansKeepsItsLatinWeights() {
        if (!roboto.canRead()) return
        assertTrue(same(UiSansTypeface, roboto(400), latin))
        assertTrue(same(uiSansAt(UiSansSemiBold), roboto(UiSansSemiBold), latin))
    }
}
