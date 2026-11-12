import { describe, expect, it } from "vitest";
import {
  goesAsKey,
  InputFrame,
  modifiers,
  pictureFraction,
  textPieces,
  wheelPixels,
  wireButton,
  type ScreenStreamInput,
} from "../screenStreamInput";

describe("pictureFraction", () => {
  const element = { left: 100, top: 50, width: 400, height: 400 };

  it("maps a point to fractions of a picture that fills the element", () => {
    expect(
      pictureFraction({ clientX: 200, clientY: 150 }, element, {
        width: 800,
        height: 800,
      })
    ).toEqual({ x: 0.25, y: 0.25 });
  });

  it("skips the bars around a letterboxed picture", () => {
    // An 800x400 picture is 400x200 here, with 100px bars above and below.
    const picture = { width: 800, height: 400 };
    expect(pictureFraction({ clientX: 300, clientY: 250 }, element, picture)).toEqual({
      x: 0.5,
      y: 0.5,
    });
    expect(pictureFraction({ clientX: 300, clientY: 150 }, element, picture)).toEqual({
      x: 0.5,
      y: 0,
    });
  });

  it("clamps points outside the picture to its edges", () => {
    expect(
      pictureFraction({ clientX: 0, clientY: 900 }, element, {
        width: 800,
        height: 800,
      })
    ).toEqual({ x: 0, y: 1 });
  });

  it("answers the origin before the picture has a size", () => {
    expect(
      pictureFraction({ clientX: 300, clientY: 250 }, element, { width: 0, height: 0 })
    ).toEqual({ x: 0, y: 0 });
  });
});

describe("wire input", () => {
  it("numbers the secondary button 1 and the middle button 2", () => {
    expect([0, 1, 2].map(wireButton)).toEqual([0, 2, 1]);
  });

  it("lists the held modifiers", () => {
    expect(
      modifiers({ shiftKey: true, ctrlKey: false, altKey: false, metaKey: true })
    ).toEqual(["shift", "meta"]);
  });
});

describe("wheelPixels", () => {
  it("counts lines as 16 pixels and pages as the page's height", () => {
    expect(wheelPixels({ deltaMode: 0, deltaX: 1.5, deltaY: -3 }, 600)).toEqual({
      dx: 1.5,
      dy: -3,
    });
    expect(wheelPixels({ deltaMode: 1, deltaX: 0, deltaY: 3 }, 600)).toEqual({
      dx: 0,
      dy: 48,
    });
    expect(wheelPixels({ deltaMode: 2, deltaX: 0, deltaY: -1 }, 600)).toEqual({
      dx: 0,
      dy: -600,
    });
  });
});

describe("textPieces", () => {
  it("keeps text that fits one event whole", () => {
    expect(textPieces("你好, world")).toEqual(["你好, world"]);
    expect(textPieces("")).toEqual([]);
  });

  it("splits a long paste so each event fits, no character split", () => {
    const text = "中".repeat(3000) + "😀".repeat(10);
    const pieces = textPieces(text);
    expect(pieces.join("")).toBe(text);
    expect(pieces.length).toBeGreaterThan(1);
    for (const piece of pieces) {
      const bytes = new TextEncoder().encode(
        JSON.stringify({ t: "text", text: piece })
      ).length;
      expect(bytes).toBeLessThanOrEqual(4096);
      expect(piece.length).toBeLessThanOrEqual(4096);
    }
  });
});

const key = (init: Partial<KeyboardEvent>) =>
  ({
    isComposing: false,
    keyCode: 0,
    key: "a",
    code: "KeyA",
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    ...init,
  }) as KeyboardEvent;

describe("goesAsKey", () => {
  it("leaves an IME's keys, a paste and a soft keyboard's letter to make text", () => {
    expect(goesAsKey(key({}))).toBe(true);
    expect(goesAsKey(key({ isComposing: true }))).toBe(false);
    expect(goesAsKey(key({ keyCode: 229 }))).toBe(false);
    expect(goesAsKey(key({ key: "Process" }))).toBe(false);
    expect(goesAsKey(key({ key: "Dead" }))).toBe(false);
    expect(goesAsKey(key({ key: "v", code: "KeyV", metaKey: true }))).toBe(false);
    expect(goesAsKey(key({ key: "v", code: "KeyV", ctrlKey: true }))).toBe(false);
    expect(goesAsKey(key({ key: "a", code: "" }))).toBe(false);
    expect(goesAsKey(key({ key: "Enter", code: "" }))).toBe(true);
  });
});

const frames = () => {
  let waiting: (() => void) | undefined;
  const clock = (run: () => void) => {
    waiting = run;
    return () => (waiting = undefined);
  };
  return Object.assign(clock, { run: () => waiting?.() });
};

describe("InputFrame", () => {
  it("sends the latest move and the wheel summed once a frame", () => {
    const sent: ScreenStreamInput[] = [];
    const clock = frames();
    const frame = new InputFrame((input) => sent.push(input), clock);
    frame.move({ type: "move", x: 0.1, y: 0.1, mods: [] });
    frame.move({ type: "move", x: 0.2, y: 0.2, mods: [] });
    frame.wheel({ t: "wheel", x: 0.5, y: 0.5, dx: 1, dy: 16 });
    frame.wheel({ t: "wheel", x: 0.6, y: 0.5, dx: 0, dy: 32 });
    expect(sent).toEqual([]);
    clock.run();
    expect(sent).toEqual([
      { type: "move", x: 0.2, y: 0.2, mods: [] },
      { t: "wheel", x: 0.6, y: 0.5, dx: 1, dy: 48 },
    ]);
  });

  it("sends what waits before a press, and nothing once dropped", () => {
    const sent: ScreenStreamInput[] = [];
    const clock = frames();
    const frame = new InputFrame((input) => sent.push(input), clock);
    frame.move({ type: "move", x: 0.3, y: 0.3, mods: [] });
    frame.now();
    expect(sent).toEqual([{ type: "move", x: 0.3, y: 0.3, mods: [] }]);
    frame.move({ type: "move", x: 0.4, y: 0.4, mods: [] });
    frame.drop();
    clock.run();
    expect(sent).toHaveLength(1);
  });
});
