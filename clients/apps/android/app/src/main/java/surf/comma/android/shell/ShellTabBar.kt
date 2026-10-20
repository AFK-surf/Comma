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

/** The app's tabs, in tab-bar order. Search sits between Inbox and Settings but opens over the tabs. */
enum class AppTab { HOME, INBOX, SETTINGS }

/**
 * The floating tab bar, as the iOS app draws it: one glass capsule holding Home, Inbox, task search and the
 * member's avatar for Settings, glyphs only, with the selected tab on a grey pill that glides between them, and
 * beside it its own glass circle with Comma's mark, which opens the router chat. Inbox carries a dot while a row
 * it shows is unread and Settings while something there needs the member; the circle counts router replies not
 * yet seen and breathes while Comma is replying. Selecting the selected tab again asks it to go back to its top.
 */
class ShellTabBar(context: Context) : FrameLayout(context) {
    var onSelect: ((AppTab) -> Unit)? = null
    var onSearch: (() -> Unit)? = null
    var onRouter: (() -> Unit)? = null

    private val capsule = FrameLayout(context).apply { glass(fill = R.color.token_glass_frosted) }
    private val pill = View(context).apply {
        background = rounded(context.getColor(R.color.token_glass_selection), context.dp(PILL_DP / 2).toFloat())
    }
    private val pillX = DesignSpring(pill, DynamicAnimation.TRANSLATION_X, DesignMotion.springSpatial)
    private val home = item(R.drawable.ic_tab_home, R.string.shell_tab_home, R.id.tab_home)
    private val inbox = item(R.drawable.ic_tab_inbox, R.string.shell_tab_inbox, R.id.tab_inbox)
    private val search = item(R.drawable.ic_tab_search, R.string.shell_tab_search, R.id.tab_search)
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
        glass(fill = R.color.token_glass_frosted)
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
    private var breathing: ObjectAnimator? = null
    private var selected = AppTab.HOME
    private val items get() = listOf(home, inbox, search, settings)

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
        home.setOnClickListener { choose(AppTab.HOME) }
        inbox.setOnClickListener { choose(AppTab.INBOX) }
        settings.setOnClickListener { choose(AppTab.SETTINGS) }
        search.setOnClickListener { it.selectionTick(); onSearch?.invoke() }
        router.setOnClickListener { it.selectionTick(); onRouter?.invoke() }
        settings.tactile(0.9f)
        router.tactile(0.92f)
        applySelection(animate = false)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val circle = context.dp(HEIGHT_DP)
        val capsuleWidth = width - circle - context.dp(GAP_DP)
        (capsule.layoutParams as LayoutParams).width = capsuleWidth
        val itemWidth = capsuleWidth / items.size
        items.forEachIndexed { index, view ->
            (view.layoutParams as LayoutParams).apply { this.width = itemWidth; leftMargin = index * itemWidth }
        }
        (pill.layoutParams as LayoutParams).width = itemWidth - context.dp(PILL_INSET_DP * 2)
        (router.layoutParams as LayoutParams).leftMargin = capsuleWidth + context.dp(GAP_DP)
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(circle, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        if (changed) applySelection(animate = false)
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
        val itemWidth = (capsule.layoutParams as LayoutParams).width / items.size
        val target = (index(selected) * itemWidth + context.dp(PILL_INSET_DP)).toFloat()
        if (animate && itemWidth > 0) pillX.animateTo(target) else { pillX.cancel(); pill.translationX = target }
    }

    private fun index(tab: AppTab) = when (tab) {
        AppTab.HOME -> 0
        AppTab.INBOX -> 1
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
    fun frostShapes(): List<Pair<android.graphics.Rect, Float>> = listOf(
        android.graphics.Rect(capsule.left, capsule.top, capsule.right, capsule.bottom) to capsule.height / 2f,
        android.graphics.Rect(router.left, router.top, router.right, router.bottom) to router.height / 2f,
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
        const val BREATH_MS = 900L
    }
}
