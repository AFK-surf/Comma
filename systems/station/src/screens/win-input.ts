// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 7470ca2abe) station/src/screens/win-input.ts: `KEYS`,
// `WinInput` as they are there. Cue's own part is at the end: `DesktopWinInput`, which takes the wire's desktop input
// (mesh/screens.ts `helperInput`: `{type: "move" | "down" | "up" | "scroll" | "keydown" | "keyup"}`, what Cue's client
// sends a computer's screen) and gives `WinInput` still.fail's form of it (docs/desktop-screen.md, "Deviations").
//
// A person's input (source.ts `ScreenInput`, as a page has it) as Windows' SendInput posts it: which mouse button went
// down or up, a wheel in Windows' units (120 a notch), a page's key `code` as the key's scan code (its place on the
// keyboard, whatever the layout) or, for a key without one, its virtual key. What stillfail-screen is given
// (native/screen's input.rs: `{op: "mouse" | "wheel" | "key" | "text"}`); it only posts. Windows counts double clicks
// itself, and keeps which modifiers are down: a key that comes with modifiers not pressed before it (a phone's keys
// row: ⌃ then c) has them pressed round it.
import type { DeviceInput, ScreenInput as WireInput } from "./source.ts";
import type { InputOps } from "./screen-pipe.ts";

/// still.fail's source.ts `ScreenInput`, as `WinInput` takes it: Cue's `DeviceInput` and the two kinds Cue's client does
/// not send (text typed at once, a device's button).
type ScreenInput = DeviceInput | { t: "text"; text: string } | { t: "button"; name: string };

export type WinOp =
  | { op: "mouse"; type: "move" | "down" | "up"; x: number; y: number; button: number }
  | { op: "wheel"; x: number; y: number; dx: number; dy: number }
  | { op: "key"; scan: number; ext: boolean; vk: number; down: boolean }
  | { op: "text"; text: string };

type Key = { scan: number; ext?: boolean; vk?: number };

