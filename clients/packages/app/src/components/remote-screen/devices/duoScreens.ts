// What a 3D iPhone Duo shows on its screens, and where a press on one lands, without three.js: the stage that draws the
// model (DuoStage.tsx) and the stage that sends input (ScreenStreamStage.tsx) share it. The model's screens carry UVs
// (iphone-duo.rig.json `screens`); the simulator's picture arrives upright for the viewer however the device is turned
// (`turn`, degrees clockwise, as useScreenDeviceStanding reports it).
import type { ListedScreen } from "@comma/core-client";
import type { ScreenDevicePose, ScreenTurn } from "../screenDevice";

export type DuoPosture = NonNullable<ListedScreen["postures"]>[number];
export type DuoPostureId = DuoPosture["id"];
export type DuoScreen = DuoPosture["screen"];

/** A point on a picture or a texture: x across, y down (picture) or up (UV). */
export type DuoPoint = { x: number; y: number };

/**
 * Where a point of a screen's UV space is on that screen's own upright picture (orientation 0), x across and y up.
 * Cover: u from the hinge across, v up. Inner: u across the open device from the cover half, v along the hinge to the
 * device's top; its upright picture has its top at the camera half and its right at the device's bottom, as the
 * simulator's inner panel stands a quarter past the device's turn (opened as a book, not turned, its UI is landscape
 * with its top up). (The rig's v; the
 * loaded model's UVs, glTF's, have it down: `1 - y`.)
 */
function natural(screen: DuoScreen, u: number, v: number): DuoPoint {
  return screen === "cover" ? { x: u, y: v } : { x: 1 - v, y: u };
}

/**
 * The picture as it arrives for a device turned `turn` clockwise: a point of the upright picture (x across, y up) as a
 * fraction of the arriving frame (x across, y down), which is what the input path takes.
 */
function turned(at: DuoPoint, turn: ScreenTurn): DuoPoint {
  switch (turn) {
    case 90:
      return { x: at.y, y: at.x };
    case 180:
      return { x: 1 - at.x, y: at.y };
    case 270:
      return { x: 1 - at.y, y: 1 - at.x };
    default:
      return { x: at.x, y: 1 - at.y };
  }
}

/**
 * A UV on a screen's mesh, as the loaded model has it (glTF: y down), as a fraction of the picture that arrives (x
 * across, y down from its top left).
 */
export function duoPictureAt(
  screen: DuoScreen,
  turn: ScreenTurn,
  uv: DuoPoint
): DuoPoint {
  return turned(natural(screen, uv.x, 1 - uv.y), turn);
}

/**
 * The texture transform (three.js `Texture.matrix`, row-major 3×3) that puts the arriving picture on a screen's mesh:
 * from the mesh's (glTF) UV to the texture's own coordinates, which a flipped picture texture has y up.
 */
export function duoTextureMatrix(
  screen: DuoScreen,
  turn: ScreenTurn
): [number, number, number, number, number, number, number, number, number] {
  const at = (u: number, v: number) => {
    const p = duoPictureAt(screen, turn, { x: u, y: v });
    return { s: p.x, t: 1 - p.y };
  };
  const o = at(0, 0);
  const u = at(1, 0);
  const v = at(0, 1);
  return [u.s - o.s, v.s - o.s, o.s, u.t - o.t, v.t - o.t, o.t, 0, 0, 1];
}

/** The screen the simulator shows for a fold it reports: the cover display when closed, else the inner one. */
export function duoScreenOf(pose: ScreenDevicePose | undefined): DuoScreen | undefined {
  if (pose === undefined) return undefined;
  return pose === "closed" ? "cover" : "inner";
}

const landscape = (turn: number) => turn % 180 !== 0;

/**
 * How far the model is turned clockwise before the viewer in a posture. A tent stands with its hinge on top and a laptop
 * with its hinge across, whatever the picture does; upright, it stands as the picture does once that agrees with the
 * posture (landscape or portrait), and at the posture's own quarter until then. `follows`: its picture is its panel's
 * own, whose UI's turn plays live; the model turns as the device says it does, with that turn, not before it.
 */
export function duoModelTurn(
  posture: DuoPosture,
  pictureTurn: ScreenTurn | undefined,
  follows = false
): ScreenTurn {
  if (posture.stand === "tent") return 90;
  if (posture.stand === "laptop") return 0;
  if (follows && pictureTurn !== undefined) return pictureTurn;
  if (
    pictureTurn !== undefined &&
    landscape(pictureTurn) === landscape(posture.orientation)
  )
    return pictureTurn;
  return posture.orientation;
}

/** A posture chosen here, and whether the device's fold has since come to its screen. */
export type DuoChoice = {
  id: DuoPostureId;
  reached: boolean;
  /** The screen shown when it was chosen: a choice on that screen only turns the device. */
  from?: DuoScreen | undefined;
};

/**
 * Whether the model turns as the device says (its panel's own picture, whose UI's turn plays live), not at once: a turn
 * on the screen it shows, so that the model and the UI on it turn together. A change of screen turns it at once: the new
 * panel's way up is said only after it shows.
 */
export function duoModelFollows(
  panelPicture: boolean,
  posture: DuoPosture,
  chosen: DuoChoice | undefined
): boolean {
  return panelPicture && (chosen === undefined || chosen.from === posture.screen);
}

/**
 * The posture a device standing so is in: of those its screen and its picture's shape allow, the one whose opening is
 * nearest its hinge's angle when its station says it (a tent beside a cover held landscape, a laptop beside an open
 * device held portrait); else the upright one.
 */
export function duoPostureStanding(
  postures: readonly DuoPosture[],
  screen: DuoScreen,
  wide: boolean,
  hinge: number | undefined
): DuoPosture | undefined {
  const fits = postures.filter(
    (posture) => posture.screen === screen && landscape(posture.orientation) === wide
  );
  if (hinge === undefined) return fits.find((posture) => posture.stand === "upright");
  return fits.reduce<DuoPosture | undefined>(
    (best, posture) =>
      best === undefined ||
      Math.abs(posture.opening - hinge) < Math.abs(best.opening - hinge)
        ? posture
        : best,
    undefined
  );
}

/** How near its opening a hinge is once a posture chosen got there. */
export const DUO_HINGE_REACHED = 10;

/**
 * The posture a device is shown in: the one chosen, on its way; once there, while the device stands so (its fold, and
 * its hinge where its station says it: another person may have moved it since); else the one its fold, picture and
 * hinge say (`duoPostureStanding`), the first until they say anything.
 */
export function duoPostureShown(
  postures: readonly DuoPosture[],
  chosen: DuoChoice | undefined,
  pose: ScreenDevicePose | undefined,
  pictureTurn: ScreenTurn | undefined,
  hinge?: number
): DuoPosture | undefined {
  const pick = postures.find((posture) => posture.id === chosen?.id);
  const screen = duoScreenOf(pose);
  const wide = pictureTurn !== undefined && landscape(pictureTurn);
  const standing = duoPostureStanding(postures, screen ?? "cover", wide, hinge);
  if (pick && !chosen?.reached) return pick;
  if (
    pick &&
    (screen === undefined || pick.screen === screen) &&
    (hinge === undefined || standing === undefined || standing.id === pick.id)
  )
    return pick;
  return standing ?? postures[0];
}
