import { useCommaMessages } from "@comma/i18n/react";
import type { AppShortcutId } from "./appShortcutRegistry";

export type AppShortcutCopy = Record<
  AppShortcutId,
  { title: string; description: string }
>;

/** What Settings and the command palette call each app shortcut command. */
export function useAppShortcutCopy(): AppShortcutCopy {
  const m = useCommaMessages();
  return {
    "go-settings": {
      title: m.settings_go_settings(),
      description: m.settings_go_settings_description(),
    },
    "go-comma-assistant": {
      title: m.settings_go_comma_assistant(),
      description: m.settings_go_comma_assistant_description(),
    },
    "go-search": {
      title: m.settings_go_search(),
      description: m.settings_go_search_description(),
    },
    "go-inbox": {
      title: m.settings_go_inbox(),
      description: m.settings_go_inbox_description(),
    },
    "go-drive": {
      title: m.settings_go_drive(),
      description: m.settings_go_drive_description(),
    },
    "go-tasks": {
      title: m.settings_go_tasks(),
      description: m.settings_go_tasks_description(),
    },
    "go-plugins": {
      title: m.settings_go_plugins(),
      description: m.settings_go_plugins_description(),
    },
    "toggle-left-sidebar": {
      title: m.settings_toggle_left_sidebar(),
      description: m.settings_toggle_left_sidebar_description(),
    },
    "history-back": {
      title: m.settings_history_back(),
      description: m.settings_history_back_description(),
    },
    "history-forward": {
      title: m.settings_history_forward(),
      description: m.settings_history_forward_description(),
    },
    "toggle-right-sidebar": {
      title: m.settings_toggle_right_sidebar(),
      description: m.settings_toggle_right_sidebar_description(),
    },
  };
}
