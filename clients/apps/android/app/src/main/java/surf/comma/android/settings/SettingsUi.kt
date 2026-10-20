package surf.comma.android.settings

import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Outline
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.ColorRes
import androidx.annotation.DrawableRes
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

internal fun Context.dp(value: Float): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()
internal fun Context.dp(value: Int): Int = dp(value.toFloat())
internal fun Context.color(@ColorRes id: Int): Int = getColor(id)

internal fun Context.text(level: Level, @ColorRes color: Int, weight: Int = DesignFonts.regular) = TextView(this).apply {
    DesignTypography.applyTo(this, level, weight)
    setTextColor(color(color))
    includeFontPadding = false
}

internal fun roundRect(color: Int, radius: Float) = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = radius
    setColor(color)
}

/** Clips children to the view's rounded background. */
internal fun View.clipToRoundedBackground(radius: Float) {
    outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) = outline.setRoundRect(0, 0, view.width, view.height, radius)
    }
    clipToOutline = true
}

/**
 * Press feedback: the pressed colour fades in and out with the feedback timings, and an optional
 * spring scale. Colour and opacity use durations and curves; scale uses the scale spring.
 */
internal class PressFeedback(private val view: View, @ColorRes pressed: Int, private val scale: Boolean) {
    private val pressedColor = view.context.getColor(pressed)
    private val background = ColorDrawable(Color.TRANSPARENT)
    private var animator: ValueAnimator? = null
    private val scaleX = DesignSpring(view, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val scaleY = DesignSpring(view, DynamicAnimation.SCALE_Y, DesignMotion.springScale)

    init {
        view.background = background
        view.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> if (v.isEnabled) set(true)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> set(false)
            }
            false
        }
    }

    private fun set(pressed: Boolean) {
        animator?.cancel()
        val from = background.color
        val to = if (pressed) pressedColor else Color.TRANSPARENT
        animator = ValueAnimator.ofObject(ArgbEvaluator(), from, to).apply {
            duration = DesignMotion.durationMillis(if (pressed) DesignMotion.feedbackIn else DesignMotion.feedbackOut)
            interpolator = DesignMotion.softInOut
            addUpdateListener { background.color = it.animatedValue as Int }
            start()
        }
        if (scale) {
            val target = if (pressed) DesignMotion.pressScale() else 1f
            scaleX.animateTo(target)
            scaleY.animateTo(target)
        }
    }
}

/**
 * An on/off switch for the trailing end of a [SettingsRow]; the row takes the taps and speaks for
 * it. The thumb moves on the spatial spring; the track colour changes with the state timing.
 */
internal class SettingsSwitch(context: Context) : FrameLayout(context) {
    private val onColor = context.color(R.color.token_bg_brand_solid)
    private val offColor = context.color(R.color.token_border_primary)
    private var trackColor = offColor
    private val track = roundRect(offColor, context.dp(14).toFloat())
    private val inset = context.dp(3)
    private val thumb = View(context).apply {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.WHITE)
        }
    }
    private val thumbX = DesignSpring(thumb, DynamicAnimation.TRANSLATION_X, DesignMotion.springSpatial)
    private var colors: ValueAnimator? = null

    var checked = false
        private set

    init {
        background = track
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(thumb, LayoutParams(context.dp(22), context.dp(22), Gravity.CENTER_VERTICAL or Gravity.START).apply {
            marginStart = inset
        })
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) = super.onMeasure(
        MeasureSpec.makeMeasureSpec(context.dp(46), MeasureSpec.EXACTLY),
        MeasureSpec.makeMeasureSpec(context.dp(28), MeasureSpec.EXACTLY),
    )

    private val travel get() = (context.dp(46) - context.dp(22) - 2 * inset).toFloat()

    /** Moves to [on]; [animate] false jumps there, as when the page first shows. */
    fun set(on: Boolean, animate: Boolean = true) {
        if (on == checked) return
        checked = on
        val target = if (on) travel else 0f
        colors?.cancel()
        if (!animate) {
            thumbX.cancel()
            thumb.translationX = target
            trackColor = if (on) onColor else offColor
            track.setColor(trackColor)
            return
        }
        thumbX.animateTo(target)
        colors = ValueAnimator.ofObject(ArgbEvaluator(), trackColor, if (on) onColor else offColor).apply {
            duration = DesignMotion.durationMillis(DesignMotion.stateChange)
            interpolator = DesignMotion.softInOut
            addUpdateListener {
                trackColor = it.animatedValue as Int
                track.setColor(trackColor)
            }
            start()
        }
    }

    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        alpha = if (enabled) 1f else 0.5f
    }
}

