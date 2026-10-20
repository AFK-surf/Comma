/**
 * The flight's material: hold the source's, then cross to the bubble's
 * between `start` and `end` (offsets in 0..1).
 *
 * Offsets that coincide keep only their later keyframe, which is the value
 * the animation shows from that offset on. A zero-length segment changes
 * nothing visible, but Chromium's composited background-color animation can
 * sample one into a non-finite color; the GPU process rejects that paint op
 * and may stall for a crash dump.
 */
export function materialKeyframes(
  from: string,
  to: string,
  start: number,
  end: number
): Keyframe[] {
  const stops = [
    { offset: 0, backgroundColor: from },
    { offset: start, backgroundColor: from },
    { offset: end, backgroundColor: to },
    { offset: 1, backgroundColor: to },
  ];
  return stops.filter((stop, index) => stop.offset !== stops[index + 1]?.offset);
}
