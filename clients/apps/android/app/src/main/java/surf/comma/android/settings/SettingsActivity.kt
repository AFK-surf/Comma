package surf.comma.android.settings

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.live.ChatRoute
import surf.comma.android.chat.live.routeFor
import surf.comma.android.settings.devices.DeviceSetupOffer

/**
 * The settings pages on their own, for the ways in from outside the tabs: setting up a Comma device a
 * notification offered, and a restored task that starts here. It slides in from the right and leaves with
 * the system back gesture. Inside the app, Settings is a tab.
 */
internal class SettingsActivity : ComponentActivity() {
    private val authRepository by lazy { AuthGraph.get(this) }
    private lateinit var settings: SettingsHost
    private var leaving = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0)
        overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        settings = SettingsHost(this, embedded = false, toast = { text, _ -> Toast.makeText(this, text, Toast.LENGTH_SHORT).show() }) {
            leave()
        }
        setContentView(settings.host)
        // Idempotent; covers a restored task that starts here rather than in the app.
        AuthGraph.scope.launch { authRepository.start() }

        // After a theme, language or text size change the stack comes back as it was, without sliding in.
        val keys = savedInstanceState?.getStringArrayList(STATE_PAGES)
        if (keys.isNullOrEmpty()) {
            // A setup offer opens over the root, so back from it returns to Settings rather than leaving.
            settings.open(RootPage(settings))
            DeviceSetupOffer.parse(intent.getStringExtra(EXTRA_SETUP_OFFER))?.let { settings.open(AddDevicePage(settings, it)) }
        } else {
            keys.mapNotNull(::pageFor).forEach(settings::restore)
            if (settings.host.top == null) settings.restore(RootPage(settings))
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(authRepository.state, authRepository.conversationScope) { state, scope -> routeFor(state, scope != null) }
                    .collect { if (it == ChatRoute.AUTH) leave(animate = false) }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Notifications may have been allowed or blocked in system settings meanwhile.
        settings.renderAll()
    }

    override fun onDestroy() {
        if (isFinishing && ::settings.isInitialized) settings.host.clear()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putStringArrayList(STATE_PAGES, ArrayList(settings.host.keys.filter { it in RESTORABLE || it == AddDevicePage.KEY || DeveloperSettings.restores(it) }))
    }

    /** Pages that can be rebuilt from their key alone. */
    private fun pageFor(key: String): SettingsPage? = when (key) {
        RootPage.KEY -> RootPage(settings)
        ProfilePage.KEY -> ProfilePage(settings)
        DevicesPage.KEY -> DevicesPage(settings)
        LicensesPage.KEY -> LicensesPage(settings)
        // An offer must also survive recreation while its Bluetooth permission is still pending.
        AddDevicePage.KEY -> DeviceSetupOffer.parse(intent.getStringExtra(EXTRA_SETUP_OFFER)).let { offer ->
            if (SettingsGraph.addDevice != null || offer != null) AddDevicePage(settings, offer) else null
        }
        else -> DeveloperSettings.page(settings, key)
    }

    private fun leave(animate: Boolean = true) {
        if (leaving) return
        leaving = true
        if (!animate) settings.host.clear()
        finish()
    }

    companion object {
        private const val EXTRA_SETUP_OFFER = "settings.setup_offer"
        private const val STATE_PAGES = "settings.pages"
        private val RESTORABLE = setOf(RootPage.KEY, ProfilePage.KEY, DevicesPage.KEY, LicensesPage.KEY)

        fun start(activity: Activity) {
            activity.startActivity(Intent(activity, SettingsActivity::class.java))
        }

        fun startAddDevice(activity: Activity, offer: DeviceSetupOffer) {
            activity.startActivity(Intent(activity, SettingsActivity::class.java).putExtra(EXTRA_SETUP_OFFER, offer.json().toString()))
        }
    }
}
