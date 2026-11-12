// A person's input (source.ts `DeviceInput`, checked by mesh/screens.ts `deviceInput`) as an iOS Simulator takes it
// (simulator.ts; the Computer Use helper's SimulatorStreamSession.swift posts it), after still.fail's sim-input.ts: the left
// button held is a finger on the screen, a wheel a finger dragging, a key its USB HID usage, typed text keys of a US
// keyboard (anything else pasted: SimulatorStreamSession.swift sets the device's pasteboard, then ⌘V, and lets the app
// iOS refuses it to paste from other apps while the view lasts). Simulator.app's own shortcuts
// press the device's buttons: ⌘⇧H home, ⌃⌘⇧H the app switcher, ⌘L lock, ⌘K the software keyboard (the client's home and
// lock buttons send the first and third). A button of the device's case goes by its HID usage (sim-chrome.ts), held as long
// as a person holds it.
import type { DeviceInput } from "./source.ts";

export type SimOp =
  | { op: "touch"; type: "begin" | "move" | "end"; x: number; y: number; edge?: number }
  | { op: "scroll"; x: number; y: number; dx: number; dy: number }
  | { op: "key"; type: "down" | "up"; usage: number }
  | { op: "button"; name: "home" | "app_switcher" | "lock" | "keyboard" }
  | { op: "paste"; text: string }
  | { op: "pose"; name: string }
  | { op: "rotate" }
  | { op: "button"; name: "volume_up" | "volume_down" }
  /// A hardware button by its HID usage (the device's case, sim-chrome.ts), held from `down` until it comes up.
  | { op: "hid"; page: number; usage: number; down: boolean };

/// A page's KeyboardEvent.code → the USB HID keyboard usage (page 7).
export const USAGES: Record<string, number> = {
  ...Object.fromEntries([..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"].map((c, i) => [`Key${c}`, 0x04 + i])),
  ...Object.fromEntries([..."123456789"].map((c, i) => [`Digit${c}`, 0x1e + i])),
  Digit0: 0x27, Enter: 0x28, NumpadEnter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c, Minus: 0x2d,
  Equal: 0x2e, BracketLeft: 0x2f, BracketRight: 0x30, Backslash: 0x31, Semicolon: 0x33, Quote: 0x34, Backquote: 0x35,
  Comma: 0x36, Period: 0x37, Slash: 0x38, CapsLock: 0x39,
  ...Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`F${i + 1}`, 0x3a + i])),
  Insert: 0x49, Home: 0x4a, PageUp: 0x4b, Delete: 0x4c, End: 0x4d, PageDown: 0x4e, ArrowRight: 0x4f, ArrowLeft: 0x50,
  ArrowDown: 0x51, ArrowUp: 0x52,
  ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3, ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6,
  MetaRight: 0xe7,
};

/// A ScreenInput's `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift) and the left modifier key each is.
const MODS: [number, number][] = [[1, 0xe2], [2, 0xe0], [4, 0xe3], [8, 0xe1]];
const MOD_OF_USAGE: Record<number, number> = { 0xe0: 2, 0xe4: 2, 0xe1: 8, 0xe5: 8, 0xe2: 1, 0xe6: 1, 0xe3: 4, 0xe7: 4 };
const SHIFT = 0xe1;

/// What a US keyboard types each printable ASCII character with: its usage, and whether with shift (still.fail
/// sim-input.ts `TYPED`).
export const TYPED: Record<string, [number, boolean]> = (() => {
  const out: Record<string, [number, boolean]> = { " ": [0x2c, false], "\n": [0x28, false], "\t": [0x2b, false] };
  for (let i = 0; i < 26; i++) {
    out[String.fromCharCode(97 + i)] = [0x04 + i, false];
    out[String.fromCharCode(65 + i)] = [0x04 + i, true];
  }
  const rows: [string, string, number][] = [["1234567890", "!@#$%^&*()", 0x1e], ["-=[]\\", "_+{}|", 0x2d], [";'`,./", ':"~<>?', 0x33]];
  for (const [plain, shifted, first] of rows) {
    [...plain].forEach((c, i) => (out[c] = [first + i, false]));
    [...shifted].forEach((c, i) => (out[c] = [first + i, true]));
  }
  return out;
})();

