import { describe, expect, it } from "vitest";
import { clampInspectorPanelPosition, positionInspectorPanel } from "../panel-position";

const viewport = {
  height: 768,
  left: 0,
  top: 0,
  width: 1024,
};
const panel = {
  height: 420,
  width: 360,
};

describe("positionInspectorPanel", () => {
  it.each(
    [
      {
        name: "places the panel beside the active element when the preferred side fits",
        anchor: { height: 120, left: 120, top: 80, width: 240 },
        panel,
        expected: { left: 368, side: "right", top: 80 },
      },
      {
        name: "flips to the left when the preferred side does not fit",
        anchor: { height: 120, left: 720, top: 80, width: 240 },
        panel,
        expected: { left: 352, side: "left", top: 80 },
      },
      {
        name: "uses a vertical side and shifts along the viewport edge",
        anchor: { height: 60, left: 390, top: 60, width: 250 },
        panel: { height: 240, width: 520 },
        expected: { left: 390, side: "bottom", top: 128 },
      },
    ].map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { anchor, panel: panelSize, expected }) => {
    expect(positionInspectorPanel({ anchor, panel: panelSize, viewport })).toEqual(
      expected
    );
  });

  it("falls back inside a large element when no outer side can contain it", () => {
    const anchor = {
      height: 740,
      left: 20,
      top: 14,
      width: 984,
    };
    const position = positionInspectorPanel({
      anchor,
      panel,
      viewport,
    });

    expect(position.side).toBe("inside");
    expect(position.left).toBeGreaterThan(anchor.left);
    expect(position.left + panel.width).toBeLessThan(anchor.left + anchor.width);
    expect(position.top).toBeGreaterThan(anchor.top);
    expect(position.top + panel.height).toBeLessThan(anchor.top + anchor.height);
  });

  it("clamps a manually dragged panel inside the viewport", () => {
    expect(
      clampInspectorPanelPosition({
        panel,
        position: {
          left: 900,
          top: -200,
        },
        viewport,
      })
    ).toEqual({
      left: 652,
      top: 12,
    });
  });
});
