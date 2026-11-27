import { Matrix3, Vector3 } from "three";
import { describe, expect, it } from "vitest";
import {
  duoModelFollows,
  duoModelTurn,
  duoPictureAt,
  duoPostureShown,
  duoTextureMatrix,
  type DuoPosture,
} from "../devices/duoScreens";
import { DUO_MODEL_AXES, duoEase, duoPoseBetween, duoPoseOf } from "../devices/duoPose";
import type { ScreenTurn } from "../screenDevice";

const POSTURES: readonly DuoPosture[] = [
  {
    id: "coverPortrait",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 0,
    pose: "closed",
  },
  {
    id: "coverLandscape",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 90,
    pose: "closed",
  },
  {
    id: "tent",
    screen: "cover",
    opening: 75,
    stand: "tent",
    orientation: 90,
    pose: "closed",
  },
  {
    id: "laptop",
    screen: "inner",
    opening: 105,
    stand: "laptop",
    orientation: 0,
    pose: "open",
  },
  {
    id: "innerLandscape",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 90,
    pose: "open",
  },
  {
    id: "innerPortrait",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 0,
    pose: "open",
  },
];
const posture = (id: DuoPosture["id"]) => POSTURES.find((one) => one.id === id)!;
const close = (a: { x: number; y: number }, b: { x: number; y: number }) => {
  expect(a.x).toBeCloseTo(b.x, 6);
  expect(a.y).toBeCloseTo(b.y, 6);
};

// The rig's UVs (v up) as the loaded model has them (glTF: v down).
const uv = (u: number, v: number) => ({ x: u, y: 1 - v });

describe("a press on a screen of the 3D Duo", () => {
  it("lands on the cover picture as its UVs say, upright", () => {
    // u from the hinge (the picture's left), v up.
    close(duoPictureAt("cover", 0, uv(0, 1)), { x: 0, y: 0 });
    close(duoPictureAt("cover", 0, uv(1, 0)), { x: 1, y: 1 });
    close(duoPictureAt("cover", 0, uv(0.25, 0.75)), { x: 0.25, y: 0.25 });
  });

  it("lands on the inner picture with its top at the camera half and its right at the device's bottom", () => {
    // u 1 is the camera half: the picture's top; v 0 the device's bottom: the picture's right.
    close(duoPictureAt("inner", 0, uv(0, 1)), { x: 0, y: 1 });
    close(duoPictureAt("inner", 0, uv(1, 0)), { x: 1, y: 0 });
    close(duoPictureAt("inner", 0, uv(0.2, 0.9)), { x: 0.1, y: 0.8 });
  });

  it("follows the picture turned with the device: its corner goes round clockwise", () => {
    // The cover's top left (u 0, v 1) as the device turns a quarter at a time: top right, bottom right, bottom left.
    const topLeft = uv(0, 1);
    close(duoPictureAt("cover", 90, topLeft), { x: 1, y: 0 });
    close(duoPictureAt("cover", 180, topLeft), { x: 1, y: 1 });
    close(duoPictureAt("cover", 270, topLeft), { x: 0, y: 1 });
    // The inner one's top left (camera half, device top: u 1, v 1) likewise.
    close(duoPictureAt("inner", 90, uv(1, 1)), { x: 1, y: 0 });
  });

  it("is where the texture puts the same point of the picture", () => {
    // The texture's own coordinates have y up: a picture point (x, y down) is (x, 1 - y) on it.
    for (const screen of ["cover", "inner"] as const)
      for (const turn of [0, 90, 180, 270] as ScreenTurn[]) {
        const matrix = new Matrix3().set(...duoTextureMatrix(screen, turn));
        for (const point of [uv(0.1, 0.2), uv(0.7, 0.95)]) {
          const st = new Vector3(point.x, point.y, 1).applyMatrix3(matrix);
          const at = duoPictureAt(screen, turn, point);
          close({ x: st.x, y: 1 - st.y }, at);
        }
      }
  });
});

