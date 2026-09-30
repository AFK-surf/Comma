export type RecorderBounds = { x: number; y: number; width: number; height: number };
export type RecorderCenter = { x: number; y: number };

/** A recorder-sized native rectangle, never the work-area-sized click-through sheet. */
export function recorderWindowBounds(
  center: RecorderCenter,
  size: { width: number; height: number; anchorY?: number | undefined },
  area: RecorderBounds,
  clamp = true
): RecorderBounds {
  const width = Math.min(Math.ceil(size.width), 720, area.width);
  const height = Math.min(Math.ceil(size.height), 640, area.height);
  const x = Math.round(center.x - width / 2);
  const y = Math.round(center.y - (size.anchorY ?? height / 2));
  return {
    x: clamp ? Math.max(area.x, Math.min(x, area.x + area.width - width)) : x,
    y: clamp ? Math.max(area.y, Math.min(y, area.y + area.height - height)) : y,
    width,
    height,
  };
}
