import type { ScreenChromePanel, ScreenChromePictures } from "@comma/core-client";
import type { ScreenDeviceAction, ScreenTurn } from "./screenDevice";

// An iOS Simulator drawn as Xcode draws it: its case and buttons, ported from still.fail's
// apps/mbui/src/sfpages/screen_case.mbt. The station makes the pictures of what Xcode has on its Mac (its sim-chrome.ts),
// turned as the device stands; the case has the panel's shape cut out of it, so the live picture shows through it. Its
// buttons are pressed where they are, held as long as a person holds them.

export type ScreenCaseRect = { x: number; y: number; width: number; height: number };

/** A button of the case as it stands: where it rests, the way it goes in, its HID usage (none: only drawn). */
export type ScreenCaseButton = {
  name: string;
  at: ScreenCaseRect;
  dx: number;
  dy: number;
  front: boolean;
  usage?: { page: number; usage: number } | undefined;
};

/** A device's case as it stands now, in its own points, all turned as its picture is. */
export type ScreenCase = {
  /** Which of the device's panels, and the way its pictures are turned (quarters clockwise). */
  panel: number;
  key: string;
  turn: 0 | 1 | 2 | 3;
  frame: { width: number; height: number };
  screen: ScreenCaseRect;
  /**
   * How far in each of the picture's corners is under the case, in the case's points, top left and round it as it stands:
   * the panel's own corners less a little (they are no circles), so none of the picture shows outside the case.
   */
  corners: [number, number, number, number];
  /** The CSS `superellipse(k)` of each of `corners`, in the same order, where the mask says it; none: circles. */
  shapes?: [number, number, number, number] | undefined;
  buttons: ScreenCaseButton[];
};

/** How much of a panel's corner is cut off the square picture under the case (still.fail's `case_corner_share`). */
const CASE_CORNER_SHARE = 0.8;

/** A device's case as the stage has it: its panels, and the way to ask for a panel's pictures turned. */
export type ScreenStreamChrome = {
  /** What names the pictures of this computer's devices, beside each panel's own key. */
  key: string;
  panels: readonly ScreenChromePanel[];
  pictures(panel: number, turn: number): Promise<ScreenChromePictures>;
};

/** The rect `r` of a `w`×`h` frame, the frame turned `turn` quarters clockwise. */
export function turnedCaseRect(
  r: ScreenCaseRect,
  w: number,
  h: number,
  turn: number
): ScreenCaseRect {
  switch (turn) {
    case 1:
      return { x: h - r.y - r.height, y: r.x, width: r.height, height: r.width };
    case 2:
      return {
        x: w - r.x - r.width,
        y: h - r.y - r.height,
        width: r.width,
        height: r.height,
      };
    case 3:
      return { x: r.y, y: w - r.x - r.width, width: r.height, height: r.width };
    default:
      return r;
  }
}

/** A way (dx, dy) turned as turnedCaseRect does. */
export function turnedCaseWay(dx: number, dy: number, turn: number): [number, number] {
  switch (turn) {
    case 1:
      return [-dy, dx];
    case 2:
      return [-dx, -dy];
    case 3:
      return [dy, -dx];
    default:
      return [dx, dy];
  }
}

const shapeOf = (width: number, height: number) =>
  Math.min(width, height) / Math.max(width, height);

/**
 * The case of the panel a picture of this shape (`ratio`: its width over its height) is of, standing as `stood` says
 * while that is a way the picture can stand; none where no panel has its shape.
 */
export function screenCaseOf(
  panels: readonly ScreenChromePanel[],
  ratio: number | undefined,
  stood: ScreenTurn
): ScreenCase | undefined {
  if (!ratio || panels.length === 0) return undefined;
  const shape = shapeOf(ratio, 1);
  let panel = -1;
  let off = 0.01;
  panels.forEach((p, i) => {
    if (!(p.width > 0 && p.height > 0)) return;
    const away = Math.abs(shape - shapeOf(p.width, p.height));
    if (away < off) {
      off = away;
      panel = i;
    }
  });
  const p = panels[panel];
  if (!p) return undefined;
  // (as the station says it stands, while that is a way the picture can stand: the picture of a turn comes on its own)
  const lying = p.width > p.height !== ratio > 1;
  const said = (stood / 90) as 0 | 1 | 2 | 3;
  const saysLying = said % 2 === 1;
  const turn = saysLying === lying ? said : lying ? 1 : 0;
  const { width: fw, height: fh } = p.frame;
  const rect = (r: ScreenCaseRect) => turnedCaseRect(r, fw, fh, turn);
  const screen = rect(p.screen);
  const short = Math.min(screen.width, screen.height);
  const unit = short * CASE_CORNER_SHARE;
  const curve = (i: number) => p.curves?.[(i + 4 - turn) % 4];
  // (a corner the mask says as a superellipse is drawn as that, the panel's own: no circle to keep inside it)
  const corner = (i: number) =>
    p.curves
      ? curve(i)!.reach * short
      : p.corners.length === 4
        ? p.corners[(i + 4 - turn) % 4]! * unit
        : 0;
  return {
    panel,
    key: p.key,
    turn,
    frame: turn % 2 === 1 ? { width: fh, height: fw } : { width: fw, height: fh },
    screen,
    corners: [corner(0), corner(1), corner(2), corner(3)],
    ...(p.curves
      ? {
          shapes: [curve(0)!.k, curve(1)!.k, curve(2)!.k, curve(3)!.k] as [
            number,
            number,
            number,
            number,
          ],
        }
      : {}),
    buttons: p.buttons.map((b) => {
      const [dx, dy] = turnedCaseWay(b.dx, b.dy, turn);
      return {
        name: b.name,
        at: rect(b),
        dx,
        dy,
        front: b.front === true,
        ...(b.page && b.usage ? { usage: { page: b.page, usage: b.usage } } : {}),
      };
    }),
  };
}

