package surf.comma.android.media

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class) // MimeTypeMap
@Config(sdk = [35])
class MediaRoutingTest {
    private fun blob(size: Long) = MediaSource.AgentResource("agent", MediaBlobRef("a".repeat(32), "b".repeat(64), size))
    private fun display(name: String?, mime: String?, size: Long? = 1_000, source: MediaSource? = blob(1_000)) =
        MediaRouting.display(MediaAttachment(name, mime, size, source))

    @Test fun onlyTheClosedListIsInlineAndEverythingElseIsAFileCard() {
        assertEquals(AttachmentDisplay.IMAGE, display("a.png", "image/png"))
        assertEquals(AttachmentDisplay.IMAGE, display("a.JPG", "image/jpg"))
        assertEquals(AttachmentDisplay.VIDEO, display("a.mp4", "video/mp4"))
        assertEquals(AttachmentDisplay.VIDEO, display("a.m4v", "video/x-m4v"))
        assertEquals(AttachmentDisplay.VIDEO, display("a.webm", null))
        assertEquals(AttachmentDisplay.VIDEO, display("a.webm", "application/octet-stream"))
        for ((name, mime) in listOf("a.svg" to "image/svg+xml", "a.html" to "text/html", "a.pdf" to "application/pdf",
                "a.heic" to "image/heic", "a.mov" to "video/quicktime", "a.png" to "text/html", "a.mp4" to "image/png")) {
            assertEquals("$name $mime", AttachmentDisplay.FILE, display(name, mime))
        }
    }

    @Test fun byteSizeDoesNotDisableSupportedInlineMedia() {
        assertEquals(AttachmentDisplay.VIDEO, display("a.mp4", "video/mp4", size = 10_000_000, source = blob(10_000_000)))
        assertEquals(AttachmentDisplay.VIDEO, display("a.mp4", "video/mp4", size = 25_000_000, source = blob(25_000_000)))
        assertEquals(AttachmentDisplay.IMAGE, display("a.png", "image/png", size = 25_000_000, source = blob(25_000_000)))
        assertEquals(AttachmentDisplay.FILE, display("a.png", "image/png", size = 50_000_000, source = null))
        // A source with no display size remains available.
        assertEquals(AttachmentDisplay.VIDEO, display("a.mp4", "video/mp4", size = null, source = blob(9_000_000)))
    }

    @Test fun nothingToDownloadMeansAFileCard() {
        assertEquals(AttachmentDisplay.FILE, display("a.png", "image/png", source = null))
        assertEquals(AttachmentDisplay.FILE, display("a.mp4", "video/mp4", source = null))
    }

    @Test fun fileKindsPreferASpecificDeclaredTypeAndOtherwiseTheExtension() {
        assertEquals(FileKind.PDF, FileKinds.kind("report", "application/pdf"))
        assertEquals(FileKind.PDF, FileKinds.kind("report.pdf", "application/octet-stream"))
        assertEquals(FileKind.CODE, FileKinds.kind("x.svg", "image/svg+xml"))
        assertEquals(FileKind.CODE, FileKinds.kind("page.html", "text/html"))
        assertEquals(FileKind.CODE, FileKinds.kind("main.kt", "text/plain"))
        assertEquals(FileKind.TEXT, FileKinds.kind("notes.txt", "text/plain"))
        assertEquals(FileKind.TEXT, FileKinds.kind("sheet.xlsx", null))
        assertEquals(FileKind.ARCHIVE, FileKinds.kind("bundle.zip", ""))
        assertEquals(FileKind.ARCHIVE, FileKinds.kind("bundle", "application/zip"))
        assertEquals(FileKind.AUDIO, FileKinds.kind("voice", "audio/ogg"))
        assertEquals(FileKind.VIDEO, FileKinds.kind("clip.mov", null))
        assertEquals(FileKind.IMAGE, FileKinds.kind("photo.heic", "image/heic"))
        assertEquals(FileKind.OTHER, FileKinds.kind("data.bin", "application/x-thing"))
        assertEquals(FileKind.OTHER, FileKinds.kind(null, null))
    }

    @Test fun openTypeAndSafeNames() {
        assertEquals("application/pdf", FileKinds.openType("a.bin", "application/pdf"))
        assertEquals("text/html", FileKinds.openType("a.html", "text/html; charset=utf-8"))
        assertEquals("image/jpeg", FileKinds.openType("a.jpg", "image/jpg"))
        assertEquals("application/octet-stream", FileKinds.openType("a.unknownext", null))
        assertEquals("report.pdf", FileKinds.safeFileName("../../etc/report.pdf"))
        assertEquals("ab.txt", FileKinds.safeFileName("a:b*.txt"))
        assertEquals("attachment", FileKinds.safeFileName(".."))
        assertEquals("attachment", FileKinds.safeFileName(null))
        assertEquals("季度报告.pdf", FileKinds.safeFileName("季度报告.pdf"))
        val long = FileKinds.safeFileName("x".repeat(300) + ".pdf")
        assertEquals(120, long.length)
        assertEquals(".pdf", long.takeLast(4))
    }
}
