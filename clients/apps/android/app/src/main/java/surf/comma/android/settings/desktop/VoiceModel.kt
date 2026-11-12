package surf.comma.android.settings.desktop

import android.media.AudioAttributes
import android.media.MediaDataSource
import android.media.MediaPlayer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.Base64
import java.util.Locale

/** Plays a voice sample; [finished] is told whether it played to the end. */
internal interface VoicePlayback {
    fun play(data: ByteArray, finished: (Boolean) -> Unit)
    fun stop()
}

/** Media playback (not the call's voice stream), so the sample is heard at the media volume. */
internal class MediaVoicePlayback : VoicePlayback {
    private var player: MediaPlayer? = null
    private var finished: ((Boolean) -> Unit)? = null

    override fun play(data: ByteArray, finished: (Boolean) -> Unit) {
        stop()
        val player = MediaPlayer()
        this.player = player
        this.finished = finished
        try {
            player.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            player.setDataSource(BytesSource(data))
            player.setOnCompletionListener { if (this.player === it) complete(true) }
            player.setOnErrorListener { mp, _, _ -> if (this.player === mp) complete(false); true }
            player.setOnPreparedListener { if (this.player === it) it.start() }
            player.prepareAsync()
        } catch (e: Exception) {
            stop()
            throw e
        }
    }

    override fun stop() {
        player?.release()
        player = null
        finished = null
    }

    private fun complete(success: Boolean) {
        val completion = finished
        stop()
        completion?.invoke(success)
    }

    private class BytesSource(private val bytes: ByteArray) : MediaDataSource() {
        override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
            if (position >= bytes.size) return -1
            val count = minOf(size.toLong(), bytes.size - position).toInt()
            System.arraycopy(bytes, position.toInt(), buffer, offset, count)
            return count
        }
        override fun getSize() = bytes.size.toLong()
        override fun close() = Unit
    }
}

/** A voice to choose: the platform's default (id ""), the Workspace's custom voice ("custom"), or a preset. */
internal data class VoiceOption(val id: String, val title: String?, val detail: String?, val presetLocale: String? = null, val female: Boolean? = null) {
    companion object {
        fun preset(name: String): VoiceOption {
            val info = PRESETS[name]
            return VoiceOption(name, name.replaceFirstChar { it.uppercase() }, null, info?.first, info?.second)
        }

        private val PRESETS: Map<String, Pair<String, Boolean>> = mapOf(
            "quartz" to ("en-AU" to true), "ripple" to ("en-AU" to false), "vesper" to ("en-GB" to false),
            "willow" to ("en-IE" to true), "stone" to ("en-IE" to false), "gleam" to ("en-US" to true),
            "meridian" to ("en-US" to false), "bossa" to ("pt-BR" to true), "tempo" to ("pt-BR" to false),
            "beacon" to ("en-PH" to false), "delta" to ("en-US" to true), "cinder" to ("en-US" to false),
            "nuri" to ("de" to true), "juni" to ("de" to true), "flitz" to ("de" to false), "brise" to ("fr" to true),
            "sillage" to ("fr" to false), "nira" to ("hi" to true), "harema" to ("ja" to true),
            "shida" to ("ja" to false), "noeul" to ("ko" to true),
        )
    }
}

internal sealed interface VoicePreview {
    val voice: String
    data class Loading(override val voice: String) : VoicePreview
    data class Playing(override val voice: String) : VoicePreview
}

/**
 * Settings > Voice settings: the Workspace's `voice` topic (numbers, call voice, readiness and its API keys), and
 * voice samples. A sample never changes the chosen voice; a newer one, choosing a voice or leaving stops it.
 */
