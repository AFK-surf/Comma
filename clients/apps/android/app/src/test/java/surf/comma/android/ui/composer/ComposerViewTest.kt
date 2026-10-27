package surf.comma.android.ui.composer

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.graphics.Rect
import android.net.Uri
import android.os.Looper
import android.provider.MediaStore
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.children
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowToast
import org.robolectric.annotation.Config
import surf.comma.android.R

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ComposerViewTest {
    @Test fun `a running reply keeps send available for the next message`() = withComposer { activity, _, composer ->
        val sent = mutableListOf<String>()
        composer.onSend = { text, _ -> sent += text }
        composer.setGenerating(true)
        val send = byDescription(composer, activity.getString(R.string.composer_send))
        assertEquals(View.VISIBLE, send.visibility)
        send.performClick()
        assertTrue("an empty draft sends nothing", sent.isEmpty())
        composer.field.setText("one more thing")
        send.performClick()
        assertEquals(listOf("one more thing"), sent)
        assertEquals("", composer.text)
        assertEquals(View.VISIBLE, send.visibility)
        assertEquals(activity.getString(R.string.composer_send), send.contentDescription)
    }

    @Test fun `pending admission keeps input editable and focused while duplicate sends are blocked`() {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val root = FrameLayout(activity)
            val composer = ComposerView(activity)
            composer.attachTo(root)
            activity.setContentView(root)
            val input = descendants(composer).filterIsInstance<EditText>().single()
            input.requestFocus()
            input.setText("first")
            val send = descendants(composer).single { it.contentDescription == activity.getString(R.string.composer_send) }
            var attempts = 0
            var complete: ((Boolean) -> Unit)? = null
            composer.onSubmit = { _, _, done -> attempts++; complete = done }
            send.performClick()
            assertEquals(1, attempts)
            assertTrue(input.isEnabled)
            assertTrue(input.hasFocus())
            send.performClick()
            assertEquals(1, attempts)
            complete!!(false)
            assertEquals("first", input.text.toString())
            send.performClick()
            assertEquals(2, attempts)
            input.setText("next")
            complete!!(true)
            assertEquals("next", input.text.toString())
            assertTrue(input.hasFocus())
            send.performClick()
            assertEquals(3, attempts)
            complete!!(true)
            assertEquals("", input.text.toString())
            assertTrue(input.isEnabled)
            assertTrue(input.hasFocus())
        }
    }

    @Test fun `plus opens the menu and back, a tap outside or plus again closes it`() = withComposer { activity, root, composer ->
        val menu = menu(root)
        val plus = byDescription(composer, activity.getString(R.string.composer_attach))
        plus.performClick()
        assertTrue(menu.shown)
        assertEquals(View.VISIBLE, menu.visibility)
        assertEquals(root.childCount - 1, root.indexOfChild(menu)) // above everything else
        assertEquals(activity.getString(R.string.composer_attach_close), plus.contentDescription)

        activity.onBackPressedDispatcher.onBackPressed()
        assertFalse(menu.shown)
        assertEquals(activity.getString(R.string.composer_attach), plus.contentDescription)

        plus.performClick()
        menu.performClick() // the transparent layer around the card
        assertFalse(menu.shown)

        plus.performClick()
        composer.dismiss()
        assertFalse(menu.shown)

        plus.performClick()
        plus.performClick()
        assertFalse(menu.shown)
    }

    @Test fun `photos picked in the system picker become draft attachments`() = withComposer { activity, root, composer ->
        val added = mutableListOf<List<Uri>>()
        composer.onAttachmentsAdded = { batch -> added += batch.map { it.uri } }
        composer.systemPhotoLimit = { 100 }
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_photos)).performClick()
        assertFalse("choosing a row closes the menu", menu(root).shown)

        val request = shadowOf(activity).nextStartedActivityForResult
        assertEquals(MediaStore.ACTION_PICK_IMAGES, request.intent.action)
        assertEquals(8, request.intent.getIntExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 0))
        val picked = listOf(Uri.parse("content://media/picker/1"), Uri.parse("content://media/picker/2"))
        val result = Intent().apply {
            clipData = ClipData.newRawUri(null, picked[0]).apply { addItem(ClipData.Item(picked[1])) }
        }
        shadowOf(activity).receiveResult(request.intent, Activity.RESULT_OK, result)

        assertEquals(listOf(picked), added)
        assertEquals(picked, composer.attachments.map { it.uri })
    }

    @Test fun `the picker limit shrinks with the free slots and a full draft disables the menu`() = withComposer { activity, root, composer ->
        composer.systemPhotoLimit = { 100 }
        val menu = menu(root)
        val photos = byDescription(menu, activity.getString(R.string.composer_attach_photos))
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        photos.performClick()
        val first = shadowOf(activity).nextStartedActivityForResult
        val six = (1..6).map { Uri.parse("content://media/picker/$it") }
        shadowOf(activity).receiveResult(first.intent, Activity.RESULT_OK, clip(six))
        assertEquals(6, composer.attachments.size)

        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        photos.performClick()
        val second = shadowOf(activity).nextStartedActivityForResult
        assertEquals(2, second.intent.getIntExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 0))
        shadowOf(activity).receiveResult(second.intent, Activity.RESULT_OK, clip(listOf(Uri.parse("content://a"), Uri.parse("content://b"))))
        assertEquals(8, composer.attachments.size)

        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        assertTrue(descendants(menu).filterIsInstance<android.widget.TextView>()
            .any { it.visibility == View.VISIBLE && it.text == activity.resources.getQuantityString(R.plurals.composer_attach_full, 8, 8) })
        assertFalse(photos.isEnabled)
        photos.performClick()
        assertNull(shadowOf(activity).nextStartedActivityForResult)
    }

    @Test fun `files use the document picker and extra picks past the limit are dropped`() = withComposer { activity, root, composer ->
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_files)).performClick()
        val request = shadowOf(activity).nextStartedActivityForResult
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, request.intent.action)
        assertTrue(request.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        val twelve = (1..12).map { Uri.parse("content://docs/$it") }
        shadowOf(activity).receiveResult(request.intent, Activity.RESULT_OK, clip(twelve))
        assertEquals(twelve.take(8), composer.attachments.map { it.uri })
    }

    @Test fun `the photo picker offers videos too, a question card's only images`() = withComposer { activity, root, composer ->
        composer.systemPhotoLimit = { 100 }
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_photos)).performClick()
        val draft = shadowOf(activity).nextStartedActivityForResult
        assertEquals(MediaStore.ACTION_PICK_IMAGES, draft.intent.action)
        assertNull(draft.intent.type)
        shadowOf(activity).receiveResult(draft.intent, Activity.RESULT_CANCELED, null)

        composer.pickQuestionImages("question", 4)
        assertEquals("image/*", shadowOf(activity).nextStartedActivityForResult.intent.type)
    }

    @Test fun `the file picker takes any file and the core decides which it sends`() = withComposer { activity, root, composer ->
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_files)).performClick()
        val request = shadowOf(activity).nextStartedActivityForResult
        assertArrayEquals(arrayOf("*/*"), request.intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
    }

    @Test fun `a file over the upload limit is not added and a message says so, an image over it is`() = withComposer { activity, root, composer ->
        val folder = java.nio.file.Files.createTempDirectory("picked").toFile()
        try {
            fun sparse(name: String, size: Long) = Uri.fromFile(java.io.File(folder, name).apply {
                java.io.RandomAccessFile(this, "rw").use { it.setLength(size) }
            })
            val limit = 512L * 1024 * 1024
            val video = sparse("clip.mp4", limit + 1)
            val fits = sparse("short.mp4", limit)
            val photo = sparse("photo.jpg", limit + 1)
            byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
            byDescription(menu(root), activity.getString(R.string.composer_attach_files)).performClick()
            val request = shadowOf(activity).nextStartedActivityForResult
            shadowOf(activity).receiveResult(request.intent, Activity.RESULT_OK, clip(listOf(video, fits, photo)))
            assertEquals(activity.getString(R.string.composer_attach_too_large), ShadowToast.getTextOfLatestToast())
            assertEquals(listOf(fits, photo), composer.attachments.map { it.uri })
            assertEquals(listOf("short.mp4", "photo.jpg"), composer.attachments.map { it.file.name })
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test fun `without a camera app nothing is added and a message explains`() = withComposer { activity, root, composer ->
        shadowOf(RuntimeEnvironment.getApplication()).checkActivities(true)
        val added = mutableListOf<Uri>()
        composer.onAttachmentsAdded = { batch -> added += batch.map { it.uri } }
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_camera)).performClick()
        assertEquals(activity.getString(R.string.composer_camera_unavailable), ShadowToast.getTextOfLatestToast())
        assertTrue(added.isEmpty())
        assertTrue(composer.attachments.isEmpty())
    }

    @Test fun `a cancelled picker adds nothing`() = withComposer { activity, root, composer ->
        composer.systemPhotoLimit = { 100 }
        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_photos)).performClick()
        val request = shadowOf(activity).nextStartedActivityForResult
        shadowOf(activity).receiveResult(request.intent, Activity.RESULT_CANCELED, null)
        assertTrue(composer.attachments.isEmpty())
        assertFalse(menu(root).shown)
    }

    @Test fun `a draft longer than one line takes the full width above the buttons`() = withComposer { activity, _, composer ->
        val input = descendants(composer).filterIsInstance<EditText>().single()
        val plus = byDescription(composer, activity.getString(R.string.composer_attach))
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()

        input.setText("short")
        layOut()
        val send = byDescription(composer, activity.getString(R.string.composer_send))
        assertFalse(row.stacked)
        assertSingleRow(row, plus, input, send)

        input.setText("word ".repeat(200))
        layOut()
        assertTrue(row.stacked)
        assertStacked(row, plus, input, send)

        input.setText("short again")
        layOut()
        assertFalse(row.stacked)
        assertSingleRow(row, plus, input, send)

        input.setText("one\ntwo")
        layOut()
        assertTrue("a line break stacks even when each line is short", row.stacked)
        assertStacked(row, plus, input, send)
    }

    @Test fun `clearing a stacked draft restores the single row`() = withComposer { activity, _, composer ->
        val input = descendants(composer).filterIsInstance<EditText>().single()
        val plus = byDescription(composer, activity.getString(R.string.composer_attach))
        // Described by whether this build has voice credentials; either way it is the same button.
        val micLabels = setOf(R.string.composer_mic, R.string.composer_voice_unavailable).map(activity::getString)
        val mic = descendants(composer).single { it.contentDescription in micLabels }
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        layOut()
        val restingHeight = row.height

        input.setText("one\ntwo\nthree")
        layOut()
        assertTrue(row.stacked)
        assertTrue(row.height > restingHeight)

        input.setText("")
        layOut()
        assertFalse(row.stacked)
        assertEquals(restingHeight, row.height)
        assertSingleRow(row, plus, input, mic)
    }

    @Test fun `sending a stacked draft restores the single row`() = withComposer { activity, _, composer ->
        val input = descendants(composer).filterIsInstance<EditText>().single()
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        composer.onSend = { _, _ -> }
        input.setText("one\ntwo")
        layOut()
        assertTrue(row.stacked)
        byDescription(composer, activity.getString(R.string.composer_send)).performClick()
        layOut()
        assertEquals("", input.text.toString())
        assertFalse(row.stacked)
    }

    @Test fun `the row decides from the width between the buttons`() {
        val perChar: (CharSequence) -> Float = { it.length * 10f }
        assertFalse(ComposerRow.needsOwnRow("", 100, perChar))
        assertFalse(ComposerRow.needsOwnRow("0123456789", 100, perChar))
        assertTrue(ComposerRow.needsOwnRow("01234567890", 100, perChar))
        assertTrue(ComposerRow.needsOwnRow("a\nb", 100, perChar))
        assertFalse("not measured yet", ComposerRow.needsOwnRow("01234567890", 0, perChar))
        // A long draft is settled by its head alone.
        val measured = mutableListOf<Int>()
        assertTrue(ComposerRow.needsOwnRow("x".repeat(5000), 100) { measured += it.length; it.length * 10f })
        assertEquals(listOf(128), measured)
    }

    /** Buttons and field share one row: the field sits between them. */
    private fun assertSingleRow(row: ComposerRow, plus: View, input: View, trailing: View) {
        val plusBox = boxIn(row, plus)
        val inputBox = boxIn(row, input)
        val trailingBox = boxIn(row, trailing)
        assertTrue("field starts after +", inputBox.left >= plusBox.right)
        assertTrue("field ends before the button", inputBox.right <= trailingBox.left)
        assertTrue("+ is beside the field", plusBox.top >= inputBox.top && plusBox.bottom <= inputBox.bottom)
        assertTrue("the button is beside the field", trailingBox.top >= inputBox.top && trailingBox.bottom <= inputBox.bottom)
    }

    /** The field spans the row on top; + and the button hold the bottom corners under it. */
    private fun assertStacked(row: ComposerRow, plus: View, input: View, trailing: View) {
        val plusBox = boxIn(row, plus)
        val inputBox = boxIn(row, input)
        val trailingBox = boxIn(row, trailing)
        assertTrue("field reaches over +", inputBox.left < plusBox.right)
        assertTrue("field reaches over the button", inputBox.right > trailingBox.left)
        assertTrue("+ is under the field", plusBox.top >= inputBox.bottom)
        assertTrue("the button is under the field", trailingBox.top >= inputBox.bottom)
        assertTrue("+ keeps the bottom-left corner", plusBox.left < row.width / 2 && plusBox.bottom <= row.height)
        assertTrue("the button keeps the bottom-right corner", trailingBox.right > row.width / 2 && trailingBox.bottom <= row.height)
        assertEquals(plusBox.centerY(), trailingBox.centerY())
    }

    /** Laid-out bounds of [view] inside [ancestor], ignoring any running travel. */
    private fun boxIn(ancestor: View, view: View): Rect {
        val box = Rect(0, 0, view.width, view.height)
        var current = view
        while (current !== ancestor) {
            box.offset(current.left, current.top)
            current = current.parent as View
        }
        return box
    }

    private fun layOut() = shadowOf(Looper.getMainLooper()).idle()

    private fun clip(uris: List<Uri>) = Intent().apply {
        clipData = ClipData.newRawUri(null, uris.first()).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
    }

    @Test fun `the composer sits 20 dp above the bottom inset, 24 dp from the edges`() = withComposer { activity, root, composer ->
        val density = activity.resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val navigation = dp(24)
        // Both full-screen chat and hosts that already reserve the navigation area.
        for (reserved in listOf(0, navigation)) {
            root.setPadding(0, 0, 0, reserved)
            for (keyboard in listOf(0, dp(300), 0)) {
                ViewCompat.dispatchApplyWindowInsets(composer, WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, navigation))
                    .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, keyboard))
                    .build())
                root.measure(View.MeasureSpec.makeMeasureSpec(dp(400), View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(dp(800), View.MeasureSpec.EXACTLY))
                root.layout(0, 0, dp(400), dp(800))
                val pill = composer.getChildAt(0)
                val visibleBottom = composer.y + pill.bottom
                assertEquals("20 dp above navigation or the keyboard, counted once",
                    (root.height - maxOf(navigation, keyboard) - dp(20)).toFloat(), visibleBottom, 0f)
                assertEquals("24 dp gutter", dp(24), pill.left)
                assertEquals(dp(24), composer.width - pill.right)
            }
        }
    }

    @Test fun `the composer is a raised card in the composer colour`() = withComposer { activity, _, composer ->
        val pill = composer.getChildAt(0) as ComposerPill
        assertEquals(activity.getColor(R.color.token_composer_bg), (pill.background as android.graphics.drawable.GradientDrawable).color?.defaultColor)
        assertEquals(0xFFFFFFFF.toInt(), activity.getColor(R.color.token_composer_bg))
        assertTrue("lifted off the page", pill.elevation > 0f)
        assertFalse("the shadow is not cut at the pill", composer.clipToPadding)
    }

    @Test fun `on the dark page the composer is a lighter grey card with a visible edge`() {
        RuntimeEnvironment.setQualifiers("+night")
        withComposer { activity, _, composer ->
            val pill = composer.getChildAt(0) as ComposerPill
            assertEquals(0xFF303030.toInt(), activity.getColor(R.color.token_composer_bg))
            assertEquals(0xFF4F4F4F.toInt(), activity.getColor(R.color.token_composer_border))
            assertEquals(0xFF303030.toInt(), (pill.background as android.graphics.drawable.GradientDrawable).color?.defaultColor)
        }
    }

    private fun withComposer(block: (ComponentActivity, FrameLayout, ComposerView) -> Unit) {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val root = FrameLayout(activity)
            val composer = ComposerView(activity)
            composer.attachTo(root)
            activity.setContentView(root)
            block(activity, root, composer)
        }
    }

    private fun menu(root: FrameLayout): AttachMenuView =
        root.children.filterIsInstance<AttachMenuView>().single()

    private fun byDescription(view: View, description: String): View =
        descendants(view).single { it.contentDescription == description }

    private fun descendants(view: View): Sequence<View> = sequence {
        yield(view)
        if (view is ViewGroup) view.children.forEach { yieldAll(descendants(it)) }
    }
}
