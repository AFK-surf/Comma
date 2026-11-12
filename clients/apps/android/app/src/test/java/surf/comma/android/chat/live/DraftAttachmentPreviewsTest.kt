package surf.comma.android.chat.live

import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.conversation.*
import surf.comma.android.media.*
import surf.comma.android.ui.composer.*
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DraftAttachmentPreviewsTest {
    @Test(timeout = 20000) fun `a failed picked image keeps its name and local source after activity recreation`() = runBlocking {
        val sessions = FakeSessions().apply { scopes.value = scope(1) }
        val core = FakeChatViewCore().apply { uploads = false }
        val repository = ChatView(sessions, core, io = Dispatchers.Unconfined).apply { start(); setForeground(true) }
        val http = FakeAuthorizedHttp(testSession(group = GROUP))
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val image = File.createTempFile("draft", ".jpg").apply { writeBytes(byteArrayOf(1, 2)) }
        val prepared = ImagePreprocessor { PreparedImage(image, "image.jpg", UploadImageFormat.JPEG, ImageDimensions(1, 1)) }
        val original = ComposerAttachment("picked", Uri.parse("content://test/green"), PickedFile("green.png", "image/png", 2))
        Robolectric.buildActivity(ComponentActivity::class.java).setup().use { activity ->
            val previews = ViewModelProvider(activity.get())[DraftAttachmentPreviews::class.java]
            fun draft(store: DraftAttachmentPreviews) = ChatImageDraft(http, prepared,
                { _, _ -> error("not a file") }, owner, repository, store)
            val first = draft(previews)
            first.add(listOf(original))
            val before = first.shown.first { it.singleOrNull()?.state == AttachmentUploadState.Failed }.single()
            first.close()
            activity.recreate()
            val second = draft(ViewModelProvider(activity.get())[DraftAttachmentPreviews::class.java])
            val after = second.shown.first { it.isNotEmpty() }.single()
            assertEquals(before.attachment.uri, after.attachment.uri)
            assertEquals(before.attachment.file.name, after.attachment.file.name)
            assertTrue(after.attachment.local)
            assertEquals(AttachmentUploadState.Failed, after.state)
            // The restored row id still addresses retry and removal in the core.
            core.uploads = true
            second.retry(after.attachment.id)
            assertEquals(AttachmentUploadState.Done, second.shown.first().single().state)
            second.remove(after.attachment.id)
            assertTrue(second.shown.first().isEmpty())
            assertNull(previews.get(http.session.value!!, after.attachment.id))
            second.close()
        }
        repository.close()
        owner.cancel()
        image.delete()
        Unit
    }

    @Test fun `a different login cannot inherit a picked preview`() {
        val store = DraftAttachmentPreviews()
        val first = testSession()
        store.remember(first, "row", ComposerAttachment("pick", Uri.parse("content://test/a"), PickedFile("a.png", "image/png", 1)))
        val next = first.copy(id = first.id.copy(generation = "next"))
        assertNull(store.get(next, "row"))
        store.keepSession(next)
        assertNull(store.get(first, "row"))
    }
}
