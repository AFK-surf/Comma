package surf.comma.android.core

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.concurrent.TimeUnit

/** A file the app holds as a request's body: sent as it is read, exactly the size the core was told. */
class LocalFileBodyTest {
    private val server = MockWebServer().apply { start() }
    private val client = OkHttpClient.Builder().retryOnConnectionFailure(false).build()

    @After fun after() = server.shutdown()

    private fun put(file: HostLocalFile) = client.newCall(Request.Builder().url(server.url("/v1/comma/groups/g/files"))
        .put(LocalFileBody(file, "application/octet-stream".toMediaType())).build()).execute()

    @Test fun `the file goes as its bytes, its length the size given`() {
        val bytes = ByteArray(300_000) { (it % 251).toByte() }
        var opened = 0
        server.enqueue(MockResponse().setResponseCode(201))
        put(HostLocalFile(bytes.size.toLong()) { opened++; ByteArrayInputStream(bytes) }).use { assertEquals(201, it.code) }
        val received = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("300000", received.getHeader("content-length"))
        assertArrayEquals(bytes, received.body.readByteArray())
        assertEquals(1, opened)
    }

    @Test fun `a part of the file is read from where it is asked, up to where it ends`() {
        val bytes = ByteArray(300_000) { (it % 251).toByte() }
        val file = HostLocalFile(bytes.size.toLong()) { ByteArrayInputStream(bytes) }
        assertArrayEquals(bytes.copyOfRange(100_000, 200_000), file.read(100_000, 100_000))
        assertArrayEquals(bytes.copyOfRange(250_000, 300_000), file.read(250_000, 100_000))
        assertEquals(0, file.read(300_000, 10).size)
    }

    @Test fun `a file that is not the size given fails the request`() {
        server.enqueue(MockResponse().setResponseCode(201))
        assertThrows(IOException::class.java) { put(HostLocalFile(10) { ByteArrayInputStream(ByteArray(11)) }).close() }
        server.enqueue(MockResponse().setResponseCode(201))
        assertThrows(IOException::class.java) { put(HostLocalFile(10) { ByteArrayInputStream(ByteArray(9)) }).close() }
    }
}