internal class VoiceModel(val scope: WorkspaceScope, private val audio: VoicePlayback, private val language: () -> String = {
    Locale.getDefault().toLanguageTag()
}) {
    val feed = WorkspaceTopic(scope, "voice", json("prefer" to scope.workspaceId), workspaceField = true)
    private var previewRequest = 0
    private var previewJob: Job? = null
    var preview: VoicePreview? = null
        private set
    var previewFailed = false
        private set

    val integration get() = feed.value?.optJSONObject("integration")
    val preferences get() = integration?.optJSONObject("preferences")
    val selected: String
        get() {
            val voice = preferences?.optJSONObject("voice")
            return if (voice?.string("kind") == "custom") "custom" else voice?.string("name").orEmpty()
        }
    val customVoice: VoiceOption?
        get() {
            val custom = preferences?.optJSONObject("custom_voice") ?: return null
            return VoiceOption("custom", custom.string("name"), custom.string("description"))
        }
    val presetVoices get() = integration?.strings("voices").orEmpty().map(VoiceOption::preset)

    /** The chosen voice's own name; null for the default or the unnamed custom voice. */
    fun selectedOption(): VoiceOption? = when (selected) {
        "" -> null
        "custom" -> customVoice ?: VoiceOption("custom", null, null)
        else -> presetVoices.firstOrNull { it.id == selected } ?: VoiceOption.preset(selected)
    }

    fun choice(voice: String): Any = when (voice) {
        "" -> JSONObject.NULL
        "custom" -> json("kind" to "custom")
        else -> json("kind" to "preset", "name" to voice)
    }

    suspend fun select(voice: String): Boolean {
        stop()
        return scope.perform("voice.setPreferences", json("voice" to choice(voice))) != null
    }

    /** Plays [voice]'s sample; pressed again while it loads or plays, stops it. */
    fun preview(voice: String) {
        if (preview?.voice == voice) { stop(); return }
        stop()
        previewFailed = false
        if (!scope.current) { scope.changed(); return }
        val request = previewRequest
        preview = VoicePreview.Loading(voice)
        scope.changed()
        previewJob = scope.work.launch { loadPreview(voice, request) }
    }

    private suspend fun loadPreview(voice: String, request: Int) {
        try {
            val answer = scope.call("voice.preview", json("voice" to choice(voice), "language" to language())) as? JSONObject
            if (request != previewRequest) return
            val data = answer?.string("audio")?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
            if (data == null || data.isEmpty() || data.size > MAX_SAMPLE_BYTES) throw IllegalStateException("sample")
            preview = VoicePreview.Playing(voice)
            scope.changed()
            audio.play(data) { success ->
                if (previewRequest != request) return@play
                stop()
                if (!success) { previewFailed = true; scope.changed() }
            }
        } catch (e: CancellationException) {
            if (request == previewRequest) stop()
        } catch (e: Exception) {
            if (request != previewRequest) return
            stop()
            if (scope.current) { previewFailed = true; scope.changed() }
        }
    }

    fun stop() {
        previewRequest++
        previewJob?.cancel()
        previewJob = null
        audio.stop()
        if (preview != null) { preview = null; scope.changed() }
    }

    suspend fun refresh() { scope.perform("voice.refresh", workspaceParameter = false) }

    private companion object { const val MAX_SAMPLE_BYTES = 10 * 1024 * 1024 }
}

/**
 * A Workspace's API keys: the voice agent's (inline on Voice settings, sharing its subscription) or the Router's. A
 * created key's full value is kept only until its page closes or the member is done with it.
 */
internal class ApiKeysModel(val feed: WorkspaceTopic, val voice: Boolean) {
    val scope get() = feed.scope
    var created: JSONObject? = null
        private set

    val keys get() = feed.value?.objects("keys").orEmpty()
    val secret get() = created?.string("key")

    /** Creates a key; [expiresAt] (Unix seconds) only for voice keys. */
    suspend fun create(name: String, expiresAt: Long? = null): Boolean {
        val params = json("name" to name.trim())
        if (voice && expiresAt != null) params.put("expiresAt", expiresAt)
        created = scope.perform(if (voice) "voice.createKey" else "routerKeys.create", params)?.json
        scope.changed()
        return created != null
    }

    fun clearSecret() {
        if (created == null) return
        created = null
        scope.changed()
    }

    fun rename(key: String, name: String) =
        scope.launch(if (voice) "voice.updateKey" else "routerKeys.rename", json("key" to key, "name" to name.trim()))

    fun setActive(key: String, active: Boolean) = scope.launch(if (voice) "voice.updateKey" else "routerKeys.setStatus",
        json("key" to key, "status" to if (active) "active" else "disabled"))

    fun delete(key: String) = scope.launch(if (voice) "voice.deleteKey" else "routerKeys.delete", json("key" to key))

    companion object {
        fun router(scope: WorkspaceScope) =
            ApiKeysModel(WorkspaceTopic(scope, "routerKeys", json("prefer" to scope.workspaceId), workspaceField = true), voice = false)
    }
}
