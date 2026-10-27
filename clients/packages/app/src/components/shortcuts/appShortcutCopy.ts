import { messages, type CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import type { AppShortcutId } from "./appShortcutRegistry";

export type AppShortcutCopy = Record<
  AppShortcutId,
  { title: string; description: string }
>;

type Message = (inputs?: undefined, options?: { locale?: CommaLocale }) => string;

const copyMessages: Record<AppShortcutId, { title: Message; description: Message }> = {
  "go-settings": {
    title: messages.settings_go_settings,
    description: messages.settings_go_settings_description,
  },
  "go-comma-assistant": {
    title: messages.settings_go_comma_assistant,
    description: messages.settings_go_comma_assistant_description,
  },
  "go-search": {
    title: messages.settings_go_search,
    description: messages.settings_go_search_description,
  },
  "go-inbox": {
    title: messages.settings_go_inbox,
    description: messages.settings_go_inbox_description,
  },
  "go-drive": {
    title: messages.settings_go_drive,
    description: messages.settings_go_drive_description,
  },
  "go-tasks": {
    title: messages.settings_go_tasks,
    description: messages.settings_go_tasks_description,
  },
  "go-plugins": {
    title: messages.settings_go_plugins,
    description: messages.settings_go_plugins_description,
  },
  "toggle-left-sidebar": {
    title: messages.settings_toggle_left_sidebar,
    description: messages.settings_toggle_left_sidebar_description,
  },
  "history-back": {
    title: messages.settings_history_back,
    description: messages.settings_history_back_description,
  },
  "history-forward": {
    title: messages.settings_history_forward,
    description: messages.settings_history_forward_description,
  },
  "toggle-right-sidebar": {
    title: messages.settings_toggle_right_sidebar,
    description: messages.settings_toggle_right_sidebar_description,
  },
};

/** What Settings and the command palette call each app shortcut command. */
export function useAppShortcutCopy(): AppShortcutCopy {
  useCommaMessages();
  return Object.fromEntries(
    Object.entries(copyMessages).map(([id, copy]) => [
      id,
      { title: copy.title(), description: copy.description() },
    ])
  ) as AppShortcutCopy;
}

/** A shortcut command's title in `locale`: the palette also finds it by its English name. */
export function appShortcutTitle(id: AppShortcutId, locale: CommaLocale) {
  return copyMessages[id].title(undefined, { locale });
}
