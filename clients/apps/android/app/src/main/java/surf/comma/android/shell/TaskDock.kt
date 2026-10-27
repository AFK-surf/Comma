package surf.comma.android.shell

import android.annotation.SuppressLint
import android.content.res.ColorStateList
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.labels.LabelDot
import surf.comma.android.labels.TaskLabelsSheet
import surf.comma.android.routines.ProviderMarks
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.list.FlowLayout
import surf.comma.android.tasks.list.deviceName
import surf.comma.android.tasks.list.originName
import surf.comma.android.tasks.list.statusTint
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.GlassIconButton
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.dpf
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignLabelColors
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography.Level
import kotlin.math.abs

/**
 * The open Task as a panel over the app, as the iOS app's dock: minimized, only its bar (close, title and status,
 * actions) shows at the bottom edge and the app ends above it; dragging the bar, or tapping it, follows the finger
 * up into a full sheet holding the Task's conversation, which can be read and replied to. Tapping the title on the
 * open sheet grows the Task's details (status, where it came from, labels) out of the header; the close button
 * slides the sheet away. Another Task opened while one is docked takes over the same dock.
 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class TaskDock(private val shell: Shell, private val onState: (open: Boolean, raised: Boolean) -> Unit) : FrameLayout(shell.activity) {
    private val activity = shell.activity
    private val store = shell.store
    private val theme = TaskTheme(activity)
    private val dimmer = View(activity).apply {
        setBackgroundColor(activity.getColor(R.color.token_bg_overlay))
        alpha = 0f
        isClickable = false
    }
    private val panel = FrameLayout(activity).apply {
        id = R.id.task_dock
        background = rounded(activity.getColor(R.color.token_bg_primary), activity.dpf(BAR_RADIUS_DP))
        clipToOutline = true
        elevation = activity.dpf(16f)
        isClickable = true
    }
    private val content = FrameLayout(activity)
    private val header = Header()
    private val details = Details()
    private val outside = View(activity).apply {
        visibility = GONE
        isClickable = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        setOnClickListener { details.toggle(false) }
    }
    private val slide = DesignSpring(this, PROGRESS, DesignMotion.springSpatial, 0.001f)
    private val touchSlop = ViewConfiguration.get(activity).scaledTouchSlop
    private var conversation: TaskConversation? = null
    private var chat: LiveChatScreen? = null
    private var chatLife: ChildLifecycle? = null
    private var taskId: String? = null
    private var safeTop = 0
    private var safeBottom = 0
    private var dismissing = false
    /** Whether the app is on screen; the Task's conversation keeps its stream only while it is, like the router's. */
    private var foreground = true
    private val back = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            if (details.open) details.toggle(false) else minimize()
        }
    }

    /** 0 minimized, 1 expanded; past 0 downwards while it leaves. */
    private var progress = 0f
        set(value) {
            field = value
            applyProgress()
        }

    val isOpen: Boolean get() = taskId != null

    init {
        visibility = GONE
        clipChildren = false
        addView(dimmer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        panel.addView(content, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        // The conversation fades out under the header, so the title and its buttons read over any message.
        val page = activity.getColor(R.color.token_bg_primary)
        panel.addView(View(activity).apply {
            background = android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(page, page, page, androidx.core.graphics.ColorUtils.setAlphaComponent(page, 0)))
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LayoutParams(LayoutParams.MATCH_PARENT, activity.dp(BAR_DP + 24), Gravity.TOP))
        // While the details card is open, a tap anywhere outside it closes it.
        panel.addView(outside, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        panel.addView(details, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.TOP))
        panel.addView(header, LayoutParams(LayoutParams.MATCH_PARENT, activity.dp(BAR_DP), Gravity.TOP))
        // The header stays over the details card that grows out of it.
        header.translationZ = activity.dpf(12f)
        addView(panel, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        dimmer.setOnClickListener { minimize() }
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            safeTop = bars.top
            safeBottom = bars.bottom
            requestLayout()
            insets
        }
        activity.onBackPressedDispatcher.addCallback(activity, back)
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { store.tasks.state.collect { header.render(); details.render() } }
                launch { store.pinned.collect { header.render() } }
            }
        }
    }

    /** Shows [id]: a new Task builds its conversation; the open one only rises. [raise] false leaves it minimized. */
    fun open(id: String, raise: Boolean = true) {
        // The same Task opened again while it slides away stays.
        dismissing = false
        if (taskId != id) {
            releaseChat()
            taskId = id
            details.reset()
            val opened = TaskConversation.open(activity, id, foreground)
            val life = ChildLifecycle(activity)
            val screen = LiveChatScreen(activity, opened.view, AuthGraph.get(activity).state, retrySession = { AuthGraph.get(activity).retry() },
                onOpenAccount = {}, owner = life, embedded = true)
            conversation = opened
            chatLife = life
            chat = screen
            content.removeAllViews()
            content.addView(screen.root, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            screen.setTopChrome(activity.dp(BAR_DP))
            screen.onOpenTaskCard = { taskId, _ -> store.openTask(taskId) }
            screen.bind()
            life.lifecycleScope.launch { opened.view.state.collect { if (details.open) details.render() } }
            life.lifecycleScope.launch { opened.worker.collect { details.render() } }
            header.render()
            details.render()
            activity.lifecycleScope.launch { details.load(id) }
        }
        if (visibility != VISIBLE) {
            visibility = VISIBLE
            // A Task opens raised, from below the screen.
            progress = if (raise) -0.4f else 0f
        }
        if (raise) expand() else minimize()
    }

    fun expand() {
        slide.animateTo(1f)
        back.isEnabled = true
        onState(true, true)
    }

    fun minimize() {
        details.toggle(false)
        chat?.dismissInput()
        slide.animateTo(0f)
        back.isEnabled = false
        onState(true, false)
    }

    /** The close button: the sheet slides away, then the Task is let go. */
    fun close() {
        if (taskId == null) return
        dismissing = true
        chat?.dismissInput()
        back.isEnabled = false
        slide.animateTo(-0.35f)
        onState(false, false)
    }

    /** The app came on screen or left it: the open Task's stream follows, as the router chat's does. */
    fun setForeground(visible: Boolean) {
        foreground = visible
        conversation?.view?.setForeground(visible)
    }

    /**
     * The open Task is gone from the store (sign-out, another account or Workspace): the dock lets it go at once,
     * without sliding, so nothing of the old scope stays on screen.
     */
    fun dismissNow() {
        if (taskId == null) return
        gone()
    }

    /** The activity ends: the Task's conversation and chat stop, without telling the shell or the store. */
    fun release() {
        dismissing = false
        back.isEnabled = false
        releaseChat()
        content.removeAllViews()
        taskId = null
    }

    private fun releaseChat() {
        chat?.release()
        chatLife?.destroy()
        conversation?.close()
        chat = null
        chatLife = null
        conversation = null
    }

    private fun gone() {
        dismissing = false
        back.isEnabled = false
        visibility = GONE
        releaseChat()
        content.removeAllViews()
        taskId = null
        store.closeTask()
        onState(false, false)
    }

    private fun sheetTop(): Float = (safeTop + activity.dp(SHEET_TOP_GAP_DP)).toFloat()
    private fun barTop(): Float = (height - activity.dp(BAR_DP) - safeBottom).toFloat()

    private fun applyProgress() {
        if (height == 0) return
        val p = progress
        val top = barTop() + (sheetTop() - barTop()) * p
        panel.translationY = top
        val clamped = p.coerceIn(0f, 1f)
        (panel.background as android.graphics.drawable.GradientDrawable).cornerRadius =
            activity.dpf(BAR_RADIUS_DP + (SHEET_RADIUS_DP - BAR_RADIUS_DP) * clamped)
        dimmer.alpha = 0.3f * clamped
        dimmer.isClickable = clamped > 0.5f
        content.alpha = ((p - 0.1f) / 0.4f).coerceIn(0f, 1f)
        // [gone] clears [dismissing]: the spring keeps moving the sheet below this line until it settles, but the
        // Task is let go only once.
        if (dismissing && p <= -0.3f) gone()
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        val height = (bottom - top) - sheetTop().toInt()
        if (panel.height != height) {
            panel.layoutParams.height = height
            panel.requestLayout()
        }
        applyProgress()
    }

    // MARK: Dragging the bar and the open sheet's header

    private var dragging = false
    private var downY = 0f
    private var startProgress = 0f
    private var velocity: VelocityTracker? = null

    private fun headerTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downY = event.rawY
                startProgress = progress
                dragging = false
                velocity?.recycle(); velocity = VelocityTracker.obtain()
            }
            MotionEvent.ACTION_MOVE -> {
                val dy = event.rawY - downY
                if (!dragging && abs(dy) > touchSlop) { dragging = true; slide.cancel(); header.parent.requestDisallowInterceptTouchEvent(true) }
                if (dragging) {
                    val travel = (barTop() - sheetTop()).coerceAtLeast(1f)
                    progress = (startProgress - dy / travel).coerceIn(-0.2f, 1.05f)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (dragging) {
                dragging = false
                velocity?.computeCurrentVelocity(1000)
                val v = velocity?.yVelocity ?: 0f
                val travel = (barTop() - sheetTop()).coerceAtLeast(1f)
                val up = if (abs(v) > activity.dp(600)) v < 0 else progress > 0.5f
                if (up) { slide.animateTo(1f, -v / travel); back.isEnabled = true; onState(true, true) }
                else { slide.animateTo(0f, -v / travel); back.isEnabled = false; onState(true, false); chat?.dismissInput() }
                return true
            }
        }
        velocity?.addMovement(event)
        return dragging
    }

    private fun task(): TaskSummary? = taskId?.let(store::task)

    /** Close, title and status, and the Task's actions. Tapping the title opens the details; minimized, it raises. */
    private inner class Header : FrameLayout(activity) {
        private val close = GlassIconButton(activity, R.drawable.ic_action_close, activity.getString(R.string.task_close))
        private val more = GlassIconButton(activity, R.drawable.ic_action_more, activity.getString(R.string.task_actions))
        private val title = activity.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium).apply { gravity = Gravity.CENTER }
        private val status = TaskStatusIconView(activity)
        private val statusText = activity.label(Level.MINI, R.color.token_text_quaternary, DesignFonts.medium)
        private val chevron = ImageView(activity).apply {
            setImageResource(R.drawable.ic_chevron_down_small)
            imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_placeholder))
        }
        private val titleBlock = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(title, LinearLayout.LayoutParams(-2, -2))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(status, LinearLayout.LayoutParams(activity.dp(11), activity.dp(11)))
                addView(statusText, LinearLayout.LayoutParams(-2, -2).apply { marginStart = activity.dp(4) })
                addView(chevron, LinearLayout.LayoutParams(activity.dp(14), activity.dp(14)).apply { marginStart = activity.dp(2) })
            }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = activity.dp(1) })
            isClickable = true
            isFocusable = true
            tactile(1.06f)
        }

        init {
            setPadding(activity.dp(16), 0, activity.dp(16), 0)
            addView(close, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.START))
            addView(titleBlock, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT).apply {
                marginStart = activity.dp(56); marginEnd = activity.dp(56)
            })
            addView(more, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL or Gravity.END))
            close.setOnClickListener { close() }
            titleBlock.setOnClickListener { if (progress < 0.5f) expand() else details.toggle(!details.open) }
            more.setOnClickListener { anchor ->
                val task = task() ?: return@setOnClickListener
                shell.actions.menu(task, archive = {
                    close()
                    store.setArchived(task, true) { archived ->
                        store.showToast(activity.getString(R.string.task_archived_toast), undo = { store.setArchived(archived, false) })
                    }
                }).show(anchor)
            }
            setOnTouchListener { _, event -> headerTouch(event) }
            titleBlock.setOnTouchListener { view, event ->
                if (headerTouch(event)) { view.isPressed = false; true } else false
            }
        }

        override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) headerTouch(event)
            else if (event.actionMasked == MotionEvent.ACTION_MOVE && headerTouch(event)) return true
            return false
        }

        fun render() {
            val task = task()
            title.text = task?.title?.ifBlank { null } ?: activity.getString(R.string.task_title_fallback)
            status.isVisible = task != null
            statusText.isVisible = task != null
            chevron.isVisible = task != null
            more.isVisible = task != null
            if (task != null) {
                val bucket = task.bucket.takeIf { it != TaskStatusBucket.ARCHIVED } ?: TaskStatusBucket.IN_PROGRESS
                status.setStatus(bucket, statusTint(activity, bucket))
                statusText.text = theme.statusLabel(bucket).let { label ->
                    if (task.host?.online == false) activity.getString(R.string.task_offline, label) else label
                }
            }
            titleBlock.contentDescription = listOfNotNull(title.text, statusText.text.takeIf { task != null }).joinToString(", ")
            titleBlock.stateDescription = activity.getString(R.string.task_toggle)
        }

        fun setChevronFlipped(open: Boolean) = chevron.animate().rotation(if (open) 180f else 0f)
            .setDuration(DesignMotion.durationMillis(DesignMotion.stateChange)).start()

        /**
         * On the open card, which is a surface already, the buttons give up their glass and sit on it as glyphs: no
         * glass on glass. Over the conversation they have it again.
         */
        fun setButtonsOnCard(onCard: Boolean) {
            listOf(close, more).forEach { button ->
                val drawable = button.background ?: return@forEach
                android.animation.ValueAnimator.ofInt(drawable.alpha, if (onCard) 0 else 255).apply {
                    duration = DesignMotion.durationMillis(200)
                    addUpdateListener { drawable.alpha = it.animatedValue as Int }
                    start()
                }
            }
        }

        /** The title and its status line as they rest, in this header's coordinates: where the card grows from. */
        fun titleBounds(into: android.graphics.RectF) {
            val status = statusText.parent as View
            val left = titleBlock.left + minOf(title.left, status.left)
            val right = titleBlock.left + maxOf(title.right, status.right)
            val top = titleBlock.top + title.top
            val bottom = titleBlock.top + (if (status.visibility == VISIBLE) status.bottom else title.bottom)
            into.set(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
        }
    }

    /** The open details card: the Task's properties and its labels. */
    private inner class Details : LinearLayout(activity) {
        var open = false
            private set
        private val properties = FlowLayout(activity, activity.dp(6))
        private val workerCaption = caption(R.string.task_details_worker)
        private val machineCaption = caption(R.string.task_details_machine)
        private val machine = FlowLayout(activity, activity.dp(6))
        private val worker = FlowLayout(activity, activity.dp(6))
        private val labels = FlowLayout(activity, activity.dp(6))
        private var catalog: List<TaskLabel>? = null
        private var busy = false
        /** The label change [busy] waits for; an older change's answer or timeout leaves a newer one waiting. */
        private var busyRequest = 0

        /** How far the card has grown across (0, the title capsule's width; 1, the sheet's) and down. */
        private var wide = 0f
            set(value) { field = value; place() }
        private var tall = 0f
            set(value) { field = value; place() }
        private val wideMotion = androidx.dynamicanimation.animation.SpringAnimation(this, WIDE)
        private val tallMotion = androidx.dynamicanimation.animation.SpringAnimation(this, TALL)
        private val surface = android.graphics.drawable.GradientDrawable()
        private val shape = android.graphics.RectF()
        private val closed = android.graphics.RectF()
        private val glassColor = activity.getColor(R.color.token_glass_over_page)
        private val cardColor = activity.getColor(R.color.token_card_primary)
        private var fade: android.animation.ValueAnimator? = null

        init {
            orientation = VERTICAL
            // The card sits 8dp in from the sheet's edges; its rows start under the header row.
            setPadding(activity.dp(28), activity.dp(BAR_DP + 6), activity.dp(28), activity.dp(28))
            setWillNotDraw(false)
            surface.setStroke(1, activity.getColor(R.color.token_glass_border))
            outlineAmbientShadowColor = activity.getColor(R.color.token_composer_shadow_ambient)
            outlineSpotShadowColor = activity.getColor(R.color.token_composer_shadow_spot)
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setRoundRect(shape.left.toInt(), shape.top.toInt(), shape.right.toInt(), shape.bottom.toInt(), radius())
                }
            }
            // The rows show only inside the growing surface.
            clipToOutline = true
            listOf(wideMotion, tallMotion).forEach {
                it.spring = androidx.dynamicanimation.animation.SpringForce(0f).setDampingRatio(1f)
                // A 0-to-1 progress: the default pixel threshold would call it finished at once.
                it.setMinimumVisibleChange(androidx.dynamicanimation.animation.DynamicAnimation.MIN_VISIBLE_CHANGE_SCALE)
            }
            tallMotion.addEndListener { _, canceled, _, _ ->
                // Closing narrows and lifts fully opaque; only then do the rows fade.
                if (!canceled && !open) fadeContent(0f, 120)
            }
            addView(caption(R.string.task_details_properties))
            addView(properties, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) })
            addView(workerCaption, LayoutParams(-2, -2).apply { topMargin = activity.dp(18) })
            addView(worker, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) })
            addView(machineCaption, LayoutParams(-2, -2).apply { topMargin = activity.dp(18) })
            addView(machine, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) })
            addView(caption(R.string.task_details_labels), LayoutParams(-2, -2).apply { topMargin = activity.dp(18) })
            addView(labels, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) })
            setContentAlpha(0f)
        }

        var wideValue: Float
            get() = wide
            set(value) { wide = value }
        var tallValue: Float
            get() = tall
            set(value) { tall = value }

        private fun radius(): Float = minOf(activity.dpf(30f), shape.height() / 2f)

        /** The card between the title capsule and the full card, each axis on its own spring. */
        private fun place() {
            header.titleBounds(closed)
            if (closed.isEmpty) closed.set(activity.dpf(8f), activity.dpf(8f), width - activity.dpf(8f), activity.dpf(BAR_DP - 8f))
            closed.inset(-activity.dpf(14f), -activity.dpf(5f))
            val inset = activity.dpf(8f)
            val openBottom = maxOf(height.toFloat(), activity.dpf(BAR_DP.toFloat()))
            shape.set(
                closed.left + (inset - closed.left) * wide, closed.top + (inset - closed.top) * tall,
                closed.right + (width - inset - closed.right) * wide, closed.bottom + (openBottom - closed.bottom) * tall,
            )
            val grown = maxOf(wide, tall).coerceIn(0f, 1f)
            surface.setColor(androidx.core.graphics.ColorUtils.blendARGB(glassColor, cardColor, grown))
            elevation = activity.dpf(2f + 10f * grown)
            invalidateOutline()
            invalidate()
        }

        override fun onDraw(canvas: android.graphics.Canvas) {
            if (taskId == null) return
            surface.cornerRadius = radius()
            surface.setBounds(shape.left.toInt(), shape.top.toInt(), shape.right.toInt(), shape.bottom.toInt())
            surface.draw(canvas)
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            super.onLayout(changed, l, t, r, b)
            post { place() }
        }

        /** Closed, the card is only the title's capsule under the header, which takes the touches. */
        override fun dispatchTouchEvent(event: MotionEvent): Boolean = open && super.dispatchTouchEvent(event)

        private fun setContentAlpha(value: Float) {
            for (i in 0 until childCount) getChildAt(i).alpha = value
        }

        private fun fadeContent(to: Float, ms: Long) {
            fade?.cancel()
            val from = if (childCount > 0) getChildAt(0).alpha else 0f
            fade = android.animation.ValueAnimator.ofFloat(from, to).apply {
                duration = DesignMotion.durationMillis(ms)
                interpolator = DesignMotion.smoothOut
                addUpdateListener { setContentAlpha(it.animatedValue as Float) }
                start()
            }
        }

        private fun axis(motion: androidx.dynamicanimation.animation.SpringAnimation, target: Float, stiffness: Float) {
            if (!android.animation.ValueAnimator.areAnimatorsEnabled()) {
                motion.cancel()
                if (motion === wideMotion) wide = target else tall = target
                return
            }
            motion.spring.stiffness = stiffness
            motion.animateToFinalPosition(target)
        }

        private fun caption(text: Int) = activity.label(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply { setText(text) }

        fun reset() {
            shown = null
            catalog = null
            busy = false
            busyRequest++
            open = false
            wideMotion.cancel(); tallMotion.cancel()
            wide = 0f; tall = 0f
            setContentAlpha(0f)
            outside.visibility = GONE
            header.setChevronFlipped(false)
            header.setButtonsOnCard(false)
        }

        suspend fun load(id: String) {
            try {
                val next = store.call { labelCatalog(it) }
                if (taskId == id) { catalog = next.labels; render() }
            } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) {}
        }

        fun toggle(show: Boolean) {
            if (show == open) return
            open = show
            header.setChevronFlipped(show)
            header.setButtonsOnCard(show)
            outside.visibility = if (show) VISIBLE else GONE
            if (show) {
                render()
                // Opening, the card drops down first and widens behind it; the rows come in with the growth.
                axis(tallMotion, 1f, LEADING_STIFFNESS)
                axis(wideMotion, 1f, TRAILING_STIFFNESS)
                fadeContent(1f, 160)
            } else {
                // Closing, it narrows first and lifts behind it.
                axis(wideMotion, 0f, LEADING_STIFFNESS)
                axis(tallMotion, 0f, TRAILING_STIFFNESS)
            }
        }

        /** What the card last drew; a stream update that changes none of it leaves the views alone. */
        private var shown: Any? = null

        fun render() {
            val task = task() ?: return
            val key = listOf(task, catalog, busy, open, conversation?.worker?.value)
            if (key == shown) return
            shown = key
            properties.removeAllViews()
            val bucket = task.bucket.takeIf { it != TaskStatusBucket.ARCHIVED } ?: TaskStatusBucket.IN_PROGRESS
            properties.addView(pill(TaskStatusIconView(activity).apply { setStatus(bucket, statusTint(activity, bucket), spin = open) },
                theme.statusLabel(bucket), chevron = task.canSetStatus).apply {
                if (task.canSetStatus) {
                    stateDescription = activity.getString(R.string.task_details_change_status)
                    setOnClickListener { statusMenu(it, task, bucket) }
                }
            })
            originName(activity, task.origin)?.let { name ->
                properties.addView(pill(ImageView(activity).apply { setImageDrawable(ProviderMarks.drawable(activity, task.origin)) }, name))
            }
            if (task.origin == "comma" && task.clientPlatform != null) {
                properties.addView(pill(ImageView(activity).apply {
                    setImageResource(R.drawable.ic_filter_device)
                    imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_quaternary))
                }, deviceName(activity, task.clientPlatform)))
            }
            worker.removeAllViews()
            val bound = conversation?.worker?.value
            workerCaption.isVisible = bound != null
            worker.isVisible = bound != null
            if (bound != null) {
                val name = bound.name.ifEmpty { activity.getString(R.string.task_details_worker) }
                worker.addView(pill(workerAvatar(bound.vendor, name), name, chevron = true, forward = true).apply {
                    stateDescription = activity.getString(R.string.task_details_worker_steps)
                    setOnClickListener { WorkerHistorySheet(activity, store, task.id, bound).show() }
                })
            }
            // Where a Task a station hosts runs: the machine, and whether it is reached.
            val host = task.host
            machine.removeAllViews()
            machineCaption.isVisible = host != null
            machine.isVisible = host != null
            if (host != null) {
                val name = host.machine ?: activity.getString(R.string.task_machine_fallback)
                machine.addView(pill(ImageView(activity).apply {
                    setImageResource(R.drawable.ic_filter_device)
                    imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_quaternary))
                }, if (host.online == false) activity.getString(R.string.task_offline, name) else name))
            }
            labels.removeAllViews()
            val known = catalog
            val applied = known.orEmpty().filter { it.id in task.labelIds }
            applied.forEach { label ->
                labels.addView(pill(ImageView(activity).apply {
                    setImageDrawable(LabelDot(DesignLabelColors.resolve(activity, label.color), activity.dp(18), activity.dp(8)))
                }, label.name).apply { if (known != null) setOnClickListener { labelMenu(it, task, known) } })
            }
            if (known != null && known.isEmpty() && applied.isEmpty()) {
                labels.addView(activity.label(Level.SMALL, R.color.token_text_quaternary).apply {
                    setText(R.string.task_details_no_labels)
                    minHeight = activity.dp(32); gravity = Gravity.CENTER_VERTICAL
                })
            }
            if (known == null) labels.addView(android.widget.ProgressBar(activity), LayoutParams(activity.dp(20), activity.dp(20)))
            else labels.addView(ImageView(activity).apply {
                setImageResource(R.drawable.ic_plus_small)
                imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_quaternary))
                setPadding(activity.dp(6), activity.dp(6), activity.dp(6), activity.dp(6))
                contentDescription = activity.getString(R.string.task_details_add_label)
                alpha = if (busy) 0.4f else 1f
                setOnClickListener { labelMenu(it, task, known) }
            }, LayoutParams(activity.dp(32), activity.dp(32)))
        }

        private fun statusMenu(anchor: View, task: TaskSummary, bucket: TaskStatusBucket) {
            ActionMenu(activity)
                .item(theme.statusLabel(bucket), checked = true, enabled = false) {}
                .divider()
                .item(theme.statusLabel(TaskStatusBucket.DONE), R.drawable.ic_task_done) { conversation?.view?.let { store.setStatus(task, "completed", it) } }
                .item(theme.statusLabel(TaskStatusBucket.CANCELLED), R.drawable.ic_task_cancelled, destructive = true) {
                    conversation?.view?.let { store.setStatus(task, "cancelled", it) }
                }
                .show(anchor)
        }

        /** Each label with its dot, checked while it is on the Task, then Manage labels. */
        private fun labelMenu(anchor: View, task: TaskSummary, catalog: List<TaskLabel>) {
            if (busy) return
            val menu = ActionMenu(activity)
            catalog.forEach { label ->
                val on = label.id in task.labelIds
                menu.item(label.name, checked = on, iconDrawable = LabelDot(DesignLabelColors.resolve(activity, label.color),
                    activity.dp(20), activity.dp(10))) {
                    val current = task.labelIds.filter { id -> catalog.any { it.id == id } }
                    val request = ++busyRequest
                    val settle = { if (busy && request == busyRequest) { busy = false; render() } }
                    busy = true
                    render()
                    store.setLabels(task, if (on) current - label.id else current + label.id) { settle() }
                    postDelayed({ settle() }, 4_000)
                }
            }
            menu.divider().item(activity.getString(R.string.task_details_manage_labels), R.drawable.ic_filter_label) {
                TaskLabelsSheet(activity) { activity.lifecycleScope.launch { taskId?.let { load(it) } } }.show()
            }
            menu.show(anchor)
        }

        /** The desktop task panel's pill: a hairline capsule around a glyph and a label. */
        /**
         * A Worker as the logo of its model's maker on a plain disc, as on the desktop: Comma's mark for Comma's own
         * model, the Worker's initial while the maker is not known.
         */
        private fun workerAvatar(vendor: String?, name: String): View {
            val disc = rounded(activity.getColor(R.color.token_bg_primary), activity.dpf(9f),
                activity.getColor(R.color.token_border_primary), maxOf(1, activity.dp(1) / 2))
            val logo = ModelLogos.drawable(activity, vendor)
                ?: return activity.label(Level.MICRO, R.color.token_text_primary, DesignFonts.semibold).apply {
                    text = name.take(1).uppercase()
                    gravity = Gravity.CENTER
                    background = disc
                }
            return ImageView(activity).apply {
                setImageDrawable(logo)
                scaleType = ImageView.ScaleType.FIT_CENTER
                // The logo fills 85% of the disc, the desktop's size.
                val inset = activity.dpf(1.35f).toInt().coerceAtLeast(1)
                setPadding(inset, inset, inset, inset)
                background = disc
            }
        }

        private fun pill(glyph: View, text: String, chevron: Boolean = false, forward: Boolean = false): LinearLayout = LinearLayout(activity).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = activity.dp(32)
            setPadding(activity.dp(10), 0, activity.dp(if (chevron) 8 else 12), 0)
            background = rounded(0, activity.dpf(16f), activity.getColor(R.color.token_border_primary), maxOf(1, activity.dp(1)))
            addView(glyph, LayoutParams(activity.dp(18), activity.dp(18)))
            addView(activity.label(Level.SMALL, R.color.token_text_primary, DesignFonts.medium).apply { this.text = text },
                LayoutParams(-2, -2).apply { marginStart = activity.dp(6) })
            if (chevron) addView(ImageView(activity).apply {
                setImageResource(if (forward) R.drawable.ic_settings_chevron else R.drawable.ic_chevron_down_small)
                imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_placeholder))
            }, LayoutParams(activity.dp(16), activity.dp(16)).apply { marginStart = activity.dp(2) })
        }
    }

    companion object {
        const val BAR_DP = 60
        const val BAR_RADIUS_DP = 22f
        const val SHEET_RADIUS_DP = 32f
        const val SHEET_TOP_GAP_DP = 10
        /** Room the minimized bar takes at the foot of the app, with the gap above it. */
        fun reserve(context: android.content.Context, safeBottom: Int) = context.dp(BAR_DP + 6) + safeBottom

        /** The iOS card's two axes: response 0.25 s and 0.38 s, critically damped. */
        private const val LEADING_STIFFNESS = 632f
        private const val TRAILING_STIFFNESS = 273f

        private val WIDE = object : FloatPropertyCompat<View>("wide") {
            override fun getValue(view: View) = (view as TaskDock.Details).wideValue
            override fun setValue(view: View, value: Float) { (view as TaskDock.Details).wideValue = value }
        }
        private val TALL = object : FloatPropertyCompat<View>("tall") {
            override fun getValue(view: View) = (view as TaskDock.Details).tallValue
            override fun setValue(view: View, value: Float) { (view as TaskDock.Details).tallValue = value }
        }

        private val PROGRESS = object : FloatPropertyCompat<TaskDock>("progress") {
            override fun getValue(dock: TaskDock) = dock.progress
            override fun setValue(dock: TaskDock, value: Float) { dock.progress = value }
        }
    }
}
