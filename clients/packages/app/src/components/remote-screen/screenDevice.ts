import type { ScreenStreamChrome } from "./screenCase";
import type { ScreenStreamInput } from "./screenStreamInput";

/**
 * What a screen's source can do. A computer's screen declares nothing; a phone
 * or a simulator declares the rest. "Device" here is such a handset, not a
 * Device of the domain, which is the computer that may host it.
 */
export type ScreenStreamCapabilities = {
  /** How a press reaches the screen: a mouse's pointer, or a finger. */
  input: "pointer" | "touch";
  buttons: readonly ScreenDeviceButton[];
  /**
   * The device's body round the picture, one shape for each panel: a foldable
   * has two, and the one nearest the picture's shape shows. A source without
   * any shows a plain picture.
   */
  shapes?: readonly [ScreenDeviceShape, ...ScreenDeviceShape[]] | undefined;
  /** The ways a foldable can stand; a device that does not fold has none. */
  poses?: readonly ScreenDevicePose[] | undefined;
  /**
   * An iOS Simulator's case and buttons as Xcode has them (screenCase.ts), drawn round the picture instead of `shapes`
   * once its pictures have come; none where its Mac has none, or for an Android device.
   */
  chrome?: ScreenStreamChrome | undefined;
};

export type ScreenDevicePose = "closed" | "book" | "open";

/** What the source says of the device as it changes, when it says. */
export type ScreenDeviceState = {
  orientation?: ScreenTurn | undefined;
  pose?: ScreenDevicePose | undefined;
};

export type ScreenDeviceButton = "home" | "lock" | "volume" | "rotate";

/** A device standing upright. All lengths are in one unit of the source's own. */
export type ScreenDeviceShape = {
  frame: { width: number; height: number };
  screen: { x: number; y: number; width: number; height: number };
  /** The screen's corner radii: top left, then clockwise. */
  corners: readonly [number, number, number, number];
  /**
   * The CSS `superellipse(k)` each corner is drawn as, in the same order, where the source knows its shape that closely (a
   * simulator's mask); its radius is then that corner's `corners`. None: circles.
   */
  shapes?: readonly [number, number, number, number] | undefined;
};

/** The CSS `corner-shape` of corners drawn as `shapes` say, in the order a `border-radius` takes them. */
export function screenCornerShape(
  shapes: readonly [number, number, number, number] | undefined
): string | undefined {
  return shapes?.map((k) => `superellipse(${k})`).join(" ");
}

/** Degrees clockwise. */
export type ScreenTurn = 0 | 90 | 180 | 270;

export type ScreenDeviceAction =
  | "home"
  | "lock"
  | "volume_up"
  | "volume_down"
  | "rotate"
  | "fold"
  | "half_fold"
  | "unfold";

/** What can be done on the device now. All act on the device, so they ask for control, as a press on the picture does. */
export function screenDeviceActions(
  capabilities: ScreenStreamCapabilities | undefined,
  control: boolean,
  pose?: ScreenDevicePose | undefined
): ScreenDeviceAction[] {
  if (!capabilities) return [];
  const { buttons, poses = [] } = capabilities;
  const actions: ScreenDeviceAction[] = [];
  if (!control) return actions;
  if (buttons.includes("home")) actions.push("home");
  if (buttons.includes("lock")) actions.push("lock");
  if (buttons.includes("volume")) actions.push("volume_up", "volume_down");
  if (buttons.includes("rotate")) actions.push("rotate");
  // What it can go to from how it stands; not said: open, as a foldable mostly is.
  const now = pose ?? "open";
  if (poses.includes("closed") && now !== "closed") actions.push("fold");
  if (poses.includes("book") && now !== "book") actions.push("half_fold");
  if (poses.includes("open") && now !== "open") actions.push("unfold");
  return actions;
}

const META = 4;
const SHIFT = 8;

const keyPress = (key: string, code: string, mods: number): ScreenStreamInput[] => [
  { t: "key", kind: "down", key, code, mods },
  { t: "key", kind: "up", key, code, mods },
];

