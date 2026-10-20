package surf.comma.android

import android.app.Application
import android.os.Process
import android.util.Log
import androidx.work.Configuration
import surf.comma.android.chat.math.MathTypesetter
import surf.comma.android.settings.OpenActivities
import surf.comma.android.settings.TextSizeStore

/** WorkManager is initialized on demand so fixture launches keep their direct startup path. */
open class CommaApplication : Application(), Configuration.Provider {
    override fun onCreate() {
        super.onCreate()
        // The math process has no files to read and nothing to show; it only lays out formulas.
        if (Process.isIsolated()) return
        MathTypesetter.install(this)
        // Before any screen binds its typography.
        TextSizeStore.load(this)
        OpenActivities.register(this)
    }

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().setMinimumLoggingLevel(Log.ERROR).build()
}
