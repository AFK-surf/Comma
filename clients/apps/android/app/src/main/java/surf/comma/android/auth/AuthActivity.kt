package surf.comma.android.auth

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.os.Bundle
import android.text.InputType
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import surf.comma.android.scroll.widget.ScrollContainer
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.ui.connection.ConnectionColumn
import surf.comma.android.ui.connection.ConnectionErrorController
import surf.comma.android.ui.connection.ConnectionErrorView
import surf.comma.android.ui.connection.ConnectionSpinner
import surf.comma.android.ui.connection.connectionAvailability
import surf.comma.android.ui.composer.ButtonScale
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

class AuthActivity : ComponentActivity() {
    private val repository by lazy { AuthGraph.get(this) }
    private lateinit var pages: AuthPages
    private lateinit var connectionError: ConnectionErrorController

    private lateinit var google: MaterialButton
    private lateinit var googleProgress: ProgressBar
    private lateinit var googleMessage: TextView

    private lateinit var emailBox: TextInputLayout
    private lateinit var email: TextInputEditText
    private lateinit var emailMessage: TextView

    private lateinit var codeInstruction: TextView
    private lateinit var codeAddress: TextView
    internal lateinit var codeInput: CodeInputView
    private lateinit var codeMessage: TextView
    private lateinit var resend: MaterialButton
    private lateinit var change: MaterialButton
    private lateinit var resendRow: View

    private lateinit var statusTitle: TextView
    private lateinit var statusBody: TextView
    private lateinit var statusDetail: TextView
    private lateinit var statusProgress: ConnectionSpinner
    private lateinit var switchAccount: MaterialButton
    private lateinit var logout: MaterialButton

    private lateinit var bottomBar: View
    private lateinit var primary: MaterialButton
    private lateinit var primaryProgress: ProgressBar

