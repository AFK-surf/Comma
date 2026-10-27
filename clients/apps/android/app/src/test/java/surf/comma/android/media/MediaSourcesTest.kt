package surf.comma.android.media

import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.chat.live.toChatAttachment

internal class FakeAuthorizedHttp(session: AuthorizedSession? = testSession()) : AuthorizedHttp {
    override val session = MutableStateFlow(session)
}
internal fun testSession(generation: String = "epoch-1", group: String = "group", url: String = "https://example.test/") =
    AuthorizedSession(MediaSessionId("account", generation, group), url.toHttpUrl())

internal fun testRef() = MediaBlobRef("a".repeat(32), "b".repeat(64), 100)
internal const val UPLOAD_PATH = "/uploads/abcdefghijklmnopqrstuv-image.jpg"

class MediaSourcesTest {
    @Test fun aFileIsAskedOfTheCoreByItsSourceInTheSessionsGroup() {
        val blob = MediaSource.AgentResource("agent/1", testRef()).fileSource("group")
        assertEquals("agent-blob", blob.getString("source"))
        assertEquals("agent/1", blob.getString("agent"))
        assertEquals(setOf("kind", "uuid", "hash", "size"), blob.getJSONObject("blobRef").keys().asSequence().toSet())
        val attachment = MediaSource.MessageAttachment("c/1", "m?2", 7, testRef()).fileSource("group")
        assertEquals(listOf("attachment", "group", "c/1", "m?2", 7),
            listOf("source", "group", "conversation", "message", "index").map(attachment::get))
        val file = MediaSource.UploadedFile(UPLOAD_PATH).fileSource("group")
        assertEquals(listOf("group-file", UPLOAD_PATH), listOf(file.get("source"), file.get("path")))
    }

    @Test fun invalidRefsAndOrdinaryWorkspacePathsAreNotDownloadCapabilities() {
        listOf("/workspace/image.png", "/.conversation-attachments/a.png", "/uploads/short-a.png", UPLOAD_PATH + "/../a.jpg").forEach {
            assertThrows(IllegalArgumentException::class.java) { MediaSource.UploadedFile(it) }
        }
        assertThrows(IllegalArgumentException::class.java) { MediaBlobRef("A".repeat(32), "b".repeat(64), 1) }
        assertThrows(IllegalArgumentException::class.java) { testRef().copy(size = -1) }
        assertEquals(25_000_000L, testRef().copy(size = 25_000_000).size)
    }

    @Test fun keysIncludeSessionAccountGroupAndOriginAndUseBlobHash() {
        val session = testSession()
        val source = MediaSource.AgentResource("agent", testRef())
        val key = mediaCacheKey(session, source)
        assertEquals(key, mediaCacheKey(session, source.copy(ref = testRef().copy(uuid = "c".repeat(32)))))
        listOf(session.copy(id = session.id.copy(accountId = "other")), session.copy(id = session.id.copy(generation = "epoch-2")),
            session.copy(id = session.id.copy(groupId = "other")), session.copy(baseUrl = "https://other.test/".toHttpUrl())).forEach {
            assertNotEquals(key, mediaCacheKey(it, source))
        }
        val a = MediaSource.MessageAttachment("c", "m", 0, testRef())
        assertNotEquals(mediaCacheKey(session, a), mediaCacheKey(session, a.copy(index = 1)))
    }

    @Test fun aFileTheCoreReadsByItsPlaceAloneIsAskedForByItsPlace() {
        // A Task a station hosts: its message's file names its place, and no blob.
        val file = surf.comma.android.conversation.MessageAttachment(
            blockType = "image", blockIndex = 0, fileName = "shot.png", title = null, mimeType = null, size = 3,
            workspacePath = null, widthPx = null, heightPx = null, blobRef = null, agentId = null, downloadable = true,
        )
        val source = file.toChatAttachment("station:st:7", "7:4", "image").file.source
        assertEquals(MediaSource.MessageAttachment("station:st:7", "7:4", 0, null), source)
        assertEquals(listOf("attachment", "station:st:7", "7:4", 0),
            listOf("source", "conversation", "message", "index").map(source!!.fileSource("group")::get))
        assertNull(source.ref)
    }
}
