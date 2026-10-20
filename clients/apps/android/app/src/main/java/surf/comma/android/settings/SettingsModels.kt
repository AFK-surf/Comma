package surf.comma.android.settings

import surf.comma.android.settings.devices.CommaBoards

/** The signed-in person, as the client core's `profile` topic says. */
data class Profile(val id: String, val email: String, val name: String?, val avatarId: String?) {
    /** The name to show: the trimmed name, else [fallbackName], else the email. */
    fun displayName(fallbackName: String? = null): String =
        name?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackName?.trim()?.takeIf { it.isNotEmpty() } ?: email
}

/** What the avatar shows right now: the profile's avatar, which is a picked image while it uploads (the core's). */
sealed interface AvatarSource {
    data object None : AvatarSource
    data class Remote(val avatarId: String) : AvatarSource
}

/** One signed-in session of this account. Times are Unix seconds. */
data class DeviceSession(
    val id: String,
    val label: String?,
    val clientKind: String?,
    val clientPlatform: String?,
    val authenticatedAt: Long?,
    val lastSeenAt: Long?,
    val current: Boolean,
)

/** A Connector device of the workspace: a computer or a Comma device. Times are Unix seconds. */
data class HomeDevice(
    val id: String,
    val name: String,
    val online: Boolean,
    /** The Connector's hardware or application source. */
    val clientSource: String?,
    val disconnectedAt: Long?,
    /** Whether the device lets Comma act through it; off, it only answers reads. */
    val allowsOperations: Boolean = false,
) {
    val isCommaDevice: Boolean get() = clientSource in CommaBoards.clientSources
}

/** Whether the agent asks before it creates, edits or deletes workspace labels. */
enum class LabelPolicy(val wire: String) {
    ASK("ask"),
    AUTO("auto");

    companion object {
        fun parse(value: String?): LabelPolicy? = entries.firstOrNull { it.wire == value }
    }
}

enum class SettingsProblem { NETWORK, NAME_EMPTY, NAME_TOO_LONG, AVATAR_TOO_LARGE, AVATAR_TYPE, FORBIDDEN, SERVER, STORAGE }

/** A change that did not stick. The screen reverts to the server's value and says why. */
enum class SettingsAction {
    LOAD_PROFILE, RENAME, CHANGE_AVATAR, REMOVE_AVATAR, LABEL_POLICY, LOAD_DEVICES, REMOVE_DEVICE, REMOVE_OTHER_DEVICES,
    THEME, TEXT_SIZE, LANGUAGE,
}
data class SettingsNotice(val action: SettingsAction, val problem: SettingsProblem)

/** Immutable snapshot for the settings screens, always for one session generation. */
data class SettingsState(
    val generation: Long? = null,
    val profile: Profile? = null,
    val avatar: AvatarSource = AvatarSource.None,
    val profileLoading: Boolean = false,
    val profileProblem: SettingsProblem? = null,
    val labelPolicy: LabelPolicy? = null,
    val labelPolicyLoading: Boolean = false,
    val sessions: List<DeviceSession>? = null,
    val sessionsLoading: Boolean = false,
    val sessionsProblem: SettingsProblem? = null,
)

object ProfileRules {
    const val MAX_NAME_LENGTH = 64

    /** The server counts graphemes after trimming; so does this. */
    fun nameLength(name: String): Int {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return 0
        val iterator = java.text.BreakIterator.getCharacterInstance()
        iterator.setText(trimmed)
        var count = 0
        while (iterator.next() != java.text.BreakIterator.DONE) count++
        return count
    }

    fun problem(name: String): SettingsProblem? = when (nameLength(name)) {
        0 -> SettingsProblem.NAME_EMPTY
        in 1..MAX_NAME_LENGTH -> null
        else -> SettingsProblem.NAME_TOO_LONG
    }
}
