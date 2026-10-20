package surf.comma.android.settings

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// All identifiers and names below are invented test data.
class SettingsModelsTest {
    private fun device(clientSource: String?) =
        HomeDevice("dev_test", "Test", online = true, clientSource = clientSource, disconnectedAt = null)

    @Test fun `every Comma firmware board is a Comma device`() {
        listOf("t-circle", "m5stack-sticks3", "waveshare-amoled-1-32", "esp32-devkit").forEach {
            assertTrue(it, device(it).isCommaDevice)
        }
    }

    @Test fun `computers and unknown sources are not Comma devices`() {
        listOf("comma_dev", "comma_staging", "comma", "connector", "some-future-board", null).forEach {
            assertFalse(it ?: "null", device(it).isCommaDevice)
        }
    }
}
