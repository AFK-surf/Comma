import {
  chordKeybinding,
  sequenceKeybinding,
  type AppKeybinding,
  type AppKeybindingPlatform,
} from "@comma/ui";

export type AppShortcutId =
  | "go-settings"
  | "go-comma-assistant"
  | "go-search"
  | "go-inbox"
  | "go-drive"
  | "go-tasks"
  | "go-plugins"
  | "toggle-left-sidebar"
  | "history-back"
  | "history-forward"
  | "toggle-right-sidebar";

export type AppShortcutDefinition = {
  id: AppShortcutId;
  /** Stable settings row id under keyboard-shortcuts. */
  settingsItemId: string;
};

export const appShortcutDefinitions = [
  { id: "go-settings", settingsItemId: "keyboard.go-settings" },
  { id: "go-comma-assistant", settingsItemId: "keyboard.go-comma-assistant" },
  { id: "go-search", settingsItemId: "keyboard.go-search" },
  { id: "go-inbox", settingsItemId: "keyboard.go-inbox" },
  { id: "go-drive", settingsItemId: "keyboard.go-drive" },
  { id: "go-tasks", settingsItemId: "keyboard.go-tasks" },
  { id: "go-plugins", settingsItemId: "keyboard.go-plugins" },
  { id: "toggle-left-sidebar", settingsItemId: "keyboard.toggle-left-sidebar" },
  { id: "history-back", settingsItemId: "keyboard.history-back" },
  { id: "history-forward", settingsItemId: "keyboard.history-forward" },
  { id: "toggle-right-sidebar", settingsItemId: "keyboard.toggle-right-sidebar" },
] as const satisfies readonly AppShortcutDefinition[];

export type AppShortcutBindings = Record<AppShortcutId, AppKeybinding | null>;
export type AppShortcutPlatform = AppKeybindingPlatform;

export const createDefaultAppShortcutBindings = (
  platform: AppShortcutPlatform
): AppShortcutBindings => {
  const primary =
    platform === "macos" ? ({ meta: true } as const) : ({ control: true } as const);

  return {
    "go-settings": chordKeybinding("Comma", primary),
    "go-comma-assistant": sequenceKeybinding("KeyG", "KeyC"),
    "go-search": chordKeybinding("KeyK", primary),
    "go-inbox": sequenceKeybinding("KeyG", "KeyI"),
    "go-drive": sequenceKeybinding("KeyG", "KeyD"),
    "go-tasks": sequenceKeybinding("KeyG", "KeyT"),
    "go-plugins": sequenceKeybinding("KeyG", "KeyP"),
    "toggle-left-sidebar": chordKeybinding("KeyB", primary),
    "history-back": chordKeybinding("BracketLeft", primary),
    "history-forward": chordKeybinding("BracketRight", primary),
    "toggle-right-sidebar": chordKeybinding("KeyB", {
      ...primary,
      alt: true,
    }),
  };
};

export const appShortcutIds = appShortcutDefinitions.map(
  (definition) => definition.id
) as AppShortcutId[];
