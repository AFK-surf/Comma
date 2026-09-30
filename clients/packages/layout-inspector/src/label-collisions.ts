import type { InspectorRect } from "./geometry";

export type OverlayLabelCollisionItem = {
  axis: "horizontal" | "vertical";
  rect: InspectorRect;
};

export type OverlayLabelShift = {
  x: number;
  y: number;
};

const collisionGap = 4;
const searchStep = 4;
const viewportInset = 4;

export function resolveOverlayLabelCollisions({
  items,
  obstacles = [],
  viewport,
}: {
  items: readonly OverlayLabelCollisionItem[];
  obstacles?: readonly InspectorRect[];
  viewport: InspectorRect;
}): OverlayLabelShift[] {
  const occupied = [...obstacles];

  return items.map((item) => {
    const shifts = collisionCandidates(item.axis, viewport);
    let bestShift = shifts[0] ?? { x: 0, y: 0 };
    let bestScore = Number.POSITIVE_INFINITY;

    for (const shift of shifts) {
      const candidate = shiftRect(item.rect, shift);
      const overlap = occupied.reduce(
        (total, placed) => total + overlapArea(candidate, placed, collisionGap),
        0
      );
      const overflow = viewportOverflow(candidate, viewport, viewportInset);

      if (overlap === 0 && overflow === 0) {
        bestShift = shift;
        break;
      }

      const score =
        overflow * 1_000_000 + overlap * 1_000 + Math.abs(shift.x) + Math.abs(shift.y);
      if (score < bestScore) {
        bestScore = score;
        bestShift = shift;
      }
    }

    occupied.push(shiftRect(item.rect, bestShift));
    return bestShift;
  });
}

function collisionCandidates(
  axis: OverlayLabelCollisionItem["axis"],
  viewport: InspectorRect
) {
  const maxDistance = Math.max(viewport.width, viewport.height);
  const candidates: OverlayLabelShift[] = [{ x: 0, y: 0 }];
  const primaryAxis = axis === "horizontal" ? "x" : "y";
  const secondaryAxis = primaryAxis === "x" ? "y" : "x";

  for (let distance = searchStep; distance <= maxDistance; distance += searchStep) {
    candidates.push(
      axisShift(primaryAxis, -distance),
      axisShift(primaryAxis, distance),
      axisShift(secondaryAxis, -distance),
      axisShift(secondaryAxis, distance),
      { x: -distance, y: -distance },
      { x: distance, y: -distance },
      { x: -distance, y: distance },
      { x: distance, y: distance }
    );
  }

  return candidates;
}

function axisShift(axis: "x" | "y", distance: number): OverlayLabelShift {
  return axis === "x" ? { x: distance, y: 0 } : { x: 0, y: distance };
}

function shiftRect(rect: InspectorRect, shift: OverlayLabelShift): InspectorRect {
  return {
    ...rect,
    left: rect.left + shift.x,
    top: rect.top + shift.y,
  };
}

function overlapArea(left: InspectorRect, right: InspectorRect, gap: number) {
  const width =
    Math.min(rectRight(left), rectRight(right) + gap) -
    Math.max(left.left, right.left - gap);
  const height =
    Math.min(rectBottom(left), rectBottom(right) + gap) -
    Math.max(left.top, right.top - gap);

  return Math.max(0, width) * Math.max(0, height);
}

function viewportOverflow(rect: InspectorRect, viewport: InspectorRect, inset: number) {
  const left = Math.max(0, viewport.left + inset - rect.left);
  const top = Math.max(0, viewport.top + inset - rect.top);
  const right = Math.max(0, rectRight(rect) - (rectRight(viewport) - inset));
  const bottom = Math.max(0, rectBottom(rect) - (rectBottom(viewport) - inset));

  return left + top + right + bottom;
}

function rectRight(rect: InspectorRect) {
  return rect.left + rect.width;
}

function rectBottom(rect: InspectorRect) {
  return rect.top + rect.height;
}