describe("the 3D Duo's posture", () => {
  it("turns upright with the picture once it agrees, and at the posture's own quarter until then", () => {
    expect(duoModelTurn(posture("coverLandscape"), 270)).toBe(270);
    expect(duoModelTurn(posture("coverLandscape"), 0)).toBe(90);
    // Its panel's own picture: the model turns when the device does, with its UI's turn, not before it.
    expect(duoModelTurn(posture("coverLandscape"), 0, true)).toBe(0);
    // Only for a turn on the screen it shows: a change of screen turns it at once.
    expect(
      duoModelFollows(true, posture("coverLandscape"), {
        id: "coverLandscape",
        reached: false,
        from: "cover",
      })
    ).toBe(true);
    expect(
      duoModelFollows(true, posture("innerLandscape"), {
        id: "innerLandscape",
        reached: false,
        from: "cover",
      })
    ).toBe(false);
    expect(duoModelTurn(posture("innerPortrait"), 180)).toBe(180);
    // A tent keeps its hinge on top and a laptop its hinge across, whatever the picture does.
    expect(duoModelTurn(posture("tent"), 270)).toBe(90);
    expect(duoModelTurn(posture("laptop"), 90)).toBe(0);
  });

  it("shows the posture chosen on its way, and what the device says once it leaves it", () => {
    const chosen = { id: "laptop", reached: false } as const;
    expect(duoPostureShown(POSTURES, chosen, "closed", 0)?.id).toBe("laptop");
    expect(duoPostureShown(POSTURES, { ...chosen, reached: true }, "open", 0)?.id).toBe(
      "laptop"
    );
    // Folded since from elsewhere: the cover, as the picture stands.
    expect(
      duoPostureShown(POSTURES, { ...chosen, reached: true }, "closed", 90)?.id
    ).toBe("coverLandscape");
    expect(duoPostureShown(POSTURES, undefined, "open", 270)?.id).toBe(
      "innerLandscape"
    );
    expect(duoPostureShown(POSTURES, undefined, undefined, undefined)?.id).toBe(
      "coverPortrait"
    );
  });

  it("reads a tent or a laptop from the hinge its station says, another person's choice too", () => {
    // Nothing chosen here: the hinge tells a laptop from an open device held portrait, a tent from a cover held landscape.
    expect(duoPostureShown(POSTURES, undefined, "open", 0, 105)?.id).toBe("laptop");
    expect(duoPostureShown(POSTURES, undefined, "open", 0, 180)?.id).toBe(
      "innerPortrait"
    );
    expect(duoPostureShown(POSTURES, undefined, "closed", 90, 75)?.id).toBe("tent");
    expect(duoPostureShown(POSTURES, undefined, "closed", 90, 0)?.id).toBe(
      "coverLandscape"
    );
    // Chosen here and reached, then moved from elsewhere on the same screen: what the device says now.
    const laptop = { id: "laptop", reached: true } as const;
    expect(duoPostureShown(POSTURES, laptop, "open", 0, 105)?.id).toBe("laptop");
    expect(duoPostureShown(POSTURES, laptop, "open", 0, 180)?.id).toBe("innerPortrait");
    // On its way, a sweep through other angles keeps it.
    expect(
      duoPostureShown(POSTURES, { ...laptop, reached: false }, "open", 0, 160)?.id
    ).toBe("laptop");
  });

  it("faces the viewer with the screen that shows, upright", () => {
    // In the device's axes the cover display looks out along +z when closed, the inner one along +z when open.
    const out = new Vector3(0, 0, 1);
    for (const id of [
      "coverPortrait",
      "coverLandscape",
      "innerLandscape",
      "innerPortrait",
    ] as const) {
      const one = posture(id);
      const facing = out.clone().applyQuaternion(duoPoseOf(one, one.orientation).turn);
      // (seen a little from the side and above)
      expect(facing.z).toBeGreaterThan(0.95);
    }
    // Inner portrait (0) has the camera half (toward +x) on top, as a laptop's raised half; opened as a book (90), the
    // hinge stands up the middle, the cover half on the left as the closed device's cover display was.
    const up = new Vector3(1, 0, 0).applyQuaternion(
      duoPoseOf(posture("innerPortrait"), 0).turn
    );
    expect(up.y).toBeGreaterThan(0.95);
    const left = new Vector3(-1, 0, 0).applyQuaternion(
      duoPoseOf(posture("innerLandscape"), 90).turn
    );
    expect(left.x).toBeLessThan(-0.95);
    // A tent's hinge runs across on top; a laptop's cover half lies flat, its inner face up toward the viewer.
    const tent = duoPoseOf(posture("tent"), 90).turn;
    const hinge = new Vector3(0, 1, 0).applyQuaternion(tent);
    expect(Math.abs(hinge.y)).toBeLessThan(0.15);
    expect(hinge.x).toBeGreaterThan(0.8);
    // (the cover half's outside, 75° open from the camera half lying along +x)
    const coverOut = new Vector3(
      -Math.sin((75 * Math.PI) / 180),
      0,
      Math.cos((75 * Math.PI) / 180)
    ).applyQuaternion(tent);
    expect(coverOut.z).toBeGreaterThan(0.5);
    const laptop = duoPoseOf(posture("laptop"), 0).turn;
    const opening = (posture("laptop").opening * Math.PI) / 180;
    const lyingFace = new Vector3(
      Math.sin(opening),
      0,
      -Math.cos(opening)
    ).applyQuaternion(laptop);
    expect(lyingFace.y).toBeGreaterThan(0.8);
    expect(lyingFace.z).toBeGreaterThan(0.3);
    // (and the camera half stands up behind it)
    expect(new Vector3(1, 0, 0).applyQuaternion(laptop).y).toBeGreaterThan(0.8);
  });

  it("brings the model's glTF axes to the device's", () => {
    // glTF y (out of the open inner display) is the device's z; glTF -z (its top) the device's y.
    const z = new Vector3(0, 1, 0).applyQuaternion(DUO_MODEL_AXES);
    const y = new Vector3(0, 0, -1).applyQuaternion(DUO_MODEL_AXES);
    expect(z.z).toBeCloseTo(1, 6);
    expect(y.y).toBeCloseTo(1, 6);
  });

  it("moves between two by the opening and the turn together, easing in and out", () => {
    expect(duoEase(0)).toBe(0);
    expect(duoEase(1)).toBe(1);
    expect(duoEase(0.5)).toBeCloseTo(0.5, 6);
    expect(duoEase(0.1)).toBeLessThan(0.1);
    const from = duoPoseOf(posture("coverPortrait"), 0);
    const to = duoPoseOf(posture("innerLandscape"), 90);
    const half = duoPoseBetween(from, to, 0.5);
    expect(half.opening).toBe(90);
    expect(half.turn.angleTo(from.turn)).toBeCloseTo(half.turn.angleTo(to.turn), 6);
    expect(duoPoseBetween(from, to, 1).turn.angleTo(to.turn)).toBeCloseTo(0, 6);
  });
});
