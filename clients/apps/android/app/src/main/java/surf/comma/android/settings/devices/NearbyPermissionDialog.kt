package surf.comma.android.settings.devices

import android.app.Activity
import android.widget.LinearLayout
import surf.comma.android.R
import surf.comma.android.settings.SettingsDialog
import surf.comma.android.settings.dp

/** One explanation after sign-in, using the same dialog and type as Settings. */
internal class NearbyPermissionDialog(activity: Activity, onContinue: () -> Unit,
    private val onDismiss: () -> Unit) : SettingsDialog(activity) {
    init {
        card.addView(title("Find Comma devices near you"))
        card.addView(message("Allow Nearby devices to find a new Comma device when you open the app."),
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(12) })
        card.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(button("Not now", R.color.token_bg_quaternary, R.color.token_text_primary).apply {
                setOnClickListener { dismiss() }
            }, LinearLayout.LayoutParams(0, activity.dp(48), 1f))
            addView(button("Continue", R.color.token_bg_brand_solid, null).apply {
                setOnClickListener { dismiss(); onContinue() }
            }, LinearLayout.LayoutParams(0, activity.dp(48), 1f).apply { marginStart = activity.dp(8) })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }
    override fun onClosing() = onDismiss()
}
