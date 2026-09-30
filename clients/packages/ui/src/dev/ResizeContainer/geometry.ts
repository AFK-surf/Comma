export type ResizeContainerMode = "pixel" | "relative";

export type Size = {
  width: number;
  height: number;
};

export type Rect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

/** Edges that a single resize gesture is allowed to move. */
export type ResizeEdges = {
  left: boolean;
  right: boolean;
  top: boolean;
  bottom: boolean;
};

const clamp = (value: number, min: number, max: number) =>
  Math.min(Math.max(value, min), max);

/**
 * Keep `rect` fully inside `canvas`.
 *
 * Size is preserved whenever it fits; the box is nudged toward the top-left to
 * stay in bounds, and only shrinks when it is wider/taller than the canvas.
 */
export const clampRectToCanvas = (rect: Rect, canvas: Size, minSize: Size): Rect => {
  const width = clamp(rect.width, Math.min(minSize.width, canvas.width), canvas.width);
  const height = clamp(
    rect.height,
    Math.min(minSize.height, canvas.height),
    canvas.height
  );
  const x = clamp(rect.x, 0, Math.max(0, canvas.width - width));
  const y = clamp(rect.y, 0, Math.max(0, canvas.height - height));
  return { x, y, width, height };
};

/** Convert a pixel rect into canvas-relative ratios (0-1 of each axis). */
export const toRelativeRect = (rect: Rect, canvas: Size): Rect => ({
  x: canvas.width > 0 ? rect.x / canvas.width : 0,
  y: canvas.height > 0 ? rect.y / canvas.height : 0,
  width: canvas.width > 0 ? rect.width / canvas.width : 0,
  height: canvas.height > 0 ? rect.height / canvas.height : 0,
});

/** Convert canvas-relative ratios (0-1) back into a pixel rect. */
export const toPixelRect = (relative: Rect, canvas: Size): Rect => ({
  x: relative.x * canvas.width,
  y: relative.y * canvas.height,
  width: relative.width * canvas.width,
  height: relative.height * canvas.height,
});

/**
 * Adapt the content rect after the canvas resizes.
 *
 * - `pixel`: keep the content size, move it toward the top-left to stay visible,
 *   and only shrink it when it can no longer fit.
 * - `relative`: keep the content's proportional position and size, so it scales
 *   together with the canvas.
 */
export const adaptRectToCanvas = (
  rect: Rect,
  prevCanvas: Size,
  nextCanvas: Size,
  mode: ResizeContainerMode,
  minSize: Size
): Rect => {
  if (mode === "relative" && prevCanvas.width > 0 && prevCanvas.height > 0) {
    const relative = toRelativeRect(rect, prevCanvas);
    return clampRectToCanvas(toPixelRect(relative, nextCanvas), nextCanvas, minSize);
  }
  return clampRectToCanvas(rect, nextCanvas, minSize);
};

export type MoveOptions = {
  /** Constrain movement to the dominant axis (Shift). */
  lockAxis?: boolean;
};

/** Move the whole rect by (dx, dy) while keeping it inside the canvas. */
export const applyMove = (
  startRect: Rect,
  dx: number,
  dy: number,
  canvas: Size,
  options: MoveOptions = {}
): Rect => {
  let moveX = dx;
  let moveY = dy;
  if (options.lockAxis) {
    if (Math.abs(dx) >= Math.abs(dy)) moveY = 0;
    else moveX = 0;
  }
  return {
    ...startRect,
    x: clamp(startRect.x + moveX, 0, Math.max(0, canvas.width - startRect.width)),
    y: clamp(startRect.y + moveY, 0, Math.max(0, canvas.height - startRect.height)),
  };
};

export type ResizeOptions = {
  /** Keep the rect center fixed, mirroring the dragged edge (Alt/Option). */
  fromCenter?: boolean;
};

/**
 * Resize the rect by dragging the given edges, respecting the minimum size and
 * the canvas bounds.
 */
