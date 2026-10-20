package surf.comma.android.ui.composer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts

/**
 * The system photo picker in multi-select mode, with the selection limit chosen per launch (the
 * free attachment slots) rather than fixed at registration. Input must be at least 2; a single
 * free slot uses the single-photo picker instead (see [PhotoPick]).
 */
internal class CappedPhotoPicker : ActivityResultContract<Int, List<Uri>>() {
    override fun createIntent(context: Context, input: Int): Intent =
        ActivityResultContracts.PickMultipleVisualMedia(input)
            .createIntent(context, PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))

    override fun parseResult(resultCode: Int, intent: Intent?): List<Uri> =
        ActivityResultContracts.PickMultipleVisualMedia().parseResult(resultCode, intent)

    companion object {
        /** The system picker's own selection cap. */
        fun systemLimit(): Int = MediaStore.getPickImagesMaxLimit()
    }
}
