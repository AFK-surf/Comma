import { describe, expect, it } from "vitest";
import { modifiers, pictureFraction, wireButton } from "../screenStreamInput";

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
