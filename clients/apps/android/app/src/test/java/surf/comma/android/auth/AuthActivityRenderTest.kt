package surf.comma.android.auth

import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R

/** Drives [AuthActivity.render] with explicit states; the repository itself is not exercised. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AuthActivityRenderTest {
    private lateinit var controller: ActivityController<AuthActivity>
    private lateinit var activity: AuthActivity
    private val codeLogin = AuthState.Login(email = "alice@example.test", challengeId = "challenge-1")

    @Before fun setUp() {
        controller = Robolectric.buildActivity(AuthActivity::class.java).setup()
        activity = controller.get()
        // Let the repository settle, then stop collecting so only the test drives render().
        ShadowLooper.idleMainLooper()
        controller.pause().stop()
        ShadowLooper.idleMainLooper()
    }

    @After fun tearDown() = controller.close()

    private val primary get() = activity.findViewById<TextView>(R.id.auth_primary)
    private val email get() = activity.findViewById<TextView>(R.id.auth_email)
    private val code get() = activity.findViewById<CodeEditText>(R.id.auth_code)

    /** Text of every view a person can currently see, excluding pages that have slid away. */
    private fun visibleTexts(): List<String> {
        // Let page and message fades finish.
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        val out = mutableListOf<String>()
        fun walk(view: View) {
            if (view.visibility != View.VISIBLE || view.alpha == 0f) return
            if (view is TextView && view.text.isNotEmpty()) out += view.text.toString()
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(activity.window.decorView)
        return out
    }

    private fun type(text: String) {
        code.onCreateInputConnection(android.view.inputmethod.EditorInfo())!!.commitText(text, 1)
    }

    @Test fun emailStepShowsTheWelcomeAndWaitsForAnAddress() {
        activity.render(AuthState.Login())
        assertTrue(visibleTexts().contains(activity.getString(R.string.auth_welcome_title)))
        assertEquals(activity.getString(R.string.auth_continue_email), primary.text.toString())
        assertFalse(primary.isEnabled)
        email.text = "alice@example.test"
        assertTrue(primary.isEnabled)
    }

    @Test fun googleComesFirstThenOrThenEmail() {
        activity.render(AuthState.Login())
        val texts = visibleTexts()
        val google = texts.indexOf(activity.getString(R.string.auth_continue_google))
        val or = texts.indexOf(activity.getString(R.string.auth_or))
        val emailHint = texts.indexOf(activity.getString(R.string.auth_email))
        assertTrue("$texts", google >= 0 && or > google && (emailHint < 0 || emailHint > or))
        val button = activity.findViewById<com.google.android.material.button.MaterialButton>(R.id.auth_google)
        assertTrue(button.isClickable)
        assertNull("the G keeps Google's colours", button.iconTint)
        assertEquals("a soft light-mode outline", activity.getColor(R.color.token_border_primary), button.strokeColor!!.defaultColor)
        val location = IntArray(2).also(button::getLocationOnScreen)[1]
        val emailTop = IntArray(2).also(email::getLocationOnScreen)[1]
        assertTrue(location < emailTop)
    }

    @Test fun googleBusyShowsASpinnerAndIgnoresTaps() {
        activity.render(AuthState.Login())
        email.text = "alice@example.test"
        activity.render(AuthState.Login(email = "alice@example.test", googleBusy = true))
        val button = activity.findViewById<com.google.android.material.button.MaterialButton>(R.id.auth_google)
        assertEquals("", button.text.toString())
        assertFalse(button.isClickable)
        assertEquals(activity.getString(R.string.auth_google_busy), button.contentDescription)
        val spinner = (button.parent as ViewGroup).getChildAt(1)
        assertEquals(View.VISIBLE, spinner.visibility)
        assertFalse("email waits for Google", primary.isEnabled)
        activity.render(AuthState.Login(email = "alice@example.test"))
        assertEquals(activity.getString(R.string.auth_continue_google), button.text.toString())
        assertTrue(button.isClickable)
        assertEquals(View.GONE, spinner.visibility)
        assertTrue(primary.isEnabled)
    }

    @Test fun googleProblemsShowUnderTheButtonAndEmailStaysUsable() {
        activity.render(AuthState.Login())
        email.text = "alice@example.test"
        AuthProblem.entries.filter { it.name.startsWith("GOOGLE_") || it == AuthProblem.ACCOUNT_DISABLED }.forEach { problem ->
            activity.render(AuthState.Login(email = "alice@example.test", googleProblem = problem))
            assertTrue(problem.name, visibleTexts().any { it.isNotBlank() && it !in listOf(
                activity.getString(R.string.auth_continue_google), activity.getString(R.string.auth_or)) &&
                (it.contains("Google") || it == activity.getString(R.string.auth_account_disabled)) })
            assertTrue(primary.isEnabled)
        }
    }

    @Test fun googleLinkCodeStepSaysWhyAndHasNoResend() {
        activity.render(AuthState.Login())
        activity.render(AuthState.Login("alice@example.test", "link-1", linkingGoogle = true))
        val texts = visibleTexts()
        assertTrue(texts.contains(activity.getString(R.string.auth_google_link_sent_to)))
        assertTrue(texts.contains("alice@example.test"))
        assertTrue(texts.contains(activity.getString(R.string.auth_back)))
        assertFalse(texts.contains(activity.getString(R.string.auth_resend)))
        assertEquals("the Google address is not put in the email field", "", email.text.toString())
    }

    @Test fun codeStepShowsTheAddressAndTakesFocusFromTheEmailField() {
        activity.render(AuthState.Login())
        email.requestFocus()
        activity.render(codeLogin)
        assertTrue(visibleTexts().contains("alice@example.test"))
        assertTrue(visibleTexts().contains(activity.getString(R.string.auth_check_email_title)))
        // Focus moves straight from one editor to the other, so the keyboard never closes.
        assertTrue(code.isFocused)
        assertFalse(primary.isEnabled)
        type("123456".take(5))
        assertFalse(primary.isEnabled)
    }

    @Test fun aRejectedCodeShowsTheErrorUntilTheNextDigit() {
        activity.render(AuthState.Login())
        activity.render(codeLogin)
        activity.render(codeLogin.copy(busy = true))
        activity.render(codeLogin.copy(problem = AuthProblem.INVALID_CODE))
        val message = activity.getString(R.string.auth_invalid_code)
        assertTrue(visibleTexts().contains(message))
        activity.codeInput.cells.forEach { assertTrue(it.invalid) }
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        assertEquals("", activity.codeInput.code)
        // The emptied cells cannot be submitted, but the error stays until the next digit.
        assertFalse(primary.isEnabled)
        assertTrue(visibleTexts().contains(message))
        type("4")
        assertFalse(visibleTexts().contains(message))
        activity.codeInput.cells.forEach { assertFalse(it.invalid) }
    }

    @Test fun aNetworkFailureKeepsTheCodeSoSignInCanBeRetried() {
        activity.render(AuthState.Login())
        activity.render(codeLogin)
        type("123456")
        activity.render(codeLogin.copy(busy = true))
        assertFalse("Busy shows progress instead of a label", primary.text.isNotEmpty())
        activity.render(codeLogin.copy(problem = AuthProblem.NETWORK))
        assertEquals("123456", activity.codeInput.code)
        assertTrue(visibleTexts().contains(activity.getString(R.string.auth_network_error)))
        assertTrue(primary.isEnabled)
        assertEquals(activity.getString(R.string.auth_login), primary.text.toString())
    }

    @Test fun anEmailProblemDisappearsOnceTheAddressIsEdited() {
        activity.render(AuthState.Login())
        email.text = "alice@example.test"
        activity.render(AuthState.Login(email = "alice@example.test", problem = AuthProblem.NETWORK))
        val message = activity.getString(R.string.auth_network_error)
        assertTrue(visibleTexts().contains(message))
        email.text = "alice@example.tes"
        assertFalse(visibleTexts().contains(message))
    }

    @Test fun editingTheAddressKeepsWhatWasTyped() {
        activity.render(AuthState.Login())
        email.text = "alice@example.test"
        activity.render(codeLogin)
        activity.render(AuthState.Login())
        assertEquals("alice@example.test", email.text.toString())
        assertTrue(email.isFocused)
    }

    @Test fun signingOutClearsTheAddress() {
        activity.render(AuthState.Login())
        email.text = "alice@example.test"
        activity.render(AuthState.Connected(Account("a", "alice@example.test", null, "active"),
            WorkspaceSelection(Workspace("w", "g", "Team"), "chat-1")))
        assertTrue(visibleTexts().contains(activity.getString(R.string.auth_connected, "Team")))
        assertTrue(visibleTexts().contains(activity.getString(R.string.auth_logout)))
        activity.render(AuthState.Login())
        assertEquals("", email.text.toString())
    }

    @Test fun storageFailureOffersRetryAndSwitchAccount() {
        activity.render(AuthState.Retry(AuthProblem.STORAGE))
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        val texts = visibleTexts()
        assertTrue(texts.contains(activity.getString(R.string.auth_storage_title)))
        assertTrue(texts.contains(activity.getString(R.string.auth_storage_error)))
        assertTrue(texts.contains(activity.getString(R.string.auth_switch_account)))
        assertEquals(activity.getString(R.string.auth_retry), activity.findViewById<TextView>(R.id.connection_error_retry).text.toString())
        assertTrue(activity.findViewById<TextView>(R.id.connection_error_retry).isClickable)
    }

    @Test fun networkRetryPageUsesTheSharedReasonAndKeepsProgressInPlace() {
        activity.render(AuthState.Retry(AuthProblem.NETWORK))
        val texts = visibleTexts()
        assertTrue(texts.contains(activity.getString(R.string.connection_unreachable_title)) ||
            texts.contains(activity.getString(R.string.connection_offline_title)))
        assertTrue(texts.contains(activity.getString(R.string.auth_retry)))
        activity.render(AuthState.Connecting(ConnectionStep.SESSION))
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.connection_error_page).visibility)
        assertTrue(visibleTexts().contains(activity.getString(R.string.connection_retrying)))
        assertFalse(activity.findViewById<View>(R.id.connection_error_retry).isClickable)
        activity.render(AuthState.Login())
        // The page fades out before it goes.
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.connection_error_page).visibility)
    }

    @Test fun connectingHidesTheBottomAction() {
        activity.render(AuthState.Login())
        activity.render(AuthState.Connecting(ConnectionStep.WORKSPACE))
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        assertFalse(visibleTexts().contains(activity.getString(R.string.auth_login)))
        assertTrue(visibleTexts().contains(activity.getString(R.string.auth_connecting)))
    }
}