/// Where a finger that goes down is a system gesture's (0..1 of the screen from the edge): the home indicator's swipe up,
/// the top's pull down.
const BOTTOM_EDGE = 0.97;
const TOP_EDGE = 0.02;

/// One view's input as it goes: whether a finger is down (and from which edge), the modifier keys held.
export class SimInput {
  #finger: { edge: number } | null = null;
  #held = 0;

  /// What `e` is posted as.
  ops(e: DeviceInput): SimOp[] {
    switch (e.t) {
      case "pointer": {
        const x = clamp(e.x), y = clamp(e.y);
        const left = (e.buttons & 1) === 1;
        if (this.#finger === null) {
          if (e.kind !== "down" || !left) return [];
          const edge = y >= BOTTOM_EDGE ? 3 : y <= TOP_EDGE ? 2 : 0;
          this.#finger = { edge };
          return [{ op: "touch", type: "begin", x, y, ...(edge ? { edge } : {}) }];
        }
        const edge = this.#finger.edge;
        if (left && e.kind !== "up") return [{ op: "touch", type: "move", x, y, ...(edge ? { edge } : {}) }];
        this.#finger = null;
        return [{ op: "touch", type: "end", x, y, ...(edge ? { edge } : {}) }];
      }
      case "wheel":
        return e.dx === 0 && e.dy === 0 ? [] : [{ op: "scroll", x: clamp(e.x), y: clamp(e.y), dx: e.dx, dy: e.dy }];
      case "key":
        return this.#key(e.kind === "down", e.code, e.mods);
      case "text":
        return this.#text(e.text);
      case "pose":
        return e.name === "closed" || e.name === "open" ? [{ op: "pose", name: e.name }] : [];
      case "button":
        return [{ op: "hid", page: e.page, usage: e.usage, down: e.down }];
      case "device":
        return e.name === "rotate" ? [{ op: "rotate" }] : [{ op: "button", name: e.name }];
    }
  }

  #key(down: boolean, code: string, mods: number): SimOp[] {
    const usage = USAGES[code];
    if (usage === undefined) return [];
    const mod = MOD_OF_USAGE[usage];
    if (mod !== undefined) {
      this.#held = down ? this.#held | mod : this.#held & ~mod;
      return [{ op: "key", type: down ? "down" : "up", usage }];
    }
    // Simulator.app's shortcuts for the device's buttons.
    const meta = (mods & 4) !== 0, shift = (mods & 8) !== 0, ctrl = (mods & 2) !== 0, alt = (mods & 1) !== 0;
    if (meta && !alt) {
      const button = ctrl ? (shift && code === "KeyH" ? "app_switcher" : null)
        : shift && code === "KeyH" ? "home" : !shift && code === "KeyL" ? "lock" : !shift && code === "KeyK" ? "keyboard" : null;
      if (button !== null) return down ? [{ op: "button", name: button }] : [];
    }
    // A key that comes with modifiers not held before it (a phone's keys row) has them pressed round it.
    const round = MODS.filter(([bit]) => (mods & bit) !== 0 && (this.#held & bit) === 0).map(([, u]) => u);
    const key: SimOp = { op: "key", type: down ? "down" : "up", usage };
    if (round.length === 0) return [key];
    return down ? [...round.map((u): SimOp => ({ op: "key", type: "down", usage: u })), key] : [key, ...round.reverse().map((u): SimOp => ({ op: "key", type: "up", usage: u }))];
  }

  /// Typed text: a US keyboard's keys where each character has one, else the whole of it pasted (still.fail
  /// sim-input.ts `#text`).
  #text(text: string): SimOp[] {
    if (text === "") return [];
    const keys = [...text].map((c) => TYPED[c]);
    if (keys.some((k) => k === undefined)) return [{ op: "paste", text }];
    const out: SimOp[] = [];
    for (const [usage, shift] of keys as [number, boolean][]) {
      const press = shift && (this.#held & 8) === 0;
      if (press) out.push({ op: "key", type: "down", usage: SHIFT });
      out.push({ op: "key", type: "down", usage }, { op: "key", type: "up", usage });
      if (press) out.push({ op: "key", type: "up", usage: SHIFT });
    }
    return out;
  }
}

const clamp = (v: number) => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0);
