import { describe, expect, it } from "vitest";
import {
  screenDeviceAgrees,
  screenDeviceTurnFrames,
  screenDeviceTurnFrom,
  screenDeviceTurnSettled,
  screenDeviceActions,
  screenDevicePress,
  screenDeviceShape,
  screenDeviceShortcut,
  screenDeviceTurn,
  turnScreenDeviceShape,
  type ScreenStreamCapabilities,
} from "../screenDevice";
import { fakeFoldable, fakePhone } from "./fakeScreenDevice";

const device = (
  capabilities: Partial<ScreenStreamCapabilities>
): ScreenStreamCapabilities => ({
  input: "touch",
  buttons: [],
  ...capabilities,
});

const keys = (
  code: string,
  held: { shift?: boolean; meta?: boolean; ctrl?: boolean; alt?: boolean }
) => ({
  code,
  shiftKey: held.shift ?? false,
  metaKey: held.meta ?? false,
  ctrlKey: held.ctrl ?? false,
  altKey: held.alt ?? false,
});

describe("screenDeviceActions", () => {
  it("offers a computer's source nothing", () => {
    expect(screenDeviceActions(undefined, true)).toEqual([]);
  });

  it("offers only what the source declares", () => {
    expect(screenDeviceActions(device({ buttons: ["lock"] }), true)).toEqual(["lock"]);
    expect(screenDeviceActions(device({ buttons: ["volume"] }), true)).toEqual([
      "volume_up",
      "volume_down",
    ]);
    expect(screenDeviceActions(device({ buttons: ["rotate"] }), true)).toEqual([
      "rotate",
    ]);
    expect(screenDeviceActions(device({ shapes: fakePhone }), true)).toEqual([]);
  });

  it("leaves nothing to one without control", () => {
    expect(
      screenDeviceActions(
        device({ buttons: ["home", "lock", "volume", "rotate"] }),
        false
      )
    ).toEqual([]);
  });
});

describe("screenDevicePress", () => {
  it("tells a device's source as the station reads it", () => {
    expect(screenDevicePress("rotate")).toEqual([{ t: "device", name: "rotate" }]);
    expect(screenDevicePress("volume_up")).toEqual([
      { t: "device", name: "volume_up" },
    ]);
    // Home is Simulator's ⌘⇧H, lock its ⌘L: meta is bit 2, shift bit 3.
    expect(screenDevicePress("home")[0]).toEqual({
      t: "key",
      kind: "down",
      key: "h",
      code: "KeyH",
      mods: 12,
    });
    expect(
      screenDevicePress("lock").map((input) => "kind" in input && input.kind)
    ).toEqual(["down", "up"]);
    expect(screenDevicePress("lock")[0]).toMatchObject({ code: "KeyL", mods: 4 });
  });
});

describe("screenDeviceShape", () => {
  const [cover, inner] = fakeFoldable;

  it("takes the first panel until there is a picture", () => {
    expect(screenDeviceShape(fakeFoldable, undefined)).toBe(cover);
  });

  it("follows the picture's shape from panel to panel, however it stands", () => {
    expect(screenDeviceShape(fakeFoldable, 1250 / 1780)).toBe(inner);
    expect(screenDeviceShape(fakeFoldable, 468 / 678)).toBe(cover);
    expect(screenDeviceShape(fakeFoldable, 1780 / 1250)).toBe(inner);
    expect(screenDeviceShape(fakeFoldable, 678 / 468)).toBe(cover);
  });
});

describe("screenDeviceTurn", () => {
  const [phone] = fakePhone;
  const upright = 390 / 840;
  const sideways = 840 / 390;

  it("reads the picture's aspect when the source reports nothing", () => {
    expect(screenDeviceTurn(phone, upright, undefined)).toBe(0);
    expect(screenDeviceTurn(phone, sideways, undefined)).toBe(90);
  });

  it("takes which way from the source's report", () => {
    expect(screenDeviceTurn(phone, upright, 180)).toBe(180);
    expect(screenDeviceTurn(phone, sideways, 270)).toBe(270);
  });

  it("goes by the picture when a report disagrees with it", () => {
    expect(screenDeviceTurn(phone, upright, 90)).toBe(0);
    expect(screenDeviceTurn(phone, sideways, 180)).toBe(90);
  });

  it("takes the report until there is a picture", () => {
    expect(screenDeviceTurn(phone, undefined, 270)).toBe(270);
    expect(screenDeviceTurn(phone, undefined, undefined)).toBe(0);
  });
});

describe("turnScreenDeviceShape", () => {
  // Not symmetric: each gap and each corner differs.
  const shape = {
    frame: { width: 100, height: 200 },
    screen: { x: 1, y: 2, width: 90, height: 180 },
    corners: [10, 20, 30, 40],
  } as const;

  it("carries the screen and its corners a quarter clockwise", () => {
    expect(turnScreenDeviceShape(shape, 90)).toEqual({
      frame: { width: 200, height: 100 },
      // What was 18 below the screen is now 18 to its left.
      screen: { x: 18, y: 1, width: 180, height: 90 },
      corners: [40, 10, 20, 30],
    });
  });

  it("comes back to itself", () => {
    expect(turnScreenDeviceShape(turnScreenDeviceShape(shape, 270), 90)).toEqual(shape);
    expect(turnScreenDeviceShape(shape, 180)).toEqual(
      turnScreenDeviceShape(turnScreenDeviceShape(shape, 90), 90)
    );
  });
});

