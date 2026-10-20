package surf.comma.android.chat.data

import android.content.Intent
import surf.comma.android.BuildConfig
import surf.comma.android.fixture.FixtureConversationSource

object ConversationSourceFactory {
    fun useFixtures(intent: Intent): Boolean = BuildConfig.BUILD_TYPE == "benchmark" ||
        intent.getBooleanExtra("fixtures", false) ||
        (BuildConfig.FLAVOR == "dev" && !intent.getBooleanExtra("login", false))
    fun create(): ConversationSource = FixtureConversationSource()
}
