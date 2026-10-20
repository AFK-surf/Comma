package surf.comma.android.core

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** The core's downloads as the app writes them: whole files only, in place of what was there, under the root. */
class HostDownloadsTest {
    @get:Rule val folder = TemporaryFolder()
    private val server = MockWebServer().apply { start() }
    private val client = OkHttpClient()
    private val downloads by lazy { HostDownloads(File(folder.root, "downloads")) }

    @After fun after() = server.shutdown()

    private fun get(body: MockResponse): Response {
        server.enqueue(body)
        return client.newCall(Request.Builder().url(server.url("/file")).build()).execute()
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test fun aWholeBodyTakesItsPlaceWithItsSizeAndHash() {
        val bytes = ByteArray(200_000) { (it * 7).toByte() }
        val id = downloads.begin(get(MockResponse().setBody(Buffer().write(bytes))), "account/key/clip.mp4")
        var step: Map<String, Any>
        val received = mutableListOf<Long>()
        do {
            step = downloads.step(id) { true }
            (step["received"] as? Long)?.let(received::add)
        } while ("sha256" !in step)
        assertTrue("says how much arrived on the way", received.isNotEmpty())
        assertEquals(bytes.size.toLong(), step["size"])
        assertEquals(sha256(bytes), step["sha256"])
        val file = downloads.file("account/key/clip.mp4")!!
        assertArrayEquals(bytes, file.readBytes())
        assertEquals(listOf("clip.mp4"), file.parentFile!!.list()!!.toList())
    }

    @Test fun aGivenUpOrBrokenDownloadLeavesNothing() {
        val bytes = ByteArray(200_000) { it.toByte() }
        val id = downloads.begin(get(MockResponse().setBody(Buffer().write(bytes))), "account/key/a.bin")
        downloads.step(id) { true }
        downloads.close(id)
        assertTrue(File(folder.root, "downloads").walkTopDown().none { it.isFile })
        // The session ended while it ran: it stops, and nothing stays.
        val ended = downloads.begin(get(MockResponse().setBody(Buffer().write(bytes))), "account/key/b.bin")
        assertThrows(IOException::class.java) { downloads.step(ended) { false } }
        assertTrue(File(folder.root, "downloads").walkTopDown().none { it.isFile })
    }

    @Test fun pathsStayUnderTheRootAndRetainKeepsOneAccount() {
        assertNull(downloads.file("../outside"))
        assertThrows(IOException::class.java) {
            downloads.begin(get(MockResponse().setBody("x")), "../outside/x")
        }
        File(folder.root, "downloads/a/k/x").apply { parentFile!!.mkdirs(); writeText("a") }
        File(folder.root, "downloads/b/k/y").apply { parentFile!!.mkdirs(); writeText("b") }
        downloads.retain("a")
        assertTrue(File(folder.root, "downloads/a/k/x").exists())
        assertFalse(File(folder.root, "downloads/b").exists())
        downloads.remove("a/k")
        assertFalse(File(folder.root, "downloads/a/k").exists())
        downloads.retain(null)
        assertTrue(File(folder.root, "downloads").list()!!.isEmpty())
    }
}