export const applyResize = (
  startRect: Rect,
  edges: ResizeEdges,
  dx: number,
  dy: number,
  canvas: Size,
  minSize: Size,
  options: ResizeOptions = {}
): Rect => {
  if (options.fromCenter) {
    return applyResizeFromCenter(startRect, edges, dx, dy, canvas, minSize);
  }

  let { x, y, width, height } = startRect;

  if (edges.right) {
    width = clamp(startRect.width + dx, minSize.width, canvas.width - startRect.x);
  }
  if (edges.left) {
    const clampedDx = clamp(dx, -startRect.x, startRect.width - minSize.width);
    x = startRect.x + clampedDx;
    width = startRect.width - clampedDx;
  }
  if (edges.bottom) {
    height = clamp(startRect.height + dy, minSize.height, canvas.height - startRect.y);
  }
  if (edges.top) {
    const clampedDy = clamp(dy, -startRect.y, startRect.height - minSize.height);
    y = startRect.y + clampedDy;
    height = startRect.height - clampedDy;
  }

  return { x, y, width, height };
};

/** Center the rect within the canvas, shrinking only if it does not fit. */
export const centerRect = (rect: Rect, canvas: Size): Rect => {
  const width = Math.min(rect.width, canvas.width);
  const height = Math.min(rect.height, canvas.height);
  return {
    width,
    height,
    x: (canvas.width - width) / 2,
    y: (canvas.height - height) / 2,
  };
};

/** Which center guide lines are currently active. */
export type CenterGuides = {
  /** Vertical line at the canvas center-x (content is horizontally centered). */
  vertical: boolean;
  /** Horizontal line at the canvas center-y (content is vertically centered). */
  horizontal: boolean;
};

export const NO_GUIDES: CenterGuides = { vertical: false, horizontal: false };

/**
 * Snap the rect so its center latches onto the canvas center when it gets close,
 * reporting which guide lines should be shown.
 */
export const snapRectToCenter = (
  rect: Rect,
  canvas: Size,
  threshold: number
): { rect: Rect; guides: CenterGuides } => {
  const canvasCenterX = canvas.width / 2;
  const canvasCenterY = canvas.height / 2;
  const rectCenterX = rect.x + rect.width / 2;
  const rectCenterY = rect.y + rect.height / 2;

  let { x, y } = rect;
  let vertical = false;
  let horizontal = false;

  if (Math.abs(rectCenterX - canvasCenterX) <= threshold) {
    x = canvasCenterX - rect.width / 2;
    vertical = true;
  }
  if (Math.abs(rectCenterY - canvasCenterY) <= threshold) {
    y = canvasCenterY - rect.height / 2;
    horizontal = true;
  }

  return {
    rect: { ...rect, x, y },
    guides: vertical || horizontal ? { vertical, horizontal } : NO_GUIDES,
  };
};

/** Resize symmetrically about the original center; both sides mirror the drag. */
const applyResizeFromCenter = (
  startRect: Rect,
  edges: ResizeEdges,
  dx: number,
  dy: number,
  canvas: Size,
  minSize: Size
): Rect => {
  let { x, y, width, height } = startRect;

  if (edges.left || edges.right) {
    const centerX = startRect.x + startRect.width / 2;
    const delta = edges.right ? dx : -dx;
    const maxHalf = Math.max(
      minSize.width / 2,
      Math.min(centerX, canvas.width - centerX)
    );
    const half = clamp(startRect.width / 2 + delta, minSize.width / 2, maxHalf);
    width = half * 2;
    x = centerX - half;
  }
  if (edges.top || edges.bottom) {
    const centerY = startRect.y + startRect.height / 2;
    const delta = edges.bottom ? dy : -dy;
    const maxHalf = Math.max(
      minSize.height / 2,
      Math.min(centerY, canvas.height - centerY)
    );
    const half = clamp(startRect.height / 2 + delta, minSize.height / 2, maxHalf);
    height = half * 2;
    y = centerY - half;
  }

  return { x, y, width, height };
};
