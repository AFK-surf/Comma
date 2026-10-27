import type { GlobalShortcut, GlobalShortcutBinding } from "@comma/native-bridge";
import {
  sameAppKeyModifiers,
  type AppKeybinding,
  type AppKeyCode,
} from "@comma/ui/components/settings-shortcut";
import {
  appShortcutIds,
  type AppShortcutBindings,
  type AppShortcutId,
} from "./appShortcutRegistry";

const globalShortcutKeyCode = (shortcut: GlobalShortcut): AppKeyCode | "Space" =>
  shortcut.key === "space"
    ? "Space"
    : shortcut.key === "comma"
      ? "Comma"
      : /^[0-9]$/.test(shortcut.key)
        ? (`Digit${shortcut.key}` as AppKeyCode)
        : (`Key${shortcut.key.toLocaleUpperCase()}` as AppKeyCode);

export const appBindingConflictsWithGlobalShortcut = (
  binding: AppKeybinding | null,
  shortcut: GlobalShortcutBinding
) =>
  shortcut !== null &&
  binding?.kind === "chord" &&
  binding.stroke.code === globalShortcutKeyCode(shortcut) &&
  sameAppKeyModifiers(binding.stroke.modifiers, shortcut.modifiers);

export const findAppShortcutConflictForGlobalShortcut = (
  bindings: AppShortcutBindings,
  shortcut: GlobalShortcutBinding
): AppShortcutId | undefined =>
  appShortcutIds.find((id) =>
    appBindingConflictsWithGlobalShortcut(bindings[id], shortcut)
  );

/** Whether two global shortcuts are the same chord; never for an unset one. */
export const sameGlobalShortcut = (
  left: GlobalShortcutBinding,
  right: GlobalShortcutBinding
) =>
  left !== null &&
  right !== null &&
  left.key === right.key &&
  sameAppKeyModifiers(left.modifiers, right.modifiers);
