package surf.comma.android.chat.render

import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.text.TextPaint
import android.view.View
import androidx.core.content.ContextCompat
import androidx.lifecycle.findViewTreeLifecycleOwner
import androidx.lifecycle.lifecycleScope
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.chat.model.SPEAKER_PERSON
import surf.comma.android.chat.model.SPEAKER_ROUTER
import surf.comma.android.people.PersonAvatarView
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.ui.theme.UiSansSemiBold
import surf.comma.android.ui.theme.uiSansAt

/**
 * Who says each left-side row of a Task, as iOS and desktop show it: every such row ([PreparedChatMessage.speakerGutterPx])
 * is set in by the avatar gutter, whatever view draws it, so bubbles, cards and pictures share one left edge; the last
 * row of a speaker's run carries the speaker's avatar in the gutter, level with the foot of its bubble or content.
 * The Router wears the Comma mark, a Worker the sparkles on the Agent tint, another person their photo or initials.
 */
internal class SpeakerAvatars(private val timeline: ChatTimelineView) : RecyclerView.ItemDecoration() {
    private val density = timeline.resources.displayMetrics.density
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    /** White on a tint, as on the brand bubble and the People lists' faces. */
    private val onTint = ChatPalette.from(timeline.context).userText
    private val letters = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = onTint
        typeface = uiSansAt(UiSansSemiBold)
        textAlign = Paint.Align.CENTER
    }
    private val mark = ContextCompat.getDrawable(timeline.context, R.drawable.ic_cue_mark)!!.mutate().apply {
        setTint(ContextCompat.getColor(timeline.context, R.color.token_text_primary))
    }
    private val sparkles = ContextCompat.getDrawable(timeline.context, R.drawable.ic_settings_sparkles)!!.mutate().apply {
        setTint(onTint)
    }
    private val bounds = Rect()
    private val oval = RectF()
    private val matrix = Matrix()

    override fun getItemOffsets(outRect: Rect, view: View, parent: RecyclerView, state: RecyclerView.State) {
        outRect.set(timeline.rowOf(view)?.speakerGutterPx ?: 0, 0, 0, 0)
    }

    override fun onDraw(canvas: Canvas, parent: RecyclerView, state: RecyclerView.State) {
        for (index in 0 until parent.childCount) {
            val child = parent.getChildAt(index)
            val row = timeline.rowOf(child) ?: continue
            val speaker = row.message.speaker ?: continue
            if (!row.message.speakerAvatar || row.speakerGutterPx == 0) continue
            val size = MessageLayoutPrecomputer.SPEAKER_AVATAR_DP * density
            // Right of the page's side margin, the gutter's gap away from the row's content.
            val left = child.left + child.translationX + row.sideMarginPx - row.speakerGutterPx
            val foot = if (row.drawBubble) row.bubbleTopPx + row.bubbleHeightPx else row.cellHeightPx - row.tailPx
            val bottom = child.top + child.translationY + foot
            oval.set(left, bottom - size, left + size, bottom)
            val alpha = (child.alpha * 255).toInt()
            when {
                speaker == SPEAKER_ROUTER -> drawMark(canvas, alpha)
                speaker.startsWith(SPEAKER_PERSON) -> drawPerson(canvas, row, alpha)
                else -> drawWorker(canvas, alpha)
            }
        }
    }

    /** The Comma mark, as an Agent's mark is drawn: smaller than a face, centred in its place. */
    private fun drawMark(canvas: Canvas, alpha: Int) {
        inset(AGENT_MARK_DP)
        mark.bounds = bounds
        mark.alpha = alpha
        mark.draw(canvas)
    }

    private fun drawWorker(canvas: Canvas, alpha: Int) {
        inset(AGENT_MARK_DP)
        fill.shader = null
        fill.color = ContextCompat.getColor(timeline.context, R.color.token_label_indigo)
        fill.alpha = alpha
        canvas.drawCircle(bounds.exactCenterX(), bounds.exactCenterY(), bounds.width() / 2f, fill)
        val icon = (bounds.width() * 0.7f).toInt()
        val inset = (bounds.width() - icon) / 2
        sparkles.setBounds(bounds.left + inset, bounds.top + inset, bounds.left + inset + icon, bounds.top + inset + icon)
        sparkles.alpha = alpha
        sparkles.draw(canvas)
    }

    private fun drawPerson(canvas: Canvas, row: PreparedChatMessage, alpha: Int) {
        val name = row.message.otherWriterName.orEmpty()
        val source = row.message.otherWriterAvatar?.let { runCatching { JSONObject(it) }.getOrNull() }
        val owner = timeline.findViewTreeLifecycleOwner()
        val photo = if (source == null || owner == null) null else PersonAvatarView.photo(source,
            surf.comma.android.auth.AuthGraph.core(timeline.context), owner.lifecycleScope) { timeline.invalidate() }
        if (photo != null) {
            val shader = BitmapShader(photo, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            val scale = maxOf(oval.width() / photo.width, oval.height() / photo.height)
            matrix.setScale(scale, scale)
            matrix.postTranslate(oval.centerX() - photo.width * scale / 2f, oval.centerY() - photo.height * scale / 2f)
            shader.setLocalMatrix(matrix)
            fill.shader = shader
            fill.alpha = alpha
            canvas.drawOval(oval, fill)
            fill.shader = null
            return
        }
        fill.shader = null
        fill.color = PersonAvatarView.tint(timeline.context, name)
        fill.alpha = alpha
        canvas.drawOval(oval, fill)
        letters.textSize = oval.height() * 0.4f
        letters.alpha = alpha
        val initials = PersonAvatarView.initials(name)
        val baseline = oval.centerY() - (letters.descent() + letters.ascent()) / 2f
        canvas.drawText(initials, oval.centerX(), baseline, letters)
    }

    /** [bounds]: a square of [sizeDp] centred in the avatar's place. */
    private fun inset(sizeDp: Float) {
        val size = sizeDp * density
        val dx = (oval.width() - size) / 2f
        val dy = (oval.height() - size) / 2f
        bounds.set((oval.left + dx).toInt(), (oval.top + dy).toInt(), (oval.left + dx + size).toInt(), (oval.top + dy + size).toInt())
    }

    private companion object {
        /** The Router's and a Worker's mark, inside a face's place (iOS `AgentAvatar`). */
        const val AGENT_MARK_DP = 16f
    }
}
