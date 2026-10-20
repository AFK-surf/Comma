package surf.comma.android.ui.kit

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.ColorInt
import androidx.annotation.ColorRes
import androidx.annotation.DrawableRes
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/*
 * The shared building blocks of the tabs, drawn after the iOS app: its glass controls, the one empty state,
 * the grey capsule buttons, the small attention dot and tactile presses. The iOS text styles map onto the
 * design foundation's levels one step apart, as they are on iOS: title3 → LARGE, body → REGULAR,
 * subheadline → SMALL, footnote → MINI, caption → MICRO.
 */

fun Context.dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()
fun Context.dpf(value: Float): Float = value * resources.displayMetrics.density
fun View.dp(value: Int): Int = context.dp(value)

@ColorInt fun Context.ink(@ColorRes id: Int): Int = getColor(id)

/** A text view at a foundation level, weight and colour, without font padding. */
fun Context.label(level: Level, @ColorRes color: Int, weight: Int = DesignFonts.regular, lines: Int = 1): TextView =
    TextView(this).apply {
        DesignTypography.applyTo(this, level, weight)
        setTextColor(getColor(color))
        includeFontPadding = false
        if (lines > 0) {
            maxLines = lines
            ellipsize = TextUtils.TruncateAt.END
        }
    }

/** A tinted glyph from `res/drawable`. */
fun Context.glyph(@DrawableRes icon: Int, @ColorRes tint: Int = R.color.token_text_primary): ImageView = ImageView(this).apply {
    setImageResource(icon)
    imageTintList = ColorStateList.valueOf(getColor(tint))
    scaleType = ImageView.ScaleType.FIT_CENTER
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
}

fun rounded(@ColorInt fill: Int, radius: Float, @ColorInt stroke: Int = 0, strokeWidth: Int = 0) = GradientDrawable().apply {
    cornerRadius = radius
    setColor(fill)
    if (strokeWidth > 0) setStroke(strokeWidth, stroke)
}

/** Clips the view and its children to a rounded rectangle of [radius]; a negative radius makes a capsule. */
fun View.clipRounded(radius: Float) {
    outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            val r = if (radius < 0) minOf(view.width, view.height) / 2f else radius
            outline.setRoundRect(0, 0, view.width, view.height, r)
        }
    }
    clipToOutline = true
}

/**
 * The iOS app's glass, drawn on Android as the colour the glass shows over the page with a hairline edge and a
 * soft shadow: the tab bar, the status switcher, the filter capsule, toasts and the floating close buttons.
 * A negative [radius] makes a capsule.
 */
fun View.glass(radius: Float = -1f, elevated: Boolean = true, @ColorRes fill: Int = R.color.token_glass_over_page) {
    val fillColor = context.getColor(fill)
    val fill = GradientDrawable().apply {
        setColor(fillColor)
        setStroke(maxOf(1, (resources.displayMetrics.density * 0.5f).toInt()), context.getColor(R.color.token_glass_border))
    }
    background = fill
    addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
        fill.cornerRadius = if (radius < 0) minOf(v.width, v.height) / 2f else radius
    }
    outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            val r = if (radius < 0) minOf(view.width, view.height) / 2f else radius
            outline.setRoundRect(0, 0, view.width, view.height, r)
        }
    }
    if (elevated) {
        elevation = context.dpf(12f)
        outlineAmbientShadowColor = context.getColor(R.color.token_composer_shadow_ambient)
        outlineSpotShadowColor = context.getColor(R.color.token_composer_shadow_spot)
    }
}

/**
 * A press that answers the moment a finger lands: the view shrinks a little on the scale spring and springs
 * back on release, as the iOS app's tactile buttons do. [scale] is the pressed size; [target] is what shrinks.
 */
fun View.tactile(scale: Float = 0.96f, target: View = this) {
    val press = tactilePress(scale, target)
    setOnTouchListener { v, event -> press(v, event); false }
}

private fun tactilePress(scale: Float, target: View): (View, MotionEvent) -> Unit {
    val x = DesignSpring(target, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    val y = DesignSpring(target, DynamicAnimation.SCALE_Y, DesignMotion.springScale)
    return { v, event ->
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> if (v.isEnabled) { x.animateTo(scale); y.animateTo(scale) }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { x.animateTo(1f); y.animateTo(1f) }
        }
    }
}

/**
 * A press that paints [pressed] over the view the moment a finger lands and lets it go on release. It draws in the
 * foreground, so the view keeps its own surface underneath.
 */
fun View.pressedFill(@ColorRes pressed: Int = R.color.token_surface_ink, radius: Float = 0f) {
    val press = fillPress(pressed, radius)
    setOnTouchListener { v, event -> press(v, event); false }
}