describe("screenDeviceShortcut", () => {
  it("knows Simulator's shortcuts", () => {
    const on = (code: string, shift = false) =>
      screenDeviceShortcut(keys(code, { meta: true, shift }), true);
    expect(on("KeyH", true)).toBe("home");
    expect(on("KeyL")).toBe("lock");
    expect(on("ArrowUp")).toBe("volume_up");
    expect(on("ArrowDown")).toBe("volume_down");
    expect(on("ArrowRight")).toBe("rotate");
  });

  it("takes its modifiers exactly", () => {
    expect(screenDeviceShortcut(keys("KeyH", { meta: true }), true)).toBeUndefined();
    expect(
      screenDeviceShortcut(keys("KeyL", { meta: true, shift: true }), true)
    ).toBeUndefined();
    // ⌃⌘⇧H is another of Simulator's: the app switcher.
    expect(
      screenDeviceShortcut(keys("KeyH", { meta: true, shift: true, ctrl: true }), true)
    ).toBeUndefined();
    expect(
      screenDeviceShortcut(keys("KeyS", { meta: true, alt: true }), true)
    ).toBeUndefined();
    expect(screenDeviceShortcut(keys("KeyS", {}), true)).toBeUndefined();
  });

  it("goes by Ctrl away from macOS", () => {
    expect(screenDeviceShortcut(keys("KeyL", { ctrl: true }), false)).toBe("lock");
    expect(screenDeviceShortcut(keys("KeyL", { meta: true }), false)).toBeUndefined();
    expect(screenDeviceShortcut(keys("KeyL", { ctrl: true }), true)).toBeUndefined();
  });
});

describe("a device's turn", () => {
  const held = {
    turning: false,
    agreed: true,
    arrived: true,
    unmoved: false,
    restored: false,
    heldMs: 600,
    arrivedMs: 300,
    quietMs: 300,
  };
  const nothing = { ...held, arrived: false, unmoved: true };

  it("swaps to the source's picture only when the frame has turned and the picture has settled", () => {
    expect(screenDeviceTurnSettled({ ...held, turning: true })).toBe("wait");
    expect(screenDeviceTurnSettled({ ...held, quietMs: 40, arrivedMs: 40 })).toBe(
      "wait"
    );
    expect(screenDeviceTurnSettled(held)).toBe("swap");
    // A picture that never goes quiet goes on after a while.
    expect(screenDeviceTurnSettled({ ...held, quietMs: 0, arrivedMs: 900 })).toBe(
      "swap"
    );
  });

  it("turns back from a press that turned nothing, late enough for a slow device, then lets go", () => {
    expect(screenDeviceTurnSettled({ ...nothing, heldMs: 2000 })).toBe("wait");
    expect(screenDeviceTurnSettled({ ...nothing, heldMs: 2600 })).toBe("turn");
    expect(screenDeviceTurnSettled({ ...nothing, heldMs: 2600, restored: true })).toBe(
      "release"
    );
  });

  it("follows a device that went another way, and waits while its report and picture differ", () => {
    const other = { ...held, arrived: false };
    expect(screenDeviceTurnSettled(other)).toBe("turn");
    expect(screenDeviceTurnSettled({ ...other, agreed: false })).toBe("wait");
    const [phone] = fakePhone;
    expect(screenDeviceAgrees(phone, 390 / 840, 0)).toBe(true);
    expect(screenDeviceAgrees(phone, 840 / 390, 0)).toBe(false);
    expect(screenDeviceAgrees(phone, 840 / 390, 270)).toBe(true);
  });

  it("starts from the old standing, the short way round", () => {
    expect(screenDeviceTurnFrom(0, 90)).toBe(-90);
    expect(screenDeviceTurnFrom(270, 0)).toBe(-90);
    expect(screenDeviceTurnFrom(0, 270)).toBe(90);
    expect(Math.abs(screenDeviceTurnFrom(90, 270))).toBe(180);
  });

  it.each([
    ["a tall device going sideways", -90, 710, 310, 760, 900],
    ["a tall device coming upright", -90, 310, 710, 760, 900],
    ["a nearly square one", -90, 700, 640, 760, 900],
    ["a half turn", 180, 310, 710, 400, 900],
  ])(
    "stays inside the stage at every point: %s",
    (_, from, width, height, areaWidth, areaHeight) => {
      const frames = screenDeviceTurnFrames({
        from,
        width,
        height,
        areaWidth,
        areaHeight,
        startScale: 1,
      });
      expect(frames[0]!.rotate).toBe(from);
      expect(frames.at(-1)).toMatchObject({ rotate: 0, scale: 1, offset: 1 });
      for (const { rotate, scale } of frames) {
        const radians = (rotate * Math.PI) / 180;
        const [cos, sin] = [Math.abs(Math.cos(radians)), Math.abs(Math.sin(radians))];
        expect((width * cos + height * sin) * scale).toBeLessThanOrEqual(
          areaWidth + 0.01
        );
        expect((width * sin + height * cos) * scale).toBeLessThanOrEqual(
          areaHeight + 0.01
        );
      }
    }
  );

  it("starts at the size the device had, so the turn does not jump", () => {
    const [first] = screenDeviceTurnFrames({
      from: -90,
      width: 700,
      height: 300,
      areaWidth: 760,
      areaHeight: 900,
      startScale: 0.5,
    });
    expect(first!.scale).toBeCloseTo(0.5);
  });
});