/** What tells the device to act. Its home and lock buttons are Simulator.app's shortcuts on the wire. */
export function screenDevicePress(action: ScreenDeviceAction): ScreenStreamInput[] {
  if (action === "home") return keyPress("h", "KeyH", META | SHIFT);
  if (action === "lock") return keyPress("l", "KeyL", META);
  if (action === "fold") return [{ t: "pose", name: "closed" }];
  if (action === "half_fold") return [{ t: "pose", name: "book" }];
  if (action === "unfold") return [{ t: "pose", name: "open" }];
  return [{ t: "device", name: action }];
}

const longToShort = (ratio: number) => Math.max(ratio, 1 / ratio);

/**
 * The panel whose shape is nearest the picture's, however the picture stands:
 * the first until there is a picture.
 */
export function screenDeviceShape(
  shapes: readonly [ScreenDeviceShape, ...ScreenDeviceShape[]],
  pictureRatio: number | undefined
): ScreenDeviceShape {
  if (!pictureRatio) return shapes[0];
  const off = ({ screen }: ScreenDeviceShape) =>
    Math.abs(
      Math.log(longToShort(screen.width / screen.height) / longToShort(pictureRatio))
    );
  return shapes.reduce((best, shape) => (off(shape) < off(best) ? shape : best));
}

/**
 * How the device stands: the source owns its picture, and the frame goes round
 * what arrives. The picture's aspect says whether the device lies on its side.
 * The source's report says which way, while it agrees with the picture: a
 * report can lead or trail the frames. With no report, a device on its side is
 * taken to be turned clockwise, and an upright one not turned.
 */
export function screenDeviceTurn(
  shape: ScreenDeviceShape,
  pictureRatio: number | undefined,
  reported: ScreenTurn | undefined
): ScreenTurn {
  if (!pictureRatio) return reported ?? 0;
  const sideways = pictureRatio > 1 !== shape.screen.width / shape.screen.height > 1;
  if (reported !== undefined && (reported % 180 !== 0) === sideways) return reported;
  return sideways ? 90 : 0;
}

/**
 * Whether the source's report and its picture say the same of how the device stands. The two come apart for a moment
 * in a turn, in either order: until they agree there is nothing to draw it by.
 */
export function screenDeviceAgrees(
  shape: ScreenDeviceShape,
  pictureRatio: number | undefined,
  reported: ScreenTurn | undefined
): boolean {
  if (!pictureRatio || reported === undefined) return true;
  const sideways = pictureRatio > 1 !== shape.screen.width / shape.screen.height > 1;
  return (reported % 180 !== 0) === sideways;
}

/** The degrees a device that now stands at `turn` starts from, to come from `was` the short way. */
export function screenDeviceTurnFrom(was: ScreenTurn, turn: ScreenTurn): number {
  return ((was - turn + 540) % 360) - 180;
}

/** How long a device takes to turn on the page. */
export const SCREEN_DEVICE_TURN_MS = 320;

// A source's frames while its device turns: its own rotation animation shows in them until this long has none...
const TURN_QUIET_MS = 150;
// ...or this long after the turn showed, by which a device's own animation has played, whatever else moves on it.
const TURN_PLAYED_MS = 450;
// A press that turned nothing (an app that holds its orientation) turns back after this.
const TURN_NOTHING_MS = 2500;

/** What a stage holding its last picture does now. */
export function screenDeviceTurnSettled(held: {
  /** The frame is still turning. */
  turning: boolean;
  /** The report and the picture say the same. */
  agreed: boolean;
  /** The source says it stands as the frame does, turned from where it was held. */
  arrived: boolean;
  /** The source still says it stands where it was held. */
  unmoved: boolean;
  /** The frame stands where it was held. */
  restored: boolean;
  heldMs: number;
  arrivedMs: number;
  quietMs: number;
}): "wait" | "swap" | "turn" | "release" {
  if (held.turning) return "wait";
  if (held.arrived)
    return held.quietMs >= TURN_QUIET_MS || held.arrivedMs >= TURN_PLAYED_MS
      ? "swap"
      : "wait";
  const late = held.heldMs >= TURN_NOTHING_MS;
  // The report and the picture are yet to agree: one of them is on its way.
  if (!held.agreed && !late) return "wait";
  if (held.unmoved) {
    if (held.restored) return late ? "release" : "wait";
    return late ? "turn" : "wait";
  }
  // It went another way than the frame did.
  return "turn";
}

