import { uiClock } from "@comma/ui/clock";

/** One viewer input event on the stream's `input` data channel. `x` and `y` are fractions of the video frame. */
export type ScreenStreamInput =
  | { type: "move"; x: number; y: number; mods: Modifier[] }
  | {
      type: "down" | "up";
      x: number;
      y: number;
      button: 0 | 1 | 2;
      clicks: number;
      mods: Modifier[];
    }
  | { type: "scroll"; x: number; y: number; dx: number; dy: number; mods: Modifier[] }
  // `key`: what the key types, for a key whose place the computer does not know (another layout's).
  | { type: "keydown" | "keyup"; code: string; key?: string; mods: Modifier[] }
  // Text an IME composed or a paste carried: the computer's form of a device's `t: "text"` (systems/station mesh/screens.ts `helperInput`).
  | { type: "text"; text: string }
  // A device's source reads these (systems/station mesh/screens.ts `deviceInput`). `buttons`: bit 0 is the finger.
  | {
      t: "pointer";
      kind: "down" | "up" | "move";
      x: number;
      y: number;
      buttons: number;
    }
  | { t: "wheel"; x: number; y: number; dx: number; dy: number }
  | { t: "key"; kind: "down" | "up"; key: string; code: string; mods: number }
  // still.fail's `{t:"text"}` (its docs/remote-screens.md input message).
  | { t: "text"; text: string }
  | { t: "device"; name: "volume_up" | "volume_down" | "rotate" }
  // A foldable's hinge.
  | { t: "pose"; name: "closed" | "book" | "open" }
  // A button of a simulator's case by its HID usage, as it goes down and comes up (screenCase.ts).
  | { t: "button"; page: number; usage: number; down: boolean };

type Modifier = "shift" | "ctrl" | "alt" | "meta";

type Keys = { shiftKey: boolean; ctrlKey: boolean; altKey: boolean; metaKey: boolean };
type Point = { clientX: number; clientY: number };
type Box = { left: number; top: number; width: number; height: number };

export function modifiers(event: Keys): Modifier[] {
  const mods: Modifier[] = [];
  if (event.shiftKey) mods.push("shift");
  if (event.ctrlKey) mods.push("ctrl");
  if (event.altKey) mods.push("alt");
  if (event.metaKey) mods.push("meta");
  return mods;
}

/** The held modifiers as a device's `mods`: bit 0 alt, 1 ctrl, 2 meta, 3 shift. */
export function deviceMods(event: Keys): number {
  return (
    (event.altKey ? 1 : 0) |
    (event.ctrlKey ? 2 : 0) |
    (event.metaKey ? 4 : 0) |
    (event.shiftKey ? 8 : 0)
  );
}

/**
 * Where a pointer is in the picture, as fractions of it. The video element
 * letterboxes a picture whose shape differs from its own, so the fractions
 * are of the picture inside the element, clamped to its edges.
 */
export function pictureFraction(
  point: Point,
  element: Box,
  picture: { width: number; height: number }
): { x: number; y: number } {
  if (
    !(
      picture.width > 0 &&
      picture.height > 0 &&
      element.width > 0 &&
      element.height > 0
    )
  )
    return { x: 0, y: 0 };
  const scale = Math.min(
    element.width / picture.width,
    element.height / picture.height
  );
  const width = picture.width * scale;
  const height = picture.height * scale;
  const left = element.left + (element.width - width) / 2;
  const top = element.top + (element.height - height) / 2;
  return {
    x: clamp((point.clientX - left) / width),
    y: clamp((point.clientY - top) / height),
  };
}

/** The wire's button: 0 primary, 1 secondary, 2 middle. DOM numbers the last two the other way. */
export function wireButton(button: number): 0 | 1 | 2 {
  return button === 2 ? 1 : button === 1 ? 2 : 0;
}

function clamp(value: number) {
  return Math.min(1, Math.max(0, value));
}

/** A line of the wheel, in pixels (still.fail web/src/screen/input.ts `LINE`): a mouse that counts in lines. */
export const WHEEL_LINE = 16;

/**
 * A wheel event's travel in pixels, whatever it counts in: lines (Firefox's
 * mouse wheel) or pages (still.fail input.ts, "wheel").
 */
export function wheelPixels(
  event: Pick<WheelEvent, "deltaMode" | "deltaX" | "deltaY">,
  pageHeight: number
): { dx: number; dy: number } {
  const by =
    event.deltaMode === 1 ? WHEEL_LINE : event.deltaMode === 2 ? pageHeight : 1;
  return { dx: event.deltaX * by, dy: event.deltaY * by };
}

