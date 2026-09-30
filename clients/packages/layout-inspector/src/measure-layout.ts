import {
  createGridGapSegments,
  createInnerEdgeSegments,
  createOuterEdgeSegments,
  insetRect,
  parseResolvedTrackList,
  rectBottom,
  rectRight,
  type BoxEdges,
  type InspectorRect,
  type OverlaySegment,
} from "./geometry";

export type LayoutMeasurement = {
  border: BoxEdges;
  boxSizing: string;
  contentRect: InspectorRect;
  cssHeight: string;
  cssWidth: string;
  display: string;
  element: Element;
  gap: {
    column: number;
    row: number;
  };
  margin: BoxEdges;
  nodeLabel: string;
  padding: BoxEdges;
  rect: InspectorRect;
  geometry: LayoutGeometrySupport;
  segments: OverlaySegment[];
  transformed: boolean;
};

export type LayoutGeometryLimit =
  | "anonymous-text-flex-items"
  | "collapsed-grid-tracks"
  | "display-contents-flex-items"
  | "transformed-coordinate-space";

export type LayoutGeometrySupport = {
  boxModel: boolean;
  gap: boolean;
  limits: LayoutGeometryLimit[];
};

type FlexItemRect = InspectorRect & {
  margin: BoxEdges;
};

export function measureElement(element: Element): LayoutMeasurement | null {
  const domRect = element.getBoundingClientRect();
  const rect = {
    height: domRect.height,
    left: domRect.left,
    top: domRect.top,
    width: domRect.width,
  };

  if (
    !Number.isFinite(rect.left) ||
    !Number.isFinite(rect.top) ||
    rect.width <= 0 ||
    rect.height <= 0
  ) {
    return null;
  }

  const style = getComputedStyle(element);
  if (style.display === "none" || style.display === "contents") return null;

  const geometry = resolveGeometrySupport(element, style);
  const margin = readEdges(style, "margin");
  const border = readEdges(style, "border");
  const padding = readEdges(style, "padding");
  const paddingRect = insetRect(rect, border);
  const contentRect = insetRect(paddingRect, padding);
  const gap = geometry.gap
    ? readUsedGapLengths(style, contentRect, element)
    : {
        column: absolutePixelLength(style.columnGap) ?? 0,
        row: absolutePixelLength(style.rowGap) ?? 0,
      };
  const rowGap = gap.row;
  const columnGap = gap.column;
  const segments = [
    ...(geometry.boxModel
      ? [
          ...createOuterEdgeSegments(rect, margin),
          ...createInnerEdgeSegments(rect, border, "border"),
          ...createInnerEdgeSegments(paddingRect, padding, "padding"),
        ]
      : []),
    ...(geometry.gap
      ? measureGapSegments({
          columnGap,
          contentRect,
          element,
          rowGap,
          style,
        })
      : []),
  ];

  return {
    border,
    boxSizing: style.boxSizing,
    contentRect,
    cssHeight: style.height,
    cssWidth: style.width,
    display: style.display,
    element,
    gap: {
      column: columnGap,
      row: rowGap,
    },
    geometry,
    margin,
    nodeLabel: describeElement(element),
    padding,
    rect,
    segments,
    transformed: geometry.limits.includes("transformed-coordinate-space"),
  };
}

