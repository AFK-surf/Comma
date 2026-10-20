package surf.comma.android.chat.live

import android.app.Dialog
import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.Window
import android.widget.LinearLayout
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography

enum class FailedSendChoice { RETRY, DELETE }

/**
 * What to do with an unsent message, by its list row. Retry sends it again with its original
 * client request id; delete removes only the local pending copy, since nothing reached the server.
 */
class FailedSendActions(
    private val requestIdFor: (rowId: Long) -> String?,
    private val retry: (clientRequestId: String) -> Unit,
    private val delete: (clientRequestId: String) -> Unit,
) {
    /** Whether [rowId] is an unsent message that has options. */
    fun has(rowId: Long) = requestIdFor(rowId) != null

    fun choose(rowId: Long, choice: FailedSendChoice) {
        val requestId = requestIdFor(rowId) ?: return
        when (choice) {
            FailedSendChoice.RETRY -> retry(requestId)
            FailedSendChoice.DELETE -> delete(requestId)
        }
    }
}

/** A small bottom sheet with the two choices for an unsent message. */
class FailedSendSheet(context: Context, private val onChoice: (FailedSendChoice) -> Unit) : Dialog(context) {
    init {
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        val density = context.resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(8), dp(8), dp(16))
            background = GradientDrawable().apply {
                setColor(context.getColor(R.color.token_bg_primary))
                val radius = dp(20).toFloat()
                cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
            }
        }
        fun row(id: Int, label: Int, color: Int, choice: FailedSendChoice) = TextView(context).apply {
            this.id = id
            setText(label)
            setTextColor(context.getColor(color))
            DesignTypography.applyTo(this, DesignTypography.Level.REGULAR, DesignFonts.medium)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = dp(52)
            setPadding(dp(16), 0, dp(16), 0)
            val ripple = TypedValue()
            context.theme.resolveAttribute(android.R.attr.selectableItemBackground, ripple, true)
            setBackgroundResource(ripple.resourceId)
            setOnClickListener {
                dismiss()
                onChoice(choice)
            }
        }
        content.addView(row(R.id.failed_send_retry, R.string.chat_retry, R.color.token_text_primary, FailedSendChoice.RETRY),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        content.addView(row(R.id.failed_send_delete, R.string.chat_delete, R.color.token_text_error_primary, FailedSendChoice.DELETE),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setContentView(content)
        setCanceledOnTouchOutside(true)
        window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            setGravity(Gravity.BOTTOM)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
    }
}
