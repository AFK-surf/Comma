// How the 3D iPhone Duo stands in each posture, and the way between two: its opening and its turn before the viewer.
// The viewer looks down -z with y up. The model's own axes (glTF, y up out of the open inner display, its top at -z) are
// first brought to the device's (iphone-duo.rig.json's Blender axes: x across the open device with the camera half at
// +x, y along the hinge to its top, z out of the inner display), so that closed, it shows its cover display upright with
// the hinge on the left.
import { Euler, Matrix4, Quaternion, Vector3 } from "three";
import type { ScreenTurn } from "../screenDevice";
import type { DuoPosture } from "./duoScreens";

/** The model's glTF axes as the device's. */
export const DUO_MODEL_AXES = new Quaternion().setFromEuler(
  new Euler(Math.PI / 2, 0, 0)
);

/** How long a change of posture plays. */
export const DUO_POSTURE_MS = 600;

// How far the viewer looks down on a laptop and a tent, in degrees.
const LAPTOP_LOOK = 25;
const TENT_LOOK = 12;
const TENT_SIDE = -18;
// An upright posture is seen straight on; a drag off its screens turns it a little (DUO_TILT).
const VIEW_YAW = 0;
const VIEW_PITCH = 0;

/** A pose of the model: how far it opens (degrees) and how it is turned before the viewer (device axes to view). */
export type DuoPoseState = { opening: number; turn: Quaternion };

const about = (axis: "x" | "y" | "z", degrees: number) =>
  new Quaternion().setFromAxisAngle(
    new Vector3(axis === "x" ? 1 : 0, axis === "y" ? 1 : 0, axis === "z" ? 1 : 0),
    (degrees * Math.PI) / 180
  );

/**
 * The pose of a posture with the model turned `modelTurn` clockwise (duoModelTurn). Upright, a closed device shows its
 * cover display as is; an open one is turned three quarters more, so that its inner display's own upright (its top at
 * the camera half) is up. A laptop lies on its cover half with the camera half raised behind; a tent stands on its two outer
 * edges, the hinge on top and the cover half toward the viewer.
 */
export function duoPoseOf(posture: DuoPosture, modelTurn: ScreenTurn): DuoPoseState {
  const { opening, turn } = standOf(posture, modelTurn);
  return {
    opening,
    turn: about("x", VIEW_PITCH).multiply(about("y", VIEW_YAW)).multiply(turn),
  };
}

function standOf(posture: DuoPosture, modelTurn: ScreenTurn): DuoPoseState {
  const { opening } = posture;
  if (posture.stand === "laptop") {
    // The cover half (the opening up from the camera half) lies on its back toward the viewer, and the camera half stands
    // at its far edge; the device's top is to the left.
    const at = opening * (Math.PI / 180);
    const [cos, sin] = [Math.cos(at), Math.sin(at)];
    const basis = new Matrix4().makeBasis(
      new Vector3(0, sin, cos),
      new Vector3(-1, 0, 0),
      new Vector3(0, -cos, sin)
    );
    return {
      opening,
      turn: about("x", LAPTOP_LOOK).multiply(
        new Quaternion().setFromRotationMatrix(basis)
      ),
    };
  }
  if (posture.stand === "tent") {
    // The halves' bisector (from the hinge, half the opening up from the camera half) points down, and the way across it
    // toward the cover half points at the viewer; the hinge runs across.
    const half = (opening / 2) * (Math.PI / 180);
    const [cos, sin] = [Math.cos(half), Math.sin(half)];
    const basis = new Matrix4().makeBasis(
      new Vector3(0, -cos, -sin),
      new Vector3(1, 0, 0),
      new Vector3(0, -sin, cos)
    );
    const stand = new Quaternion().setFromRotationMatrix(basis);
    return {
      opening,
      // (and more from its side than the others, so that both halves show)
      turn: about("x", TENT_LOOK).multiply(about("y", TENT_SIDE)).multiply(stand),
    };
  }
  return {
    opening,
    turn: about("z", -(modelTurn + (posture.screen === "inner" ? 270 : 0))),
  };
}

/** Ease in and out (cubic): how far a change has come at a share of its time. */
export function duoEase(t: number): number {
  const at = Math.min(1, Math.max(0, t));
  return at < 0.5 ? 4 * at * at * at : 1 - (-2 * at + 2) ** 3 / 2;
}

/** The pose a share of the way (already eased) from one to the other: the opening straight, the turn the short way. */
export function duoPoseBetween(
  from: DuoPoseState,
  to: DuoPoseState,
  share: number
): DuoPoseState {
  return {
    opening: from.opening + (to.opening - from.opening) * share,
    turn: from.turn.clone().slerp(to.turn, share),
  };
}

/** Where the camera looks and from how far. */
export type DuoFraming = { center: Vector3; distance: number };

/**
 * The camera's place to show a box (the posed model's, in view axes) whole and in the middle: `fill` of the view across
 * its larger share, the box's near face at that size.
 */
export function duoFrame(
  box: { min: Vector3; max: Vector3 },
  fovDegrees: number,
  aspect: number,
  fill = 0.82
): DuoFraming {
  const size = new Vector3().subVectors(box.max, box.min);
  const center = new Vector3().addVectors(box.min, box.max).multiplyScalar(0.5);
  const tan = Math.tan((fovDegrees * Math.PI) / 360);
  const fit =
    Math.max(size.y / (2 * tan), size.x / (2 * tan * Math.max(aspect, 1e-3))) / fill;
  return { center, distance: fit + size.z / 2 };
}

export function duoFramingBetween(
  from: DuoFraming,
  to: DuoFraming,
  share: number
): DuoFraming {
  return {
    center: from.center.clone().lerp(to.center, share),
    distance: from.distance * (to.distance / from.distance) ** share,
  };
}

/**
 * A slight turn of the whole device a drag off its showing screen gives (as on the phone app): close to the pointer for
 * small drags, ever stiffer toward its limits, which it never passes. Degrees: `yaw` turns its right side away for a
 * drag right, `pitch` tips its top toward the viewer for a drag down.
 */
export const DUO_TILT = { maxYaw: 25, maxPitch: 15, degreesPerPixel: 0.15 } as const;

export type DuoTilt = { yaw: number; pitch: number };

/** The drag carried so far, in degrees before the limits, kept within three times them so a drag back acts at once. */
const clampTilt = (value: number, limit: number) =>
  Math.min(3 * limit, Math.max(-3 * limit, value));

export function duoTiltAccumulate(raw: DuoTilt, dx: number, dy: number): DuoTilt {
  return {
    yaw: clampTilt(raw.yaw + dx * DUO_TILT.degreesPerPixel, DUO_TILT.maxYaw),
    pitch: clampTilt(raw.pitch + dy * DUO_TILT.degreesPerPixel, DUO_TILT.maxPitch),
  };
}

/** The turn shown for a carried drag, each angle within its limit. */
export function duoTiltAngles(raw: DuoTilt): DuoTilt {
  return {
    yaw: DUO_TILT.maxYaw * Math.tanh(raw.yaw / DUO_TILT.maxYaw),
    pitch: DUO_TILT.maxPitch * Math.tanh(raw.pitch / DUO_TILT.maxPitch),
  };
}
