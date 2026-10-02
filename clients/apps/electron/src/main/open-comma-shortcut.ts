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
        shortcut.key === "space"
          ? "Space"
          : shortcut.key === "comma"
            ? ","
            : shortcut.key.toUpperCase(),
      ].join("+");
}

/** Owns at most one OS registration; edits reserve the new chord before
 * releasing the old one so an unavailable chord cannot erase the binding.
 * Suspended, it holds none: the chord's keys reach the focused window. */
export class OpenCommaShortcut {
  #accelerator: string | undefined;
  #suspended = false;
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
    if (this.#suspended) {
      // Reserved only to check it is free; held once the suspension ends.
      if (accelerator) this.platform.unregister(accelerator);
      return;
    }
    if (previous) this.platform.unregister(previous);
  }

  /**
   * The onboarding teaches this shortcut: while its window is open the keys
   * reach that window instead of opening Comma. The binding is kept and held
   * again when the suspension ends. Returns false when another app took the
   * chord meanwhile; the binding is then not held until it is set again.
   */
  setSuspended(suspended: boolean) {
    if (this.#suspended === suspended) return true;
    this.#suspended = suspended;
    const accelerator = this.#accelerator;
    if (!accelerator) return true;
    if (suspended) {
      this.platform.unregister(accelerator);
      return true;
    }
    if (this.platform.register(accelerator, this.open)) return true;
    this.#accelerator = undefined;
    return false;
  }

  dispose() {
    this.set(null);
  }
}
