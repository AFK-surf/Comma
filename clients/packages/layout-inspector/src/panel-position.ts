import { rectBottom, rectRight, type InspectorRect } from "./geometry";

export type InspectorPanelPlacementSide =
  | "bottom"
  | "inside"
  | "left"
  | "manual"
  | "right"
  | "top";

export type InspectorPanelPosition = {
  left: number;
  side: InspectorPanelPlacementSide;
  top: number;
};

export type InspectorPanelSize = {
  height: number;
  width: number;
};

type PositionPanelOptions = {
  anchor: InspectorRect;
  gap?: number;
  inset?: number;
  panel: InspectorPanelSize;
  viewport: InspectorRect;
};

type ClampPanelOptions = {
  inset?: number;
  panel: InspectorPanelSize;
  position: Pick<InspectorPanelPosition, "left" | "top">;
  viewport: InspectorRect;
};

const defaultGap = 8;
const defaultInset = 12;

export function positionInspectorPanel({
  anchor,
  gap = defaultGap,
  inset = defaultInset,
  panel,
  viewport,
}: PositionPanelOptions): InspectorPanelPosition {
  const viewportRight = rectRight(viewport);
  const viewportBottom = rectBottom(viewport);
  const anchorRight = rectRight(anchor);
  const anchorBottom = rectBottom(anchor);
  const available = {
    bottom: viewportBottom - anchorBottom - gap - inset,
    left: anchor.left - viewport.left - gap - inset,
    right: viewportRight - anchorRight - gap - inset,
    top: anchor.top - viewport.top - gap - inset,
  };

  const candidates: Array<{
    fits: boolean;
    position: InspectorPanelPosition;
  }> = [
    {
      fits: available.right >= panel.width,
      position: {
        left: anchorRight + gap,
        side: "right",
        top: clamp(
          anchor.top,
          viewport.top + inset,
          viewportBottom - panel.height - inset
        ),
      },
    },
    {
      fits: available.left >= panel.width,
      position: {
        left: anchor.left - panel.width - gap,
        side: "left",
        top: clamp(
          anchor.top,
          viewport.top + inset,
          viewportBottom - panel.height - inset
        ),
      },
    },
    {
      fits: available.bottom >= panel.height,
      position: {
        left: clamp(
          anchor.left,
          viewport.left + inset,
          viewportRight - panel.width - inset
        ),
        side: "bottom",
        top: anchorBottom + gap,
      },
    },
    {
      fits: available.top >= panel.height,
      position: {
        left: clamp(
          anchor.left,
          viewport.left + inset,
          viewportRight - panel.width - inset
        ),
        side: "top",
        top: anchor.top - panel.height - gap,
      },
    },
  ];
  const fittingCandidate = candidates.find((candidate) => candidate.fits);
  if (fittingCandidate) return fittingCandidate.position;

  const fitsInsideAnchor =
    anchor.width >= panel.width + gap * 2 && anchor.height >= panel.height + gap * 2;
  if (fitsInsideAnchor) {
    return {
      left: clamp(
        anchorRight - panel.width - gap,
        anchor.left + gap,
        viewportRight - panel.width - inset
      ),
      side: "inside",
      top: clamp(
        anchor.top + gap,
        viewport.top + inset,
        Math.min(
          anchorBottom - panel.height - gap,
          viewportBottom - panel.height - inset
        )
      ),
    };
  }

  return candidates
    .map(({ position }, index) => {
      const clamped = clampInspectorPanelPosition({
        inset,
        panel,
        position,
        viewport,
      });
      return {
        index,
        overlap: intersectionArea(
          {
            ...clamped,
            height: panel.height,
            width: panel.width,
          },
          anchor
        ),
        position: {
          ...clamped,
          side: position.side,
        },
      };
    })
    .toSorted(
      (left, right) => left.overlap - right.overlap || left.index - right.index
    )[0]!.position;
}

export function clampInspectorPanelPosition({
  inset = defaultInset,
  panel,
  position,
  viewport,
}: ClampPanelOptions): Pick<InspectorPanelPosition, "left" | "top"> {
  return {
    left: clamp(
      position.left,
      viewport.left + inset,
      rectRight(viewport) - panel.width - inset
    ),
    top: clamp(
      position.top,
      viewport.top + inset,
      rectBottom(viewport) - panel.height - inset
    ),
  };
}

function intersectionArea(left: InspectorRect, right: InspectorRect) {
  const width = Math.max(
    0,
    Math.min(rectRight(left), rectRight(right)) - Math.max(left.left, right.left)
  );
  const height = Math.max(
    0,
    Math.min(rectBottom(left), rectBottom(right)) - Math.max(left.top, right.top)
  );
  return width * height;
}

function clamp(value: number, minimum: number, maximum: number) {
  if (maximum < minimum) return minimum;
  return Math.min(Math.max(value, minimum), maximum);
}
