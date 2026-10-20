package surf.comma.android.platform.photo

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.CancellationException
import surf.comma.android.platform.logging.AppLog
import surf.comma.android.ui.Background
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.coroutines.coroutineContext

internal const val MAX_CONVERSATION_IMAGE_BYTES = 16 * 1024 * 1024

/** Imports a picker result into app-owned storage before its temporary grant can expire. */
object PickedImageStore {
    suspend fun import(context: Context, source: Uri): Uri? = withContext(Background.files) {
        val directory = File(context.applicationContext.filesDir, "conversation_images")
        if (!directory.exists() && !directory.mkdirs()) return@withContext null
        val id = UUID.randomUUID().toString()
        val temporary = File(directory, ".$id.tmp")
        val destination = File(directory, "$id.image")
        val copied = try {
            context.contentResolver.openInputStream(source)?.use { input ->
                temporary.outputStream().use outputUse@{ output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val remaining = MAX_CONVERSATION_IMAGE_BYTES - total
                        val read = input.read(
                            buffer,
                            0,
                            minOf(buffer.size.toLong(), remaining + 1).toInt(),
                        )
                        if (read < 0) break
                        total += read
                        if (total > MAX_CONVERSATION_IMAGE_BYTES) return@outputUse false
                        output.write(buffer, 0, read)
                    }
                    total > 0
                }
            } ?: false
        } catch (cancelled: CancellationException) {
            temporary.delete()
            throw cancelled
        } catch (error: Exception) {
            AppLog.warn("PickedImageStore", error, "Unable to persist picked image")
            false
        }
        if (!copied || !temporary.renameTo(destination)) {
            temporary.delete()
            return@withContext null
        }
        Uri.fromFile(destination)
    }

    suspend fun deleteIfOwned(context: Context, uri: Uri): Unit = withContext(Background.files) {
        if (uri.scheme != "file") return@withContext
        val directory = runCatching {
            File(context.applicationContext.filesDir, "conversation_images").canonicalFile
        }.getOrNull() ?: return@withContext
        val file = runCatching { uri.path?.let(::File)?.canonicalFile }
            .getOrNull() ?: return@withContext
        if (file.parentFile == directory && file.name.endsWith(".image")) {
            runCatching { file.delete() }
        }
        Unit
    }
}
