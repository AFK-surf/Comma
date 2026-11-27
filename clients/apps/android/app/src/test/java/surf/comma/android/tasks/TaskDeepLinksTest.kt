package surf.comma.android.tasks

import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TaskDeepLinksTest {
    @Test fun `parses valid task deep links for the build scheme`() {
        assertEquals(
            TaskDeepLink("wsp_1", "grp1_2_3", "cnv_4"),
            TaskDeepLinks.parse(
                Uri.parse("comma://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4"),
                "comma",
            ),
        )
        assertEquals(
            TaskDeepLink("wsp_1", "grp1_2_3", "cnv_4"),
            TaskDeepLinks.parse(
                Uri.parse("comma-staging://task/?workspace=wsp_1&group=grp1_2_3&task=cnv_4"),
                "comma-staging",
            ),
        )
    }

    @Test fun `rejects mismatched scheme, bad structure or invalid ids`() {
        val invalid = listOf(
            "comma://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
            "https://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
            "comma-staging://tasks?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
            "comma-staging://task/extra?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
            "comma-staging://user@task?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
            "comma-staging://task:80?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
            "comma-staging://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4#frag",
            "comma-staging://task?workspace=wsp_1&group=grp1_2_3",
            "comma-staging://task?workspace=wsp_1&task=cnv_4",
            "comma-staging://task?group=grp1_2_3&task=cnv_4",
            "comma-staging://task?workspace=..&group=grp1_2_3&task=cnv_4",
            "comma-staging://task?workspace=wsp_1/evil&group=grp1_2_3&task=cnv_4",
            "comma-staging://task?workspace=${"a".repeat(257)}&group=grp1_2_3&task=cnv_4",
        )
        for (raw in invalid) {
            assertNull(raw, TaskDeepLinks.parse(Uri.parse(raw), "comma-staging"))
        }
    }
}
