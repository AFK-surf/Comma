package surf.comma.android.core

import okhttp3.MediaType
import okhttp3.RequestBody
import okio.BufferedSink
import okio.source
import java.io.IOException
import java.io.InputStream

/**
 * Files a pick left with the app, which a product request's body can be (`localFileRef`): the core names one, the
 * app sends it as it reads it, so a large file is never held whole.
 */
fun interface HostLocalFiles {
    /** The file [ref] names, or null when the app holds none by that name. */
    fun open(ref: String): HostLocalFile?
}

/** A file of [size] bytes, read from [open] each time it is sent. */
class HostLocalFile(val size: Long, val open: () -> InputStream)

/** [length] bytes of the file from [offset]: fewer only where it ends. */
internal fun HostLocalFile.read(offset: Long, length: Int): ByteArray {
    val part = ByteArray(length)
    var got = 0
    open().use { stream ->
        var skipped = 0L
        while (skipped < offset) {
            val n = stream.skip(offset - skipped)
            if (n > 0) skipped += n else if (stream.read() >= 0) skipped++ else break
        }
        while (got < length) {
            val n = stream.read(part, got, length - got)
            if (n < 0) break
            got += n
        }
    }
    return if (got == length) part else part.copyOf(got)
}

/** [file] as a request's body: exactly its [HostLocalFile.size] bytes, or the request fails. */
internal class LocalFileBody(private val file: HostLocalFile, private val type: MediaType?) : RequestBody() {
    override fun contentType(): MediaType? = type
    override fun contentLength(): Long = file.size

    // Read again for each attempt: OkHttp may send the body more than once (a retried connection).
    override fun writeTo(sink: BufferedSink) {
        file.open().source().use { source ->
            var written = 0L
            while (true) {
                val read = source.read(sink.buffer, CHUNK_BYTES)
                if (read < 0) break
                written += read
                if (written > file.size) throw IOException("The file grew while it was sent.")
                sink.emitCompleteSegments()
            }
            if (written != file.size) throw IOException("The file shrank while it was sent.")
        }
    }

    private companion object { const val CHUNK_BYTES = 65_536L }
}
