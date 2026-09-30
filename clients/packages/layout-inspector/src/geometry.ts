export type InspectorRect = {
  height: number;
  left: number;
  top: number;
  width: number;
};

export type BoxEdges = {
  bottom: number;
  left: number;
  right: number;
  top: number;
};

export type OverlayKind = "border" | "gap" | "margin" | "padding";

export type OverlaySegment = {
  axis: "horizontal" | "vertical";
  key: string;
  kind: OverlayKind;
  property: InspectedLayoutProperty;
  rect: InspectorRect;
  value: number;
};

const minimumSize = 0.01;

export function rectRight(rect: InspectorRect) {
  return rect.left + rect.width;
}

export function rectBottom(rect: InspectorRect) {
  return rect.top + rect.height;
}

export function insetRect(rect: InspectorRect, edges: BoxEdges): InspectorRect {
  return {
    left: rect.left + edges.left,
    top: rect.top + edges.top,
    width: Math.max(0, rect.width - edges.left - edges.right),
    height: Math.max(0, rect.height - edges.top - edges.bottom),
  };
}

export function createInnerEdgeSegments(
  rect: InspectorRect,
  edges: BoxEdges,
  kind: Extract<OverlayKind, "border" | "padding">
): OverlaySegment[] {
  const segments: OverlaySegment[] = [];
  const property = (edge: keyof BoxEdges) =>
    (kind === "border"
      ? `border-${edge}-width`
      : `${kind}-${edge}`) as InspectedLayoutProperty;
  const horizontalInset = Math.max(0, edges.left) + Math.max(0, edges.right);
  const verticalInset = Math.max(0, edges.top) + Math.max(0, edges.bottom);

  pushSegment(segments, {
    axis: "horizontal",
    key: `${kind}-top`,
    kind,
    property: property("top"),
    rect: {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: Math.max(0, edges.top),
    },
    value: edges.top,
  });
  pushSegment(segments, {
    axis: "vertical",
    key: `${kind}-right`,
    kind,
    property: property("right"),
    rect: {
      left: rectRight(rect) - Math.max(0, edges.right),
      top: rect.top + Math.max(0, edges.top),
      width: Math.max(0, edges.right),
      height: Math.max(0, rect.height - verticalInset),
    },
    value: edges.right,
  });
  pushSegment(segments, {
    axis: "horizontal",
    key: `${kind}-bottom`,
    kind,
    property: property("bottom"),
    rect: {
      left: rect.left,
      top: rectBottom(rect) - Math.max(0, edges.bottom),
      width: rect.width,
      height: Math.max(0, edges.bottom),
    },
    value: edges.bottom,
  });
  pushSegment(segments, {
    axis: "vertical",
    key: `${kind}-left`,
    kind,
    property: property("left"),
    rect: {
      left: rect.left,
      top: rect.top + Math.max(0, edges.top),
      width: Math.max(0, edges.left),
      height: Math.max(0, rect.height - verticalInset),
    },
    value: edges.left,
  });

  if (horizontalInset > rect.width || verticalInset > rect.height) {
    return segments.map((segment) => ({
      ...segment,
      rect: {
        ...segment.rect,
        height: Math.min(segment.rect.height, rect.height),
        width: Math.min(segment.rect.width, rect.width),
      },
    }));
  }

  return segments;
}

export function createOuterEdgeSegments(
  rect: InspectorRect,
  edges: BoxEdges
): OverlaySegment[] {
  const left = Math.max(0, edges.left);
  const right = Math.max(0, edges.right);
  const top = Math.max(0, edges.top);
  const bottom = Math.max(0, edges.bottom);
  const segments: OverlaySegment[] = [];

  pushSegment(segments, {
    axis: "horizontal",
    key: "margin-top",
    kind: "margin",
    property: "margin-top",
    rect:
      edges.top >= 0
        ? {
            left: rect.left - left,
            top: rect.top - top,
            width: rect.width + left + right,
            height: top,
          }
        : {
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: Math.min(rect.height, Math.abs(edges.top)),
          },
    value: edges.top,
  });
  pushSegment(segments, {
    axis: "vertical",
    key: "margin-right",
    kind: "margin",
    property: "margin-right",
    rect:
      edges.right >= 0
        ? {
            left: rectRight(rect),
            top: rect.top,
            width: right,
            height: rect.height,
          }
        : {
            left: Math.max(rect.left, rectRight(rect) - Math.abs(edges.right)),
            top: rect.top,
            width: Math.min(rect.width, Math.abs(edges.right)),
            height: rect.height,
          },
    value: edges.right,
  });
  pushSegment(segments, {
    axis: "horizontal",
    key: "margin-bottom",
    kind: "margin",
    property: "margin-bottom",
    rect:
      edges.bottom >= 0
        ? {
            left: rect.left - left,
            top: rectBottom(rect),
            width: rect.width + left + right,
            height: bottom,
          }
        : {
            left: rect.left,
            top: Math.max(rect.top, rectBottom(rect) - Math.abs(edges.bottom)),
            width: rect.width,
            height: Math.min(rect.height, Math.abs(edges.bottom)),
          },
    value: edges.bottom,
  });
  pushSegment(segments, {
    axis: "vertical",
    key: "margin-left",
    kind: "margin",
    property: "margin-left",
    rect:
      edges.left >= 0
        ? {
            left: rect.left - left,
            top: rect.top,
            width: left,
            height: rect.height,
          }
        : {
            left: rect.left,
            top: rect.top,
            width: Math.min(rect.width, Math.abs(edges.left)),
            height: rect.height,
          },
    value: edges.left,
  });

  return segments;
}

