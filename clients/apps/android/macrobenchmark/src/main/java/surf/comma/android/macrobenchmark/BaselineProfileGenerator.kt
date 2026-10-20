package surf.comma.android.macrobenchmark

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Ignore
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Skeleton only: enable explicitly in P5, after both P1 compilation baselines are recorded. */
@Ignore("P1 prepares the generator but does not generate a Baseline Profile")
@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {
    @get:Rule val baselineProfile = BaselineProfileRule()

    @Test fun conversation() = baselineProfile.collect(packageName = TARGET_PACKAGE) {
        pressHome()
        launchConversation("cold_start")
        flingSequence()
    }
}
