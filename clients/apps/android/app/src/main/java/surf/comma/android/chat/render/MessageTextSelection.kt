package surf.comma.android.chat.render

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.Rect
import android.view.ActionMode
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import android.widget.ImageView
import android.widget.Magnifier
import android.widget.PopupWindow
import androidx.activity.OnBackPressedCallback
import androidx.activity.findViewTreeOnBackPressedDispatcherOwner
import androidx.core.graphics.ColorUtils
import surf.comma.android.R
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.ui.MessageActionsPopup
import kotlin.math.roundToInt

/** One active bubble: existing layout, system handles, magnifier and floating copy toolbar. */
internal class MessageTextSelection(
    private val cell: ChatMessageCell,
    private val geometry: MessageSelectionGeometry,
    private val runs: () -> List<MessageSelectionGeometry.Run>,
    private val fullText: String,
    private val onFinish: () -> Unit,
) {
    private val density = cell.resources.displayMetrics.density
    private val brand = cell.context.getColor(R.color.token_bg_brand_solid)
    private val highlight = Paint().apply {
        val tint = if (geometry.item.drawBubble && geometry.item.message.role == ChatRole.USER)
            ChatPalette.from(cell.context).userText else brand
        color = ColorUtils.setAlphaComponent(tint, 64)
    }
    private val location = IntArray(2)
    private val visible = Rect()
    private var mode: ActionMode? = null
    private var closed = false
    private var wholeMessage = false
    internal var start = 0
        private set
    internal var end = 0
        private set
    internal val selectedText: String
        get() = if (wholeMessage) fullText else geometry.text.substring(start, end)
    internal val text: String get() = geometry.text
    private val startHandle = Handle(true)
    private val endHandle = Handle(false)
    private val magnifier by lazy { Magnifier.Builder(cell).build() }
    private var magnifying = false
    private var dragging: Handle? = null
    private var pointerX = 0f
    private var pointerY = 0f
    private val back = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() = finish()
    }
    private val preDraw = ViewTreeObserver.OnPreDrawListener {
        updateHandles()
        true
    }
    private val focusChange = ViewTreeObserver.OnGlobalFocusChangeListener { _, next ->
        if (next != null && next !== cell) finish()
    }
    private val autoScroll = object : Runnable {
        override fun run() {
            val handle = dragging ?: return
            val list = cell.parent as? ChatTimelineView ?: return
            val position = IntArray(2).also(list::getLocationOnScreen)
            val top = position[1] + list.paddingTop
            val bottom = position[1] + list.chatBottomPx
            val edge = cell.resources.getDimension(R.dimen.spacing_3xl)
            val dy = when {
                pointerY < top + edge -> -8 * density
                pointerY > bottom - edge -> 8 * density
                else -> 0f
            }
            if (dy != 0f) list.scrollBy(0, dy.roundToInt())
            cell.getLocationOnScreen(location)
            cell.scrollSelectionHorizontally(pointerX - location[0], pointerY - location[1])
            handle.move(pointerX, pointerY)
            if (!closed && dragging != null) cell.postOnAnimation(this)
        }
    }

    fun begin(anchor: PointF?) {
        if (anchor != null) {
            val word = geometry.wordAt(geometry.offsetAt(runs(), anchor.x, anchor.y))
            if (word.isEmpty()) return finish()
            start = word.first
            end = word.last + 1
        } else {
            // Keyboard and accessibility actions select the message without a touch position.
            start = 0
            end = geometry.text.length
            wholeMessage = true
        }
        cell.findViewTreeOnBackPressedDispatcherOwner()?.onBackPressedDispatcher?.addCallback(back)
        cell.viewTreeObserver.addOnPreDrawListener(preDraw)
        cell.viewTreeObserver.addOnGlobalFocusChangeListener(focusChange)
        mode = cell.startActionMode(object : ActionMode.Callback2() {
            override fun onCreateActionMode(actionMode: ActionMode, menu: Menu): Boolean {
                menu.add(0, android.R.id.copy, 0, android.R.string.copy).setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
                menu.add(0, android.R.id.selectAll, 1, android.R.string.selectAll).setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
                return true
            }
            override fun onPrepareActionMode(actionMode: ActionMode, menu: Menu) = false
            override fun onActionItemClicked(actionMode: ActionMode, item: MenuItem): Boolean = when (item.itemId) {
                android.R.id.copy -> { copy(); true }
                android.R.id.selectAll -> { selectAll(); true }
                else -> false
            }
            override fun onDestroyActionMode(actionMode: ActionMode) = finish()
            override fun onGetContentRect(actionMode: ActionMode, view: View, outRect: Rect) {
                val a = geometry.caret(runs(), start, false)
                val b = geometry.caret(runs(), end, true)
                cell.getLocalVisibleRect(visible)
                if (a == null || b == null || visible.isEmpty) outRect.set(visible)
                else {
                    val top = (minOf(a.y, b.y) - cell.resources.getDimension(R.dimen.spacing_3xl))
                        .roundToInt().coerceIn(visible.top, visible.bottom - 1)
                    // When the toolbar fits only below the text, leave the handle touch targets clear.
                    val bottom = maxOf(a.y, b.y) + cell.resources.getDimension(R.dimen.spacing_6xl)
                    outRect.set(minOf(a.x, b.x).roundToInt(), top,
                        maxOf(a.x, b.x).roundToInt() + 1, bottom.roundToInt().coerceIn(top + 1, visible.bottom))
                }
            }
        }, ActionMode.TYPE_FLOATING)
        changed()
    }

    fun selectAll() {
        start = 0
        end = geometry.text.length
        // A task reference can split one logical message across rows. Keep its full-text copy.
        wholeMessage = true
        changed()
    }

    fun copy() {
        MessageActionsPopup.copyMessage(cell.context, selectedText)
        finish()
    }

    fun moveHandle(isStart: Boolean, x: Float, y: Float) {
        val offset = geometry.offsetAt(runs(), x, y)
        wholeMessage = false
        if (isStart && offset < end) start = offset
        else if (!isStart && offset > start) end = offset
        changed()
    }

    fun selectRange(from: Int, to: Int): Boolean {
        if (from !in 0..geometry.text.length || to !in from..geometry.text.length || from == to) return false
        val first = geometry.boundary(from)
        val last = geometry.boundary(to)
        if (first >= last) return false
        start = first
        end = last
        wholeMessage = false
        changed()
        return true
    }

    fun draw(canvas: Canvas) {
        if (!closed) geometry.draw(canvas, runs(), start, end, highlight)
    }

    private fun changed() {
        cell.invalidate()
        mode?.invalidateContentRect()
        updateHandles()
    }

    private fun updateHandles() {
        if (closed || !cell.isAttachedToWindow) return
        val current = runs()
        startHandle.place(geometry.caret(current, start, false))
        endHandle.place(geometry.caret(current, end, true))
    }

    fun finish() {
        if (closed) return
        closed = true
        dragging = null
        cell.removeCallbacks(autoScroll)
        if (magnifying) magnifier.dismiss()
        cell.viewTreeObserver.removeOnPreDrawListener(preDraw)
        cell.viewTreeObserver.removeOnGlobalFocusChangeListener(focusChange)
        back.remove()
        startHandle.popup.dismiss()
        endHandle.popup.dismiss()
        mode?.finish()
        mode = null
        cell.invalidate()
        onFinish()
    }

    private inner class Handle(val isStart: Boolean) {
        private val attributes = cell.context.obtainStyledAttributes(intArrayOf(
            if (isStart) android.R.attr.textSelectHandleLeft else android.R.attr.textSelectHandleRight))
        private val drawable = requireNotNull(attributes.getDrawable(0)).mutate().also {
            attributes.recycle()
            it.setTint(brand)
        }
        private val size = cell.resources.getDimensionPixelSize(R.dimen.spacing_6xl)
        private val dx = (size - drawable.intrinsicWidth) / 2
        private val hotspotX = dx + drawable.intrinsicWidth * if (isStart) 0.75f else 0.25f
        private var touchX = 0f
        private var touchY = 0f
        private var lastX = Int.MIN_VALUE
        private var lastY = Int.MIN_VALUE
        private var caret: PointF? = null
        private val image = ImageView(cell.context).apply {
            setImageDrawable(this@Handle.drawable)
            scaleType = ImageView.ScaleType.FIT_START
            setPadding(dx, 0, dx, (size - drawable.intrinsicHeight).coerceAtLeast(0))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        val point = caret ?: return@setOnTouchListener false
                        cell.getLocationOnScreen(location)
                        touchX = event.rawX - location[0] - point.x
                        touchY = event.rawY - location[1] - point.y
                        dragging = this@Handle
                        pointerX = event.rawX
                        pointerY = event.rawY
                        mode?.hide(Long.MAX_VALUE)
                        cell.postOnAnimation(autoScroll)
                    }
                    MotionEvent.ACTION_MOVE -> {
                        pointerX = event.rawX
                        pointerY = event.rawY
                        move(pointerX, pointerY)
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        dragging = null
                        cell.removeCallbacks(autoScroll)
                        if (magnifying) magnifier.dismiss()
                        magnifying = false
                        mode?.hide(0)
                        changed()
                    }
                }
                true
            }
        }
        val popup = PopupWindow(image, size, size, false).apply {
            isClippingEnabled = false
            inputMethodMode = PopupWindow.INPUT_METHOD_NOT_NEEDED
        }

        fun move(rawX: Float, rawY: Float) {
            cell.getLocationOnScreen(location)
            val x = rawX - location[0] - touchX
            val y = rawY - location[1] - touchY - 1
            moveHandle(isStart, x, y)
            if (!closed && cell.isHardwareAccelerated) {
                magnifier.show(x.coerceIn(0f, cell.width.toFloat()), y.coerceIn(0f, cell.height.toFloat()))
                magnifying = true
            }
        }

        fun place(point: PointF?) {
            caret = point
            if (point == null || !cell.getLocalVisibleRect(visible) ||
                point.x !in visible.left.toFloat()..visible.right.toFloat() ||
                point.y !in visible.top.toFloat()..visible.bottom.toFloat()) {
                popup.dismiss()
                return
            }
            val list = cell.parent as? ChatTimelineView
            if (list != null && (cell.y + point.y < list.paddingTop || cell.y + point.y > list.chatBottomPx)) {
                popup.dismiss()
                return
            }
            cell.getLocationInWindow(location)
            val x = (location[0] + point.x - hotspotX).roundToInt()
            val y = (location[1] + point.y).roundToInt()
            if (!popup.isShowing) popup.showAtLocation(cell, Gravity.TOP or Gravity.LEFT, x, y)
            else if (lastX != x || lastY != y) popup.update(x, y, -1, -1)
            lastX = x
            lastY = y
        }
    }
}
