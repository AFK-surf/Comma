package surf.comma.android.media

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest

/**
 * Whole-file downloads as the app shows them: the client core's state of each file, started and cancelled from here,
 * ready once the core put the file on the device. The download itself (its request, the check against the blob ref,
 * what is kept) is the core's and is tested there.
 */
class MediaFileStoreTest {
    @get:Rule val folder = TemporaryFolder()
    private val session = testSession()
    private val http = FakeAuthorizedHttp(session)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val core by lazy { FakeDownloadCore(folder.root) }
    private fun store() = MediaFileStore(http, core, { File(folder.root, it) }, scope, Dispatchers.Unconfined)

    @After fun after() = scope.cancel()

    private fun bytes(size: Int, seed: Int = 1) = ByteArray(size) { (it * 31 + seed).toByte() }
    private fun ref(bytes: ByteArray) = MediaBlobRef("a".repeat(32),
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, bytes.size.toLong())
    private fun video(bytes: ByteArray, name: String = "clip.mp4", message: String = "m") =
        MediaAttachment(name, "video/mp4", bytes.size.toLong(), MediaSource.MessageAttachment("c", message, 2, ref(bytes)))
    private fun source(attachment: MediaAttachment) = attachment.source!!.fileSource(session.id.groupId)

    /** The download's state now: the core's answers and the file work run in place, so it is where the steps left it. */
    private fun MediaDownload.until(matches: (MediaDownloadState) -> Boolean) =
        assertTrue(state.value.toString(), matches(state.value))

    @Test fun startsTheCoresDownloadAndIsReadyWithItsFile() = runBlocking<Unit> {
        val body = bytes(400_000)
        val clip = video(body)
        core.serve(source(clip), body)
        val download = store().download(clip)!!
        assertEquals(MediaDownloadState.Idle, download.state.value)
        val file = download.awaitFile()!!
        assertArrayEquals(body, file.readBytes())
        assertEquals("clip.mp4", file.name)
        val asked = core.calls.single { it.first == "downloads.start" }.second
        assertEquals(source(clip).toString(), asked.getJSONObject("source").toString())
        assertEquals(JSONObject().put("size", body.size).put("sha256", ref(body).hash).toString(), asked.getJSONObject("expect").toString())
        // Another store (the next screen) finds the same file.
        assertEquals(file, store().download(clip)!!.awaitFile())
    }

    @Test fun downloadingShowsAtOnceAndCancellingReturnsToIdle() = runBlocking<Unit> {
        val body = bytes(300_000)
        val clip = video(body)
        core.serve(source(clip), body)
        val release = core.hold(source(clip))
        val download = store().download(clip)!!
        val watching = async { download.state.first { it is MediaDownloadState.Downloading } }
        download.start()
        assertEquals(body.size.toLong(), (watching.await() as MediaDownloadState.Downloading).total)
        download.cancel()
        download.until { it == MediaDownloadState.Idle }
        release.complete(Unit)
        assertTrue(core.calls.any { it.first == "downloads.cancel" })
        core.held.clear()
        assertArrayEquals(body, download.awaitFile()!!.readBytes())
    }

    @Test fun aRefusalSaysWhetherToTryAgain() = runBlocking<Unit> {
        val body = bytes(50_000)
        val clip = video(body)
        val download = store().download(clip)!!
        core.refuse(source(clip), "network")
        assertNull(download.awaitFile())
        assertEquals(MediaDownloadState.Failed(MediaDownloadState.Failure.NETWORK), download.state.value)
        core.served.clear()
        core.serve(source(clip), bytes(50_000, seed = 2))
        core.calls.clear()
        val again = store().download(clip)!!
        assertNull(again.awaitFile())
        assertEquals(MediaDownloadState.Failed(MediaDownloadState.Failure.UNAVAILABLE), again.state.value)
    }

    @Test fun anotherSessionLeavesEarlierHandlesIdleAndInert() = runBlocking<Unit> {
        val body = bytes(200_000)
        val clip = video(body)
        core.serve(source(clip), body)
        core.hold(source(clip))
        val files = store()
        val download = files.download(clip)!!
        download.start()
        assertTrue(download.state.value is MediaDownloadState.Downloading)
        settled { core.calls.isNotEmpty() }
        http.session.value = testSession(generation = "epoch-2")
        settled { download.state.value == MediaDownloadState.Idle }
        core.held.values.forEach { it.complete(Unit) }
        download.start() // A handle from the ended session stays inert.
        assertEquals(1, core.calls.count { it.first == "downloads.start" })
        http.session.value = null
        assertNull(files.download(clip))
    }

    @Test fun awaitFileIsNullWhenCancelledMidway() = runBlocking<Unit> {
        val body = bytes(300_000)
        val clip = video(body)
        core.serve(source(clip), body)
        core.hold(source(clip))
        val download = store().download(clip)!!
        val waiting = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { download.awaitFile() }
        download.until { it is MediaDownloadState.Downloading }
        download.cancel()
        assertNull(waiting.await())
    }
}