/// A page's KeyboardEvent.code → the key's scan code (set 1; `ext`: an E0 key), or a virtual key where the scan code
/// does not say it (Pause, the media keys).
export const KEYS: Record<string, Key> = {
  Escape: { scan: 0x01 }, Digit1: { scan: 0x02 }, Digit2: { scan: 0x03 }, Digit3: { scan: 0x04 }, Digit4: { scan: 0x05 },
  Digit5: { scan: 0x06 }, Digit6: { scan: 0x07 }, Digit7: { scan: 0x08 }, Digit8: { scan: 0x09 }, Digit9: { scan: 0x0a },
  Digit0: { scan: 0x0b }, Minus: { scan: 0x0c }, Equal: { scan: 0x0d }, Backspace: { scan: 0x0e }, Tab: { scan: 0x0f },
  KeyQ: { scan: 0x10 }, KeyW: { scan: 0x11 }, KeyE: { scan: 0x12 }, KeyR: { scan: 0x13 }, KeyT: { scan: 0x14 },
  KeyY: { scan: 0x15 }, KeyU: { scan: 0x16 }, KeyI: { scan: 0x17 }, KeyO: { scan: 0x18 }, KeyP: { scan: 0x19 },
  BracketLeft: { scan: 0x1a }, BracketRight: { scan: 0x1b }, Enter: { scan: 0x1c }, ControlLeft: { scan: 0x1d },
  KeyA: { scan: 0x1e }, KeyS: { scan: 0x1f }, KeyD: { scan: 0x20 }, KeyF: { scan: 0x21 }, KeyG: { scan: 0x22 },
  KeyH: { scan: 0x23 }, KeyJ: { scan: 0x24 }, KeyK: { scan: 0x25 }, KeyL: { scan: 0x26 }, Semicolon: { scan: 0x27 },
  Quote: { scan: 0x28 }, Backquote: { scan: 0x29 }, ShiftLeft: { scan: 0x2a }, Backslash: { scan: 0x2b },
  KeyZ: { scan: 0x2c }, KeyX: { scan: 0x2d }, KeyC: { scan: 0x2e }, KeyV: { scan: 0x2f }, KeyB: { scan: 0x30 },
  KeyN: { scan: 0x31 }, KeyM: { scan: 0x32 }, Comma: { scan: 0x33 }, Period: { scan: 0x34 }, Slash: { scan: 0x35 },
  ShiftRight: { scan: 0x36 }, NumpadMultiply: { scan: 0x37 }, AltLeft: { scan: 0x38 }, Space: { scan: 0x39 },
  CapsLock: { scan: 0x3a }, F1: { scan: 0x3b }, F2: { scan: 0x3c }, F3: { scan: 0x3d }, F4: { scan: 0x3e },
  F5: { scan: 0x3f }, F6: { scan: 0x40 }, F7: { scan: 0x41 }, F8: { scan: 0x42 }, F9: { scan: 0x43 }, F10: { scan: 0x44 },
  NumLock: { scan: 0x45, ext: true }, ScrollLock: { scan: 0x46 }, Numpad7: { scan: 0x47 }, Numpad8: { scan: 0x48 },
  Numpad9: { scan: 0x49 }, NumpadSubtract: { scan: 0x4a }, Numpad4: { scan: 0x4b }, Numpad5: { scan: 0x4c },
  Numpad6: { scan: 0x4d }, NumpadAdd: { scan: 0x4e }, Numpad1: { scan: 0x4f }, Numpad2: { scan: 0x50 },
  Numpad3: { scan: 0x51 }, Numpad0: { scan: 0x52 }, NumpadDecimal: { scan: 0x53 }, IntlBackslash: { scan: 0x56 },
  F11: { scan: 0x57 }, F12: { scan: 0x58 }, NumpadEqual: { scan: 0x59 }, F13: { scan: 0x64 }, F14: { scan: 0x65 },
  F15: { scan: 0x66 }, F16: { scan: 0x67 }, F17: { scan: 0x68 }, F18: { scan: 0x69 }, F19: { scan: 0x6a },
  F20: { scan: 0x6b }, F21: { scan: 0x6c }, F22: { scan: 0x6d }, F23: { scan: 0x6e }, KanaMode: { scan: 0x70 },
  IntlRo: { scan: 0x73 }, F24: { scan: 0x76 }, Convert: { scan: 0x79 }, NonConvert: { scan: 0x7b }, IntlYen: { scan: 0x7d },
  NumpadComma: { scan: 0x7e },
  NumpadEnter: { scan: 0x1c, ext: true }, ControlRight: { scan: 0x1d, ext: true }, NumpadDivide: { scan: 0x35, ext: true },
  PrintScreen: { scan: 0x37, ext: true }, AltRight: { scan: 0x38, ext: true }, Home: { scan: 0x47, ext: true },
  ArrowUp: { scan: 0x48, ext: true }, PageUp: { scan: 0x49, ext: true }, ArrowLeft: { scan: 0x4b, ext: true },
  ArrowRight: { scan: 0x4d, ext: true }, End: { scan: 0x4f, ext: true }, ArrowDown: { scan: 0x50, ext: true },
  PageDown: { scan: 0x51, ext: true }, Insert: { scan: 0x52, ext: true }, Delete: { scan: 0x53, ext: true },
  MetaLeft: { scan: 0x5b, ext: true }, MetaRight: { scan: 0x5c, ext: true }, OSLeft: { scan: 0x5b, ext: true },
  OSRight: { scan: 0x5c, ext: true }, ContextMenu: { scan: 0x5d, ext: true },
  Pause: { scan: 0, vk: 0x13 }, AudioVolumeMute: { scan: 0, vk: 0xad }, AudioVolumeDown: { scan: 0, vk: 0xae },
  AudioVolumeUp: { scan: 0, vk: 0xaf }, MediaTrackNext: { scan: 0, vk: 0xb0 }, MediaTrackPrevious: { scan: 0, vk: 0xb1 },
  MediaStop: { scan: 0, vk: 0xb2 }, MediaPlayPause: { scan: 0, vk: 0xb3 },
};

/// A ScreenInput's `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift) and the keys that press them.
const MODIFIERS: { bit: number; codes: string[] }[] = [
  { bit: 2, codes: ["ControlLeft", "ControlRight"] },
  { bit: 8, codes: ["ShiftLeft", "ShiftRight"] },
  { bit: 1, codes: ["AltLeft", "AltRight"] },
  { bit: 4, codes: ["MetaLeft", "MetaRight", "OSLeft", "OSRight"] },
];

/// A page's wheel (pixels, positive down and right) in Windows' units (120 a notch, positive up and right): a page's
/// notch is about 100 pixels.
export const WHEEL_PER_PIXEL = 1.2;

/// DOM `buttons` bits (1 left, 2 right, 4 middle) → DOM `button` (0 left, 1 middle, 2 right).
const BUTTON_OF_BIT: Record<number, number> = { 1: 0, 2: 2, 4: 1 };
const lowestBit = (bits: number) => bits & -bits;

const keyOp = (key: Key, down: boolean): WinOp => ({ op: "key", scan: key.scan, ext: key.ext === true, vk: key.vk ?? 0, down });

/// One view's input as it goes: which buttons and modifiers are held, the wheel's part of a notch not sent yet.
export class WinInput {
  #buttons = 0;
  /// Modifier keys pressed and not let go (their codes).
  #held = new Set<string>();
  #wheel = { x: 0, y: 0 };