/**
 * A titled group of rows on one rounded surface, split by hairlines where the page shows through, with an
 * optional footnote under it: the iOS app's grouped surface (24dp corners, captions 4dp in from its edge).
 */
internal class SettingsSection(context: Context, title: CharSequence?) : LinearLayout(context) {
    val card = LinearLayout(context).apply {
        orientation = VERTICAL
        val radius = context.dp(24).toFloat()
        background = roundRect(context.color(R.color.token_bg_tertiary), radius)
        clipToRoundedBackground(radius)
        showDividers = SHOW_DIVIDER_MIDDLE
        dividerDrawable = GradientDrawable().apply {
            setColor(context.color(R.color.token_bg_primary))
            setSize(1, maxOf(1, (context.resources.displayMetrics.density * 0.67f).toInt()))
        }
    }
    private val footer = context.text(Level.MINI, R.color.token_text_tertiary).apply {
        isVisible = false
        setPadding(context.dp(4), context.dp(8), context.dp(4), 0)
    }

    init {
        orientation = VERTICAL
        if (title != null) {
            addView(context.text(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
                text = title
                isAccessibilityHeading = true
                setPadding(context.dp(4), 0, context.dp(4), context.dp(8))
            })
        }
        addView(card, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(footer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    fun add(row: View): SettingsSection = apply { card.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)) }

    /** The footnote under the group. */
    fun footer(text: CharSequence?): SettingsSection = apply {
        footer.text = text
        footer.isVisible = !text.isNullOrEmpty()
    }
}

/** Icon, title (and optional detail line), then the current value or a chevron. */
internal class SettingsRow(context: Context, @DrawableRes icon: Int?, title: CharSequence, @ColorRes tint: Int = R.color.token_fg_primary) :
    LinearLayout(context) {
    val icon = ImageView(context).apply {
        if (icon != null) setImageResource(icon)
        imageTintList = ColorStateList.valueOf(context.color(if (tint == R.color.token_fg_primary) R.color.token_text_secondary else tint))
        isVisible = icon != null
    }
    val title = context.text(Level.REGULAR, if (tint == R.color.token_fg_primary) R.color.token_text_primary else tint).apply {
        text = title
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
    }
    val detail = context.text(Level.SMALL, R.color.token_text_quaternary).apply {
        isVisible = false
        maxLines = DETAIL_MAX_LINES
        ellipsize = TextUtils.TruncateAt.END
    }
    val value = context.text(Level.REGULAR, R.color.token_text_tertiary).apply {
        isVisible = false
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        gravity = Gravity.END
    }
    val chevron = ImageView(context).apply {
        setImageResource(R.drawable.ic_settings_chevron)
        imageTintList = ColorStateList.valueOf(context.color(R.color.token_fg_quaternary))
        isVisible = false
    }
    private val trailing = FrameLayout(context)

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = context.dp(50)
        setPadding(context.dp(14), context.dp(10), context.dp(10), context.dp(10))
        addView(this.icon, LayoutParams(context.dp(20), context.dp(20)).apply { marginEnd = context.dp(8) })
        // The value sits on the title's line, so the description below can use the row's full
        // width rather than wrapping beside the value.
        val titleLine = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(this@SettingsRow.title, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(value, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                marginStart = context.dp(12)
            })
        }
        val texts = LinearLayout(context).apply {
            orientation = VERTICAL
            addView(titleLine, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            addView(detail, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(2) })
        }
        addView(texts, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        fitValue()
        addView(trailing, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(chevron, LayoutParams(context.dp(20), context.dp(20)).apply { marginStart = context.dp(4) })
    }

    fun value(text: CharSequence?, chevron: Boolean = false) = apply {
        value.text = text
        value.isVisible = !text.isNullOrEmpty()
        this.chevron.isVisible = chevron
    }

    fun detail(text: CharSequence?) = apply {
        detail.text = text
        detail.isVisible = !text.isNullOrEmpty()
        fitValue()
    }

    /** Beside a title with a description, a long value wraps rather than squeezing the title. */
    private fun fitValue() {
        val screen = context.resources.displayMetrics.widthPixels
        val described = detail.isVisible
        value.maxLines = if (described) 2 else 1
        value.maxWidth = if (described) (screen * DESCRIBED_VALUE_WIDTH).toInt() else screen / 2
    }

    private companion object {
        const val DETAIL_MAX_LINES = 3
        const val DESCRIBED_VALUE_WIDTH = 0.36f
    }

    fun trailing(view: View?) = apply {
        trailing.removeAllViews()
        if (view != null) trailing.addView(view)
    }

    fun onClick(action: ((SettingsRow) -> Unit)?) = apply {
        if (action == null) {
            setOnClickListener(null)
            isClickable = false
            return@apply
        }
        if (background == null) PressFeedback(this, R.color.token_surface_ink, scale = false)
        setOnClickListener { action(this) }
    }

    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        alpha = if (enabled) 1f else 0.5f
    }
}

