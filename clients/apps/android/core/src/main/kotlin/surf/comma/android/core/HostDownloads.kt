package surf.comma.android.core

import okhttp3.Response
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * The client core's downloads (`DownloadPorts` in the core's Android host): files of any size written from the network
 * straight to [root], each under the path the core names. A file takes its place only once its body is whole; until
 * then it is a partial file beside it, removed when the download is given up. The core decides what is downloaded,
 * kept and removed; this class moves the bytes.
 */
class HostDownloads(val root: File) {
    private class Download(val response: Response, val target: File, val partial: File, val out: OutputStream) {
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var received = 0L
    }

    private val open = ConcurrentHashMap<Long, Download>()
    private val next = AtomicLong(1)

    /** The file at [path] under [root]; null for a path that leaves it. */
    fun file(path: String): File? {
        val file = File(root, path)
        val base = root.canonicalPath + File.separator
        return file.takeIf { it.canonicalPath.startsWith(base) }
    }

    /** A 200 [response] begins writing to [path]: its id. */
    fun begin(response: Response, path: String): Long {
        val target = file(path) ?: throw IOException("The path leaves the download directory.")
        check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs()) { "Cannot make the download directory." }
        val id = next.getAndIncrement()
        val partial = File(target.parentFile, ".${target.name}.partial-$id")
        open[id] = Download(response, target, partial, partial.outputStream())
        return id
    }

    /**
     * Writes what arrives, at least [CHUNK] bytes unless the body ends: how much is written, or once the body is whole
     * the file in place with its size and SHA-256.
     */
    fun step(id: Long, current: () -> Boolean): Map<String, Any> {
        val download = open[id] ?: throw IOException("No such download.")
        try {
            val source = download.response.body?.source() ?: throw IOException("The answer has no body.")
            val buffer = ByteArray(CHUNK.toInt())
            var read = 0L
            while (read < CHUNK) {
                if (!current()) throw IOException("The session ended.")
                val count = source.read(buffer)
                if (count < 0) return finish(id, download)
                download.out.write(buffer, 0, count)
                download.digest.update(buffer, 0, count)
                download.received += count
                read += count
            }
            return mapOf("received" to download.received)
        } catch (e: Exception) {
            close(id)
            throw e
        }
    }

    private fun finish(id: Long, download: Download): Map<String, Any> {
        open.remove(id)
        download.out.close()
        download.response.close()
        val declared = download.response.body?.contentLength()?.takeIf { it >= 0 }
        if (declared != null && declared != download.received) {
            download.partial.delete()
            throw IOException("The answer broke off.")
        }
        if (!download.partial.renameTo(download.target)) {
            download.target.delete()
            if (!download.partial.renameTo(download.target)) {
                download.partial.delete()
                throw IOException("Cannot put the download in place.")
            }
        }
        return mapOf("size" to download.received,
            "sha256" to download.digest.digest().joinToString("") { "%02x".format(it) })
    }

    /** Gives a download up: nothing of it stays. */
    fun close(id: Long) {
        val download = open.remove(id) ?: return
        runCatching { download.out.close() }
        download.response.close()
        download.partial.delete()
    }

    fun closeAll() = open.keys.toList().forEach(::close)

    fun remove(path: String) {
        file(path)?.deleteRecursively()
    }

    /** Removes every top-level directory but [keep]; everything when it is null. */
    fun retain(keep: String?) {
        root.listFiles()?.filter { it.name != keep }?.forEach { it.deleteRecursively() }
    }

    private companion object {
        const val CHUNK = 64L * 1024
    }
}