/** Installs the foreground [pressedFill] paints and returns its touch handling, for a view that also does more. */
private fun View.fillPress(@ColorRes pressed: Int, radius: Float): (View, MotionEvent) -> Unit {
    val drawable = GradientDrawable().apply { cornerRadius = radius; setColor(0) }
    foreground = drawable
    val color = context.getColor(pressed)
    return { v, event ->
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> if (v.isEnabled) { v.animate().cancel(); drawable.setColor(color) }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> drawable.setColor(0)
        }
    }
}

fun View.selectionTick() = performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
fun View.confirmTick() = performHapticFeedback(HapticFeedbackConstants.CONFIRM)

/** The grey capsule the empty states and footers offer their way out with (iOS secondary compact button). */
// Styled entirely here in code on the platform widget, like the composer's buttons; AppCompat's tinting adds nothing.
@SuppressLint("AppCompatCustomView")
class CapsuleButton(context: Context, text: CharSequence) : TextView(context) {
    init {
        DesignTypography.applyTo(this, Level.SMALL, DesignFonts.medium)
        includeFontPadding = false
        setTextColor(context.getColor(R.color.token_text_primary))
        this.text = text
        gravity = Gravity.CENTER
        minHeight = context.dp(36)
        setPadding(context.dp(16), 0, context.dp(16), 0)
        background = rounded(context.getColor(R.color.token_bg_tertiary), context.dpf(18f))
        tactile(0.96f)
    }
}

/** The small brand dot an unread row and the tab bar's Inbox carry. */
class AttentionDot(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_bg_brand_solid) }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(context.dp(SIZE_DP), context.dp(SIZE_DP))

    override fun onDraw(canvas: Canvas) = canvas.drawCircle(width / 2f, height / 2f, minOf(width, height) / 2f, paint)

    companion object { const val SIZE_DP = 8 }
}

/**
 * The app's one empty state: a 24dp glyph, a title, an optional line of explanation and the ways out, centred
 * in the room it is given.
 */
class EmptyStateView(context: Context) : LinearLayout(context) {
    private val icon = context.glyph(R.drawable.ic_empty_planning, R.color.token_text_tertiary)
    private val title = context.label(Level.SMALL, R.color.token_text_primary, DesignFonts.semibold, lines = 0)
    private val detail = context.label(Level.MINI, R.color.token_text_tertiary, lines = 0)
    private val actions = LinearLayout(context).apply {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
    }

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        setPadding(context.dp(24), context.dp(16), context.dp(24), context.dp(16))
        title.gravity = Gravity.CENTER
        title.isAccessibilityHeading = true
        detail.gravity = Gravity.CENTER
        addView(icon, LayoutParams(context.dp(24), context.dp(24)))
        addView(title, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(8) })
        addView(detail, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(4) })
        addView(actions, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(14) })
    }

    fun show(@DrawableRes glyph: Int?, title: CharSequence, detail: CharSequence? = null,
             vararg actions: Pair<CharSequence, () -> Unit>) {
        icon.isVisible = glyph != null
        glyph?.let(icon::setImageResource)
        this.title.text = title
        this.detail.text = detail
        this.detail.isVisible = !detail.isNullOrEmpty()
        this.actions.removeAllViews()
        actions.forEachIndexed { index, (label, action) ->
            this.actions.addView(CapsuleButton(context, label).apply { setOnClickListener { action() } },
                LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { if (index > 0) topMargin = context.dp(8) })
        }
        this.actions.isVisible = actions.isNotEmpty()
        (this.actions.layoutParams as LayoutParams).topMargin = context.dp(14)
    }
}

/** A circular 44dp button on glass holding one glyph: the sheets' close button, the Task header's buttons. */
class GlassIconButton(context: Context, @DrawableRes icon: Int, description: CharSequence, glass: Boolean = true) : FrameLayout(context) {
    val image = context.glyph(icon, R.color.token_text_primary)

    init {
        contentDescription = description
        isClickable = true
        isFocusable = true
        addView(image, LayoutParams(context.dp(20), context.dp(20), Gravity.CENTER))
        if (glass) {
            glass(elevated = false)
            tactile(0.9f)
        } else {
            // A view holds one touch listener, so the pressed fill and the shrink share it.
            val fill = fillPress(R.color.token_surface_ink, context.dpf(22f))
            val shrink = tactilePress(0.9f, this)
            setOnTouchListener { v, event -> fill(v, event); shrink(v, event); false }
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val side = MeasureSpec.makeMeasureSpec(context.dp(44), MeasureSpec.EXACTLY)
        super.onMeasure(side, side)
    }
}

/** The small muted caption over a group or a list section (iOS subheadline semibold, quaternary). */
fun Context.caption(text: CharSequence): TextView = label(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
    this.text = text
    isAccessibilityHeading = true
}

fun ViewGroup.matchWidth(view: View, height: Int = ViewGroup.LayoutParams.WRAP_CONTENT) =
    addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height))
