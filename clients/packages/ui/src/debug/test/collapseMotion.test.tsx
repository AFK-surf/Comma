import { describe, expect, it, vi } from "vitest";
import {
  applyCollapseMotionToDocument,
  clampCubicBezierToEditor,
  copyTextToClipboard,
  defaultCollapseMotion,
  formatCubicBezier,
  formatCubicBezierCss,
  resetCollapseMotionOnDocument,
  serializeCollapseMotionParams,
} from "../collapseMotion";

describe("collapseMotion", () => {
  it("formats cubic-bezier values for display", () => {
    expect(formatCubicBezier({ x1: 0, y1: 0, x2: 0.58, y2: 1 })).toBe(
      "0.000, 0.000, 0.580, 1.000"
    );
    expect(formatCubicBezierCss({ x1: 0, y1: 0, x2: 0.58, y2: 1 })).toBe(
      "cubic-bezier(0.000, 0.000, 0.580, 1.000)"
    );
  });

  it("clamps out-of-range editor values back into the visible plot", () => {
    expect(clampCubicBezierToEditor({ x1: -0.2, y1: -0.9, x2: 1.4, y2: 1.8 })).toEqual({
      x1: 0,
      y1: -0.25,
      x2: 1,
      y2: 1.25,
    });
  });

  it("serializes collapse motion params as formatted JSON", () => {
    const json = serializeCollapseMotionParams(defaultCollapseMotion);
    expect(JSON.parse(json)).toEqual(defaultCollapseMotion);
    expect(json).toContain('"container"');
    expect(json).toContain('"durationMs": 180');
  });

  it("copies text to the clipboard", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, {
      clipboard: { writeText },
    });

    await copyTextToClipboard('{"container":{}}');

    expect(writeText).toHaveBeenCalledWith('{"container":{}}');
  });

  it("applies and resets container/content CSS variables on document root", () => {
    applyCollapseMotionToDocument(defaultCollapseMotion);

    const root = document.documentElement;
    expect(root.style.getPropertyValue("--collapse-container-duration")).toBe("180ms");
    expect(root.style.getPropertyValue("--collapse-container-bezier-x2")).toBe("0.252");
    expect(root.style.getPropertyValue("--collapse-content-duration")).toBe("200ms");
    expect(root.style.getPropertyValue("--collapse-content-bezier-x1")).toBe("0.004");
    expect(root.style.getPropertyValue("--collapse-content-opacity-hidden")).toBe("0");
    expect(root.style.getPropertyValue("--collapse-content-scale-hidden")).toBe("0.98");
    expect(root.style.getPropertyValue("--collapse-content-translate-y-hidden")).toBe(
      "-10px"
    );

    resetCollapseMotionOnDocument();
    expect(root.style.getPropertyValue("--collapse-container-duration")).toBe("");
    expect(root.style.getPropertyValue("--collapse-content-duration")).toBe("");
    expect(root.style.getPropertyValue("--collapse-content-scale-hidden")).toBe("");
  });
});
