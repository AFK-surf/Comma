// The box round what a person selects on a screen's held frame: the box the browser's inspector draws round a picked
// element on a page (element-inspector.ts, `.comma-inspector-box`), on the frame's own pixels.

/** A box on a frame, in the frame's own pixels. `line`: its line there, so it is as wide on the screen at any size. */
export type ScreenMark = {
  x: number;
  y: number;
  width: number;
  height: number;
  line: number;
};

/**
 * A box's rounded outline as path data, `outset` beyond the box's own edge (inside it where negative). The box's
 * corners are twice its line, as the inspector's are, and an outline further out or in turns with them.
 */
export function markPath(
  { x, y, width, height, line }: ScreenMark,
  outset = 0
): string {
  const [left, top] = [x - outset, y - outset];
  const [w, h] = [Math.max(0, width + 2 * outset), Math.max(0, height + 2 * outset)];
  const r = Math.max(0, Math.min(line * 2 + outset, w / 2, h / 2));
  const [right, bottom] = [left + w, top + h];
  return (
    `M${left + r} ${top}H${right - r}A${r} ${r} 0 0 1 ${right} ${top + r}` +
    `V${bottom - r}A${r} ${r} 0 0 1 ${right - r} ${bottom}` +
    `H${left + r}A${r} ${r} 0 0 1 ${left} ${bottom - r}` +
    `V${top + r}A${r} ${r} 0 0 1 ${left + r} ${top}Z`
  );
}
