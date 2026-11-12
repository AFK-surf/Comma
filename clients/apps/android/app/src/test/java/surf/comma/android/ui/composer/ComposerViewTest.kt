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
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w400dp-h800dp")
class ComposerViewTest {
    @Test fun `a physical keyboard's Tab goes to its hook while the field has focus`() = withComposer { _, _, composer ->
        var taken = 0
        composer.onTabKey = { taken++; true }
        fun press(meta: Int = 0) = composer.dispatchKeyEvent(android.view.KeyEvent(0, 0, android.view.KeyEvent.ACTION_DOWN,
            android.view.KeyEvent.KEYCODE_TAB, 0, meta))
        composer.field.requestFocus()
        assertTrue(press())
        assertEquals(1, taken)
        press(android.view.KeyEvent.META_SHIFT_ON)
        assertEquals("Shift-Tab is not for the hook", 1, taken)
        composer.field.clearFocus()
        press()
        assertEquals("without focus in the field the hook hears nothing", 1, taken)
    }

    @Test fun `failed and active uploads give different send guidance`() = withComposer { activity, _, composer ->
        val attachment = ComposerAttachment("failed", Uri.EMPTY,
            surf.comma.android.media.PickedFile("photo.png", "image/png", 10))
        val send = byDescription(composer, activity.getString(R.string.composer_send))
        composer.showAttachments(listOf(ShownAttachment(attachment, AttachmentUploadState.Uploading())))
        send.performClick()
        assertEquals(activity.getString(R.string.composer_uploads_pending), ShadowToast.getTextOfLatestToast())
        composer.setAttachmentState(attachment.id, AttachmentUploadState.Failed)
        send.performClick()
        assertEquals(activity.getString(R.string.composer_uploads_failed), ShadowToast.getTextOfLatestToast())
        assertEquals(1, composer.attachments.size)
    }

