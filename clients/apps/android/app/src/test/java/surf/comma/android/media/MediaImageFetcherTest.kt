package surf.comma.android.media

import android.graphics.Bitmap
import android.graphics.Color
import surf.comma.android.chat.live.toChatAttachment
import coil3.ImageLoader
import coil3.fetch.SourceFetchResult
import coil3.request.Options
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

/**
 * A remote picture for Coil: the original the client core downloaded, checked to be the image its message says before
 * a decoder sees it, its size remembered. How the core reads and checks the file is the core's and is tested there.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MediaImageFetcherTest {
    @Test fun allThreeSourcesComeFromTheCoreAndRememberTheOriginalAspectRatio() = runBlocking<Unit> {
        harness { core, session, _, ratios, factory, loader ->
            val bytes = png()
            val ref = ref(bytes)
            val sources = listOf(MediaSource.AgentResource("agent", ref),
                MediaSource.MessageAttachment("conversation", "message", 7, ref),
                MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png")))
            for (source in sources) {
                core.serve(source.fileSource(session.id.groupId), bytes)
                val data = AuthorizedImage(session, MediaImage(source, "image.png", "image/png"))
                val result = fetch(factory, data, loader)
                result.source.use { assertArrayEquals(bytes, it.source().readByteArray()) }
                assertEquals(ImageDimensions(320, 160), ratios.get(data.key))
                // Shown again, it is read from the device.
                fetch(factory, data, loader).source.close()
            }
            assertEquals(3, core.calls.count { it.first == "downloads.start" })
        }
    }

    @Test fun agentReplyWithInferredPngNameDecodesVerifiedJpegBytes() = runBlocking<Unit> {
        harness { core, session, _, ratios, factory, loader ->
            val block = org.json.JSONObject(javaClass.getResource("/media/agent-reply-image.json")!!.readText())
            val message = org.json.JSONObject().put("message_id", "msg1_2105156758459645952")
                .put("seq", 925).put("actor_type", "agent")
                .put("agent_id", "agt1_2089252240962359296_2089252240962359297_2089252240962359298")
                .put("content", org.json.JSONArray().put(org.json.JSONObject().put("type", "text").put("text", "Image" )).put(block))
            val attachment = surf.comma.android.conversation.display(message)!!.attachments.single()
            val refJson = block.getJSONObject("blob_ref")
            val ref = MediaBlobRef(refJson.getString("uuid"), refJson.getString("hash"), refJson.getLong("size"))
            assertEquals(1, attachment.blockIndex)
            val routed = attachment.toChatAttachment("cnv1_2089252241788633088", "msg1_2105156758459645952", "image")
            assertEquals(AttachmentDisplay.IMAGE, MediaRouting.display(routed.file))
            val source = routed.file.source as MediaSource.AgentResource
            assertEquals(ref, source.ref)
            val bytes = javaClass.getResource("/media/agent-reply-image.jpg")!!.readBytes()
            assertEquals(70260, bytes.size)
            assertEquals(ref.hash, ref(bytes).hash)
            core.serve(source.fileSource(session.id.groupId), bytes)
            for (declaredMime in listOf(null, "application/octet-stream")) {
                val data = AuthorizedImage(session, MediaImage(source, attachment.fileName, declaredMime))
                val result = fetch(factory, data, loader)
                assertEquals("image/jpeg", result.mimeType)
                result.source.use { assertArrayEquals(bytes, it.source().readByteArray()) }
                assertEquals(ImageDimensions(1402, 1122), ratios.get(data.key))
            }
            // The core is asked for exactly the bytes the ref names.
            val asked = core.calls.first { it.first == "downloads.start" }.second
            assertEquals(ref.hash, asked.getJSONObject("expect").getString("sha256"))
            val explicitPng = AuthorizedImage(session, MediaImage(source, attachment.fileName, "image/png"))
            assertEquals("Image signature mismatch", runCatching { fetch(factory, explicitPng, loader) }.exceptionOrNull()?.message)
        }
    }

    @Test fun bytesThatAreNoImageOrNotTheFileAskedForAreNeverDecoded() = runBlocking<Unit> {
        harness { core, session, _, _, factory, loader ->
            val upload = MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png"))
            core.serve(upload.fileSource(session.id.groupId), "<svg>not an image</svg>".toByteArray())
            val svg = AuthorizedImage(session, MediaImage(upload, "a.png", "image/png"))
            assertEquals("Image signature mismatch", runCatching { fetch(factory, svg, loader) }.exceptionOrNull()?.message)
            val bytes = png()
            val badHash = MediaSource.AgentResource("agent", ref(bytes).copy(hash = "0".repeat(64)))
            core.serve(badHash.fileSource(session.id.groupId), bytes)
            val wrong = AuthorizedImage(session, MediaImage(badHash, "a.png", "image/png"))
            assertEquals("The image is not available", runCatching { fetch(factory, wrong, loader) }.exceptionOrNull()?.message)
        }
    }

    @Test fun staleSessionCannotReadEvenAnImageOnTheDevice() = runBlocking<Unit> {
        harness { core, session, auth, _, factory, loader ->
            val source = MediaSource.AgentResource("agent", ref(png()))
            core.serve(source.fileSource(session.id.groupId), png())
            val data = AuthorizedImage(session, MediaImage(source, "a.png", "image/png"))
            fetch(factory, data, loader).source.close()
            auth.session.value = session.copy(id = session.id.copy(generation = "next"))
            assertTrue(runCatching { fetch(factory, data, loader) }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
        }
    }

    private suspend fun fetch(factory: MediaImageFetcherFactory, data: AuthorizedImage, loader: ImageLoader) =
        factory.create(data, Options(RuntimeEnvironment.getApplication()), loader).fetch() as SourceFetchResult

    private suspend fun harness(
        block: suspend (FakeDownloadCore, AuthorizedSession, FakeAuthorizedHttp, AspectRatioCache, MediaImageFetcherFactory, ImageLoader) -> Unit,
    ) {
        val root: File = Files.createTempDirectory("fetch-test").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val session = testSession()
        val auth = FakeAuthorizedHttp(session)
        val core = FakeDownloadCore(root)
        val files = MediaFileStore(auth, core, { File(root, it) }, scope)
        val ratios = AspectRatioCache.memory()
        val loader = ImageLoader.Builder(RuntimeEnvironment.getApplication()).build()
        try { block(core, session, auth, ratios, MediaImageFetcherFactory(auth, files, ratios), loader) }
        finally { loader.shutdown(); scope.cancel(); root.deleteRecursively() }
    }

    private fun png(): ByteArray {
        val bitmap = Bitmap.createBitmap(320, 160, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLUE) }
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); bitmap.recycle() }.toByteArray()
    }
    private fun ref(bytes: ByteArray) = MediaBlobRef("a".repeat(32),
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, bytes.size.toLong())
}