/** How far past what shows of a button it is still pressed, in the page's pixels. */
const CASE_REACH = 16;
/** A press's room each way, in the page's pixels. */
const CASE_PRESS = 44;

/**
 * Where a button at `r` is pressed, in the case's points (`scale`: the page's pixels a point): a press's room along its
 * edge and across it, from the panel at `screen` outward, never over that, and on the case itself as it is (a home button)
 * only as far as that takes.
 */
export function screenCaseRoom(
  r: ScreenCaseRect,
  screen: ScreenCaseRect,
  front: boolean,
  scale: number
): ScreenCaseRect {
  const press = CASE_PRESS / scale;
  const reach = CASE_REACH / scale;
  if (front) {
    const width = Math.max(r.width, press);
    const height = Math.max(r.height, press);
    return {
      x: r.x + (r.width - width) / 2,
      y: r.y + (r.height - height) / 2,
      width,
      height,
    };
  }
  if (r.y + r.height <= screen.y + 1) {
    // over the panel
    const width = Math.max(r.width, press);
    const y = Math.max(r.y - reach, Math.min(r.y, screen.y - press));
    return { x: r.x + (r.width - width) / 2, y, width, height: screen.y - y };
  }
  if (r.y >= screen.y + screen.height - 1) {
    const width = Math.max(r.width, press);
    const end = Math.min(
      r.y + r.height + reach,
      Math.max(r.y + r.height, screen.y + screen.height + press)
    );
    return {
      x: r.x + (r.width - width) / 2,
      y: screen.y + screen.height,
      width,
      height: end - screen.y - screen.height,
    };
  }
  if (r.x < screen.x) {
    const height = Math.max(r.height, press);
    const x = Math.max(r.x - reach, Math.min(r.x, screen.x - press));
    return { x, y: r.y + (r.height - height) / 2, width: screen.x - x, height };
  }
  const height = Math.max(r.height, press);
  const end = Math.min(
    r.x + r.width + reach,
    Math.max(r.x + r.width, screen.x + screen.width + press)
  );
  return {
    x: screen.x + screen.width,
    y: r.y + (r.height - height) / 2,
    width: end - screen.x - screen.width,
    height,
  };
}

/** What the beside-the-device actions leave to the case: those it has a button for (still.fail's app leaves them out). */
export function screenCaseCovers(
  buttons: readonly ScreenCaseButton[],
  action: ScreenDeviceAction
): boolean {
  const has = (name: string) => buttons.some((b) => b.name === name && b.usage);
  if (action === "lock") return has("power");
  if (action === "volume_up") return has("volume-up");
  if (action === "volume_down") return has("volume-down");
  if (action === "home") return has("home");
  return false;
}

/** A panel's pictures as the page draws them: each a PNG's URL, decoded before it is said to be there. */
export type ScreenCasePictures = {
  body: string;
  buttons: Record<string, { up: string; down?: string | undefined }>;
};

const asked = new Map<string, Promise<ScreenCasePictures>>();
const came = new Map<string, ScreenCasePictures>();

const pictureKey = (chrome: ScreenStreamChrome, key: string, turn: number) =>
  `${chrome.key}\n${key}\n${turn}`;

/** A panel's pictures turned `turn`, once they have come and are decoded; none yet. */
export function screenCaseCame(
  chrome: ScreenStreamChrome,
  key: string,
  turn: number
): ScreenCasePictures | undefined {
  return came.get(pictureKey(chrome, key, turn));
}

const decoded = async (url: string) => {
  const image = new Image();
  image.src = url;
  await image.decode().catch(() => undefined);
  return url;
};

/**
 * Asks for a panel's pictures turned `turn` once (a failure may be asked again), the page's copy kept for as long as it
 * runs: the pictures are the same whoever asks.
 */
export function askScreenCase(
  chrome: ScreenStreamChrome,
  panel: number,
  turn: number
): Promise<ScreenCasePictures> {
  const p = chrome.panels[panel];
  if (!p) return Promise.reject(new Error("no such panel"));
  const id = pictureKey(chrome, p.key, turn);
  let made = asked.get(id);
  if (!made) {
    made = chrome.pictures(panel, turn).then(async (got) => {
      const url = (png: string) => decoded(`data:image/png;base64,${png}`);
      const buttons: ScreenCasePictures["buttons"] = {};
      for (const [name, b] of Object.entries(got.buttons))
        buttons[name] = {
          up: await url(b.up),
          ...(b.down ? { down: await url(b.down) } : {}),
        };
      const pictures = { body: await url(got.body), buttons };
      came.set(id, pictures);
      return pictures;
    });
    asked.set(id, made);
    made.catch(() => asked.delete(id));
  }
  return made;
}

/** The others of a device's pictures, one after another (making them is all its station does meanwhile). */
export async function askScreenCaseRest(chrome: ScreenStreamChrome): Promise<void> {
  for (const [panel] of chrome.panels.entries())
    for (let turn = 0; turn < 4; turn++)
      await askScreenCase(chrome, panel, turn).catch(() => undefined);
}
