package surf.comma.android.media

import android.net.Uri
import android.graphics.Bitmap
import android.graphics.Color
import android.widget.ImageView
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.junit.Before
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.GraphicsMode
import org.json.JSONObject
import surf.comma.android.chat.live.ChatImageDraft
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.chat.live.AttachmentCardRenderer
import surf.comma.android.conversation.*
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerAttachment
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.auth.Account
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.awaitState
import surf.comma.android.auth.TestSessionCore
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.Session
import surf.comma.android.auth.SessionToken
import java.io.File
import java.security.MessageDigest

/** Media on the real AuthRepository: its session snapshots, and the files the client core downloads for them. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], shadows = [JvmImageDecoder::class])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@OptIn(ExperimentalCoroutinesApi::class)
class AuthMediaHttpTest {
    @get:Rule val folder = TemporaryFolder()
    private val now = 1_800_000_000_000L
    // The core makes the requests; the media only names the server.
    private val baseUrl = "https://api.test/"
    private val store = MemorySessions()
    private val core = TestSessionCore(store) { now }
    private val auth = TestAuthRepository(store, { now }, Dispatchers.Unconfined, core = core)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val storage by lazy { MediaAccountStorage(File(folder.root, "media-accounts")) }
    private val http by lazy { AuthMediaHttp(auth, baseUrl, storage, scope) }
    private val downloads by lazy { FakeDownloadCore(File(folder.root, "downloads")) }
    private val downloaded = { path: String -> File(folder.root, "downloads/$path") }
    /** The session's core with the downloads' fake beside it. */
    private val media by lazy {
        object : surf.comma.android.core.CoreApi by core {
            override suspend fun call(name: String, params: JSONObject): Any? =
                if (name.startsWith("downloads.")) downloads.call(name, params) else core.call(name, params)
            override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T) =
                if (topic.getString("topic") == "download") downloads.subscribe(topic, read) else core.subscribe(topic, read)
        }
    }

    @Before fun before() { Dispatchers.setMain(UnconfinedTestDispatcher()) }

    @After fun after() {
        Dispatchers.resetMain()
        scope.cancel()
    }

    private suspend fun signIn(user: String = "alice"): AuthorizedSession {
        if (store.value == null && auth.state.value == AuthState.Starting) {
            store.value = Session(SessionToken("secret-$user"), now / 1000 + 3600, "session-$user", Account(user, "$user@example.test", null, "active"))
            http.session.value // Subscribe before the first scope is published.
            auth.start()
        } else {
            core.user = user
            auth.awaitState<AuthState.Login>()
            auth.sendCode("$user@example.test")
            auth.awaitState<AuthState.Login> { it.challengeId != null }
            auth.verify("123456")
        }
        settled { http.session.value?.id?.accountId == user }
        return http.session.value!!
    }

    @Test fun snapshotNamesAccountAndGroup() = runBlocking {
        val session = signIn()
        assertEquals("g-alice", session.id.groupId)
        assertTrue(session.id.generation.matches(Regex("[0-9a-f]{32}")))
        assertTrue(http.isCurrent(session))
    }

    @Test fun epochSurvivesANewProcessButNotASignOut() = runBlocking {
        val first = signIn()
        // A second adapter on the same storage stands in for the next process.
        val again = AuthMediaHttp(auth, baseUrl, storage, scope)
        settled { again.session.value != null }
        assertEquals(first.id.generation, again.session.value!!.id.generation)
        auth.logout()
        storage.clearAll() // What MediaAccountStorage.follow does on sign-out.
        val next = signIn("alice")
        assertNotEquals(first.id.generation, next.id.generation)
    }

    @Test fun signOutEndsTheSnapshotAtOnce() = runBlocking {
        val session = signIn()
        auth.logout()
        assertNull(http.session.value) // Same call, no dispatch in between.
        assertFalse(http.isCurrent(session))
    }

    @Test fun switchingAccountCancelsDownloadsAndDropsTheLateBody() = runBlocking {
        val alice = signIn()
        val files = MediaFileStore(http, media, downloaded, scope)
        val bytes = ByteArray(300_000) { it.toByte() }
        val source = MediaSource.AgentResource("agent", ref(bytes))
        downloads.serve(source.fileSource(alice.id.groupId), bytes)
        val release = downloads.hold(source.fileSource(alice.id.groupId))
        val download = files.download(MediaAttachment("clip.mp4", "video/mp4", null, source))!!
        download.start()
        assertTrue(download.state.value is MediaDownloadState.Downloading)
        settled { downloads.calls.isNotEmpty() }
        auth.logout()
        settled { download.state.value == MediaDownloadState.Idle }
        val bob = signIn("bob")
        assertNotEquals(alice.id.accountId, bob.id.accountId)
        release.complete(Unit)
        assertEquals(MediaDownloadState.Idle, download.state.value)
        // The old handle stays dead; a fresh one belongs to the new account.
        download.start()
        assertEquals(MediaDownloadState.Idle, download.state.value)
        assertNotEquals(download.key, files.download(MediaAttachment("clip.mp4", "video/mp4", null,
            MediaSource.AgentResource("agent", ref(bytes))))!!.key)
        files.close()
    }

    @Test fun switchingAccountLetsGoOfTheDraftsImages() = runBlocking {
        signIn()
        val preparing = kotlinx.coroutines.CompletableDeferred<Unit>()
        val ended = kotlinx.coroutines.CompletableDeferred<Unit>()
        // Making the image ready never ends: only the account's end ends it.
        val prepared = ImagePreprocessor {
            preparing.complete(Unit)
            try { kotlinx.coroutines.awaitCancellation() } finally { ended.complete(Unit) }
        }
        val timeline = FakeChatViewCore()
        val draft = ChatImageDraft(http, prepared, { _, _ -> error("not a file") }, scope, ChatView(AuthConversationSessions(auth), timeline))
        draft.add(listOf(ComposerAttachment("a", Uri.parse("content://picker/1"), PickedFile("1.jpg", "image/jpeg", 10))))
        preparing.await()
        assertEquals(AttachmentUploadState.Pending, draft.states.first()["a"])
        auth.logout()
        ended.await()
        settled { runBlocking { draft.states.first().isEmpty() } }
        signIn("bob")
        assertTrue(draft.states.first().isEmpty())
        assertTrue(timeline.calls.none { it.first == "chatView.attach" })
        draft.close()
    }

    @Test fun signOutDeletesEveryAccountsDownloads() = runBlocking {
        signIn()
        storage.follow(auth.state, scope)
        val directory = storage.directory("alice")
        File(directory, "files/key/data/clip.mp4").apply { parentFile!!.mkdirs(); writeText("video") }
        auth.logout()
        settled { !directory.exists() }
        File(storage.root, "stale").mkdirs()
        signIn("bob")
        settled { !File(storage.root, "stale").exists() }
        assertTrue(storage.directory("bob").isDirectory)
    }

    @Test fun imageOnlyUploadSendRetryAndDisplayUseTheAuthenticatedPipeline() = runBlocking {
        chatImageRoundTrip("", failUpload = false)
    }

    @Test fun failedUploadRetriesBeforeSendingImageAndTextWithTheSameDraftIdentity() = runBlocking {
        chatImageRoundTrip("look at this", failUpload = true)
    }

    private suspend fun chatImageRoundTrip(text: String, failUpload: Boolean) {
        signIn()
        val context = RuntimeEnvironment.getApplication()
        val sessions = AuthConversationSessions(auth)
        val timeline = FakeChatViewCore()
        val repository = ChatView(sessions, timeline)
        val loader = MediaImageLoader.open(context, http, MediaFileStore(http, media, downloaded, scope), scope, File(folder.root, "images"))
        val draft = ChatImageDraft(http, AndroidImagePreprocessor(context.contentResolver, File(folder.root, "outgoing")),
            AndroidPickedFileRefs(context.contentResolver), scope, repository) { image, _, session -> loader.remember(image, session) }
        // The first upload fails when asked to; the core uploads, so no upload request is the app's.
        timeline.uploads = !failUpload
        fun attached() = timeline.calls.filter { it.first == "chatView.attach" }
        try {
            repository.start()
            repository.setForeground(true)
            repository.awaitState { it.conversationId == "chat-alice" && it.cacheLoaded }
            val input = File(folder.root, "picked.png")
            val bitmap = Bitmap.createBitmap(120, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GREEN) }
            input.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            val selection = listOf(ComposerAttachment("photo", Uri.fromFile(input), PickedFile.describe(context.contentResolver, Uri.fromFile(input))))
            val requestId = draft.requestId
            draft.add(selection)
            if (failUpload) {
                settled { runBlocking { draft.states.first()["photo"] == AttachmentUploadState.Failed } }
                assertFalse(draft.send(text, selection))
                assertTrue(timeline.sends.isEmpty())
                assertEquals(requestId, draft.requestId)
                timeline.uploads = true
                draft.retry("photo")
            }
            settled { runBlocking { draft.states.first()["photo"] == AttachmentUploadState.Done } }
            assertTrue(draft.send(text, selection))
            val failed = repository.awaitState { it.timeline.filterIsInstance<TimelineEntry.Pending>()
                .any { pending -> pending.pending.status == PendingStatus.FAILED } }
            val resolve = { attachment: surf.comma.android.chat.model.ChatAttachment ->
                attachment.copy(dimensions = attachment.file.source?.let(loader::dimensions))
            }
            val mapped = mapConversation(failed, resolveMedia = resolve)
            val pendingImage = mapped.rows.single { it.attachment != null }
            assertEquals(requestId, mapped.retryTargets[pendingImage.id])
            assertEquals(AttachmentDisplay.IMAGE, pendingImage.attachment!!.display)
            assertEquals(ImageDimensions(120, 60), pendingImage.attachment.dimensions)
            val sent = timeline.sends.first()
            assertEquals(requestId, sent.getString("clientRequestId"))
            assertEquals(text, sent.getString("text"))
            val path = (failed.timeline.single() as TimelineEntry.Pending).pending.workspaceFiles.single().path
            timeline.accept = true
            repository.retry(requestId)
            val confirmed = repository.awaitState { it.timeline.any { it is TimelineEntry.Message } }
            assertEquals(1, timeline.sends.map { it.getString("clientRequestId") to it.getString("text") }.distinct().size)
            // The file goes to the core once; a failed upload is the core's to try again.
            assertEquals(1, attached().size)
            assertEquals(if (failUpload) 1 else 0, timeline.calls.count { it.first == "chatView.retryAttachment" })
            val displayed = mapConversation(confirmed, resolveMedia = resolve).rows.single { it.attachment != null }
            assertEquals(pendingImage.id, displayed.id)
            assertEquals(ImageDimensions(120, 60), displayed.attachment!!.dimensions)
            assertEquals(160f, AttachmentCardRenderer(1).bodyHeightDp(displayed, 360f), 0.1f)
            // The uploaded file, as the server keeps it under its path.
            val uploaded = attached().last().second.getJSONArray("files").getJSONObject(0)
            downloads.serve(MediaSource.UploadedFile(path).fileSource("g-alice"),
                java.util.Base64.getDecoder().decode(uploaded.getJSONObject("bytes").getString("\$bytes")))
            val view = ImageView(context)
            val binding = loader.bind(view, displayed.attachment.image()!!, 120, visible = true)
            settled { view.drawable != null }
            assertEquals(60, view.layoutParams.height)
            assertTrue(view.drawable.intrinsicWidth <= 120)
            assertEquals(path, downloads.calls.last { it.first == "downloads.start" }.second.getJSONObject("source").getString("path"))
            binding.close()
            assertTrue(File(folder.root, "outgoing").walkTopDown().none { it.isFile })
        } finally {
            draft.close(); repository.close(); loader.close()
        }
    }

    @Test fun aPickedVideoIsUploadedFromWhereItIsAndSendsWithTheDraft() = runBlocking {
        signIn()
        val context = RuntimeEnvironment.getApplication()
        val timeline = FakeChatViewCore()
        val repository = ChatView(AuthConversationSessions(auth), timeline)
        val remembered = mutableListOf<UploadedImage>()
        // Only images are made ready on the device; the core never gets a video's bytes.
        val draft = ChatImageDraft(http, { error("a video is not an image") }, AndroidPickedFileRefs(context.contentResolver),
            scope, repository) { image, _, _ -> remembered += image }
        try {
            repository.start()
            repository.setForeground(true)
            repository.awaitState { it.conversationId == "chat-alice" && it.cacheLoaded }
            val bytes = ByteArray(300_000) { (it % 251).toByte() }
            val input = File(folder.root, "clip.mp4").apply { writeBytes(bytes) }
            val picked = PickedFile.describe(context.contentResolver, Uri.fromFile(input))
            assertEquals(PickedFile("clip.mp4", picked.mimeType, 300_000), picked)
            assertEquals(FileKind.VIDEO, picked.kind)
            val selection = listOf(ComposerAttachment("video", Uri.fromFile(input), picked))
            draft.add(selection)
            settled { runBlocking { draft.states.first()["video"] == AttachmentUploadState.Done } }
            assertTrue(timeline.calls.none { it.first == "chatView.attach" })
            val file = timeline.calls.single { it.first == "chatView.attachLocalFiles" }.second.getJSONArray("files").getJSONObject(0)
            assertEquals("clip.mp4", file.getString("name"))
            assertEquals(300_000L, file.getLong("size"))
            assertEquals("video/mp4", file.getString("mediaType"))
            // The ref names the picked file for the core's host, which reads it as it sends it.
            val held = PickedLocalFiles.host(context.contentResolver).open(file.getString("localFileRef"))!!
            assertEquals(300_000L, held.size)
            assertTrue(bytes.contentEquals(held.open().use { it.readBytes() }))
            val requestId = draft.requestId
            assertTrue(draft.send("", selection))
            assertEquals(listOf(requestId), timeline.sends.map { it.getString("clientRequestId") })
            assertTrue(remembered.isEmpty())
        } finally {
            draft.close(); repository.close()
        }
    }

    @Test fun aPickedFileWithoutADeclaredSizeIsMeasured() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val input = File(folder.root, "notes.txt").apply { writeBytes(ByteArray(1_001)) }
        val local = AndroidPickedFileRefs(context.contentResolver).register(Uri.fromFile(input), null)
        assertEquals(1_001L, local.size)
        assertEquals(1_001L, PickedLocalFiles.host(context.contentResolver).open(local.ref)!!.size)
        assertTrue(Regex("lfi1_[A-Za-z0-9_-]{43}").matches(local.ref))
        assertNull(PickedLocalFiles.host(context.contentResolver).open("lfi1_" + "x".repeat(43)))
    }

    @Test fun logoutClearsSharedImageFileAndVideoMetadataCachesAndVisibleImage() = runBlocking {
        signIn()
        val context = RuntimeEnvironment.getApplication()
        val components = MediaComponents(context, auth, media, baseUrl, scope, downloaded)
        settled { components.http.session.value != null }
        val images = components.images()
        val bitmap = Bitmap.createBitmap(12, 6, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GREEN) }
        val bytes = java.io.ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        val source = MediaSource.UploadedFile("/uploads/abcdefghijklmnopqrstuv-photo.png")
        downloads.serve(source.fileSource("g-alice"), bytes)
        val image = MediaImage(source, "photo.png", "image/png", ImageDimensions(12, 6))
        val view = ImageView(context)
        val binding = images.bind(view, image, 12, visible = true)
        settled { view.drawable != null }
        val download = components.files.download(MediaAttachment("photo.png", "image/png", bytes.size.toLong(), source))!!
        download.start()
        settled { download.state.value is MediaDownloadState.Ready }
        // Metadata left by a previous process must be cleared too, even before any cover decode.
        AspectRatioCache.open(File(context.cacheDir, "media-video-sizes.json")).put(download.key, ImageDimensions(16, 9))
        val covers = components.covers()
        assertEquals(ImageDimensions(16, 9), covers.dimensions(download.key))
        val imageDirectory = File(context.cacheDir, "message-images")
        assertTrue(imageDirectory.walkTopDown().any { it.isFile })
        auth.logout()
        settled { view.drawable == null && images.dimensions(source) == null }
        // Sign-out clears the picture sizes first and the video sizes after them; the files are the core's.
        settled { !File(imageDirectory, "ratios.json").exists() && covers.dimensions(download.key) == null }
        binding.close()
        images.close()
        components.files.close()
    }

    private fun ref(bytes: ByteArray) = MediaBlobRef("a".repeat(32),
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, bytes.size.toLong())
}

/**
 * What the steps before left: the app's background work, the core's answers and the decodes run in place in unit
 * tests, so [condition] holds when they return. No test waits for time to pass.
 */
internal fun settled(condition: () -> Boolean) = org.junit.Assert.assertTrue("not settled", condition())