/** One point of a turn: how far round, and how large. */
export type ScreenDeviceTurnFrame = {
  rotate: number;
  scale: number;
  offset: number;
};

const easeInOut = (t: number) => (t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t));

/**
 * A turn of a device of this size to where it now stands, as one element: from `from` degrees round to 0, starting at
 * the size it had (`startScale`), and at each point small enough that its bounding box stays in the area.
 */
export function screenDeviceTurnFrames(turn: {
  from: number;
  width: number;
  height: number;
  areaWidth: number;
  areaHeight: number;
  startScale: number;
  steps?: number;
}): ScreenDeviceTurnFrame[] {
  const steps = turn.steps ?? 16;
  return Array.from({ length: steps + 1 }, (_, step) => {
    const offset = step / steps;
    const eased = easeInOut(offset);
    const rotate = turn.from * (1 - eased) || 0;
    const radians = (rotate * Math.PI) / 180;
    const [cos, sin] = [Math.abs(Math.cos(radians)), Math.abs(Math.sin(radians))];
    const boxWidth = turn.width * cos + turn.height * sin;
    const boxHeight = turn.width * sin + turn.height * cos;
    const fit = Math.min(turn.areaWidth / boxWidth, turn.areaHeight / boxHeight);
    const size = turn.startScale + (1 - turn.startScale) * eased;
    return { rotate, scale: Math.min(size, fit), offset };
  });
}

/** The shape as it stands turned, each length where the turn took it. */
export function turnScreenDeviceShape(
  shape: ScreenDeviceShape,
  turn: ScreenTurn
): ScreenDeviceShape {
  let turned = shape;
  for (let done = 0; done < turn; done += 90) turned = quarterTurn(turned);
  return turned;
}

function quarterTurn({
  frame,
  screen,
  corners,
  shapes,
}: ScreenDeviceShape): ScreenDeviceShape {
  const [topLeft, topRight, bottomRight, bottomLeft] = corners;
  return {
    frame: { width: frame.height, height: frame.width },
    screen: {
      x: frame.height - screen.y - screen.height,
      y: screen.x,
      width: screen.height,
      height: screen.width,
    },
    corners: [bottomLeft, topLeft, topRight, bottomRight],
    ...(shapes
      ? { shapes: [shapes[3], shapes[0], shapes[1], shapes[2]] as const }
      : {}),
  };
}

// As Simulator.app has them, on the primary modifier: ⌘ on macOS, Ctrl elsewhere.
const SHORTCUTS: readonly {
  action: ScreenDeviceAction;
  code: string;
  shift: boolean;
  keys: readonly string[];
}[] = [
  { action: "home", code: "KeyH", shift: true, keys: ["⇧", "H"] },
  { action: "lock", code: "KeyL", shift: false, keys: ["L"] },
  { action: "volume_up", code: "ArrowUp", shift: false, keys: ["↑"] },
  { action: "volume_down", code: "ArrowDown", shift: false, keys: ["↓"] },
  { action: "rotate", code: "ArrowRight", shift: false, keys: ["→"] },
];

/** The action a key press is the shortcut of, its modifiers exactly. */
export function screenDeviceShortcut(
  event: {
    code: string;
    altKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
    shiftKey: boolean;
  },
  macos: boolean
): ScreenDeviceAction | undefined {
  const primary = macos ? event.metaKey : event.ctrlKey;
  const other = macos ? event.ctrlKey : event.metaKey;
  if (!primary || other || event.altKey) return undefined;
  return SHORTCUTS.find(
    ({ code, shift }) => code === event.code && shift === event.shiftKey
  )?.action;
}

/** The keys of an action's shortcut, as a tooltip shows them. */
export function screenDeviceShortcutKeys(
  action: ScreenDeviceAction,
  macos: boolean
): string[] {
  const shortcut = SHORTCUTS.find((candidate) => candidate.action === action);
  return shortcut ? [macos ? "⌘" : "Ctrl", ...shortcut.keys] : [];
}
