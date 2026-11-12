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
    /** Whether its station serves its screen and devices on the mesh (`screen_view`), the way this app views them. */
    val screenView: Boolean = false,
    /** What it was set up as (`device_kind`): null for a computer, `stillfail` for a still.fail station. */
    val kind: String? = null,
) {
    val isCommaDevice: Boolean get() = clientSource in CommaBoards.clientSources
    /** A still.fail station: it takes Tasks only, with no access value. */
    val isStillfailStation: Boolean get() = kind == "stillfail"
    /** "View screen", and its simulators and devices, are offered: online, and its station serves them on the mesh. */
    val showsScreen: Boolean get() = online && screenView
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
    THEME, TEXT_SIZE, LANGUAGE, GLASS,
}
data class SettingsNotice(val action: SettingsAction, val problem: SettingsProblem)

/** What a step of deleting the account came to. */
sealed interface AccountDeletion {
    data class CodeSent(val challengeId: String) : AccountDeletion
    /** The account is gone; the core ends the session, and the app shows sign-in. */
    data object Deleted : AccountDeletion
    /** A subscription still renews; renewal is turned off on the web or the Mac first. */
    data object SubscriptionActive : AccountDeletion
    data object InvalidCode : AccountDeletion
    /** Codes were asked for too often; wait, then try again. */
    data object RateLimited : AccountDeletion
    data object Failed : AccountDeletion
}

/** What a step of changing the account's email came to. */
sealed interface EmailChange {
    /** A code went to the current email ([email] null) or to the new [email]. */
    data class CodeSent(val challengeId: String, val email: String? = null) : EmailChange
    /** The email changed; the profile shows the new one. */
    data object Changed : EmailChange
    data object InvalidCode : EmailChange
    data object InvalidEmail : EmailChange
    data object SameEmail : EmailChange
    /** Another account has the new email. */
    data object Taken : EmailChange
    /** The account with the new email is deleted at [until] (epoch millis); until then it is not free. */
    data class PendingDeletion(val until: Long) : EmailChange
    /** The email changed meanwhile; start again. */
    data object Stale : EmailChange
    data object RateLimited : EmailChange
    data object Failed : EmailChange
}

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
