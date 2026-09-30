import { describe, expect, it } from "vitest";
import {
  createGridGapSegments,
  createInnerEdgeSegments,
  createOuterEdgeSegments,
  insetRect,
  parseResolvedTrackList,
} from "../geometry";

describe("layout inspector geometry", () => {
  it("builds the content box and four padding segments", () => {
    const padding = { top: 4, right: 8, bottom: 12, left: 16 };
    const rect = { top: 20, left: 30, width: 200, height: 120 };

    expect(insetRect(rect, padding)).toEqual({
      top: 24,
      left: 46,
      width: 176,
      height: 104,
    });
    expect(createInnerEdgeSegments(rect, padding, "padding")).toMatchObject([
      {
        key: "padding-top",
        property: "padding-top",
        rect: { top: 20, left: 30, width: 200, height: 4 },
      },
      {
        key: "padding-right",
        rect: { top: 24, left: 222, width: 8, height: 104 },
      },
      {
        key: "padding-bottom",
        rect: { top: 128, left: 30, width: 200, height: 12 },
      },
      {
        key: "padding-left",
        rect: { top: 24, left: 30, width: 16, height: 104 },
      },
    ]);
  });

  it("draws positive margins outside and negative margins inside the border box", () => {
    const segments = createOuterEdgeSegments(
      { top: 20, left: 30, width: 100, height: 80 },
      { top: 8, right: -6, bottom: 10, left: 4 }
    );

    expect(segments.find((segment) => segment.key === "margin-top")?.rect).toEqual({
      top: 12,
      left: 26,
      width: 104,
      height: 8,
    });
    expect(segments.find((segment) => segment.key === "margin-right")).toMatchObject({
      value: -6,
      rect: {
        top: 20,
        left: 124,
        width: 6,
        height: 80,
      },
    });
  });

  it("parses resolved grid tracks with named lines and renders centered gutters", () => {
    expect(parseResolvedTrackList("[start] 100px [middle] 80.5px [end]")).toEqual([
      100, 80.5,
    ]);

    expect(
      createGridGapSegments({
        alignContent: "start",
        columnGap: 12,
        columnTracks: [100, 80],
        contentRect: { top: 20, left: 30, width: 232, height: 120 },
        justifyContent: "center",
        rowGap: 0,
        rowTracks: [120],
      })
    ).toMatchObject([
      {
        key: "grid-column-gap-0",
        kind: "gap",
        property: "column-gap",
        value: 12,
        rect: {
          top: 20,
          left: 150,
          width: 12,
          height: 120,
        },
      },
    ]);
  });
});