    private var previousChallenge: String? = null
    private var previousState: AuthState? = null
    private var previousCountdown: Pair<Long, Long>? = null
    /** The state whose problem the person has already acted on by editing; its message stays hidden. */
    private var dismissedProblem: AuthState? = null
    private var binding = false
    private var imeAnimating = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val emailPage = page(buildEmailPage(savedInstanceState))
        val codePage = page(buildCodePage())
        val statusPage = buildStatusPage()
        pages = AuthPages(listOf(emailPage, codePage, statusPage))
        bottomBar = buildBottomBar()
        // The status page has no bottom action and takes the whole page, the same area the
        // connection error page covers; the steps with an action end above the bottom bar.
        val aboveBar = FrameLayout.LayoutParams(-1, -1).apply { bottomMargin = dp(BOTTOM_BAR_HEIGHT) }
        val content = FrameLayout(this).apply {
            setBackgroundColor(getColor(R.color.token_bg_primary))
            addView(emailPage, aboveBar)
            addView(codePage, FrameLayout.LayoutParams(aboveBar))
            addView(statusPage, FrameLayout.LayoutParams(-1, -1))
            addView(bottomBar, FrameLayout.LayoutParams(-1, dp(BOTTOM_BAR_HEIGHT), Gravity.BOTTOM))
        }
        val errorPage = ConnectionErrorView(this).apply { visibility = View.GONE }
        connectionError = ConnectionErrorController(onChanged = { state ->
            content.importantForAccessibility = if (state == null) View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                else View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            if (state != null) errorPage.render(state)
            showErrorPage(errorPage, content, state != null)
        }, onRetry = {
            lifecycleScope.launch {
                try { repository.retry() } finally {
                    connectionError.present(repository.state.value)
                    connectionError.sessionRetryFinished()
                }
            }
        })
        errorPage.onRetry = connectionError::retry
        errorPage.onSwitchAccount = { AuthGraph.scope.launch { repository.logout() } }
        val root = FrameLayout(this).apply {
            addView(content, FrameLayout.LayoutParams(-1, -1))
            addView(errorPage, FrameLayout.LayoutParams(-1, -1))
        }
        followInsets(root)
        setContentView(root)
        AuthGraph.scope.launch { repository.start() }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { repository.state.collect { render(it) } }
                launch { connectionAvailability(this@AuthActivity).collect(connectionError::connectivityChanged) }
                launch {
                    while (true) {
                        repository.checkExpiry()
                        render(repository.state.value)
                        delay(1_000)
                    }
                }
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        // The OTP and session never enter Android's saved view state.
        if (repository.state.value is AuthState.Login) outState.putString("email_draft", email.text.toString())
        super.onSaveInstanceState(outState)
    }

    // region Pages

    private fun buildEmailPage(savedInstanceState: Bundle?) = column().apply {
        addHeader(this, R.string.auth_welcome_title).also { (_, subtitle) ->
            subtitle.setText(R.string.auth_welcome_subtitle)
            DesignTypography.applyTo(subtitle, Level.LARGE)
        }
        // Google's guidelines ask for its button to be at least as prominent as other options; it comes first.
        addView(buildGoogleButton(), params(32))
        googleMessage = message()
        addView(googleMessage, params(12))
        addView(orDivider(), params(24))
        emailBox = (layoutInflater.inflate(R.layout.auth_text_input, this, false) as TextInputLayout).apply {
            typeface = DesignFonts.inter(this@AuthActivity)
            hint = getString(R.string.auth_email)
            placeholderText = getString(R.string.auth_email_placeholder)
        }
        email = (emailBox.editText as TextInputEditText).apply {
            id = R.id.auth_email
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
            setSingleLine(true)
            isSaveEnabled = false
            DesignTypography.applyTo(this)
            setTextColor(getColor(R.color.token_text_primary))
            setPadding(dp(16), dp(16), dp(16), dp(16))
            imeOptions = EditorInfo.IME_ACTION_NEXT or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            setAutofillHints(View.AUTOFILL_HINT_EMAIL_ADDRESS)
            setText(savedInstanceState?.getString("email_draft").orEmpty())
            setOnEditorActionListener { _, action, _ ->
                if (action == EditorInfo.IME_ACTION_NEXT || action == EditorInfo.IME_ACTION_DONE) { submit(); true } else false
            }
            doAfterTextChanged { if (!binding) { dismissProblem(); rerender() } }
        }
        emailBox.clearErrorWhenEmailBecomesValid()
        addView(emailBox, params(24))
        emailMessage = message()
        addView(emailMessage, params(12))
    }

    private fun buildCodePage() = column().apply {
        codeInstruction = addHeader(this, R.string.auth_check_email_title).second.apply {
            setText(R.string.auth_code_sent_to)
        }
        codeAddress = label(Level.REGULAR, DesignFonts.medium).apply {
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.MIDDLE
        }
        change = textButton(R.string.auth_change).apply {
            contentDescription = getString(R.string.auth_change_email)
            setOnClickListener { AuthGraph.scope.launch { repository.changeEmail() } }
        }
        addView(InlineRow(this@AuthActivity, codeAddress, change), params(0))
        codeInput = CodeInputView(this@AuthActivity).apply {
            onCodeChanged = { dismissProblem(); rerender() }
            onCodeComplete = { if (pages.current == CODE) submit() }
            onCodeReset = { rerender() }
            editor.setOnEditorActionListener { _, action, _ ->
                if (action == EditorInfo.IME_ACTION_DONE) { submit(); true } else false
            }
        }
        addView(codeInput, params(24))
        codeMessage = message()
        addView(codeMessage, params(12))
        val notReceived = label(Level.SMALL).apply {
            setText(R.string.auth_code_not_received)
            setTextColor(getColor(R.color.token_text_quaternary))
            maxLines = 2
        }
        resend = textButton(R.string.auth_resend).apply {
            DesignTypography.applyTo(this, Level.SMALL, DesignFonts.medium)
            setOnClickListener {
                val login = repository.state.value as? AuthState.Login ?: return@setOnClickListener
                AuthGraph.scope.launch { repository.sendCode(login.email) }
            }
        }
        resendRow = InlineRow(this@AuthActivity, notReceived, resend)
        addView(resendRow, params(12))
    }

    /**
     * "Continue with Google", drawn to Google's sign-in branding guidelines: the standard colour
     * G, unchanged, with the theme's fill, stroke and text colours (light mode uses the app's softer
     * border). While busy a spinner replaces the content and the button ignores taps.
     */
    private fun buildGoogleButton(): View {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val text = if (night) GOOGLE_DARK_TEXT else GOOGLE_LIGHT_TEXT
        google = PressableButton(this).apply {
            id = R.id.auth_google
            setText(R.string.auth_continue_google)
            isAllCaps = false
            DesignTypography.applyTo(this, weight = DesignFonts.medium)
            setTextColor(text)
            setIconResource(R.drawable.ic_google_g)
            // The G keeps Google's own colours.
            iconTint = null
            iconSize = dp(20)
            iconPadding = dp(10)
            iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
            cornerRadius = dp(12)
            insetTop = 0
            insetBottom = 0
            minHeight = dp(48)
            stateListAnimator = null
            elevation = 0f
            backgroundTintList = ColorStateList.valueOf(if (night) GOOGLE_DARK_FILL else GOOGLE_LIGHT_FILL)
            // In light mode the outline uses the app's border token: Google's #747775 read as a black line.
            strokeColor = ColorStateList.valueOf(if (night) GOOGLE_DARK_STROKE else getColor(R.color.token_border_primary))
            strokeWidth = maxOf(1, dp(1))
            // Pressed and focused layers in the text colour, so they show on both the light and dark fill.
            rippleColor = ColorStateList.valueOf(text and 0x00FFFFFF or 0x1F000000)
            setOnClickListener { signInWithGoogle() }
        }
        googleProgress = ProgressBar(this).apply {
            indeterminateTintList = ColorStateList.valueOf(text)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            isVisible = false
        }
        return FrameLayout(this).apply {
            addView(google, FrameLayout.LayoutParams(-1, dp(48)))
            addView(googleProgress, FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
        }
    }

    /** A hairline either side of "or", between Google and email. */
    private fun orDivider() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        fun line() = View(this@AuthActivity).apply { setBackgroundColor(getColor(R.color.token_border_secondary)) }
        addView(line(), LinearLayout.LayoutParams(0, maxOf(1, dp(1)), 1f))
        addView(label(Level.SMALL).apply {
            setText(R.string.auth_or)
            setTextColor(getColor(R.color.token_text_quaternary))
            setPadding(dp(12), 0, dp(12), 0)
        }, LinearLayout.LayoutParams(-2, -2))
        addView(line(), LinearLayout.LayoutParams(0, maxOf(1, dp(1)), 1f))
    }

    private fun signInWithGoogle() {
        val login = previousState as? AuthState.Login ?: return
        if (login.busy || login.googleBusy || login.challengeId != null) return
        dismissProblem()
        val source = CredentialManagerGoogle(this)
        AuthGraph.scope.launch { repository.signInWithGoogle(source) }
    }

    private fun buildStatusPage() = ConnectionColumn(this).run {
        statusTitle = title.apply { setText(R.string.auth_connecting_title) }
        statusBody = label(Level.REGULAR).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(getColor(R.color.token_text_quaternary))
            // Room for the longest step, so a longer line never pushes the spinner down.
            minLines = 2
        }
        addView(statusBody, row(8))
        statusDetail = label(Level.SMALL).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(getColor(R.color.token_text_quaternary))
        }
        addView(statusDetail, row(8))
        statusProgress = ConnectionSpinner(this@AuthActivity).apply { color = getColor(R.color.token_fg_quaternary) }
        addView(statusProgress, LinearLayout.LayoutParams(dp(24), dp(24)).apply { topMargin = dp(16) })
        logout = textButton(R.string.auth_logout).apply { setOnClickListener { AuthGraph.scope.launch { repository.logout() } } }
        // Rarely needed while connecting: a small, low-contrast label at the foot of the page.
        switchAccount = textButton(R.string.auth_switch_account).apply {
            DesignTypography.applyTo(this, Level.SMALL, DesignFonts.medium)
            setTextColor(getColor(R.color.token_text_quaternary))
            setPadding(dp(16), 0, dp(16), 0)
            setOnClickListener { AuthGraph.scope.launch { repository.logout() } }
        }
        addView(logout, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(24) })
        addSpace()
        addView(switchAccount, LinearLayout.LayoutParams(-2, -2))
        scrolling()
    }

    private fun buildBottomBar(): View {
        primary = PressableButton(this).apply {
            id = R.id.auth_primary
            isAllCaps = false
            DesignTypography.applyTo(this, weight = DesignFonts.semibold)
            cornerRadius = dp(12)
            insetTop = 0
            insetBottom = 0
            minHeight = dp(48)
            // The progress indicator sits on top of the button; no elevation may cover it.
            stateListAnimator = null
            elevation = 0f
            backgroundTintList = ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled),
                intArrayOf(android.R.attr.state_pressed), intArrayOf()), intArrayOf(getColor(R.color.token_text_placeholder),
                getColor(R.color.token_bg_brand_solid_hover), getColor(R.color.token_bg_brand_solid)))
            setTextColor(getColor(android.R.color.white))
            setOnClickListener { submit() }
        }
        primaryProgress = ProgressBar(this).apply {
            indeterminateTintList = ColorStateList.valueOf(getColor(android.R.color.white))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            isVisible = false
        }
        return FrameLayout(this).apply {
            setPadding(dp(16), dp(12), dp(16), dp(12))
            clipChildren = false
            alpha = 0f
            visibility = View.INVISIBLE
            addView(primary, FrameLayout.LayoutParams(-1, dp(48)))
            addView(primaryProgress, FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
        }
    }

    // endregion

    internal fun render(state: AuthState, force: Boolean = false) {
        connectionError.present(state)
        val countdown = when (state) {
            is AuthState.Login -> remaining(state.resendAtMillis) to remaining(state.verifyAtMillis)
            is AuthState.Connecting -> remaining(state.retryAtMillis) to 0L
            else -> null
        }
        if (!force && state == previousState && countdown == previousCountdown) return
        previousCountdown = countdown
        val login = state as? AuthState.Login
        val page = when {
            login == null -> STATUS
            login.challengeId == null -> EMAIL
            else -> CODE
        }
        val pageChanged = page != pages.current
        pages.show(page, animated = previousState != null && previousState !is AuthState.Starting)
        if (login != null) renderLogin(login) else renderStatus(state)
        if (pageChanged) moveFocus(page, initial = previousState == null || previousState is AuthState.Starting)
        // A failed connection is covered by the connection error page, which has its own retry.
        showBottomBar(login != null)
        previousChallenge = login?.challengeId
        previousState = state
    }

    private fun renderLogin(login: AuthState.Login) {
        val previous = previousState
        if (previous !is AuthState.Login || previousChallenge != login.challengeId) {
            codeInput.clear()
            binding = true
            when {
                // The Google account's address is shown on the code step, not put into the email field.
                login.linkingGoogle -> Unit
                login.email.isNotEmpty() -> if (email.text.toString() != login.email) email.setText(login.email)
                // Editing the address from the code step keeps what was typed.
                previous is AuthState.Login -> Unit
                previous != null && previous !is AuthState.Starting -> email.setText("")
            }
            binding = false
            emailBox.error = null
            dismissedProblem = null
        }
        val rejected = login.problem == AuthProblem.INVALID_CODE && login.challengeId != null &&
            (previous as? AuthState.Login)?.busy == true && previous !== login
        if (rejected) codeInput.reject()
        val problemText = login.problem?.takeIf { dismissedProblem !== login }?.let { getString(problemMessage(it)) }
        val resendSeconds = remaining(login.resendAtMillis)
        val verifySeconds = remaining(login.verifyAtMillis)
        if (login.challengeId == null) {
            setMessage(emailMessage, problemText)
            setMessage(googleMessage, login.googleProblem?.takeIf { dismissedProblem !== login }?.let { getString(problemMessage(it)) })
            setGoogleBusy(login.googleBusy, available = !login.busy)
            setPrimary(
                text = if (resendSeconds > 0) countdownText(R.plurals.auth_resend_seconds, resendSeconds)
                else getString(R.string.auth_continue_email),
                enabled = resendSeconds == 0L && email.text.toString().isNotBlank() && !login.googleBusy,
                busy = login.busy,
            )
        } else {
            codeInstruction.setText(if (login.linkingGoogle) R.string.auth_google_link_sent_to else R.string.auth_code_sent_to)
            change.setText(if (login.linkingGoogle) R.string.auth_back else R.string.auth_change)
            change.contentDescription = getString(if (login.linkingGoogle) R.string.auth_back_to_sign_in else R.string.auth_change_email)
            // A Google link code cannot be resent; going back and choosing Google again sends a new one.
            resendRow.isVisible = !login.linkingGoogle
            if (codeAddress.text.toString() != login.email) codeAddress.text = login.email
            codeInput.locked = login.busy
            setMessage(codeMessage, problemText)
            resend.text = if (resendSeconds > 0) countdownText(R.plurals.auth_resend_countdown, resendSeconds)
            else getString(R.string.auth_resend)
            resend.isEnabled = !login.busy && resendSeconds == 0L
            setPrimary(
                text = if (verifySeconds > 0) countdownText(R.plurals.auth_retry_seconds, verifySeconds)
                else getString(R.string.auth_login),
                enabled = verifySeconds == 0L && codeInput.code.length == CodeText.LENGTH,
                busy = login.busy,
            )
        }
    }

    private fun renderStatus(state: AuthState) {
        val connected = state as? AuthState.Connected
        statusTitle.text = when (state) {
            is AuthState.Connected -> getString(R.string.auth_connected, state.selection.workspace.name)
            is AuthState.Retry -> getString(if (state.problem == AuthProblem.STORAGE) R.string.auth_storage_title else R.string.auth_retry_title)
            AuthState.Unconfigured -> getString(R.string.auth_unconfigured_title)
            else -> getString(R.string.auth_connecting_title)
        }
        statusBody.text = when (state) {
            is AuthState.Connected -> getString(R.string.auth_connected_description)
            is AuthState.Connecting -> getString(when (state.step) {
                ConnectionStep.SESSION -> R.string.auth_checking
                ConnectionStep.WORKSPACE -> R.string.auth_connecting
                ConnectionStep.PROVISIONING -> R.string.auth_provisioning
            }) + if (state.retryAtMillis > 0) " " + countdownText(R.plurals.auth_retry_seconds, remaining(state.retryAtMillis)) else ""
            is AuthState.Retry -> getString(problemMessage(state.problem))
            AuthState.Unconfigured -> getString(R.string.auth_unconfigured)
            else -> getString(R.string.auth_checking)
        }
        statusDetail.text = connected?.let { getString(R.string.auth_main_chat, it.selection.chatId) }
        statusDetail.isVisible = connected != null
        statusProgress.isVisible = state is AuthState.Starting || state is AuthState.Connecting
        logout.isVisible = connected != null
        switchAccount.isVisible = connected != null || state is AuthState.Connecting || state is AuthState.Retry
        if (state is AuthState.Retry) setPrimary(getString(R.string.auth_retry), enabled = true, busy = false)
    }

    private fun moveFocus(page: Int, initial: Boolean) {
        when (page) {
            EMAIL -> {
                // Focus moves between editors, so the keyboard stays up across steps.
                email.requestFocus()
                email.setSelection(email.text?.length ?: 0)
                if (!initial || email.text.isNullOrEmpty()) showKeyboard(email)
            }
            CODE -> codeInput.focusCell(0, showKeyboard = true)
            STATUS -> {
                currentFocus?.let { focused ->
                    getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(focused.windowToken, 0)
                    focused.clearFocus()
                }
            }
        }
    }

    /** Acts on the state on screen, so a stale tap never applies to a step the person cannot see. */
    private fun submit() {
        when (val state = previousState) {
            is AuthState.Login -> {
                if (state.busy || !primary.isEnabled) return
                if (state.challengeId == null) {
                    val address = email.text.toString().trim()
                    if (!android.util.Patterns.EMAIL_ADDRESS.matcher(address).matches()) {
                        emailBox.error = getString(R.string.auth_invalid_email)
                        return
                    }
                    emailBox.error = null
                    AuthGraph.scope.launch { repository.sendCode(address) }
                } else {
                    val value = codeInput.code
                    if (value.length != CodeText.LENGTH) return
                    AuthGraph.scope.launch { repository.verify(value) }
                }
            }
            is AuthState.Retry -> AuthGraph.scope.launch { repository.retry() }
            else -> Unit
        }
    }

    /** Refreshes the state on screen after local input, such as enabling the primary action. */
    private fun rerender() {
        previousState?.let { render(it, force = true) }
    }

    private fun dismissProblem() {
        val state = previousState
        if (state is AuthState.Login && (state.problem != null || state.googleProblem != null)) dismissedProblem = state
    }

    private fun setPrimary(text: String, enabled: Boolean, busy: Boolean) {
        primary.text = if (busy) "" else text
        primary.contentDescription = if (busy) getString(R.string.auth_busy) else null
        primary.isEnabled = enabled || busy
        // Busy keeps the brand colour under the progress indicator but ignores taps.
        primary.isClickable = !busy
        primaryProgress.isVisible = busy
    }

    private fun setGoogleBusy(busy: Boolean, available: Boolean) {
        google.text = if (busy) "" else getString(R.string.auth_continue_google)
        google.icon = if (busy) null else getDrawable(R.drawable.ic_google_g)
        google.contentDescription = if (busy) getString(R.string.auth_google_busy) else null
        google.isClickable = !busy && available
        googleProgress.isVisible = busy
    }

    private fun setMessage(view: TextView, text: String?) {
        if (text == null) {
            view.isVisible = false
            return
        }
        if (view.text.toString() != text || !view.isVisible) {
            view.text = text
            view.alpha = 0f
            view.isVisible = true
            view.animate().alpha(1f).setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
                .setInterpolator(DesignMotion.smoothOut)
        }
    }

    private fun showBottomBar(show: Boolean) {
        val target = if (show) 1f else 0f
        if (bottomBar.isVisible == show && bottomBar.alpha == target) return
        if (show) bottomBar.isVisible = true
        bottomBar.animate().alpha(target)
            .setDuration(DesignMotion.durationMillis(if (show) DesignMotion.dialogEnter else DesignMotion.dialogExit))
            .setInterpolator(DesignMotion.smoothOut)
            .withEndAction { if (!show) bottomBar.visibility = View.INVISIBLE }
    }

    /**
     * Fades the connection error page over the page below. Both draw the mark and the title in
     * the same place, so only the words change.
     */
    private fun showErrorPage(page: View, below: View, show: Boolean) {
        if (show) {
            if (!page.isVisible) {
                page.alpha = 0f
                page.isVisible = true
            }
        } else {
            if (!page.isVisible) return
            below.visibility = View.VISIBLE
        }
        page.animate().alpha(if (show) 1f else 0f)
            .setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
            .setInterpolator(DesignMotion.softInOut)
            .withEndAction { if (show) below.visibility = View.INVISIBLE else page.isVisible = false }
    }

    private fun showKeyboard(view: View) {
        view.post { getSystemService(InputMethodManager::class.java).showSoftInput(view, 0) }
    }

    /**
     * Content is laid out edge to edge. The bottom bar rides on the keyboard frame by frame,
     * so the primary action stays directly above it.
     */
    private fun followInsets(root: View) {
        fun apply(insets: WindowInsetsCompat) {
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            root.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
        }
        // Static insets arrive with the end state before an animation starts; ignore them then.
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            if (!imeAnimating) apply(insets)
            WindowInsetsCompat.CONSUMED
        }
        ViewCompat.setWindowInsetsAnimationCallback(root, object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_STOP) {
            override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) imeAnimating = true
            }
            override fun onProgress(insets: WindowInsetsCompat, running: List<WindowInsetsAnimationCompat>): WindowInsetsCompat {
                apply(insets)
                return insets
            }
            override fun onEnd(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                imeAnimating = false
                ViewCompat.getRootWindowInsets(root)?.let(::apply)
            }
        })
    }

    // region View helpers

    private fun page(content: LinearLayout) = ScrollContainer(this).apply {
        isFillViewport = true
        isVerticalScrollBarEnabled = false
        clipChildren = false
        addView(content, FrameLayout.LayoutParams(-1, -2))
    }

    private fun column() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        clipChildren = false
        clipToPadding = false
        setPadding(dp(16), dp(40), dp(16), dp(24))
    }

    /** Mark, title and one line of supporting text, as on every step. */
    private fun addHeader(parent: LinearLayout, @StringRes title: Int): Pair<TextView, TextView> {
        val mark = ImageView(this).apply {
            setImageResource(R.drawable.ic_cue_mark)
            imageTintList = ColorStateList.valueOf(getColor(R.color.token_fg_primary))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        parent.addView(mark, LinearLayout.LayoutParams(dp(48), dp(48)))
        val heading = label(Level.TITLE2, DesignFonts.medium).apply {
            setText(title)
            gravity = Gravity.CENTER_HORIZONTAL
            isAccessibilityHeading = true
        }
        parent.addView(heading, params(24))
        val supporting = label(Level.REGULAR).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(getColor(R.color.token_text_quaternary))
        }
        parent.addView(supporting, params(4))
        return heading to supporting
    }

    private fun message() = label(Level.SMALL).apply {
        gravity = Gravity.CENTER_HORIZONTAL
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        setTextColor(getColor(R.color.token_text_error_primary))
        isVisible = false
    }

    private fun label(level: Level, weight: Int = DesignFonts.regular) = TextView(this).apply {
        DesignTypography.applyTo(this, level, weight)
        setTextColor(getColor(R.color.token_text_primary))
    }

    private fun textButton(@StringRes text: Int) = MaterialButton(this).apply {
        setText(text)
        isAllCaps = false
        DesignTypography.applyTo(this, weight = DesignFonts.medium)
        insetTop = 0
        insetBottom = 0
        minHeight = dp(48)
        minWidth = dp(48)
        minimumHeight = dp(48)
        minimumWidth = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        backgroundTintList = ColorStateList.valueOf(android.graphics.Color.TRANSPARENT)
        stateListAnimator = null
        elevation = 0f
        setTextColor(getColorStateList(R.color.auth_text_button))
    }

    private fun params(top: Int) = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    private fun problemMessage(problem: AuthProblem) = when (problem) {
        AuthProblem.NETWORK -> R.string.auth_network_error
        AuthProblem.EMAIL_UNAVAILABLE -> R.string.auth_service_unavailable
        AuthProblem.RATE_LIMITED -> R.string.auth_rate_limited
        AuthProblem.INVALID_CODE -> R.string.auth_invalid_code
        AuthProblem.SERVER -> R.string.auth_server_error
        AuthProblem.STORAGE -> R.string.auth_storage_error
        AuthProblem.NO_WORKSPACE -> R.string.auth_no_workspace
        AuthProblem.ACCOUNT_DISABLED -> R.string.auth_account_disabled
        AuthProblem.GOOGLE_NOT_CONFIGURED -> R.string.auth_google_not_configured
        AuthProblem.GOOGLE_NO_ACCOUNT -> R.string.auth_google_no_account
        AuthProblem.GOOGLE_UNAVAILABLE -> R.string.auth_google_unavailable
        AuthProblem.GOOGLE_REJECTED -> R.string.auth_google_rejected
        AuthProblem.GOOGLE_CONFLICT -> R.string.auth_google_conflict
    }
    private fun countdownText(@PluralsRes resource: Int, seconds: Long) =
        resources.getQuantityString(resource, seconds.toInt(), seconds)
    private fun remaining(deadline: Long) = ((deadline - System.currentTimeMillis() + 999) / 1000).coerceAtLeast(0)
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    // endregion

    private companion object {
        const val EMAIL = 0
        const val CODE = 1
        const val STATUS = 2
        /** The primary button and the space around it, in dp. */
        const val BOTTOM_BAR_HEIGHT = 72
        // Google's sign-in button colours (branding guidelines), not app colours. The light outline is the exception:
        // it uses token_border_primary instead of Google's #747775.
        const val GOOGLE_LIGHT_FILL = 0xFFFFFFFF.toInt()
        const val GOOGLE_LIGHT_TEXT = 0xFF1F1F1F.toInt()
        const val GOOGLE_DARK_FILL = 0xFF131314.toInt()
        const val GOOGLE_DARK_STROKE = 0xFF8E918F.toInt()
        const val GOOGLE_DARK_TEXT = 0xFFE3E3E3.toInt()
    }
}

/** The primary button shrinks slightly while pressed. */
private class PressableButton(context: Context) : MaterialButton(context) {
    // Nullable: the platform constructor may touch pressed state before this class initialises.
    private var scale: ButtonScale? = null

    init {
        scale = ButtonScale(this, action = false)
    }

    override fun setPressed(pressed: Boolean) {
        val changed = pressed != isPressed
        super.setPressed(pressed)
        if (changed) scale?.setPressed(pressed)
    }
}

internal fun TextInputLayout.clearErrorWhenEmailBecomesValid() {
    editText?.doAfterTextChanged {
        if (android.util.Patterns.EMAIL_ADDRESS.matcher(it.toString().trim()).matches()) error = null
    }
}