export function parseResolvedTrackList(value: string) {
  const withoutLineNames = value.replaceAll(/\[[^\]]*]/g, " ");
  const tracks = Array.from(withoutLineNames.matchAll(/(-?\d*\.?\d+)px/g), (match) =>
    Number.parseFloat(match[1] ?? "")
  );

  return tracks.every(Number.isFinite) ? tracks : [];
}

export function createGridGapSegments({
  alignContent,
  columnGap,
  columnTracks,
  contentRect,
  justifyContent,
  rowGap,
  rowTracks,
}: {
  alignContent: string;
  columnGap: number;
  columnTracks: readonly number[];
  contentRect: InspectorRect;
  justifyContent: string;
  rowGap: number;
  rowTracks: readonly number[];
}): OverlaySegment[] {
  return [
    ...createTrackGapSegments({
      alignment: justifyContent,
      axis: "horizontal",
      gap: columnGap,
      keyPrefix: "grid-column-gap",
      property: "column-gap",
      rect: contentRect,
      tracks: columnTracks,
    }),
    ...createTrackGapSegments({
      alignment: alignContent,
      axis: "vertical",
      gap: rowGap,
      keyPrefix: "grid-row-gap",
      property: "row-gap",
      rect: contentRect,
      tracks: rowTracks,
    }),
  ];
}

function createTrackGapSegments({
  alignment,
  axis,
  gap,
  keyPrefix,
  property,
  rect,
  tracks,
}: {
  alignment: string;
  axis: "horizontal" | "vertical";
  gap: number;
  keyPrefix: string;
  property: Extract<InspectedLayoutProperty, "column-gap" | "row-gap">;
  rect: InspectorRect;
  tracks: readonly number[];
}) {
  if (gap <= 0 || tracks.length < 2) return [];

  const available = axis === "horizontal" ? rect.width : rect.height;
  const tracksSize = tracks.reduce((sum, track) => sum + track, 0);
  const baseGapsSize = gap * (tracks.length - 1);
  const freeSpace = Math.max(0, available - tracksSize - baseGapsSize);
  const distribution = distributeFreeSpace(alignment, freeSpace, tracks.length);
  let cursor = (axis === "horizontal" ? rect.left : rect.top) + distribution.leading;

  return tracks.slice(0, -1).map((track, index) => {
    cursor += track;
    const separation = gap + distribution.between;
    const gapStart = cursor + Math.max(0, (separation - gap) / 2);
    const segment: OverlaySegment = {
      axis: axis === "horizontal" ? "vertical" : "horizontal",
      key: `${keyPrefix}-${index}`,
      kind: "gap",
      property,
      rect:
        axis === "horizontal"
          ? {
              left: gapStart,
              top: rect.top,
              width: gap,
              height: rect.height,
            }
          : {
              left: rect.left,
              top: gapStart,
              width: rect.width,
              height: gap,
            },
      value: gap,
    };
    cursor += separation;
    return segment;
  });
}

function distributeFreeSpace(alignment: string, freeSpace: number, trackCount: number) {
  const normalized = alignment.split(" ").at(-1) ?? alignment;

  if (normalized === "end" || normalized === "flex-end") {
    return { leading: freeSpace, between: 0 };
  }
  if (normalized === "center") {
    return { leading: freeSpace / 2, between: 0 };
  }
  if (normalized === "space-between" && trackCount > 1) {
    return { leading: 0, between: freeSpace / (trackCount - 1) };
  }
  if (normalized === "space-around" && trackCount > 0) {
    const between = freeSpace / trackCount;
    return { leading: between / 2, between };
  }
  if (normalized === "space-evenly" && trackCount > 0) {
    const between = freeSpace / (trackCount + 1);
    return { leading: between, between };
  }

  return { leading: 0, between: 0 };
}

function pushSegment(segments: OverlaySegment[], segment: OverlaySegment) {
  if (
    Math.abs(segment.value) >= minimumSize &&
    segment.rect.width >= minimumSize &&
    segment.rect.height >= minimumSize
  ) {
    segments.push(segment);
  }
}
import type { InspectedLayoutProperty } from "./authored-values";