    @Test fun `an empty draft keeps send in place but inert until there is something to send`() = withComposer { activity, _, composer ->
        val sent = mutableListOf<String>()
        composer.onSend = { text, _ -> sent += text }
        val send = byDescription(composer, activity.getString(R.string.composer_send))
        assertEquals(View.VISIBLE, send.visibility)
        assertFalse("an empty draft has nothing to send", send.isEnabled)
        composer.field.setText("   ")
        assertFalse("whitespace alone is not a message", send.isEnabled)
        composer.field.setText("one more thing")
        assertTrue(send.isEnabled)
        send.performClick()
        assertEquals(listOf("one more thing"), sent)
        assertEquals("", composer.text)
        assertEquals(View.VISIBLE, send.visibility)
        assertFalse(send.isEnabled)
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
        composer.field.clearFocus()
        layOut()
        assertTrue("attachments keep the card open", descendants(composer).filterIsInstance<ComposerRow>().single().stacked)
        assertEquals((12 * activity.resources.displayMetrics.density).toInt(), composer.field.paddingTop)
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

    @Test fun `files picked with the same name are numbered in the draft`() = withComposer { activity, root, composer ->
        val folders = List(3) { java.nio.file.Files.createTempDirectory("picked").toFile() }
        try {
            val uris = folders.map { Uri.fromFile(java.io.File(it, "clip.mp4").apply { writeBytes(byteArrayOf(1)) }) }
            byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
            byDescription(menu(root), activity.getString(R.string.composer_attach_files)).performClick()
            val request = shadowOf(activity).nextStartedActivityForResult
            shadowOf(activity).receiveResult(request.intent, Activity.RESULT_OK, clip(uris))
            assertEquals(listOf("clip.mp4", "clip-2.mp4", "clip-3.mp4"), composer.attachments.map { it.file.name })
        } finally {
            folders.forEach { it.deleteRecursively() }
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

    @Test fun `every picker and the camera report the pick until they answer, with or without a file`() = withComposer { activity, root, composer ->
        val picking = mutableListOf<Boolean>()
        composer.onPicking = { picking += it }
        fun entry(description: Int, photoLimit: Int = 100): () -> Unit = {
            composer.systemPhotoLimit = { photoLimit }
            byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
            byDescription(menu(root), activity.getString(description)).performClick()
        }
        val opens = listOf(
            entry(R.string.composer_attach_files), entry(R.string.composer_attach_photos),
            entry(R.string.composer_attach_photos, photoLimit = 1), entry(R.string.composer_attach_camera),
            { composer.pickQuestionImages("question", 4) }, { composer.pickQuestionImages("question", 1) },
        )
        for (open in opens) {
            open()
            assertEquals(listOf(true), picking)
            val request = shadowOf(activity).nextStartedActivityForResult
            shadowOf(activity).receiveResult(request.intent, Activity.RESULT_CANCELED, null)
            assertEquals("${request.intent.action} answered nothing", listOf(true, false), picking)
            picking.clear()
        }
        entry(R.string.composer_attach_files)()
        val request = shadowOf(activity).nextStartedActivityForResult
        shadowOf(activity).receiveResult(request.intent, Activity.RESULT_OK, clip(listOf(Uri.parse("content://docs/1"))))
        assertEquals(listOf(true, false), picking)
        assertEquals(1, composer.attachments.size)
    }

    @Test fun `the pick ends when the app comes back without an answer, or when the composer leaves its window`() {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val root = FrameLayout(activity)
            val composer = ComposerView(activity)
            composer.attachTo(root)
            activity.setContentView(root)
            val picking = mutableListOf<Boolean>()
            composer.onPicking = { picking += it }
            fun pickFiles() {
                byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
                byDescription(menu(root), activity.getString(R.string.composer_attach_files)).performClick()
            }

            pickFiles()
            controller.pause().stop()
            assertEquals("the picker is over the app", listOf(true), picking)
            // Back from a camera in a task of its own, say, with the camera not done.
            controller.restart().resume()
            assertEquals(listOf(true, false), picking)

            pickFiles()
            controller.pause().stop().destroy()
            assertEquals("its answer goes to the next activity's composer", listOf(true, false, true, false), picking)
        }
    }

    @Test fun `focus stacks even a short draft and clearing keeps the focused card open`() = withComposer { activity, _, composer ->
        val input = composer.field
        val plus = byDescription(composer, activity.getString(R.string.composer_attach))
        val send = byDescription(composer, activity.getString(R.string.composer_send))
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        input.clearFocus()
        layOut()
        assertFalse(row.stacked)
        input.requestFocus()
        input.setText("short")
        layOut()
        assertTrue(row.stacked)
        assertStacked(row, plus, input, send)
        input.setText("")
        layOut()
        assertTrue(row.stacked)
        input.clearFocus()
        layOut()
        assertFalse(row.stacked)
        assertSingleRow(row, plus, input, send)
    }

    @Test fun `sending a stacked draft keeps the focused card ready for another message`() = withComposer { activity, _, composer ->
        val input = composer.field
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        composer.onSend = { _, _ -> }
        input.requestFocus()
        input.setText("one\ntwo")
        layOut()
        assertTrue(row.stacked)
        byDescription(composer, activity.getString(R.string.composer_send)).performClick()
        layOut()
        assertEquals("", input.text.toString())
        assertTrue(input.hasFocus())
        assertTrue(row.stacked)
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

    @Test fun `the composer sits 16 dp above the keyboard and 8 dp above navigation`() = withComposer { activity, root, composer ->
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
                val gap = if (keyboard > navigation) dp(16) else dp(8)
                assertEquals("bottom spacing is counted once, including host padding",
                    (root.height - maxOf(navigation, keyboard) - gap).toFloat(), visibleBottom, 0f)
                assertEquals("12 dp gutter", dp(12), pill.left)
                assertEquals(dp(12), composer.width - pill.right)
            }
        }
    }

    @Test fun `a physical keyboard's Return sends and keeps focus, Shift- or Alt-Return breaks the line`() = withComposer { _, _, composer ->
        val sent = mutableListOf<String>()
        composer.onSend = { text, _ -> sent += text }
        val field = composer.field
        field.requestFocus()
        fun press(meta: Int = 0, soft: Boolean = false) {
            val deviceId = if (soft) android.view.KeyCharacterMap.VIRTUAL_KEYBOARD else 1
            val flags = if (soft) android.view.KeyEvent.FLAG_SOFT_KEYBOARD else 0
            for (action in listOf(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.ACTION_UP)) {
                field.dispatchKeyEvent(android.view.KeyEvent(0, 0, action, android.view.KeyEvent.KEYCODE_ENTER, 0, meta,
                    deviceId, 0, flags))
            }
        }
        field.setText("hello world")
        field.setSelection(5)
        press(android.view.KeyEvent.META_SHIFT_ON or android.view.KeyEvent.META_SHIFT_LEFT_ON)
        assertEquals("hello\n world", field.text.toString())
        assertEquals(6, field.selectionStart)
        field.setSelection(6, field.text.length)
        press(android.view.KeyEvent.META_ALT_ON or android.view.KeyEvent.META_ALT_LEFT_ON)
        assertEquals("A selection is replaced", "hello\n\n", field.text.toString())
        assertEquals(7, field.selectionStart)
        assertTrue(sent.isEmpty())

        field.setText("ship it")
        press()
        assertEquals(listOf("ship it"), sent)
        assertEquals("", field.text.toString())
        assertTrue("the field keeps focus to type the next message", field.hasFocus())

        field.setText("soft")
        press(soft = true)
        assertEquals("a software keyboard's Return does not send", listOf("ship it"), sent)
    }

    @Test fun `restoring focus to the field does not request the keyboard`()= withComposer { activity, _, composer ->
        composer.dismiss()
        composer.field.requestFocus()
        layOut()
        val keyboard = shadowOf(activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java))
        assertFalse(keyboard.isSoftInputVisible)
    }