/**
 * A page with a top bar over a scrolling column of sections, as the iOS app's pages: the title centred at the
 * app's one title size, the back chevron at the leading edge unless [showBack] is false (a tab's root), and an
 * optional [trailing] slot. Rows scrolling under the bar bring in a hairline under it.
 */
internal class SettingsPageLayout(
    context: Context,
    title: CharSequence,
    showBack: Boolean = true,
    onBack: () -> Unit,
) : LinearLayout(context) {
    /** Each section, wrapped with its spacing, is one item of the list. Sections are only appended. */
    private val items = mutableListOf<View>()
    private val adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun getItemCount() = items.size
        // One type per item: a section is built once and its holder only ever shows that view.
        override fun getItemViewType(position: Int) = position
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(items[viewType]) {}
        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
    }
    val list = RecyclerView(context).apply {
        layoutManager = LinearLayoutManager(context)
        // The sections are few and hold live state; keep them all instead of recycling.
        setItemViewCacheSize(Int.MAX_VALUE)
        itemAnimator = null
        clipToPadding = false
        setPadding(0, context.dp(8), 0, context.dp(32))
        adapter = this@SettingsPageLayout.adapter
    }
    val bar = FrameLayout(context)
    /** Beside the title at the trailing edge: a page's own actions. */
    val trailing = LinearLayout(context).apply {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val hairline = View(context).apply {
        setBackgroundColor(context.color(R.color.token_border_primary))
        alpha = 0f
    }
    val titleView = context.text(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold).apply {
        text = title
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        isAccessibilityHeading = true
        gravity = Gravity.CENTER
    }

    init {
        orientation = VERTICAL
        setBackgroundColor(context.color(R.color.token_bg_primary))
        // Touches must not fall through to the page below while this one slides.
        isClickable = true
        if (showBack) bar.addView(ImageView(context).apply {
            setImageResource(R.drawable.ic_task_back)
            imageTintList = ColorStateList.valueOf(context.color(R.color.token_fg_primary))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(context.dp(12), context.dp(12), context.dp(12), context.dp(12))
            contentDescription = context.getString(R.string.settings_back)
            PressFeedback(this, R.color.token_bg_quaternary, scale = true)
            clipToRoundedBackground(context.dp(24).toFloat())
            setOnClickListener { onBack() }
        }, FrameLayout.LayoutParams(context.dp(48), context.dp(48), Gravity.CENTER_VERTICAL or Gravity.START).apply {
            marginStart = context.dp(4)
        })
        bar.addView(titleView, FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER).apply {
            marginStart = context.dp(64)
            marginEnd = context.dp(64)
        })
        bar.addView(trailing, FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT, Gravity.CENTER_VERTICAL or Gravity.END).apply {
            marginEnd = context.dp(8)
        })
        bar.addView(hairline, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, 1, Gravity.BOTTOM))
        addView(bar, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(52)))
        addView(list, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                val scrolled = list.canScrollVertically(-1)
                if ((hairline.alpha > 0f) != scrolled) hairline.animate().alpha(if (scrolled) 1f else 0f)
                    .setDuration(DesignMotion.durationMillis(DesignMotion.stateChange)).start()
            }
        })
    }

    /** Appends [view] as the next list item, [top] dp below the previous one. */
    fun section(view: View, top: Int = 24) = apply {
        val item = FrameLayout(context).apply {
            setPadding(context.dp(16), if (items.isEmpty()) 0 else context.dp(top), context.dp(16), 0)
            addView(view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
            layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT)
        }
        items += item
        adapter.notifyItemInserted(items.lastIndex)
    }

    /** Every section, attached to the list or not (the list only lays out what is on screen). */
    internal val sections: List<View> get() = items

    /** Status and navigation bar insets; the page draws edge to edge. */
    fun applyInsets(top: Int, bottom: Int) {
        (bar.layoutParams as LayoutParams).topMargin = top
        list.setPadding(0, list.paddingTop, 0, context.dp(32) + bottom)
        requestLayout()
    }
}
