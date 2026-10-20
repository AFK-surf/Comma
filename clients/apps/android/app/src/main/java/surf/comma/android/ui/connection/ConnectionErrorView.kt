package surf.comma.android.ui.connection

import android.content.Context
import android.content.res.ColorStateList
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import com.google.android.material.button.MaterialButton
import surf.comma.android.R
import surf.comma.android.ui.composer.ButtonScale
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography

/**
 * The mark and title stay where the connecting page puts them; the explanation and its
 * recovery actions follow. Retry is the one filled button, switching account a quiet label.
 */
internal class ConnectionErrorView(context: Context) : FrameLayout(context) {
    var onRetry: () -> Unit = {}
    var onSwitchAccount: () -> Unit = {}
    private val column = ConnectionColumn(context)
    private val title = column.title
    private val badge = column.badge
    private val detail = TextView(context).apply {
        gravity = Gravity.CENTER
        setTextColor(context.getColor(R.color.token_text_secondary))
        DesignTypography.applyTo(this, DesignTypography.Level.REGULAR)
    }
    private val retry = SpringButton(context).apply {
        id = R.id.connection_error_retry
        isAllCaps = false
        DesignTypography.applyTo(this, weight = DesignFonts.semibold)
        setText(R.string.auth_retry)
        setTextColor(context.getColor(android.R.color.white))
        backgroundTintList = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()),
            intArrayOf(context.getColor(R.color.token_bg_brand_solid_hover), context.getColor(R.color.token_bg_brand_solid)),
        )
        cornerRadius = dp(24)
        insetTop = 0
        insetBottom = 0
        minHeight = dp(48)
        stateListAnimator = null
        elevation = 0f
        setPadding(dp(40), dp(12), dp(40), dp(12))
        setOnClickListener { onRetry() }
    }
    private val progress = ConnectionSpinner(context).apply {
        id = R.id.connection_error_progress
        color = context.getColor(android.R.color.white)
        visibility = INVISIBLE
    }
    private val secondary = SpringButton(context).apply {
        id = R.id.connection_error_account
        isAllCaps = false
        DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.medium)
        setText(R.string.auth_switch_account)
        setTextColor(context.getColor(R.color.token_text_tertiary))
        backgroundTintList = ColorStateList.valueOf(android.graphics.Color.TRANSPARENT)
        stateListAnimator = null
        elevation = 0f
        insetTop = 0
        insetBottom = 0
        minHeight = dp(48)
        minimumHeight = dp(48)
        minimumWidth = dp(48)
        setPadding(dp(16), 0, dp(16), 0)
        setOnClickListener { onSwitchAccount() }
    }

    init {
        id = R.id.connection_error_page
        setBackgroundColor(context.getColor(R.color.token_bg_primary))
        // Swallows touches meant for the page underneath, but is not itself a focus stop: a
        // focused page would draw the focus highlight over everything on it.
        isClickable = true
        isFocusable = false
        title.id = R.id.connection_error_title
        detail.id = R.id.connection_error_detail
        badge.id = R.id.connection_error_badge
        column.badgeVisible = true
        column.addView(detail, column.row(8))
        column.addView(FrameLayout(context).apply {
            addView(retry, LayoutParams(-1, -2))
            addView(progress, LayoutParams(dp(18), dp(18), Gravity.CENTER_VERTICAL or Gravity.START).apply {
                marginStart = dp(20)
            })
        }, column.row(28))
        column.addView(secondary, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(4) })
        addView(column.scrolling(), LayoutParams(-1, -1))
    }

    fun render(state: ConnectionErrorState) {
        val copy = when (state.reason) {
            ConnectionErrorReason.OFFLINE -> R.string.connection_offline_title to R.string.connection_offline_detail
            ConnectionErrorReason.UNREACHABLE -> R.string.connection_unreachable_title to R.string.connection_unreachable_detail
            ConnectionErrorReason.SERVICE -> R.string.connection_service_title to R.string.connection_service_detail
            ConnectionErrorReason.RATE_LIMITED -> R.string.connection_rate_title to R.string.connection_rate_detail
            ConnectionErrorReason.STORAGE -> R.string.auth_storage_title to R.string.auth_storage_error
            ConnectionErrorReason.NO_WORKSPACE -> R.string.connection_workspace_title to R.string.auth_no_workspace
            ConnectionErrorReason.CHAT_UNAVAILABLE -> R.string.connection_chat_title to R.string.connection_chat_detail
        }
        title.setText(copy.first)
        detail.setText(copy.second)
        badge.setImageResource(if (state.reason == ConnectionErrorReason.OFFLINE) R.drawable.ic_connection_offline else R.drawable.ic_settings_backend)
        retry.setText(if (state.busy) R.string.connection_retrying else R.string.auth_retry)
        retry.isClickable = !state.busy
        // Keep the enabled colours and focus target; the controller also guards duplicate taps.
        ViewCompat.setStateDescription(retry, if (state.busy) context.getString(R.string.connection_retrying) else null)
        progress.visibility = if (state.busy) VISIBLE else INVISIBLE
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}

/**
 * Uses the shared DesignSpring-backed press treatment, including reduced motion. MaterialButton
 * needs a Material Components theme, which the chat screen's framework theme is not, so the
 * button brings the sign-in screen's theme with it.
 */
private class SpringButton(context: Context) :
    MaterialButton(android.view.ContextThemeWrapper(context, R.style.Theme_Comma_Auth)) {
    private var scale: ButtonScale? = null
    init { scale = ButtonScale(this, action = false) }
    override fun setPressed(pressed: Boolean) {
        super.setPressed(pressed)
        scale?.setPressed(pressed)
    }
}
