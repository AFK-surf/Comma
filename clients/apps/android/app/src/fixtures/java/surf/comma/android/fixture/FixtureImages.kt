package surf.comma.android.fixture

import surf.comma.android.BuildConfig
import surf.comma.android.R
import surf.comma.android.chat.model.ImageDimensions

/** 25 bundled PNGs at known dimensions; no network, density scaling or full-gallery access. */
internal object FixtureImages {
    data class Image(val resourceId: Int, val dimensions: ImageDimensions, val messageIndex: Int) {
        val source: String get() = "android.resource://${BuildConfig.APPLICATION_ID}/$resourceId"
    }
    private val sizes = listOf(
        ImageDimensions(640, 640), ImageDimensions(960, 540), ImageDimensions(540, 960),
        ImageDimensions(1024, 256), ImageDimensions(256, 1024),
    )
    private val resources = listOf(
        R.drawable.fixture_image_01,
        R.drawable.fixture_image_02,
        R.drawable.fixture_image_03,
        R.drawable.fixture_image_04,
        R.drawable.fixture_image_05,
        R.drawable.fixture_image_06,
        R.drawable.fixture_image_07,
        R.drawable.fixture_image_08,
        R.drawable.fixture_image_09,
        R.drawable.fixture_image_10,
        R.drawable.fixture_image_11,
        R.drawable.fixture_image_12,
        R.drawable.fixture_image_13,
        R.drawable.fixture_image_14,
        R.drawable.fixture_image_15,
        R.drawable.fixture_image_16,
        R.drawable.fixture_image_17,
        R.drawable.fixture_image_18,
        R.drawable.fixture_image_19,
        R.drawable.fixture_image_20,
        R.drawable.fixture_image_21,
        R.drawable.fixture_image_22,
        R.drawable.fixture_image_23,
        R.drawable.fixture_image_24,
        R.drawable.fixture_image_25,
    )
    val images: List<Image> = resources.mapIndexed { index, resourceId ->
        Image(resourceId, sizes[index % sizes.size], 18 + index * 39)
    }
    private val byMessage = images.associateBy { it.messageIndex }
    fun at(index: Int): Image? = byMessage[index]
}
