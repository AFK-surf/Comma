import type { SideChatShortcut } from "@comma/native-bridge";
import { isMediaMuteShortcut } from "@comma/ui";

export type OnboardingKeycapId = "control" | "alt" | "shift" | "meta" | "key";

/** One key of the Side Chat shortcut, as the Mac keyboard prints it. */
export type OnboardingKeycap = {
  id: OnboardingKeycapId;
  /** The `KeyboardEvent.code` positions that press it. */
  codes: readonly string[];
  /** A modifier's symbol, printed beside its name. */
  glyph: string | undefined;
  /** What the key says: a modifier's name, a letter, a digit. */
  label: string;
  /** Its name read out and written in sentences. */
  name: string;
  /** Wider than a letter key, as a modifier or the space bar is. */
  wide: boolean;
  /** The space bar: wider still, its name small along its foot. */
  bar: boolean;
};

const modifierKeycaps = [
  {
    id: "control",
    codes: ["ControlLeft", "ControlRight"],
    glyph: "⌃",
    label: "control",
    name: "Control",
    wide: true,
    bar: false,
  },
  {
    id: "alt",
    codes: ["AltLeft", "AltRight"],
    glyph: "⌥",
    label: "option",
    name: "Option",
    wide: true,
    bar: false,
  },
  {
    id: "shift",
    codes: ["ShiftLeft", "ShiftRight"],
    glyph: "⇧",
    label: "shift",
    name: "Shift",
    wide: true,
    bar: false,
  },
  {
    id: "meta",
    codes: ["MetaLeft", "MetaRight"],
    glyph: "⌘",
    label: "command",
    name: "Command",
    wide: true,
    bar: false,
  },
] as const satisfies readonly OnboardingKeycap[];

const modifierCodes = new Set<string>(modifierKeycaps.flatMap(({ codes }) => codes));

/**
 * The shortcut's keys in the order macOS writes them (⌃ ⌥ ⇧ ⌘, then the
 * key), one keycap each. The space bar's and the comma's names, which the
 * words around the keys use, come from the catalog.
 */
export function onboardingKeycaps(
  shortcut: SideChatShortcut,
  { comma: commaName, space: spaceName }: { comma: string; space: string }
): OnboardingKeycap[] {
  const key: OnboardingKeycap =
    shortcut.key === "space"
      ? {
          id: "key",
          codes: ["Space"],
          glyph: undefined,
          label: spaceName.toLocaleLowerCase(),
          name: spaceName,
          wide: true,
          bar: true,
        }
      : shortcut.key === "comma"
        ? {
            id: "key",
            codes: ["Comma"],
            glyph: undefined,
            label: ",",
            name: commaName,
            wide: false,
            bar: false,
          }
        : {
            id: "key",
            codes: [
              /\d/.test(shortcut.key)
                ? `Digit${shortcut.key}`
                : `Key${shortcut.key.toUpperCase()}`,
            ],
            glyph: undefined,
            label: shortcut.key.toUpperCase(),
            name: shortcut.key.toUpperCase(),
            wide: false,
            bar: false,
          };
  return [...modifierKeycaps.filter(({ id }) => shortcut.modifiers[id]), key];
}

/**
 * What a key pressed during the step means:
 * - `shortcut`: one of the shortcut's keys, in any order.
 * - `ignore`: not an attempt at the shortcut. A repeat, text being composed,
 *   Tab and Escape (they move and dismiss as everywhere), Caps Lock and fn, a
 *   modifier the shortcut does not use, a ⌘ chord the shortcut does not use
 *   (⌘W, ⌘Tab and Spotlight stay the system's), M on its own while it is not
 *   one of the shortcut's keys (it mutes the onboarding's sound, as it does
 *   throughout), and any key aimed at one of the onboarding's controls
 *   (`onControl`: Return on Skip setup, the arrows on the volume).
 * - `wrong`: any other key: the user meant the shortcut and missed.
 */
export function onboardingShortcutKey(
  event: Pick<
    KeyboardEvent,
    | "altKey"
    | "code"
    | "ctrlKey"
    | "defaultPrevented"
    | "isComposing"
    | "key"
    | "metaKey"
    | "repeat"
  >,
  keycaps: readonly OnboardingKeycap[],
  { onControl }: { onControl: boolean }
):
  | { kind: "shortcut"; id: OnboardingKeycapId }
  | { kind: "ignore" }
  | { kind: "wrong" } {
  const keycap = keycaps.find(({ codes }) => codes.includes(event.code));
  if (keycap) return { kind: "shortcut", id: keycap.id };
  if (
    event.repeat ||
    event.isComposing ||
    ["Dead", "Process", "Unidentified"].includes(event.key) ||
    ["Tab", "Escape", "CapsLock", "Fn", "FnLock"].includes(event.key) ||
    modifierCodes.has(event.code) ||
    (event.metaKey && !keycaps.some(({ id }) => id === "meta")) ||
    isMediaMuteShortcut(event) ||
    onControl
  ) {
    return { kind: "ignore" };
  }
  return { kind: "wrong" };
}
