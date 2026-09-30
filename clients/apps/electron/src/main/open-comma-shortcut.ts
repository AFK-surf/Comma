import type { SideChatShortcutBinding } from "@comma/native-bridge";

export interface OpenCommaShortcutPlatform {
  register(accelerator: string, callback: () => void): boolean;
  unregister(accelerator: string): void;
}

/** The Electron accelerator for a stored global-shortcut binding. */
export function shortcutAccelerator(shortcut: SideChatShortcutBinding) {
  return shortcut === null
    ? undefined
    : [
        ...(shortcut.modifiers.control ? ["Control"] : []),
        ...(shortcut.modifiers.alt ? ["Alt"] : []),
        ...(shortcut.modifiers.shift ? ["Shift"] : []),
        ...(shortcut.modifiers.meta ? ["Super"] : []),
        shortcut.key === "space" ? "Space" : shortcut.key.toUpperCase(),
      ].join("+");
}

/** Owns at most one OS registration; edits reserve the new chord before
 * releasing the old one so an unavailable chord cannot erase the binding. */
export class OpenCommaShortcut {
  #accelerator: string | undefined;
  constructor(
    private readonly platform: OpenCommaShortcutPlatform,
    private readonly open: () => void
  ) {}

  set(shortcut: SideChatShortcutBinding) {
    const accelerator = shortcutAccelerator(shortcut);
    if (accelerator === this.#accelerator) return;
    if (accelerator && !this.platform.register(accelerator, this.open)) {
      throw new Error(
        "The Open Comma global shortcut is unavailable. Choose another shortcut."
      );
    }
    const previous = this.#accelerator;
    this.#accelerator = accelerator;
    if (previous) this.platform.unregister(previous);
  }

  dispose() {
    this.set(null);
  }
}
