package surf.comma.android.settings

import android.content.Context
import surf.comma.android.R

/** What to tell the person when a change did not stick. */
internal object SettingsMessages {
    fun text(context: Context, notice: SettingsNotice): String = context.getString(resource(notice))

    fun resource(notice: SettingsNotice): Int = when (notice.action) {
        SettingsAction.LOAD_PROFILE -> R.string.settings_error_load_profile
        SettingsAction.RENAME -> when (notice.problem) {
            SettingsProblem.NAME_EMPTY -> R.string.settings_name_empty
            SettingsProblem.NAME_TOO_LONG -> R.string.settings_name_too_long
            else -> R.string.settings_error_save_profile
        }
        SettingsAction.CHANGE_AVATAR, SettingsAction.REMOVE_AVATAR -> when (notice.problem) {
            SettingsProblem.AVATAR_TOO_LARGE -> R.string.settings_avatar_too_large
            SettingsProblem.AVATAR_TYPE -> R.string.settings_avatar_type
            else -> R.string.settings_error_save_profile
        }
        SettingsAction.LABEL_POLICY -> R.string.settings_label_changes_error
        SettingsAction.LOAD_DEVICES -> R.string.settings_devices_failed
        SettingsAction.REMOVE_DEVICE -> R.string.settings_devices_remove_failed
        SettingsAction.REMOVE_OTHER_DEVICES -> R.string.settings_devices_sign_out_others_failed
        SettingsAction.THEME, SettingsAction.TEXT_SIZE, SettingsAction.LANGUAGE -> R.string.settings_error_local
    }
}