function resolveGeometrySupport(
  element: Element,
  style: CSSStyleDeclaration
): LayoutGeometrySupport {
  const limits: LayoutGeometryLimit[] = [];

  if (hasTransformedCoordinateSpace(element)) {
    limits.push("transformed-coordinate-space");
  }

  if (
    (style.display === "flex" || style.display === "inline-flex") &&
    Array.from(element.children).some(
      (child) => getComputedStyle(child).display === "contents"
    )
  ) {
    limits.push("display-contents-flex-items");
  }

  if (
    (style.display === "flex" || style.display === "inline-flex") &&
    Array.from(element.childNodes).some(
      (child) =>
        child.nodeType === Node.TEXT_NODE &&
        /[^\t\n\f\r ]/.test(child.textContent ?? "")
    )
  ) {
    limits.push("anonymous-text-flex-items");
  }

  if (
    (style.display === "grid" || style.display === "inline-grid") &&
    [
      ...parseResolvedTrackList(style.gridTemplateColumns),
      ...parseResolvedTrackList(style.gridTemplateRows),
    ].some((track) => track <= 0.01)
  ) {
    limits.push("collapsed-grid-tracks");
  }

  const transformed = limits.includes("transformed-coordinate-space");
  return {
    boxModel: !transformed,
    gap:
      !transformed &&
      !limits.includes("anonymous-text-flex-items") &&
      !limits.includes("display-contents-flex-items") &&
      !limits.includes("collapsed-grid-tracks"),
    limits,
  };
}

function hasTransformedCoordinateSpace(element: Element) {
  let current: Element | null = element;

  while (current) {
    const style = getComputedStyle(current);
    if (
      style.transform !== "none" ||
      !isIdentityPerspective(style.getPropertyValue("perspective")) ||
      !isIdentityTranslate(style.getPropertyValue("translate")) ||
      !isIdentityRotate(style.getPropertyValue("rotate")) ||
      !isIdentityScale(style.getPropertyValue("scale"))
    ) {
      return true;
    }
    const root = current.getRootNode();
    current = current.parentElement ?? (root instanceof ShadowRoot ? root.host : null);
  }

  return false;
}

function isIdentityPerspective(value: string) {
  const normalized = value.trim();
  return normalized === "" || normalized === "none";
}

function isIdentityTranslate(value: string) {
  const normalized = value.trim();
  return (
    normalized === "" ||
    normalized === "none" ||
    normalized
      .split(/\s+/)
      .every((part) => /^[-+]?0(?:\.0+)?(?:[a-z]+|%)?$/i.test(part))
  );
}

function isIdentityRotate(value: string) {
  const normalized = value.trim();
  if (normalized === "" || normalized === "none") return true;

  const angle = normalized.split(/\s+/).at(-1);
  if (!angle) return false;
  const match = /^([-+]?(?:\d+(?:\.\d*)?|\.\d+))(deg|grad|rad|turn)$/i.exec(angle);
  if (!match?.[1] || !match[2]) return false;

  const amount = Number.parseFloat(match[1]);
  const turns =
    match[2].toLowerCase() === "deg"
      ? amount / 360
      : match[2].toLowerCase() === "grad"
        ? amount / 400
        : match[2].toLowerCase() === "rad"
          ? amount / (2 * Math.PI)
          : amount;
  return Math.abs(turns - Math.round(turns)) <= 1e-9;
}

function isIdentityScale(value: string) {
  const normalized = value.trim();
  return (
    normalized === "" ||
    normalized === "none" ||
    normalized
      .split(/\s+/)
      .every((part) =>
        part.endsWith("%")
          ? Number.parseFloat(part.slice(0, -1)) === 100
          : Number(part) === 1
      )
  );
}

function readEdges(
  style: CSSStyleDeclaration,
  kind: "border" | "margin" | "padding"
): BoxEdges {
  if (kind === "border") {
    return {
      bottom: readLength(style.borderBottomWidth),
      left: readLength(style.borderLeftWidth),
      right: readLength(style.borderRightWidth),
      top: readLength(style.borderTopWidth),
    };
  }

  return {
    bottom: readLength(style[`${kind}Bottom`]),
    left: readLength(style[`${kind}Left`]),
    right: readLength(style[`${kind}Right`]),
    top: readLength(style[`${kind}Top`]),
  };
}