/** The most bytes one input event's JSON may be: what the station takes (systems/station mesh/screens.ts MAX_INPUT_BYTES). */
const MAX_INPUT_BYTES = 4096;
/** Room left in it for the event round the text. */
const TEXT_BYTES = MAX_INPUT_BYTES - 96;

/**
 * Text in pieces that each fit one input event, a character never split. A
 * long paste goes as several, in order (the station posts them so). still.fail
 * sends it whole, and its station drops text past 4096 units; Cue's station
 * takes at most 4096 bytes of JSON an event.
 */
export function textPieces(text: string): string[] {
  const encoder = new TextEncoder();
  const pieces: string[] = [];
  let piece = "";
  let bytes = 0;
  for (const character of text) {
    const size = encoder.encode(JSON.stringify(character)).length - 2;
    if (bytes + size > TEXT_BYTES && piece) {
      pieces.push(piece);
      piece = "";
      bytes = 0;
    }
    piece += character;
    bytes += size;
  }
  if (piece) pieces.push(piece);
  return pieces;
}

/**
 * Whether a key is someone starting to type, for a screen that only watches: not a shortcut, a key that moves about the
 * page, a key held down, or what an input method is composing.
 */
export function typesText(
  event: Pick<
    KeyboardEvent,
    "isComposing" | "keyCode" | "key" | "metaKey" | "ctrlKey" | "repeat"
  >
): boolean {
  if (
    event.metaKey ||
    event.ctrlKey ||
    event.repeat ||
    event.isComposing ||
    event.keyCode === 229
  )
    return false;
  return event.key.length === 1 || ["Enter", "Backspace", "Delete"].includes(event.key);
}

/**
 * Whether a key's press goes as a key. An IME composing, or a keyboard that
 * does not say which key, makes text instead; ⌘V or Ctrl+V is a paste, whose
 * text comes in its paste event; a soft keyboard's letter (no physical key)
 * comes as text too (still.fail input.ts, "keydown").
 */
export function goesAsKey(
  event: Pick<
    KeyboardEvent,
    "isComposing" | "keyCode" | "key" | "code" | "metaKey" | "ctrlKey" | "altKey"
  >
): boolean {
  if (
    event.isComposing ||
    event.keyCode === 229 ||
    event.key === "Process" ||
    event.key === "Unidentified" ||
    event.key === "Dead"
  )
    return false;
  if (
    (event.metaKey || event.ctrlKey) &&
    !event.altKey &&
    event.key.toLowerCase() === "v"
  )
    return false;
  const printable = [...event.key].length === 1;
  return !(
    printable &&
    !event.code &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey
  );
}

/** Runs a function at the next frame; what it returns calls that off. */
type Frames = (run: () => void) => () => void;

/**
 * What waits for the next frame: the latest pointer move, and the wheel
 * summed, sent once a frame (still.fail input.ts `flush`, `later`, `now`). A
 * press sends what waits first, so it lands where the last move left the
 * pointer, and that last move is never dropped.
 */
export class InputFrame {
  #move: ScreenStreamInput | null = null;
  #wheel: { input: ScreenStreamInput & { dx: number; dy: number } } | null = null;
  #frame: (() => void) | null = null;
  readonly #send: (input: ScreenStreamInput) => void;
  readonly #frames: Frames;

  constructor(
    send: (input: ScreenStreamInput) => void,
    frames: Frames = (run) => uiClock.frame(run)
  ) {
    this.#send = send;
    this.#frames = frames;
  }

  /** The pointer moved: this goes with the next frame, over any move before it. */
  move(input: ScreenStreamInput) {
    this.#move = input;
    this.#later();
  }

  /** The wheel turned: its travel is added to what waits, at this point. */
  wheel(input: ScreenStreamInput & { dx: number; dy: number }) {
    const was = this.#wheel?.input;
    this.#wheel = {
      input: { ...input, dx: (was?.dx ?? 0) + input.dx, dy: (was?.dy ?? 0) + input.dy },
    };
    this.#later();
  }

  /** Sends what waits now: before a press, a key or text. */
  now() {
    this.#frame?.();
    this.#flush();
  }

  /** Drops what waits (the stream it was for ended). */
  drop() {
    this.#frame?.();
    this.#frame = null;
    this.#move = null;
    this.#wheel = null;
  }

  #later() {
    this.#frame ??= this.#frames(() => this.#flush());
  }

  #flush() {
    this.#frame = null;
    if (this.#move) this.#send(this.#move);
    this.#move = null;
    const wheel = this.#wheel?.input;
    if (wheel && (wheel.dx || wheel.dy)) this.#send(wheel);
    this.#wheel = null;
  }
}
