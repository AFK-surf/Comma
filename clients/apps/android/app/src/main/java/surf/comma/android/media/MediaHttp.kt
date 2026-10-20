package surf.comma.android.media

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import surf.comma.android.ui.Background

class MediaHttpException(val status: Int) : IOException("Media request failed ($status)")

/** Keep the cancellation hook alive until the response body has been fully consumed. */
internal suspend fun <T> Call.consume(block: suspend (Response) -> T): T = withContext(Background.files) {
    val call = this@consume
    suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }
            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { _, value, _ -> value.close() }
            }
        })
    }.use { response ->
        // suspendCancellableCoroutine's handler no longer covers the blocking body read.
        kotlinx.coroutines.coroutineScope {
            val owner = currentCoroutineContext()[kotlinx.coroutines.Job]!!
            @OptIn(kotlinx.coroutines.InternalCoroutinesApi::class)
            val cancellation = owner.invokeOnCompletion(onCancelling = true, invokeImmediately = true) {
                if (it != null) call.cancel()
            }
            try {
                currentCoroutineContext().ensureActive()
                if (!response.isSuccessful) throw MediaHttpException(response.code)
                block(response)
            } catch (failure: IOException) {
                // Socket.close from cancellation surfaces as IOException in a blocking read.
                currentCoroutineContext().ensureActive()
                throw failure
            } finally {
                cancellation.dispose()
            }
        }
    }
}
