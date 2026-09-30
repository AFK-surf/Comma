import type { SideChatShortcut, SideChatShortcutBinding } from "@comma/native-bridge";
import { sameAppKeyModifiers, type AppKeybinding, type AppKeyCode } from "@comma/ui";
import {
  appShortcutIds,
  type AppShortcutBindings,
  type AppShortcutId,
} from "./appShortcutRegistry";

const sideChatKeyCode = (shortcut: SideChatShortcut): AppKeyCode | "Space" =>
  shortcut.key === "space"
    ? "Space"
    : /^[0-9]$/.test(shortcut.key)
      ? (`Digit${shortcut.key}` as AppKeyCode)
      : (`Key${shortcut.key.toLocaleUpperCase()}` as AppKeyCode);

export const appBindingConflictsWithSideChatShortcut = (
  binding: AppKeybinding | null,
  shortcut: SideChatShortcutBinding
) =>
  shortcut !== null &&
  binding?.kind === "chord" &&
  binding.stroke.code === sideChatKeyCode(shortcut) &&
  sameAppKeyModifiers(binding.stroke.modifiers, shortcut.modifiers);

export const findAppShortcutConflictForSideChat = (
  bindings: AppShortcutBindings,
  shortcut: SideChatShortcutBinding
): AppShortcutId | undefined =>
  appShortcutIds.find((id) =>
    appBindingConflictsWithSideChatShortcut(bindings[id], shortcut)
  );

export const sameGlobalShortcut = (
  left: SideChatShortcutBinding,
  right: SideChatShortcutBinding
) =>
  left !== null &&
  right !== null &&
  left.key === right.key &&
  sameAppKeyModifiers(left.modifiers, right.modifiers);