export function readLength(value: string) {
  if (!value || value === "normal" || value === "auto") return 0;
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function readUsedGapLengths(
  style: CSSStyleDeclaration,
  contentRect: InspectorRect,
  element: Element
) {
  const absoluteRow = absolutePixelLength(style.rowGap);
  const absoluteColumn = absolutePixelLength(style.columnGap);
  if (absoluteRow !== undefined && absoluteColumn !== undefined) {
    return { column: absoluteColumn, row: absoluteRow };
  }

  const root = document.documentElement;
  if (!root) {
    return {
      column: absoluteColumn ?? 0,
      row: absoluteRow ?? 0,
    };
  }

  const containingBlock = document.createElement("div");
  containingBlock.dataset.commaLayoutInspectorUi = "true";
  Object.assign(containingBlock.style, {
    contain: "strict",
    height: `${contentRect.height}px`,
    left: "-10000px",
    pointerEvents: "none",
    position: "fixed",
    top: "-10000px",
    visibility: "hidden",
    width: `${contentRect.width}px`,
  });

  const probe = document.createElement("div");
  Object.assign(probe.style, {
    boxSizing: "content-box",
    fontSize: style.fontSize,
    height: absoluteRow === undefined ? style.rowGap : `${absoluteRow}px`,
    position: "absolute",
    width: absoluteColumn === undefined ? style.columnGap : `${absoluteColumn}px`,
  });
  containingBlock.append(probe);
  root.append(containingBlock);

  const rect = probe.getBoundingClientRect();
  containingBlock.remove();

  return clampFlexGapsToLayoutGeometry({
    absoluteColumn,
    absoluteRow,
    element,
    gaps: {
      column: absoluteColumn ?? finiteLength(rect.width),
      row: absoluteRow ?? finiteLength(rect.height),
    },
    style,
  });
}

function clampFlexGapsToLayoutGeometry({
  absoluteColumn,
  absoluteRow,
  element,
  gaps,
  style,
}: {
  absoluteColumn: number | undefined;
  absoluteRow: number | undefined;
  element: Element;
  gaps: { column: number; row: number };
  style: CSSStyleDeclaration;
}) {
  if (style.display !== "flex" && style.display !== "inline-flex") return gaps;

  const horizontal = style.flexDirection.startsWith("row");
  const items = readFlexItemRects(element);
  if (items.length < 2) return gaps;

  const lines =
    style.flexWrap === "nowrap"
      ? [items]
      : groupFlexLines(items, horizontal ? "horizontal" : "vertical");
  const mainCeiling = minimumFlexMainSeparation(lines, horizontal);
  const crossCeiling = minimumFlexCrossSeparation(lines, horizontal);
  let { column, row } = gaps;

  if (mainCeiling !== undefined) {
    if (horizontal && absoluteColumn === undefined) {
      column = Math.min(column, mainCeiling);
    } else if (!horizontal && absoluteRow === undefined) {
      row = Math.min(row, mainCeiling);
    }
  }

  if (crossCeiling !== undefined) {
    if (horizontal && absoluteRow === undefined) {
      row = Math.min(row, crossCeiling);
    } else if (!horizontal && absoluteColumn === undefined) {
      column = Math.min(column, crossCeiling);
    }
  }

  return {
    column,
    row,
  };
}

function readFlexItemRects(element: Element) {
  return Array.from(element.children)
    .filter(isInFlowLayoutChild)
    .map((child) => {
      const rect = child.getBoundingClientRect();
      return {
        height: rect.height,
        left: rect.left,
        margin: readEdges(getComputedStyle(child), "margin"),
        top: rect.top,
        width: rect.width,
      };
    })
    .filter((rect) => rect.width > 0 && rect.height > 0);
}

function minimumFlexMainSeparation(
  lines: readonly (readonly FlexItemRect[])[],
  horizontal: boolean
) {
  const separations = lines.flatMap((line) => {
    const ordered = line.toSorted((left, right) =>
      horizontal ? left.left - right.left : left.top - right.top
    );
    return ordered.slice(0, -1).flatMap((current, index) => {
      const next = ordered[index + 1];
      if (!next) return [];
      const currentEnd = horizontal
        ? rectRight(current) + current.margin.right
        : rectBottom(current) + current.margin.bottom;
      const nextStart = horizontal
        ? next.left - next.margin.left
        : next.top - next.margin.top;
      return [finiteLength(nextStart - currentEnd)];
    });
  });

  return separations.length > 0 ? Math.min(...separations) : undefined;
}

function minimumFlexCrossSeparation(
  lines: readonly (readonly FlexItemRect[])[],
  horizontal: boolean
) {
  if (lines.length < 2) return undefined;

  const bounds = lines
    .map((line) => ({
      end: Math.max(
        ...line.map((rect) =>
          horizontal
            ? rectBottom(rect) + rect.margin.bottom
            : rectRight(rect) + rect.margin.right
        )
      ),
      start: Math.min(
        ...line.map((rect) =>
          horizontal ? rect.top - rect.margin.top : rect.left - rect.margin.left
        )
      ),
    }))
    .toSorted((left, right) => left.start - right.start);
  const separations = bounds.slice(0, -1).flatMap((current, index) => {
    const next = bounds[index + 1];
    return next ? [finiteLength(next.start - current.end)] : [];
  });

  return separations.length > 0 ? Math.min(...separations) : undefined;
}

function absolutePixelLength(value: string) {
  if (!value || value === "normal" || value === "auto") return 0;
  const match = /^(-?\d*\.?\d+)px$/.exec(value.trim());
  if (!match?.[1]) return undefined;
  return finiteLength(Number.parseFloat(match[1]));
}

function finiteLength(value: number) {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

function measureGapSegments({
  columnGap,
  contentRect,
  element,
  rowGap,
  style,
}: {
  columnGap: number;
  contentRect: InspectorRect;
  element: Element;
  rowGap: number;
  style: CSSStyleDeclaration;
}) {
  if (style.display === "grid" || style.display === "inline-grid") {
    return createGridGapSegments({
      alignContent: style.alignContent,
      columnGap,
      columnTracks: parseResolvedTrackList(style.gridTemplateColumns),
      contentRect,
      justifyContent: style.justifyContent,
      rowGap,
      rowTracks: parseResolvedTrackList(style.gridTemplateRows),
    });
  }

  if (style.display !== "flex" && style.display !== "inline-flex") return [];

  return createFlexGapSegments({
    columnGap,
    contentRect,
    element,
    flexDirection: style.flexDirection,
    flexWrap: style.flexWrap,
    rowGap,
  });
}

function createFlexGapSegments({
  columnGap,
  contentRect,
  element,
  flexDirection,
  flexWrap,
  rowGap,
}: {
  columnGap: number;
  contentRect: InspectorRect;
  element: Element;
  flexDirection: string;
  flexWrap: string;
  rowGap: number;
}) {
  const horizontal = flexDirection.startsWith("row");
  const items = readFlexItemRects(element);

  if (items.length < 2) return [];

  const lines =
    flexWrap === "nowrap"
      ? [items]
      : groupFlexLines(items, horizontal ? "horizontal" : "vertical");
  const mainGap = horizontal ? columnGap : rowGap;
  const crossGap = horizontal ? rowGap : columnGap;
  const segments: OverlaySegment[] = [];

  for (const [lineIndex, line] of lines.entries()) {
    const ordered = line.toSorted((left, right) =>
      horizontal ? left.left - right.left : left.top - right.top
    );

    for (let index = 0; index < ordered.length - 1; index += 1) {
      const current = ordered[index];
      const next = ordered[index + 1];
      if (!current || !next || mainGap <= 0) continue;

      const currentEnd = horizontal
        ? rectRight(current) + current.margin.right
        : rectBottom(current) + current.margin.bottom;
      const nextStart = horizontal
        ? next.left - next.margin.left
        : next.top - next.margin.top;
      const separation = nextStart - currentEnd;
      if (separation + 0.5 < mainGap) continue;

      const start = currentEnd + Math.max(0, (separation - mainGap) / 2);
      const lineStart = Math.min(
        ...line.map((rect) => (horizontal ? rect.top : rect.left))
      );
      const lineEnd = Math.max(
        ...line.map((rect) => (horizontal ? rectBottom(rect) : rectRight(rect)))
      );

      segments.push({
        axis: horizontal ? "vertical" : "horizontal",
        key: `flex-main-gap-${lineIndex}-${index}`,
        kind: "gap",
        property: horizontal ? "column-gap" : "row-gap",
        rect: horizontal
          ? {
              left: start,
              top: lineStart,
              width: mainGap,
              height: Math.max(0, lineEnd - lineStart),
            }
          : {
              left: lineStart,
              top: start,
              width: Math.max(0, lineEnd - lineStart),
              height: mainGap,
            },
        value: mainGap,
      });
    }
  }

  if (crossGap <= 0 || lines.length < 2) return segments;

  const lineBounds = lines
    .map((line) => ({
      end: Math.max(
        ...line.map((rect) =>
          horizontal
            ? rectBottom(rect) + rect.margin.bottom
            : rectRight(rect) + rect.margin.right
        )
      ),
      start: Math.min(
        ...line.map((rect) =>
          horizontal ? rect.top - rect.margin.top : rect.left - rect.margin.left
        )
      ),
    }))
    .toSorted((left, right) => left.start - right.start);

  for (let index = 0; index < lineBounds.length - 1; index += 1) {
    const current = lineBounds[index];
    const next = lineBounds[index + 1];
    if (!current || !next) continue;

    const separation = next.start - current.end;
    if (separation + 0.5 < crossGap) continue;

    const start = current.end + Math.max(0, (separation - crossGap) / 2);
    segments.push({
      axis: horizontal ? "horizontal" : "vertical",
      key: `flex-cross-gap-${index}`,
      kind: "gap",
      property: horizontal ? "row-gap" : "column-gap",
      rect: horizontal
        ? {
            left: contentRect.left,
            top: start,
            width: contentRect.width,
            height: crossGap,
          }
        : {
            left: start,
            top: contentRect.top,
            width: crossGap,
            height: contentRect.height,
          },
      value: crossGap,
    });
  }

  return segments;
}

function isInFlowLayoutChild(element: Element) {
  const style = getComputedStyle(element);
  return (
    style.display !== "none" &&
    style.position !== "absolute" &&
    style.position !== "fixed"
  );
}

function groupFlexLines<Item extends InspectorRect>(
  items: readonly Item[],
  mainAxis: "horizontal" | "vertical"
) {
  const crossStart = (rect: InspectorRect) =>
    mainAxis === "horizontal" ? rect.top : rect.left;
  const crossEnd = (rect: InspectorRect) =>
    mainAxis === "horizontal" ? rectBottom(rect) : rectRight(rect);
  const lines: Array<{
    end: number;
    items: Item[];
    start: number;
  }> = [];

  for (const item of items.toSorted(
    (left, right) => crossStart(left) - crossStart(right)
  )) {
    const start = crossStart(item);
    const end = crossEnd(item);
    const line = lines.find(
      (candidate) => start < candidate.end - 0.5 && end > candidate.start + 0.5
    );

    if (line) {
      line.items.push(item);
      line.start = Math.min(line.start, start);
      line.end = Math.max(line.end, end);
    } else {
      lines.push({ end, items: [item], start });
    }
  }

  return lines.map((line) => line.items);
}

function describeElement(element: Element) {
  const tag = element.tagName.toLowerCase();
  const id = element.id ? `#${element.id}` : "";
  const classes = Array.from(element.classList)
    .slice(0, 2)
    .map((name) => `.${name}`)
    .join("");
  return `${tag}${id}${classes}`;
}
