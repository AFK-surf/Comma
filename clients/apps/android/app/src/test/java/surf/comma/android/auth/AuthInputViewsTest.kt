package surf.comma.android.auth

import android.app.Activity
import android.view.LayoutInflater
import android.widget.LinearLayout
import com.google.android.material.button.MaterialButton
import com.google.android.material.shape.MaterialShapeDrawable
import com.google.android.material.textfield.TextInputLayout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import surf.comma.android.R

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AuthInputViewsTest {
    @Test fun debugDiagnosticsWriteOnlyTheSanitizedCategory() {
        ShadowLog.clear()
        NetworkDiagnostics.record(NetworkFailure(NetworkFailureKind.HTTP, 503))
        val entry = ShadowLog.getLogsForTag("NetworkFailure").single()
        assertEquals("HTTP 503", entry.msg)
        assertNull(entry.throwable)
    }

    @Test fun lightInputUsesTheRoundedOutlineAndTokenColors() = checkOutline()
    @Test @Config(qualifiers = "night") fun darkInputUsesTheRoundedOutlineAndTokenColors() = checkOutline()

    private fun checkOutline() {
        Robolectric.buildActivity(Activity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Comma_Auth) }
            controller.create()
            val parent = LinearLayout(activity)
            val box = LayoutInflater.from(activity).inflate(R.layout.auth_text_input, parent, false) as TextInputLayout
            parent.addView(box)
            activity.setContentView(parent)
            val edit = box.editText!!
            assertEquals(TextInputLayout.BOX_BACKGROUND_OUTLINE, box.boxBackgroundMode)
            assertTrue("The outline must replace the EditText underline", edit.background is MaterialShapeDrawable)
            val outline = edit.background as MaterialShapeDrawable
            val radius = 12f * activity.resources.displayMetrics.density
            listOf(box.boxCornerRadiusTopStart, box.boxCornerRadiusTopEnd,
                box.boxCornerRadiusBottomStart, box.boxCornerRadiusBottomEnd).forEach { assertEquals(radius, it, 0.01f) }
            assertEquals(activity.getColor(R.color.token_bg_quaternary), box.boxBackgroundColor)
            edit.requestFocus()
            box.refreshDrawableState()
            assertEquals(activity.getColor(R.color.token_bg_brand_solid), outline.strokeColor!!.defaultColor)
            edit.isFocusable = false
            edit.clearFocus()
            box.refreshDrawableState()
            assertEquals(activity.getColor(R.color.token_border_primary), outline.strokeColor!!.defaultColor)
        }
    }

    @Test fun resendTextChangesToTheDisabledTokenAndBack() {
        Robolectric.buildActivity(Activity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Comma_Auth) }
            controller.create()
            val button = MaterialButton(activity)
            button.setTextColor(activity.getColorStateList(R.color.auth_text_button))
            button.isEnabled = false
            assertEquals(activity.getColor(R.color.token_text_placeholder), button.currentTextColor)
            button.isEnabled = true
            assertEquals(activity.getColor(R.color.token_bg_brand_solid), button.currentTextColor)
        }
    }

    @Test fun correctingAnEmailClearsItsValidationErrorWithoutSubmitting() {
        Robolectric.buildActivity(Activity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Comma_Auth) }
            controller.create()
            val box = LayoutInflater.from(activity).inflate(R.layout.auth_text_input, LinearLayout(activity), false) as TextInputLayout
            box.clearErrorWhenEmailBecomesValid()
            box.error = activity.getString(R.string.auth_invalid_email)
            box.editText!!.setText("invalid")
            assertNotNull(box.error)
            box.editText!!.setText("alice@example.test")
            assertNull(box.error)
        }
    }
}
