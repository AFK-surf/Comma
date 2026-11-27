package surf.comma.android.chat.render

import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.view.MotionEvent
import android.view.View
import androidx.core.content.ContextCompat
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.scroll.widget.RevealDrag
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * Messages' drag to show times, for where messages came from: dragging the transcript to the left moves the person's
 * own messages with the finger ([RevealDrag]: one to one until the strip beside them is open, rubber-banded past it)
 * and uncovers, beside each that came in from a chat platform, that platform's logo, which grows in as it is
 * uncovered. The agent's messages stay where they are. Letting go springs the rows back from the finger's speed.
 */
internal class SourceReveal(private val timeline: ChatTimelineView) {
    private val density = timeline.resources.displayMetrics.density
    private val maxTravelPx = MAX_TRAVEL_DP * density
    private val logoPx = LOGO_DP * density
    private val logos = HashMap<String, Drawable?>()

    /** How far the person's rows are moved to the left, in px. */
    var travelPx = 0f
        private set
    // Critically damped: the rows return home without overshooting it.
    private val spring = DesignSpring(this, TRAVEL, DesignMotion.springSize, minimumVisibleChange = 0.5f)
    private val drag = RevealDrag(
        host = timeline,
        range = maxTravelPx,
        canStart = { timeline.scrollState == RecyclerView.SCROLL_STATE_IDLE },
        travel = { travelPx },
        moveTo = { spring.animation.cancel(); setTravel(it) },
        // The spring takes over at the finger's speed, so the rows never stop before they turn back.
        onRelease = { spring.animateTo(0f, initialVelocity = it) },
    )

    fun intercepts(event: MotionEvent): Boolean = drag.intercepts(event)

    fun onTouch(event: MotionEvent): Boolean = drag.onTouch(event)

    /** The person's own rows move; the agent's stay. */
    fun place(child: View) {
        child.translationX = if (timeline.rowOf(child)?.message?.role == ChatRole.USER) -travelPx else 0f
    }

    private fun setTravel(value: Float) {
        travelPx = value
        for (index in 0 until timeline.childCount) place(timeline.getChildAt(index))
        timeline.invalidate()
    }

    /** Each moved person's message's platform logo, in the strip the drag uncovered. */
    fun draw(canvas: Canvas) {
        if (travelPx <= 0f) return
        // The logo grows from half its size as it is uncovered, visible only above half (the shared enter rule).
        val progress = (travelPx / maxTravelPx).coerceIn(0f, 1f)
        val size = logoPx * (0.5f + 0.5f * progress)
        for (index in 0 until timeline.childCount) {
            val cell = timeline.getChildAt(index) as? ChatMessageCell ?: continue
            val item = cell.preparedItem ?: continue
            if (item.message.role != ChatRole.USER || !item.drawBubble) continue
            val logo = logo(item.message.platformSource) ?: continue
            // Centred in the uncovered strip and on the bubble, as Messages centres a time on its message.
            val centerX = cell.right + cell.translationX + maxTravelPx / 2f
            val centerY = cell.top + cell.translationY + item.bubbleTopPx + item.bubbleHeightPx / 2f
            logo.setBounds((centerX - size / 2).toInt(), (centerY - size / 2).toInt(),
                (centerX + size / 2).toInt(), (centerY + size / 2).toInt())
            logo.alpha = (progress * 255).toInt()
            logo.draw(canvas)
        }
    }

    private fun logo(platform: String?): Drawable? {
        val res = PlatformBubble.logo(platform) ?: return null
        return logos.getOrPut(platform!!) { ContextCompat.getDrawable(timeline.context, res)?.mutate() }
    }

    private companion object {
        const val MAX_TRAVEL_DP = 56f
        const val LOGO_DP = 22f

        val TRAVEL = object : FloatPropertyCompat<SourceReveal>("sourceTravel") {
            override fun getValue(reveal: SourceReveal) = reveal.travelPx
            override fun setValue(reveal: SourceReveal, value: Float) = reveal.setTravel(value)
        }
    }
}