    @Test fun `an explicit edit request opens the keyboard even if the field already has focus`() = withComposer { activity, _, composer ->
        composer.dismiss()
        composer.field.requestFocus()
        composer.focusInput()
        layOut()
        val keyboard = shadowOf(activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java))
        assertTrue(keyboard.isSoftInputVisible)
    }

    @Test fun `dismiss cancels a pending keyboard request and keeps the draft`() = withComposer { activity, _, composer ->
        composer.field.setText("unfinished draft")
        composer.focusInput()
        composer.dismiss()
        layOut()
        val keyboard = shadowOf(activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java))
        assertFalse(keyboard.isSoftInputVisible)
        assertFalse(composer.field.hasFocus())
        assertEquals("unfinished draft", composer.text)
    }

    @Test fun `the composer keeps its surface colour without platform elevation`() = withComposer { activity, _, composer ->
        val pill = composer.getChildAt(0) as ComposerPill
        assertEquals(activity.getColor(R.color.token_composer_bg), ((pill.background as android.graphics.drawable.InsetDrawable).drawable as android.graphics.drawable.GradientDrawable).color?.defaultColor)
        assertEquals(0xFFFFFFFF.toInt(), activity.getColor(R.color.token_composer_bg))
        assertEquals("custom shadow replaces platform elevation", 0f, pill.elevation, 0f)
        assertFalse("the shadow is not cut at the pill", composer.clipToPadding)
    }

    @Test fun `on the dark page the composer is a lighter grey card with a visible edge`() {
        RuntimeEnvironment.setQualifiers("+night")
        withComposer { activity, _, composer ->
            val pill = composer.getChildAt(0) as ComposerPill
            assertEquals(0xFF303030.toInt(), activity.getColor(R.color.token_composer_bg))
            assertEquals(0xFF4F4F4F.toInt(), activity.getColor(R.color.token_composer_border))
            assertEquals(0xFF303030.toInt(), ((pill.background as android.graphics.drawable.InsetDrawable).drawable as android.graphics.drawable.GradientDrawable).color?.defaultColor)
        }
    }

    @Test fun `collapsed composer matches the separate 44 dp plus and 22 dp field radius`() = withComposer { activity, root, composer ->
        val density = activity.resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        composer.field.clearFocus()
        root.measure(View.MeasureSpec.makeMeasureSpec(dp(400), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(dp(800), View.MeasureSpec.EXACTLY))
        root.layout(0, 0, dp(400), dp(800))
        val pill = composer.getChildAt(0)
        val plus = byDescription(composer, activity.getString(R.string.composer_attach)) as android.widget.ImageView
        val send = byDescription(composer, activity.getString(R.string.composer_send)) as android.widget.ImageView
        assertEquals("resting height", dp(44), pill.height)
        val outline = android.graphics.Outline()
        pill.outlineProvider.getOutline(pill, outline)
        val surface = Rect()
        assertTrue(outline.getRect(surface))
        assertEquals(Rect(dp(52), 0, pill.width, dp(44)), surface)
        assertEquals(dp(22).toFloat(), outline.radius, 0f)
        val plusBox = boxIn(pill, plus)
        assertEquals(Rect(0, 0, dp(44), dp(44)), plusBox)
        assertEquals(dp(22), plus.width - plus.paddingLeft - plus.paddingRight)
        assertEquals("8 dp gap between surfaces", dp(8), surface.left - plusBox.right)
        assertEquals("placeholder starts 16 dp inside field", dp(68), boxIn(pill, composer.field).left + composer.field.paddingLeft)
        assertEquals(0xFFB6B8BB.toInt(), composer.field.currentHintTextColor)
        assertEquals("send touch target", dp(44), send.width)
        send.background.setBounds(0, 0, send.width, send.height)
        val scaledCircle = ((send.background as android.graphics.drawable.RippleDrawable).getDrawable(0) as android.graphics.drawable.InsetDrawable).drawable as android.graphics.drawable.DrawableWrapper
        val circle = scaledCircle.drawable!!
        assertEquals("disabled circle scale", 9200, scaledCircle.level)
        assertEquals(0xFFB6B8BB.toInt(), (circle as android.graphics.drawable.GradientDrawable).color!!.defaultColor)
        composer.field.setText("ready")
        shadowOf(Looper.getMainLooper()).runToEndOfTasks()
        assertEquals(10000, scaledCircle.level)
        assertEquals(0xFF205BFF.toInt(), circle.color!!.defaultColor)
        assertEquals("send circle diameter", dp(32), circle.bounds.width())
        assertEquals("send circle right inset", dp(6), send.width - circle.bounds.right)
        assertEquals("arrow size", dp(18), send.width - send.paddingLeft - send.paddingRight)
    }

    @Test fun `focused composer has 24 dp corners and 14 dp text gutters above a 44 dp button row`() = withComposer { activity, root, composer ->
        val density = activity.resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        composer.field.requestFocus()
        composer.field.setText("one\ntwo")
        root.measure(View.MeasureSpec.makeMeasureSpec(dp(400), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(dp(800), View.MeasureSpec.EXACTLY))
        root.layout(0, 0, dp(400), dp(800))
        val pill = composer.getChildAt(0)
        val outline = android.graphics.Outline()
        pill.outlineProvider.getOutline(pill, outline)
        assertEquals(dp(24).toFloat(), outline.radius, 0f)
        val surface = Rect()
        outline.getRect(surface)
        assertEquals(0, surface.left)
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        val text = boxIn(row, composer.field)
        assertEquals(dp(14), text.left)
        assertEquals(dp(14), row.width - text.right)
        assertEquals(dp(16), composer.field.paddingTop)
        assertEquals(dp(10), composer.field.paddingBottom)
        assertEquals(dp(44), row.height - text.bottom)
        assertEquals(6, composer.field.maxLines)
    }

    @Test fun `night placeholder keeps the shared iOS colour`() {
        RuntimeEnvironment.setQualifiers("+night")
        withComposer { _, _, composer -> assertEquals(0xFF7E8187.toInt(), composer.field.currentHintTextColor) }
    }

    @Test @Config(qualifiers = "w800dp-h400dp-land") fun `compact height keeps two text lines between the corner buttons`() = withComposer { activity, root, composer ->
        composer.field.requestFocus()
        composer.field.setText("one\ntwo\nthree")
        root.measure(View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 800, 400)
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        assertFalse(row.stacked)
        assertEquals(2, composer.field.maxLines)
        assertSingleRow(row, byDescription(composer, activity.getString(R.string.composer_attach)),
            composer.field, byDescription(composer, activity.getString(R.string.composer_send)))
    }

    @Test @Config(qualifiers = "w800dp-h400dp-land") fun `landscape attachments allow six lines while the inline field keeps two`() = withComposer { activity, root, composer ->
        val input = composer.field
        input.requestFocus()
        input.setText("one\ntwo\nthree\nfour")
        fun measure() {
            root.measure(View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, 800, 400)
        }
        measure()
        val row = descendants(composer).filterIsInstance<ComposerRow>().single()
        assertFalse(row.stacked)
        assertEquals("inline landscape field", 2, input.maxLines)

        byDescription(composer, activity.getString(R.string.composer_attach)).performClick()
        byDescription(menu(root), activity.getString(R.string.composer_attach_photos)).performClick()
        val request = shadowOf(activity).nextStartedActivityForResult
        val picked = Uri.parse("content://media/picker/1")
        shadowOf(activity).receiveResult(request.intent, Activity.RESULT_OK, clip(listOf(picked)))
        measure()

        assertEquals(listOf(picked), composer.attachments.map { it.uri })
        assertTrue(row.stacked)
        assertEquals("stacked landscape field", 6, input.maxLines)
        val textHeight = input.height - input.compoundPaddingTop - input.compoundPaddingBottom
        assertTrue("more than two text lines are visible", textHeight > 2 * input.lineHeight)
    }

    @Test @Config(qualifiers = "w1200dp-h800dp-land") fun `tall landscape windows keep a stacked six line composer`() = withComposer { _, root, composer ->
        composer.field.requestFocus()
        root.measure(View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 1200, 800)
        assertTrue(descendants(composer).filterIsInstance<ComposerRow>().single().stacked)
        assertEquals(6, composer.field.maxLines)
    }

    @Test fun `surface shadow stays six percent with a downward soft falloff before and after focus`() {
        for (focused in listOf(false, true)) withComposer { activity, root, composer ->
            if (focused) composer.field.requestFocus() else composer.field.clearFocus()
            root.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, 400, 800)
            val bitmap = android.graphics.Bitmap.createBitmap(composer.width, composer.height, android.graphics.Bitmap.Config.ARGB_8888)
            composer.draw(android.graphics.Canvas(bitmap))
            val pill = composer.getChildAt(0)
            val x = pill.right - 80
            fun alpha(y: Int) = android.graphics.Color.alpha(bitmap.getPixel(x, y))
            val below = (1..7).map { alpha(pill.bottom + it) }
            val above = (1..7).map { alpha(pill.top - it) }
            assertTrue("a visible but faint shadow in either focus state: $below", below.all { it in 1..15 })
            assertTrue("3 dp offset puts more shadow below: $above / $below", below.sum() > above.sum())
            assertTrue("10 dp blur fades away from the edge: $below", below.first() > below.last())
            assertEquals("no hardware elevation shadow on top", 0f, pill.elevation, 0f)
            val plus = byDescription(composer, activity.getString(R.string.composer_attach))
            assertEquals("no second hardware shadow on plus", 0f, plus.elevation, 0f)
            val plusBox = boxIn(composer, plus)
            if (focused) {
                assertEquals("expanded plus has no independent shadow inside the card", 0xFFFFFFFF.toInt(),
                    bitmap.getPixel(plusBox.centerX(), plusBox.top - 2))
            } else {
                val a = android.graphics.Color.alpha(bitmap.getPixel(plusBox.centerX(), plusBox.bottom + 3))
                assertTrue("collapsed plus has the same faint shadow", a in 1..15)
            }
            bitmap.recycle()
        }
    }

    @Test fun `attachment feedback retains a ripple before and after focus`() = withComposer { activity, _, composer ->
        val plus = byDescription(composer, activity.getString(R.string.composer_attach))
        for (focused in listOf(false, true)) {
            if (focused) composer.field.requestFocus() else composer.field.clearFocus()
            assertTrue(plus.background is android.graphics.drawable.RippleDrawable)
        }
    }

    @Test fun `send arrow still draws after its image level resets`() = withComposer { activity, _, composer ->
        val send = byDescription(composer, activity.getString(R.string.composer_send)) as android.widget.ImageView
        val bitmap = android.graphics.Bitmap.createBitmap(24, 24, android.graphics.Bitmap.Config.ARGB_8888)
        send.drawable.setBounds(0, 0, 24, 24)
        send.setImageLevel(0)
        send.drawable.draw(android.graphics.Canvas(bitmap))
        assertTrue((0 until 24).any { x -> (0 until 24).any { y -> android.graphics.Color.alpha(bitmap.getPixel(x, y)) > 0 } })
        bitmap.recycle()
    }

    @Test fun `first RTL layout places the collapsed surface beside the plus`() = withComposer { activity, root, composer ->
        root.layoutDirection = View.LAYOUT_DIRECTION_RTL
        composer.field.clearFocus()
        root.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 400, 800)
        val pill = composer.getChildAt(0)
        val outline = android.graphics.Outline()
        pill.outlineProvider.getOutline(pill, outline)
        val bounds = Rect()
        outline.getRect(bounds)
        val plus = boxIn(pill, byDescription(composer, activity.getString(R.string.composer_attach)))
        assertEquals(0, bounds.left)
        assertEquals(pill.width - 52, bounds.right)
        assertEquals(pill.width, plus.right)
        assertEquals(8, plus.left - bounds.right)
    }

    @Test fun `hiding the keyboard collapses a nonempty draft without clearing its text`() = withComposer { _, root, composer ->
        composer.field.requestFocus()
        composer.field.setText("unfinished draft")
        for (height in listOf(300, 0)) {
            ViewCompat.dispatchApplyWindowInsets(composer, WindowInsetsCompat.Builder()
                .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, height)).build())
        }
        root.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 400, 800)
        assertEquals("unfinished draft", composer.text)
        assertFalse(composer.field.hasFocus())
        assertFalse(descendants(composer).filterIsInstance<ComposerRow>().single().stacked)
    }

    private class HeldCapture : DictationCapture {
        override val level = 0f
        var discarded = false
        override suspend fun stop() = byteArrayOf(1)
        override fun discard() { discarded = true }
    }

    private fun dictating(activity: ComponentActivity, composer: ComposerView, words: suspend (ByteArray) -> String): HeldCapture {
        shadowOf(activity).grantPermissions(android.Manifest.permission.RECORD_AUDIO)
        val capture = HeldCapture()
        composer.dictationAudio = object : DictationMicrophone {
            override suspend fun start(ended: () -> Unit) = capture
        }
        composer.transcribeDictation = words
        return capture
    }

    private fun press(view: View) {
        val time = android.os.SystemClock.uptimeMillis()
        view.dispatchTouchEvent(android.view.MotionEvent.obtain(time, time, android.view.MotionEvent.ACTION_DOWN, 1f, 1f, 0))
        view.dispatchTouchEvent(android.view.MotionEvent.obtain(time, time + 10, android.view.MotionEvent.ACTION_UP, 1f, 1f, 0))
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test fun `there is no microphone until the host can transcribe`() = withComposer { activity, _, composer ->
        val description = activity.getString(R.string.composer_dictate)
        assertEquals(View.GONE, byDescription(composer, description).visibility)
        dictating(activity, composer) { "" }
        assertEquals(View.VISIBLE, byDescription(composer, description).visibility)
    }

    @Test fun `dictated words go in at the caret`() = withComposer { activity, _, composer ->
        dictating(activity, composer) { "brave new" }
        composer.field.setText("hello world")
        composer.field.setSelection(5)
        press(byDescription(composer, activity.getString(R.string.composer_dictate)))
        val capsule = descendants(composer).filterIsInstance<DictationCapsule>().single()
        assertEquals(View.VISIBLE, capsule.visibility)
        press(capsule)
        assertEquals("hello brave new world", composer.field.text.toString())
        assertEquals("hello brave new".length, composer.field.selectionStart)
    }

    @Test fun `plus cancels a dictation, holds send meanwhile, and leaves the draft`() = withComposer { activity, _, composer ->
        val capture = dictating(activity, composer) { "words" }
        var sent = 0
        composer.onSend = { _, _ -> sent++ }
        composer.field.setText("draft")
        press(byDescription(composer, activity.getString(R.string.composer_dictate)))
        val cancel = byDescription(composer, activity.getString(R.string.composer_dictate_cancel))
        byDescription(composer, activity.getString(R.string.composer_send)).performClick()
        assertEquals(0, sent)
        cancel.performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(capture.discarded)
        assertEquals("draft", composer.field.text.toString())
        assertEquals(activity.getString(R.string.composer_attach), cancel.contentDescription)
    }

    @Test fun `a composer that leaves its window drops the dictation`() = withComposer { activity, root, composer ->
        val capture = dictating(activity, composer) { "words" }
        press(byDescription(composer, activity.getString(R.string.composer_dictate)))
        root.removeView(composer)
        assertTrue(capture.discarded)
    }

    @Test fun `a failed dictation says why and leaves the draft`() = withComposer { activity, _, composer ->
        dictating(activity, composer) { throw IllegalStateException() }
        composer.field.setText("draft")
        press(byDescription(composer, activity.getString(R.string.composer_dictate)))
        press(descendants(composer).filterIsInstance<DictationCapsule>().single())
        assertEquals(activity.getString(R.string.composer_dictation_failed), ShadowToast.getTextOfLatestToast())
        assertEquals("draft", composer.field.text.toString())
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
