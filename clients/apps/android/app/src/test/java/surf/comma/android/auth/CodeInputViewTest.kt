package surf.comma.android.auth

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.view.autofill.AutofillValue
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.widget.FrameLayout
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
import android.animation.ValueAnimator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CodeInputViewTest {
    private lateinit var controller: ActivityController<Activity>
    private lateinit var activity: Activity
    private lateinit var view: CodeInputView
    private val changes = mutableListOf<String>()
    private val completions = mutableListOf<String>()

    @Before fun setUp() {
        controller = Robolectric.buildActivity(Activity::class.java)
        activity = controller.get().apply { setTheme(R.style.Theme_Comma_Auth) }
        controller.create().start().resume().visible()
        view = CodeInputView(activity).apply {
            onCodeChanged = { changes += it }
            onCodeComplete = { completions += it }
        }
        activity.setContentView(FrameLayout(activity).apply { addView(view, FrameLayout.LayoutParams(-1, -2)) })
        ShadowLooper.idleMainLooper()
        view.focusCell(0, showKeyboard = false)
    }

    @After fun tearDown() {
        setAnimatorScale(1f)
        controller.close()
    }

    /** The system "remove animations" switch. */
    private fun setAnimatorScale(scale: Float) {
        ValueAnimator::class.java.getMethod("setDurationScale", Float::class.javaPrimitiveType).invoke(null, scale)
    }

    private val connection by lazy { view.editor.onCreateInputConnection(EditorInfo())!! }

    /** What a keyboard does for a key or a suggestion: commit text over the selection. */
    private fun type(text: String) {
        connection.commitText(text, 1)
    }

    /** The keyboard's delete key. */
    private fun backspace() {
        view.editor.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL))
        view.editor.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL))
    }

    private fun activeCell() = view.cells.indexOfFirst { it.active }

    @Test fun typingFillsCellsInOrderAndMovesTheActiveCell() {
        assertEquals(0, activeCell())
        type("4")
        type("2")
        assertEquals("42", view.code)
        assertEquals(listOf('4', '2', null, null, null, null), view.cells.map { it.digit })
        assertEquals(2, activeCell())
        assertEquals(listOf("4", "42"), changes)
        assertTrue(completions.isEmpty())
    }

    @Test fun onlyDigitsAreAccepted() {
        type("1")
        type("a")
        type(" ")
        type("-")
        assertEquals("1", view.code)
        assertEquals(1, activeCell())
        assertEquals(listOf("1"), changes)
    }

    @Test fun theSixthDigitSubmitsOnce() {
        "123456".forEach { type(it.toString()) }
        assertEquals(listOf("123456"), completions)
        assertEquals(-1, activeCell())
        type("7")
        assertEquals("123456", view.code)
        assertEquals(listOf("123456"), completions)
    }

    @Test fun backspaceReturnsToThePreviousCell() {
        type("1"); type("2"); type("3")
        backspace()
        assertEquals("12", view.code)
        assertEquals(2, activeCell())
        backspace()
        backspace()
        assertEquals("", view.code)
        assertEquals(0, activeCell())
        backspace()
        assertEquals(0, activeCell())
        // Some keyboards delete through the input connection instead of a key event.
        type("8"); type("9")
        connection.deleteSurroundingText(1, 0)
        assertEquals("8", view.code)
        assertEquals(1, activeCell())
    }

    @Test fun backspaceOnAFullCodeClearsTheLastCellThenResubmits() {
        "123456".forEach { type(it.toString()) }
        backspace()
        assertEquals("12345", view.code)
        assertEquals(5, activeCell())
        type("9")
        assertEquals(listOf("123456", "123459"), completions)
    }

    @Test fun tappingAFilledCellSelectsItSoTypingReplacesTheDigit() {
        type("1"); type("2"); type("3")
        view.focusCell(1, showKeyboard = false)
        assertEquals(1, view.editor.selectionStart)
        assertEquals(2, view.editor.selectionEnd)
        assertEquals(1, activeCell())
        type("7")
        assertEquals("173", view.code)
        // The caret moves on and selects the next digit.
        assertEquals(2, activeCell())
    }

    @Test fun tappingPastTheEndGoesToTheFirstEmptyCell() {
        type("1")
        view.focusCell(5, showKeyboard = false)
        assertEquals(1, activeCell())
    }

    @Test fun pastingAMessageTakesTheCodeAndSubmits() {
        type("9")
        view.paste("Your comma code is 123 456. It expires in 10 minutes.")
        assertEquals("123456", view.code)
        assertEquals(listOf("123456"), completions)
    }

    @Test fun pasteFromTheClipboardMenuReplacesTheWholeCode() {
        activity.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("code", "code: 654-321"))
        type("1")
        assertTrue(view.editor.onTextContextMenuItem(android.R.id.paste))
        assertEquals("654321", view.code)
        assertEquals(listOf("654321"), completions)
    }

    @Test fun pastingTextWithoutDigitsChangesNothing() {
        type("1")
        view.paste("hello")
        assertEquals("1", view.code)
        assertEquals(listOf("1"), changes)
    }

    @Test fun partialPasteKeepsTheDigitsWithoutSubmitting() {
        view.paste("12 34")
        assertEquals("1234", view.code)
        assertTrue(completions.isEmpty())
    }

    @Test fun autofillAndKeyboardSuggestionsFillEveryCell() {
        view.editor.autofill(AutofillValue.forText("246810"))
        assertEquals("246810", view.code)
        assertEquals(listOf("246810"), completions)
        view.clear()
        // A keyboard suggestion commits the whole code at the caret in one piece.
        type("Code 135 791")
        assertEquals("135791", view.code)
        assertEquals(listOf("246810", "135791"), completions)
    }

    @Test fun theEditorAsksForOneTimeCodesAndAdigitKeyboard() {
        assertEquals(android.text.InputType.TYPE_CLASS_NUMBER, view.editor.inputType)
        assertTrue(view.editor.autofillHints!!.contains("emailOTPCode"))
        assertFalse(view.editor.isSaveEnabled)
    }

    @Test fun lockedInputKeepsTheCode() {
        "12345".forEach { type(it.toString()) }
        view.locked = true
        type("6")
        view.paste("999999")
        assertEquals("12345", view.code)
        assertTrue(completions.isEmpty())
        view.locked = false
        type("6")
        assertEquals(listOf("123456"), completions)
    }

    @Test fun rejectShakesThenClearsAndReturnsToTheFirstCell() {
        "123456".forEach { type(it.toString()) }
        view.reject()
        assertTrue(view.cells.all { it.invalid })
        assertTrue("The cells shake before the code clears", view.cells[0].translationX != 0f)
        assertEquals("123456", view.code)
        // Keys during the shake are dropped rather than mixed into the rejected code.
        type("9")
        assertEquals("123456", view.code)
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        assertEquals("", view.code)
        assertTrue(view.cells.all { it.digit == null })
        assertEquals(0, activeCell())
        assertTrue(view.editor.isFocused)
        // The error outline stays until the next digit.
        assertTrue(view.cells.all { it.invalid })
        type("5")
        assertTrue(view.cells.none { it.invalid })
        assertEquals(listOf("123456"), completions)
    }

    @Test fun rejectWithAnimationsOffClearsImmediately() {
        setAnimatorScale(0f)
        "123456".forEach { type(it.toString()) }
        view.reject()
        assertEquals("", view.code)
        assertTrue(view.cells.all { it.translationX == 0f })
        assertEquals(0, activeCell())
    }

    @Test fun clearingDoesNotReportAChange() {
        type("1")
        view.clear()
        assertEquals("", view.code)
        assertEquals(listOf("1"), changes)
    }

    @Test fun codeTextExtractsTheCode() {
        assertEquals("123456", CodeText.extract("123456"))
        assertEquals("123456", CodeText.extract("123 456"))
        assertEquals("123456", CodeText.extract("Your code is 123-456, valid for 10 min"))
        assertEquals("987654", CodeText.extract("10 min: 987654"))
        assertEquals("123456", CodeText.extract("1234567"))
        assertEquals("12", CodeText.extract("a1b2"))
        assertEquals("", CodeText.extract("no digits"))
    }
}