  ops(e: ScreenInput): WinOp[] {
    switch (e.t) {
      case "pointer": {
        const before = this.#buttons;
        this.#buttons = e.buttons & 7;
        if (e.kind === "move") return [{ op: "mouse", type: "move", x: e.x, y: e.y, button: 0 }];
        if (e.kind === "down") {
          const bit = lowestBit(this.#buttons & ~before) || 1;
          this.#buttons |= bit;
          return [{ op: "mouse", type: "down", x: e.x, y: e.y, button: BUTTON_OF_BIT[bit] ?? 0 }];
        }
        const bit = lowestBit(before & ~this.#buttons) || lowestBit(before) || 1;
        this.#buttons &= ~bit;
        return [{ op: "mouse", type: "up", x: e.x, y: e.y, button: BUTTON_OF_BIT[bit] ?? 0 }];
      }
      case "wheel": {
        // Whole units only; what is left goes with the next turn the same way (a trackpad's many small ones).
        this.#wheel.x += e.dx * WHEEL_PER_PIXEL;
        this.#wheel.y -= e.dy * WHEEL_PER_PIXEL;
        const dx = Math.trunc(this.#wheel.x), dy = Math.trunc(this.#wheel.y);
        this.#wheel.x -= dx;
        this.#wheel.y -= dy;
        return dx === 0 && dy === 0 ? [] : [{ op: "wheel", x: e.x, y: e.y, dx, dy }];
      }
      case "key": {
        const key = KEYS[e.code];
        if (key === undefined) {
          // A key of no known place (another layout's, a phone's keyboard): what it types, when it types one thing.
          return e.kind === "down" && Array.from(e.key).length === 1 && (e.mods & 6) === 0 ? [{ op: "text", text: e.key }] : [];
        }
        const modifier = MODIFIERS.some((m) => m.codes.includes(e.code));
        if (modifier) {
          if (e.kind === "down") this.#held.add(e.code);
          else this.#held.delete(e.code);
          return [keyOp(key, e.kind === "down")];
        }
        if (e.kind === "up") return [keyOp(key, false)];
        // Modifiers it comes with that are not down: pressed round it.
        const round = MODIFIERS.filter((m) => (e.mods & m.bit) !== 0 && !m.codes.some((c) => this.#held.has(c))).map((m) => KEYS[m.codes[0]!]!);
        return [...round.map((k) => keyOp(k, true)), keyOp(key, true), ...round.reverse().map((k) => keyOp(k, false))];
      }
      case "text":
        return e.text === "" ? [] : [{ op: "text", text: e.text }];
      case "pose":
      case "device":
      case "button":
        return [];
    }
  }
}

/// The wire's button (0 primary, 1 secondary, 2 middle: Cue's client's `wireButton`) as DOM `buttons` bits.
const BIT_OF_WIRE_BUTTON: Record<number, number> = { 0: 1, 1: 2, 2: 4 };
/// The wire's modifier names as a `ScreenInput`'s `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift).
const MOD_BITS: Record<string, number> = { alt: 1, ctrl: 2, meta: 4, shift: 8 };

const finite = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const unit = (v: number) => Math.min(1, Math.max(0, v));
/// How far one wheel event may say it went, in a page's pixels (mesh/screens.ts's bound for a device's).
const WHEEL_MOST = 10_000;
const wheel = (v: number) => Math.min(WHEEL_MOST, Math.max(-WHEEL_MOST, v));

/// One view's input as Cue's client sends a computer's screen, posted as Windows does: the buttons held followed (a
/// move with one held is a drag), each event made still.fail's form and given to `WinInput`.
export class DesktopWinInput implements InputOps {
  readonly #win = new WinInput();
  #buttons = 0;

  ops(event: WireInput): WinOp[] {
    const e = this.#still(event);
    return e === null ? [] : this.#win.ops(e);
  }

  #still(event: WireInput): ScreenInput | null {
    const v = event as Record<string, unknown>;
    const at = finite(v.x) && finite(v.y) ? { x: unit(v.x), y: unit(v.y) } : null;
    const mods = Array.isArray(v.mods) ? v.mods.reduce((bits: number, m) => bits | (MOD_BITS[m as string] ?? 0), 0) : 0;
    switch (v.type) {
      case "move":
        return at && { t: "pointer", kind: "move", ...at, buttons: this.#buttons };
      case "down":
      case "up": {
        const bit = BIT_OF_WIRE_BUTTON[v.button as number] ?? 1;
        this.#buttons = v.type === "down" ? this.#buttons | bit : this.#buttons & ~bit;
        return at && { t: "pointer", kind: v.type, ...at, buttons: this.#buttons };
      }
      case "scroll":
        return at && finite(v.dx) && finite(v.dy) ? { t: "wheel", ...at, dx: wheel(v.dx), dy: wheel(v.dy) } : null;
      case "keydown":
      case "keyup":
        return typeof v.code === "string" && v.code.length <= 64 ? { t: "key", kind: v.type === "keydown" ? "down" : "up", key: "", code: v.code, mods } : null;
      default:
        return null;
    }
  }
}
