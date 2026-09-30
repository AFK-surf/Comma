import { describe, expect, it } from "vitest";
import {
  computeImageFilmstripFits,
  imageFilmstripBounds,
  imageFilmstripClipPath,
  imageFilmstripPaintWidth,
  imageFilmstripTranslateX,
} from "../imageFilmstripGeometry";

describe("image filmstrip geometry", () => {
  it("lays portrait and landscape images edge-to-edge on one integer-pixel strip", () => {
    const fits = computeImageFilmstripFits(
      [
        { height: 800, width: 600 },
        { height: 400, width: 800 },
      ],
      1000,
      600,
      800
    );

    expect(fits).toEqual([
      { height: 600, offset: 0, width: 450, x: 275, y: 0 },
      { height: 400, offset: 450, width: 800, x: 100, y: 100 },
    ]);
    expect(fits[0]!.offset + fits[0]!.width).toBe(fits[1]!.offset);
    for (const fit of fits) {
      expect(Object.values(fit).every(Number.isInteger)).toBe(true);
    }
  });

  it("uses the vertical union while morphing the horizontal clip window", () => {
    const fits = computeImageFilmstripFits(
      [
        { height: 800, width: 600 },
        { height: 400, width: 800 },
      ],
      1000,
      600,
      800
    );
    const bounds = imageFilmstripBounds(fits, 600);

    expect(bounds).toEqual({ bottom: 0, top: 0 });
    expect(imageFilmstripClipPath(fits[0]!, 1000, bounds)).toBe(
      "inset(0px 275px 0px 275px)"
    );
    expect(imageFilmstripClipPath(fits[1]!, 1000, bounds)).toBe(
      "inset(0px 100px 0px 100px)"
    );
    expect(imageFilmstripTranslateX(fits[0]!)).toBe(275);
    expect(imageFilmstripTranslateX(fits[1]!)).toBe(-350);
  });

  it("provides a one-pixel animation paint overlap without changing logical offsets", () => {
    const fits = computeImageFilmstripFits(
      [
        { height: 800, width: 600 },
        { height: 400, width: 800 },
      ],
      1000,
      600,
      800
    );
    const first = fits[0]!;
    const second = fits[1]!;

    expect(first.offset + first.width).toBe(second.offset);
    expect(first.offset + imageFilmstripPaintWidth(first) - second.offset).toBe(1);
  });
});
