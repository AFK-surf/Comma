package surf.comma.android.shell

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.settings.AvatarSource
import surf.comma.android.settings.AvatarView
import surf.comma.android.ui.kit.AttentionDot
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.glyph
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.selectionTick
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.widget.GlassShape
import surf.comma.android.ui.widget.LiquidGlass

/** The app's tabs, in tab-bar order. */
enum class AppTab { HOME, INBOX, APPS, SETTINGS }

/**
 * The floating tab bar, as the iOS app draws it: one glass capsule holding Home, Inbox, Apps and the member's
 * avatar for Settings, glyphs only, with the selected tab on a grey pill that glides between them, and
 * beside it its own glass circle with Comma's mark, which opens the router chat. Inbox carries a dot while a row
 * it shows is unread and Settings while something there needs the member; the circle counts router replies not
 * yet seen and breathes while Comma is replying. Selecting the selected tab again asks it to go back to its top.
 */
class ShellTabBar(context: Context) : FrameLayout(context) {
    var onSelect: ((AppTab) -> Unit)? = null
    var onRouter: (() -> Unit)? = null
    /** Sees every touch that came down on the capsule, for the glass under it: that glass presses as the capsule. */
    var onGlassTouch: ((android.view.MotionEvent) -> Unit)? = null

    private val capsule = FrameLayout(context).apply { glass(fill = R.color.token_glass_frosted, lens = true) }
    private val pill = View(context).apply {
        background = rounded(context.getColor(R.color.token_glass_selection), context.dp(PILL_DP / 2).toFloat())
    }
    private val pillX = DesignSpring(pill, DynamicAnimation.TRANSLATION_X, DesignMotion.springSpatial)
    private val home = item(R.drawable.ic_tab_home, R.string.shell_tab_home, R.id.tab_home)
    private val inbox = item(R.drawable.ic_tab_inbox, R.string.shell_tab_inbox, R.id.tab_inbox)
    private val apps = item(R.drawable.ic_tab_apps, R.string.shell_tab_apps, R.id.tab_apps)
    private val settings = FrameLayout(context).apply {
        id = R.id.tab_settings
        contentDescription = context.getString(R.string.shell_tab_settings)
        isClickable = true
        isFocusable = true
    }
    private val avatar = AvatarView(context)
    private val inboxDot = AttentionDot(context).apply { isVisible = false }
    private val settingsDot = AttentionDot(context).apply { isVisible = false }
    private val router = FrameLayout(context).apply {
        id = R.id.tab_router
        contentDescription = context.getString(R.string.shell_router)
        isClickable = true
        isFocusable = true
        glass(fill = R.color.token_glass_frosted, lens = true)
    }
    private val mark = context.glyph(R.drawable.ic_cue_mark, R.color.token_text_primary)
    private val badge = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.MICRO, DesignFonts.semibold)
        setTextColor(android.graphics.Color.WHITE)
        includeFontPadding = false
        gravity = Gravity.CENTER
        minWidth = context.dp(18)
        setPadding(context.dp(5), 0, context.dp(5), 0)
        background = rounded(context.getColor(R.color.token_bg_brand_solid), context.dp(9).toFloat())
        isVisible = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    /** The clear glass the indicator lifts into under a finger; only with the experimental glass, as it compiles a shader. */
    private val lens = if (LiquidGlass.enabled) TabBarLens(context, ::recordUnderLens) else null
    /** The tab the finger is over while the indicator is lifted. */
    private var hovered = -1
    /** The finger has left the tab it came down on: letting go on the selected tab only puts the indicator back. */
    private var wandered = false
    private var touchOnCapsule = false
    /** How far the lens stays from the finger: where it was grabbed, if it was. */
    private var grab = 0f
    private var fingerX = 0f
    private val pillWidth = DesignSpring(pill, DynamicAnimation.SCALE_X, PILL_LANDING)
    private val settle = Runnable {
        val edge = context.dp(TAB_EDGE_DP)
        val rest = lensRest(fingerX + grab - edge, itemWidth, items.size) + edge
        lens?.moveTo(lensTravel(if (rest == tabCenter(tabUnder(rest))) lensCenter(tabUnder(rest)) else rest))
    }
    private val capsuleFill = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = context.getColor(R.color.token_glass_lens_bar)
        // The bar's shadow on the page, which the lens bends in as the ring round the bar's outline.
        setShadowLayer(context.dp(LENS_SHADOW_DP).toFloat(), 0f, -context.dp(2).toFloat(), context.getColor(R.color.token_glass_lens_band))
    }
    /** Draws what the page shows under this bar, in the bar's coordinates. */
    var backdrop: ((android.graphics.Canvas) -> Unit)? = null
    private var breathing: ObjectAnimator? = null
    private var selected = AppTab.HOME
    private val items get() = listOf(home, inbox, apps, settings)

    init {
        clipChildren = false
        clipToPadding = false
        capsule.clipChildren = false
        capsule.addView(pill, LayoutParams(0, context.dp(PILL_DP), Gravity.CENTER_VERTICAL))
        items.forEach { capsule.addView(it, LayoutParams(0, LayoutParams.MATCH_PARENT)) }
        settings.addView(avatar, LayoutParams(context.dp(28), context.dp(28), Gravity.CENTER))
        // Each dot on its glyph's top-trailing corner, just clear of a 26dp glyph and the 28dp avatar.
        listOf(inbox to inboxDot, settings to settingsDot).forEach { (item, dot) ->
            item.addView(dot, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
            dot.translationX = context.dp(13).toFloat()
            dot.translationY = -context.dp(13).toFloat()
        }
        addView(capsule, LayoutParams(0, context.dp(HEIGHT_DP)))
        router.addView(mark, LayoutParams(context.dp(26), context.dp(26), Gravity.CENTER))
        router.addView(badge, LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(18), Gravity.TOP or Gravity.END).apply {
            topMargin = context.dp(4); marginEnd = context.dp(4)
        })
        addView(router, LayoutParams(context.dp(HEIGHT_DP), context.dp(HEIGHT_DP)))
        lens?.let { lens ->
            addView(lens, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            lens.onLift = { lift ->
                val scale = 1f + LENS_BAR_SCALE * lift
                capsule.scaleX = scale
                capsule.scaleY = scale
                pill.alpha = (1f - (lift / TabBarLens.FADE_SHARE).coerceAtMost(1f)) * PILL_LANDED_ALPHA
            }
            lens.onMoved = { center -> pill.translationX = center - pill.width / 2f }
            lens.onLanding = {
                pillWidth.cancel()
                pill.scaleX = PILL_LANDING_WIDTH
                pillWidth.animateTo(1f)
            }
            lens.onLanded = {
                pill.translationX = pillTarget()
                pill.animate().alpha(1f).setDuration(PILL_FADE_MS).setInterpolator(DesignMotion.smoothOut).start()
            }
        }
        home.setOnClickListener { choose(AppTab.HOME) }
        inbox.setOnClickListener { choose(AppTab.INBOX) }
        apps.setOnClickListener { choose(AppTab.APPS) }
        settings.setOnClickListener { choose(AppTab.SETTINGS) }
        router.setOnClickListener { it.selectionTick(); onRouter?.invoke() }
        settings.tactile(0.9f)
        router.tactile(0.92f)
        applySelection(animate = false)
    }

    override fun dispatchTouchEvent(event: android.view.MotionEvent): Boolean {
        if (event.actionMasked == android.view.MotionEvent.ACTION_DOWN) touchOnCapsule = event.x < capsule.right
        if (touchOnCapsule) onGlassTouch?.invoke(event)
        return super.dispatchTouchEvent(event)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val circle = context.dp(HEIGHT_DP)
        val capsuleWidth = width - circle - context.dp(GAP_DP)
        (capsule.layoutParams as LayoutParams).width = capsuleWidth
        val edge = context.dp(TAB_EDGE_DP)
        val itemWidth = (capsuleWidth - edge * 2) / items.size
        items.forEachIndexed { index, view ->
            (view.layoutParams as LayoutParams).apply { this.width = itemWidth; leftMargin = edge + index * itemWidth }
        }
        (pill.layoutParams as LayoutParams).width = pillWidthFor(itemWidth)
        (router.layoutParams as LayoutParams).leftMargin = capsuleWidth + context.dp(GAP_DP)
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(circle, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        if (changed) {
            applySelection(animate = false)
            val liftedHeight = context.dp(HEIGHT_DP) * TabBarLens.LIFTED_HEIGHT_RATIO
            lens?.barLeft = capsule.left.toFloat()
            lens?.barRight = capsule.right.toFloat()
            lens?.setSizes(pillWidthFor(itemWidth).toFloat(), context.dp(PILL_DP).toFloat(),
                lensLiftedWidth(liftedHeight, itemWidth.toFloat()), liftedHeight)
        }
    }

    // MARK: Dragging the indicator

    /** With the glass the capsule takes every touch on it as one gesture: a tap is a drag that does not go anywhere. */
    override fun onInterceptTouchEvent(event: android.view.MotionEvent): Boolean =
        LiquidGlass.enabled && event.actionMasked == android.view.MotionEvent.ACTION_DOWN && event.x < capsule.right

    @android.annotation.SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        if (!LiquidGlass.enabled) return super.onTouchEvent(event)
        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                pill.animate().cancel()
                hovered = index(selected)
                wandered = false
                val from = lensCenter(hovered)
                grab = if (tabUnder(event.x) == hovered) from - event.x else 0f
                lens?.lift(lensTravel(from))
                follow(event.x)
            }
            android.view.MotionEvent.ACTION_MOVE -> follow(event.x)
            android.view.MotionEvent.ACTION_UP -> release(tabUnder(event.x))
            android.view.MotionEvent.ACTION_CANCEL -> land(index(selected))
        }
        return true
    }

    private val itemWidth get() = (capsule.width - context.dp(TAB_EDGE_DP) * 2) / items.size

    private fun tabUnder(x: Float) = tabAt(x - context.dp(TAB_EDGE_DP), itemWidth, items.size)

    private fun tabCenter(index: Int) = context.dp(TAB_EDGE_DP) + (index + 0.5f) * itemWidth

    /** Where the lens rests on the tab at [index]: on an end tab, a little past it. */
    private fun lensCenter(index: Int): Float = when (index) {
        0 -> tabCenter(index) - context.dp(LENS_PAST_END_DP)
        items.lastIndex -> tabCenter(index) + context.dp(LENS_PAST_END_DP)
        else -> tabCenter(index)
    }

    /** The lens rests a little past the end tabs, hanging over the ends of the bar as the bar grows to meet it, and goes no further. */
    private fun lensTravel(x: Float): Float {
        val past = context.dp(LENS_PAST_END_DP)
        return x.coerceIn(tabCenter(0) - past, tabCenter(items.lastIndex) + past)
    }

    private fun follow(x: Float) {
        fingerX = x
        lens?.moveTo(lensTravel(x + grab))
        removeCallbacks(settle)
        postDelayed(settle, LENS_SETTLE_MS)
        val under = tabUnder(x)
        if (under != hovered) {
            hovered = under
            wandered = true
            items[under].selectionTick()
        }
    }

    /** A finger let go: only a tab it chose counts, as selecting the selected tab again asks that tab to go back to its top. */
    private fun release(index: Int) {
        land(index)
        if (!wandered || index != index(selected)) onSelect?.invoke(AppTab.entries.first { index(it) == index })
    }

    private fun land(index: Int) {
        removeCallbacks(settle)
        lens?.drop(tabCenter(index))
    }

    private fun recordUnderLens(canvas: android.graphics.Canvas) {
        backdrop?.invoke(canvas)
        val radius = capsule.height / 2f
        canvas.save()
        canvas.scale(capsule.scaleX, capsule.scaleY, capsule.left + capsule.width / 2f, capsule.top + capsule.height / 2f)
        canvas.drawRoundRect(capsule.left.toFloat(), capsule.top.toFloat(), capsule.right.toFloat(), capsule.bottom.toFloat(), radius, radius, capsuleFill)
        canvas.translate(capsule.left.toFloat(), capsule.top.toFloat())
        capsule.draw(canvas)
        canvas.restore()
    }

    private fun choose(tab: AppTab) {
        if (tab != selected) items[index(tab)].selectionTick()
        onSelect?.invoke(tab)
    }

    fun select(tab: AppTab) {
        if (tab == selected) return
        selected = tab
        applySelection(animate = true)
    }

    private fun applySelection(animate: Boolean) {
        home.icon.setImageResource(if (selected == AppTab.HOME) R.drawable.ic_tab_home_fill else R.drawable.ic_tab_home)
        inbox.icon.setImageResource(if (selected == AppTab.INBOX) R.drawable.ic_tab_inbox_fill else R.drawable.ic_tab_inbox)
        items.forEach { it.isSelected = false }
        items[index(selected)].isSelected = true
        val itemWidth = barItemWidth()
        // While the lens is up the indicator rides inside it, and lands with it.
        if (lens?.isVisible == true) return
        val target = pillTarget()
        if (animate && itemWidth > 0) pillX.animateTo(target) else { pillX.cancel(); pill.translationX = target }
    }

    /** The tab's width before the capsule has been laid out, too, as the indicator is placed then. */
    private fun barItemWidth() = ((capsule.layoutParams as LayoutParams).width - context.dp(TAB_EDGE_DP) * 2) / items.size

    /** As on iOS the chosen tab's indicator is as wide as it can be: past its own tab, up to the inset at the bar's ends. */
    private fun pillWidthFor(itemWidth: Int) = itemWidth + (context.dp(TAB_EDGE_DP) - context.dp(PILL_INSET_DP)) * 2

    private fun pillTarget(): Float =
        (context.dp(PILL_INSET_DP) + index(selected) * barItemWidth()).toFloat()

    private fun index(tab: AppTab) = when (tab) {
        AppTab.HOME -> 0
        AppTab.INBOX -> 1
        AppTab.APPS -> 2
        AppTab.SETTINGS -> 3
    }

    fun setAvatar(source: AvatarSource, name: String, generation: Long?) = avatar.show(source, name, generation)

    fun setInboxUnread(unread: Boolean) {
        inboxDot.isVisible = unread
        inbox.stateDescription = if (unread) context.getString(R.string.shell_unread) else null
    }

    fun setSettingsAttention(attention: Boolean) {
        settingsDot.isVisible = attention
        settings.stateDescription = if (attention) context.getString(R.string.shell_needs_attention) else null
    }

    /** Router replies not yet seen while the chat is closed, and whether Comma is replying now. */
    fun setRouter(unread: Int, replying: Boolean) {
        badge.isVisible = unread > 0
        badge.text = if (unread > 99) "99+" else unread.toString()
        router.stateDescription = when {
            replying -> context.getString(R.string.shell_router_thinking)
            unread > 0 -> context.getString(R.string.shell_router_unread, unread)
            else -> null
        }
        if (replying && breathing == null && ValueAnimator.areAnimatorsEnabled()) {
            breathing = ObjectAnimator.ofFloat(mark, View.ALPHA, 1f, 0.35f).apply {
                duration = BREATH_MS
                repeatMode = ValueAnimator.REVERSE
                repeatCount = ValueAnimator.INFINITE
                interpolator = DesignMotion.softInOut
                start()
            }
        } else if (!replying) {
            stopBreathing()
        }
    }

    private fun stopBreathing() {
        breathing?.cancel()
        breathing = null
        mark.alpha = 1f
    }

    /** An infinite animator holds the bar until cancelled; a bar taken off screen lets it go. */
    override fun onDetachedFromWindow() {
        stopBreathing()
        super.onDetachedFromWindow()
    }

    /** The capsule and the circle in this bar's coordinates, with their corner radii: what the page frosts under them. */
    fun frostShapes(): List<GlassShape> = listOf(
        GlassShape(android.graphics.Rect(capsule.left, capsule.top, capsule.right, capsule.bottom), capsule.height / 2f),
        GlassShape(android.graphics.Rect(router.left, router.top, router.right, router.bottom), router.height / 2f),
    )

    /** The router circle on screen, where the router chat zooms out of and back into. */
    fun routerBounds(into: IntArray): Pair<Int, Int> {
        router.getLocationInWindow(into)
        return router.width to router.height
    }

    private fun item(icon: Int, label: Int, id: Int) = TabItem(context, icon).apply {
        this.id = id
        contentDescription = context.getString(label)
    }

    private class TabItem(context: Context, icon: Int) : FrameLayout(context) {
        val icon: ImageView = context.glyph(icon, R.color.token_text_primary)

        init {
            isClickable = true
            isFocusable = true
            addView(this.icon, LayoutParams(context.dp(26), context.dp(26), Gravity.CENTER))
            tactile(0.88f, this.icon)
        }
    }

    companion object {
        const val HEIGHT_DP = 60
        const val GAP_DP = 10
        const val PILL_DP = 52
        const val PILL_INSET_DP = 4
        /** How far in from the capsule's ends the tabs start. */
        const val TAB_EDGE_DP = 8
        const val BREATH_MS = 900L
        /** The indicator comes down this narrow and springs out to its width. */
        private const val PILL_LANDING_WIDTH = 0.86f
        /** It comes down part way faded and finishes fading in after the lens has gone, about 350 ms after the release. */
        private const val PILL_LANDED_ALPHA = 0.6f
        private const val PILL_FADE_MS = 130L
        /** Finishes about 350 ms after the release, well after the lens has gone. */
        private val PILL_LANDING = DesignMotion.SpringToken(160f, 0.85f)
        /**
         * How much larger the whole capsule goes while the indicator is lifted: enough to all but touch the circle,
         * which it joins by a narrow pinch.
         */
        const val LENS_BAR_SCALE = 0.05f
        const val LENS_BLEND_DP = 9f
        private const val LENS_SETTLE_MS = 120L
        private const val LENS_PAST_END_DP = 6
        private const val LENS_SHADOW_DP = 9
        /** How much whiter the capsule goes then: a lot on a light page, hardly at all on a dark one. */
        const val LENS_VEIL = 0.75f
        const val LENS_VEIL_DARK = 0.07f
    }
}
