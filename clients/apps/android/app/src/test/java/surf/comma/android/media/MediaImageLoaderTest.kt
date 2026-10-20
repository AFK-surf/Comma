package surf.comma.android.media

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.Animatable
import android.widget.ImageView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], shadows = [JvmImageDecoder::class])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@OptIn(ExperimentalCoroutinesApi::class)
class MediaImageLoaderTest {
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private fun files(auth: AuthorizedHttp, core: FakeDownloadCore, root: File) =
        MediaFileStore(auth, core, { File(root.resolve("downloads"), it) }, work)
    private fun starts(core: FakeDownloadCore) = core.calls.count { it.first == "downloads.start" }

    @Before fun before() { Dispatchers.setMain(UnconfinedTestDispatcher()) }
    @After fun after() {
        Dispatchers.resetMain()
        work.cancel()
    }

    @Test fun visibleImagesWaitForFlingToEndDecodeToDisplaySizeAndKeepPlaceholder() = runBlocking {
        val root = Files.createTempDirectory("loader-test").toFile()
        run {
            val auth = FakeAuthorizedHttp(testSession())
            val core = FakeDownloadCore(root.resolve("downloads"))
            val context = RuntimeEnvironment.getApplication()
            val loader = MediaImageLoader.open(context, auth, files(auth, core, root), this, root)
            try {
                loader.setFastScrolling(true)
                val view = ImageView(context)
                val image = MediaImage(MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png")), "a.png", "image/png")
                val bitmap = Bitmap.createBitmap(1200, 600, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GREEN) }
                val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); bitmap.recycle() }.toByteArray()
                core.serve(image.source.fileSource("group"), bytes)
                val errors = mutableListOf<Throwable>()
                val binding = loader.bind(view, image, 120, visible = true, onError = errors::add)
                // A fling holds the load back; it runs in place once the fling ends.
                assertEquals(0, starts(core))
                loader.setFastScrolling(false)
                assertTrue(errors.toString(), errors.isEmpty())
                assertTrue(view.drawable.intrinsicWidth <= 120)
                assertTrue(view.drawable.intrinsicHeight <= 120)
                assertEquals(120, view.layoutParams.height)
                binding.close()
                val second = loader.bind(view, image, 120)
                assertEquals(60, second.placeholder.height)
                assertEquals(1, starts(core))
                second.setVisible(true)
                assertNotNull(view.drawable)
                auth.session.value = auth.session.value!!.let { it.copy(id = it.id.copy(generation = "next")) }
                assertNull(view.drawable)
                second.close()
            } finally { loader.close(); root.deleteRecursively() }
        }
    }

    @Test fun gifStopsWhenHiddenScrollingOrRecycled() = runBlocking {
        val root = Files.createTempDirectory("gif-loader-test").toFile()
        run {
            val context = RuntimeEnvironment.getApplication()
            val auth = FakeAuthorizedHttp(testSession())
            val core = FakeDownloadCore(root.resolve("downloads"))
            val loader = MediaImageLoader.open(context, auth, files(auth, core, root), this, root)
            try {
                val bytes = animatedGif()
                core.serve(MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "gif")).fileSource("group"), bytes)
                val view = ImageView(context)
                val errors = mutableListOf<Throwable>()
                val binding = loader.bind(view, MediaImage(MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "gif")), "a.gif", "image/gif"),
                    20, visible = true, onError = errors::add)
                // The download and the decode run in place: the picture is there when the binding returns.
                assertTrue(errors.toString(), errors.isEmpty())
                val animation = view.drawable as Animatable
                assertTrue(animation.isRunning)
                binding.setVisible(false)
                assertFalse(animation.isRunning)
                binding.setVisible(true)
                assertTrue(animation.isRunning)
                loader.setFastScrolling(true)
                assertFalse(animation.isRunning)
                loader.setFastScrolling(false)
                assertTrue(animation.isRunning)
                binding.close()
                assertFalse(animation.isRunning)
            } finally { loader.close(); root.deleteRecursively() }
        }
    }

    @Test fun sendPreviewSurvivesErrorRetryAndIsClearedWithTheSession() = runBlocking {
        val root = Files.createTempDirectory("handoff-loader-test").toFile()
        run {
            val context = RuntimeEnvironment.getApplication()
            val auth = FakeAuthorizedHttp(testSession())
            val core = FakeDownloadCore(root.resolve("downloads"))
            val loader = MediaImageLoader.open(context, auth, files(auth, core, root), this, root)
            try {
                val failing = MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png")).fileSource("group")
                core.refuse(failing, "network")
                val bitmap = Bitmap.createBitmap(120, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GREEN) }
                val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                val view = SendImageView(context).apply { layoutParams = android.view.ViewGroup.LayoutParams(120, 120) }
                val errors = mutableListOf<Throwable>()
                val image = MediaImage(MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png")), "a.png", "image/png")
                view.presentation.hold(bitmap)
                val binding = loader.bind(view, image, 120, visible = true, onError = errors::add)
                view.presentation.land()
                assertEquals(1, errors.size)
                assertSame(bitmap, view.presentation.preview)
                assertNull(view.presentation.target)
                assertEquals(120, view.layoutParams.height)
                core.serve(failing, bytes)
                val release = core.hold(failing)
                binding.retry()
                // The download is held: the preview stays until its pixels come.
                assertNull(view.presentation.target)
                assertSame(bitmap, view.presentation.preview)
                release.complete(Unit)
                assertNotNull(view.presentation.target)
                assertSame(bitmap, view.presentation.preview)
                assertEquals(120, view.layoutParams.height)
                auth.session.value = auth.session.value!!.let { it.copy(id = it.id.copy(generation = "next")) }
                assertNull(view.presentation.target)
                assertNull(view.presentation.preview)
                binding.close()
                assertNull(view.presentation.target)
            } finally { loader.close(); root.deleteRecursively() }
        }
    }

    @Test fun closingDuringDecodeDiscardsLatePixelsAndPreview() = runBlocking {
        val root = Files.createTempDirectory("cancel-handoff-test").toFile()
        run {
            val context = RuntimeEnvironment.getApplication()
            val auth = FakeAuthorizedHttp(testSession())
            val core = FakeDownloadCore(root.resolve("downloads"))
            val loader = MediaImageLoader.open(context, auth, files(auth, core, root), this, root)
            try {
                val bitmap = Bitmap.createBitmap(40, 80, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
                val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                val slow = MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png")).fileSource("group")
                core.serve(slow, bytes)
                val release = core.hold(slow)
                val view = SendImageView(context).apply { layoutParams = android.view.ViewGroup.LayoutParams(120, 120) }
                val binding = loader.bind(view, MediaImage(MediaSource.UploadedFile(UPLOAD_PATH.replace("jpg", "png")), "a.png", "image/png"), 120, visible = true)
                view.presentation.hold(bitmap)
                assertEquals(1, starts(core))
                binding.close()
                release.complete(Unit)
                assertNull(view.presentation.preview)
                assertNull(view.presentation.target)
                assertFalse(view.presentation.held)
            } finally { loader.close(); root.deleteRecursively() }
        }
    }

    @Test fun localPreviewCacheReusesEnoughPixelsButDecodesAgainWhenTooSmall() = runBlocking {
        val root = Files.createTempDirectory("local-preview-cache").toFile()
        val context = RuntimeEnvironment.getApplication()
        val loader = FakeAuthorizedHttp(testSession()).let { auth ->
            MediaImageLoader.open(context, auth, files(auth, FakeDownloadCore(root.resolve("downloads")), root), this, root.resolve("cache"))
        }
        try {
            val file = root.resolve("original.png")
            val source = Bitmap.createBitmap(400, 800, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLUE) }
            file.outputStream().use { source.compress(Bitmap.CompressFormat.PNG, 100, it) }
            val image = ViewerImage.Local(android.net.Uri.fromFile(file), "image/png", "original.png")
            fun android.graphics.drawable.Drawable.bitmap() = (this as android.graphics.drawable.BitmapDrawable).bitmap
            val small = loader.load(image, 100, 100).bitmap()
            val bigger = loader.load(image, 200, 200).bitmap()
            assertTrue(bigger.height > small.height)
            assertNotSame(small, bigger)
            assertSame(bigger, loader.load(image, 50, 50).bitmap())
            val concurrent = List(3) { async { loader.load(image, 1024, 1024).bitmap() } }.awaitAll()
            val full = concurrent.first()
            concurrent.forEach { assertSame("one shared decode for identical simultaneous attachments", full, it) }
            val active = MediaImageLoader::class.java.getDeclaredField("localLoads").apply { isAccessible = true }.get(loader) as Map<*, *>
            assertTrue("request bookkeeping is released", active.isEmpty())
            assertEquals(400, full.width)
            assertEquals(800, full.height)
            assertSame(full, loader.load(image, 630, 1260).bitmap())
            loader.clearCaches()
            assertNotSame(full, loader.load(image, 630, 1260).bitmap())
        } finally { loader.close(); root.deleteRecursively() }
    }

    @Test fun preCroppedProviderThumbnailNeverBecomesTheFullImagePreview() = runBlocking {
        val root = Files.createTempDirectory("cropped-provider-test").toFile()
        val context = RuntimeEnvironment.getApplication()
        val loader = FakeAuthorizedHttp(testSession()).let { auth ->
            MediaImageLoader.open(context, auth, files(auth, FakeDownloadCore(root.resolve("downloads")), root), this, root.resolve("cache"))
        }
        try {
            fun make(name: String, width: Int, height: Int): java.io.File = root.resolve(name).also { file ->
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLUE) }
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
            val original = make("original.png", 160, 960)
            val thumbnail = make("cropped.png", 64, 64)
            var typedReads = 0
            val provider = object : android.content.ContentProvider() {
                override fun onCreate() = true
                override fun getType(uri: android.net.Uri) = "image/png"
                override fun openFile(uri: android.net.Uri, mode: String) = android.os.ParcelFileDescriptor.open(original, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                override fun openTypedAssetFile(uri: android.net.Uri, mimeTypeFilter: String, opts: android.os.Bundle?): android.content.res.AssetFileDescriptor {
                    val requestedThumbnail = opts?.containsKey(android.content.ContentResolver.EXTRA_SIZE) == true
                    if (requestedThumbnail) typedReads++
                    val file = if (requestedThumbnail) thumbnail else original
                    return android.content.res.AssetFileDescriptor(android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY), 0, file.length())
                }
                override fun query(uri: android.net.Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): android.database.Cursor? = null
                override fun insert(uri: android.net.Uri, values: android.content.ContentValues?): android.net.Uri? = null
                override fun update(uri: android.net.Uri, values: android.content.ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
                override fun delete(uri: android.net.Uri, selection: String?, selectionArgs: Array<out String>?) = 0
            }
            provider.attachInfo(context, android.content.pm.ProviderInfo().apply { authority = "cropped.test" })
            org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("cropped.test", provider)
            val uri = android.net.Uri.parse("content://cropped.test/image")
            context.contentResolver.openTypedAssetFileDescriptor(uri, "image/*", android.os.Bundle().apply {
                putParcelable(android.content.ContentResolver.EXTRA_SIZE, android.graphics.Point(64, 64))
            })!!.use {
                val cropped = android.graphics.BitmapFactory.decodeFileDescriptor(it.fileDescriptor)
                assertEquals(cropped.width, cropped.height)
            }
            assertEquals(1, typedReads)
            val full = loader.load(ViewerImage.Local(uri, "image/png", null), 1024, 1024)
            assertEquals(160, full.intrinsicWidth)
            assertEquals(960, full.intrinsicHeight)
            assertEquals("the original fetch never asks the provider for thumbnail pixels", 1, typedReads)
        } finally { loader.close(); root.deleteRecursively() }
    }

    private fun animatedGif(): ByteArray {
        val header = byteArrayOf(71,73,70,56,57,97,1,0,1,0,-128,0,0,0,0,0,-1,-1,-1)
        val loop = byteArrayOf(33,-1,11) + "NETSCAPE2.0".toByteArray() + byteArrayOf(3,1,0,0,0)
        val frame = byteArrayOf(33,-7,4,0,10,0,0,0,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0)
        return header + loop + frame + frame + byteArrayOf(59)
    }
}
